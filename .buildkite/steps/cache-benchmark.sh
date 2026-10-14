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

export TARGET_GOOS=linux TARGET_GOARCH=amd64 TARGET_GOARM=none
export TARGET_BUILD_MODE=cgo-disabled TARGET_GO_VERSION=go1.26.5
export CACHE_BENCHMARK_REVISION="$(git rev-parse HEAD)"
export GOCACHE="$HOME/.gocache-target" GOMODCACHE="$HOME/.gomodcache"
support="$HOME/.agent-cache-benchmark"
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

# Cache commands run on the host: the hosted cache store is not reachable
# from the build container. Image preparation is outside the cache timings.
image=agent-cache-benchmark:go1.26.5
echo '--- Prepare the pinned Go build image'
timed image-preparation docker build --load --progress=plain \
  --tag "$image" --file .buildkite/Dockerfile-compile .buildkite
actual_go_version="$(docker run --rm "$image" go env GOVERSION)"
[[ "$actual_go_version" == "$TARGET_GO_VERSION" ]]

# Reuse the Backstage verifier in the same immutable Node environment.
inventory_image=node:24-bookworm-slim@sha256:ec857ea6bb60cb3d0fa4d97495590c5fe7d51be8572c307b55957eeb06569cf7
timed inventory-image-preparation docker pull "$inventory_image"
docker run --rm --network none "$inventory_image" node --version > "$results/inventory-node-version.txt"

scan_cache() {
  local mode="$1" name="$2" mount="$3:/cache"
  if [[ "$mode" == verify ]]; then mount="$mount:ro"; fi
  timed "$name-inventory" docker run --rm --network none \
    --volume "$PWD:/benchmark" --volume "$mount" "$inventory_image" \
    node /benchmark/.buildkite/steps/backstage-cache-inventory.mjs \
    "$mode" /cache /benchmark/cache-benchmark-results \
    "Go $name; benchmark manifest and seed marker excluded"
  mv "$results/file-profile.json" "$results/$name-file-profile.json"
  mv "$results/file-inventory.jsonl.gz" "$results/$name-file-inventory.jsonl.gz"
}

scan_caches() {
  scan_cache "$1" target-cache "$GOCACHE"
  scan_cache "$1" module-cache "$GOMODCACHE"
  scan_cache "$1" acknowledgements-cache "$support"
}

if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Restore the target Go build cache'
  timed target-cache-restore buildkite-agent cache restore \
    --registry '~' --cache-config-file .buildkite/cache.benchmark.yml \
    --cache-fail-on-error --name target_gocache
  echo '--- Restore supporting caches'
  timed supporting-cache-restore buildkite-agent cache restore \
    --registry '~' --cache-config-file .buildkite/cache.benchmark.yml \
    --cache-fail-on-error --name gomodcache --name acknowledgements
fi

marker="$GOCACHE/.cache-benchmark-seed"
hit=false
if [[ -f "$marker" && "$(cat "$marker")" == "$CACHE_BENCHMARK_REVISION" ]] &&
   [[ -n "$(find "$GOCACHE" -type f -name '*-d' -print -quit)" ]] &&
   [[ -s "$GOCACHE/.cache-benchmark-files.jsonl.gz" && \
      -s "$GOMODCACHE/.cache-benchmark-files.jsonl.gz" && \
      -s "$support/.cache-benchmark-files.jsonl.gz" ]]; then
  hit=true
fi
printf 'workload=go-exhaustive-integrity\nbackend=%s\ncommit=%s\ngo_version=%s\nagent_version=%s\ntarget_cache_hit=%s\n' \
  "$backend" "$CACHE_BENCHMARK_REVISION" "$actual_go_version" \
  "$(buildkite-agent --version)" "$hit" > "$results/readiness.txt"
if [[ "${CACHE_BENCHMARK_REQUIRE_HIT:-false}" == true && "$hit" != true ]]; then
  cat "$results/readiness.txt"
  echo 'Expected a populated target Go cache, but this job missed.' >&2
  exit 1
fi

mkdir -p "$GOCACHE" "$GOMODCACHE" "$support"
du -sb "$GOCACHE" "$GOMODCACHE" > "$results/cache-bytes-before.txt"
if [[ "$hit" == true ]]; then
  echo '--- Verify every restored Go cache file, directory mode, and symlink before building'
  scan_caches verify
fi
if [[ -s "$support/ACKNOWLEDGEMENTS.md.gz" ]]; then
  cp "$support/ACKNOWLEDGEMENTS.md.gz" clicommand/ACKNOWLEDGEMENTS.md.gz
fi

build_env=(--env GOPROXY=https://proxy.golang.org,direct)
if [[ "$hit" == true ]]; then
  # A verification run must have everything needed to build without downloads.
  build_env=(--network none --env GOPROXY=off --env GOSUMDB=off)
fi
echo '--- Build the Linux AMD64 agent binary (no tests)'
timed binary-build docker run --rm \
  --volume "$PWD:/work" --workdir /work \
  --volume "$GOCACHE:/root/.gocache-target" \
  --volume "$GOMODCACHE:/root/.gomodcache" \
  --env GOCACHE=/root/.gocache-target --env GOMODCACHE=/root/.gomodcache \
  --env ACKNOWLEDGEMENTS_REUSE_EXISTING=true \
  "${build_env[@]}" "$image" \
  bash -c 'go mod download && bash scripts/build-binary.sh linux amd64 0'

./pkg/buildkite-agent-linux-amd64 --version | tee "$results/binary-version.txt"
cp clicommand/ACKNOWLEDGEMENTS.md.gz "$support/ACKNOWLEDGEMENTS.md.gz"
if [[ "$hit" != true ]]; then
  echo '--- Record full Go cache inventories after the seed build'
  scan_caches seed
  printf '%s\n' "$CACHE_BENCHMARK_REVISION" > "$marker"
fi
du -sb "$GOCACHE" "$GOMODCACHE" > "$results/cache-bytes-after.txt"

if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Save the target Go build cache'
  timed target-cache-save buildkite-agent cache save \
    --registry '~' --cache-config-file .buildkite/cache.benchmark.yml \
    --cache-fail-on-error --name target_gocache
  echo '--- Save supporting caches'
  timed supporting-cache-save buildkite-agent cache save \
    --registry '~' --cache-config-file .buildkite/cache.benchmark.yml \
    --cache-fail-on-error --name gomodcache --name acknowledgements
fi

cat "$results/readiness.txt" "$results/timings.csv"
buildkite-agent annotate --context cache-benchmark --style info \
  "Workload: **Go agent with exhaustive integrity verification**. Backend: **$backend**. Cache hit: **$hit**. Full target, module, and acknowledgements inventories are attached, with separate scan/build timings. No project tests run."
