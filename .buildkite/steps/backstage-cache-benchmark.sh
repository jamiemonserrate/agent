#!/usr/bin/env bash
set -euo pipefail

backend="${1:?Specify volumes or buildkite-cache}"
case "$backend" in
  volumes|buildkite-cache) ;;
  *) echo "Unknown cache backend: $backend" >&2; exit 1 ;;
esac
if [[ "${BUILDKITE_ORGANIZATION_SLUG:-}" != jamie-test ]]; then
  echo 'This benchmark runs in jamie-test.' >&2
  exit 1
fi

export CACHE_BENCHMARK_REVISION="$(git rev-parse HEAD)"
export BACKSTAGE_REVISION=50407b790c6f668e0c00e1dcec336409eb5e55a8
export BACKSTAGE_NODE_IMAGE=node:24-bookworm-slim@sha256:ec857ea6bb60cb3d0fa4d97495590c5fe7d51be8572c307b55957eeb06569cf7
modules="$HOME/.backstage-node-modules"
source_dir="$PWD/cache-benchmark-backstage-source"
results=cache-benchmark-results
mkdir -p "$results"
printf 'phase,milliseconds\n' > "$results/timings.csv"

timed() {
  local phase="$1" start
  shift
  start="$(date +%s%N)"
  "$@"
  printf '%s,%s\n' "$phase" "$(( ($(date +%s%N) - start) / 1000000 ))" >> "$results/timings.csv"
}

echo '--- Prepare the pinned Node environment'
timed image-preparation docker pull "$BACKSTAGE_NODE_IMAGE"
docker run --rm --network none "$BACKSTAGE_NODE_IMAGE" node --version > "$results/node-version.txt"

if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Restore expanded Backstage dependencies'
  timed dependencies-cache-restore buildkite-agent cache restore \
    --registry '~' --cache-config-file .buildkite/cache.backstage.yml \
    --cache-fail-on-error --name backstage_node_modules
fi

hit=false
if [[ -f "$modules/.cache-benchmark-seed" && -s "$modules/.cache-benchmark-files.jsonl.gz" && \
      "$(cat "$modules/.cache-benchmark-seed")" == "$CACHE_BENCHMARK_REVISION" ]]; then
  hit=true
fi
printf 'workload=backstage-node-modules\nbackend=%s\ncommit=%s\nbackstage_commit=%s\nnode_image=%s\nagent_version=%s\ntarget_cache_hit=%s\n' \
  "$backend" "$CACHE_BENCHMARK_REVISION" "$BACKSTAGE_REVISION" "$BACKSTAGE_NODE_IMAGE" \
  "$(buildkite-agent --version)" "$hit" > "$results/readiness.txt"
if [[ "${CACHE_BENCHMARK_REQUIRE_HIT:-false}" == true && "$hit" != true ]]; then
  cat "$results/readiness.txt"
  echo 'Expected populated Backstage dependencies, but this job missed.' >&2
  exit 1
fi

mkdir -p "$modules" "$source_dir"
du -sb "$modules" > "$results/cache-bytes-before.txt"
echo '--- Prepare the pinned Backstage source (outside the dependency cache)'
timed source-preparation bash -o pipefail -c \
  'curl --fail --silent --show-error --location --retry 2 "$1" | tar --extract --gzip --strip-components=1 --directory "$2"' \
  _ "https://codeload.github.com/backstage/backstage/tar.gz/$BACKSTAGE_REVISION" "$source_dir"
sha256sum "$source_dir/yarn.lock" > "$results/lockfile-sha256.txt"

container=(docker run --rm --volume "$PWD:/benchmark" --volume "$source_dir:/backstage"
  --volume "$modules:/backstage/node_modules" --workdir /backstage --env YARN_ENABLE_TELEMETRY=0)
yarn_file=.yarn/releases/yarn-4.18.0.cjs
"${container[@]}" --network none "$BACKSTAGE_NODE_IMAGE" node "$yarn_file" --version > "$results/yarn-version.txt"
[[ "$(cat "$results/yarn-version.txt")" == 4.18.0 ]]

if [[ "$hit" == true ]]; then
  echo '--- Verify every restored file, directory mode, and symlink'
  timed dependency-inventory "${container[@]}" --network none "$BACKSTAGE_NODE_IMAGE" \
    node /benchmark/.buildkite/steps/backstage-cache-inventory.mjs verify \
    /backstage/node_modules /benchmark/cache-benchmark-results
else
  echo '--- Install dependencies without build scripts or tests'
  timed yarn-install "${container[@]}" "$BACKSTAGE_NODE_IMAGE" \
    node "$yarn_file" install --immutable --mode=skip-build
  find "$source_dir/packages" "$source_dir/plugins" -type d -name node_modules -prune -print \
    > "$results/excluded-workspace-node-modules.txt"
  echo '--- Record the expanded root dependency tree'
  timed dependency-inventory "${container[@]}" --network none "$BACKSTAGE_NODE_IMAGE" \
    node /benchmark/.buildkite/steps/backstage-cache-inventory.mjs seed \
    /backstage/node_modules /benchmark/cache-benchmark-results
  printf '%s\n' "$CACHE_BENCHMARK_REVISION" > "$modules/.cache-benchmark-seed"
fi

echo '--- Resolve representative packages with networking disabled'
timed offline-resolution "${container[@]}" --network none "$BACKSTAGE_NODE_IMAGE" node -e \
  'for (const name of ["typescript", "yaml", "react"]) console.log(name, require.resolve(name), require(name + "/package.json").version)' \
  > "$results/offline-resolution.txt"
du -sb "$modules" > "$results/cache-bytes-after.txt"

if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Save expanded Backstage dependencies'
  timed dependencies-cache-save buildkite-agent cache save \
    --registry '~' --cache-config-file .buildkite/cache.backstage.yml \
    --cache-fail-on-error --name backstage_node_modules
fi

cat "$results/readiness.txt" "$results/timings.csv" "$results/file-profile.json"
buildkite-agent annotate --context cache-benchmark --style info \
  "Workload: **Backstage root node_modules**. Backend: **$backend**. Cache hit: **$hit**. File distribution, content hashes, symlinks, and timings are attached as artifacts. No builds or tests run."
