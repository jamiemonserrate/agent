#!/usr/bin/env bash
set -euo pipefail

phase="${1:?Specify seed, compare, or repeat}"
case "$phase" in
  seed|compare|repeat) ;;
  *) echo "Unknown phase: $phase" >&2; exit 1 ;;
esac
if [[ "${BUILDKITE_ORGANIZATION_SLUG:-}" != jamie-test ]]; then
  echo 'This POC runs only in jamie-test.' >&2
  exit 1
fi

# Reuse cache-benchmark's real agent-build workload, paths, pinned images, and
# exhaustive inventory verifier. Only the compressed archives live on a volume.
export TARGET_GOOS=linux TARGET_GOARCH=amd64 TARGET_GOARM=none
export TARGET_BUILD_MODE=cgo-disabled TARGET_GO_VERSION=go1.26.5
CACHE_BENCHMARK_REVISION="$(git rev-parse HEAD)"
export CACHE_BENCHMARK_REVISION
export ARCHIVE_POC_KEY="$BUILDKITE_BUILD_ID"
export GOCACHE="$HOME/.gocache-target" GOMODCACHE="$HOME/.gomodcache"
export BUILDKITE_AGENT_CACHE_ARCHIVE_PATH="$HOME/.buildkite-archive-go-poc"
support="$HOME/.agent-cache-benchmark"
results="archive-cache-poc-results/go-$phase"
mkdir -p "$results" "$BUILDKITE_AGENT_CACHE_ARCHIVE_PATH"
printf 'operation,milliseconds\n' > "$results/timings.csv"
printf 'workload=go-agent\nphase=%s\nbuild=%s\njob=%s\ncommit=%s\nkey=%s\n' \
  "$phase" "$BUILDKITE_BUILD_URL" "$BUILDKITE_JOB_ID" \
  "$CACHE_BENCHMARK_REVISION" "$ARCHIVE_POC_KEY" > "$results/context.txt"
findmnt -T "$BUILDKITE_AGENT_CACHE_ARCHIVE_PATH" > "$results/mount.txt"
find -H "$BUILDKITE_AGENT_CACHE_ARCHIVE_PATH" -maxdepth 1 -type f -printf '%f %s\n' > "$results/volume-before.txt"

buildkite-agent artifact download 'archive-cache-poc-bin/buildkite-agent' . --step poc-binary
binary="$PWD/archive-cache-poc-bin/buildkite-agent"
chmod +x "$binary"
"$binary" --version > "$results/cache-agent-version.txt"

timed() {
  local label="$1" start
  shift
  start="$(date +%s%N)"
  "$@"
  printf '%s,%s\n' "$label" "$(( ($(date +%s%N) - start) / 1000000 ))" >> "$results/timings.csv"
}

cache() {
  "$binary" cache "$@" --registry '~' \
    --cache-config-file .buildkite/cache.archive-go-poc.yml --cache-fail-on-error
}

cache_log() {
  local label="$1"
  shift
  timed "$label" cache "$@" 2>&1 | tee "$results/$label.log"
}

image=agent-cache-benchmark:go1.26.5
timed image-preparation docker build --load --progress=plain \
  --tag "$image" --file .buildkite/Dockerfile-compile .buildkite
[[ "$(docker run --rm "$image" go env GOVERSION)" == "$TARGET_GO_VERSION" ]]
inventory_image=node:24-bookworm-slim@sha256:ec857ea6bb60cb3d0fa4d97495590c5fe7d51be8572c307b55957eeb06569cf7
timed inventory-image-preparation docker pull "$inventory_image"
docker run --rm --network none "$inventory_image" node --version > "$results/inventory-node-version.txt"

scan_cache() {
  local mode="$1" label="$2" name="$3" target="$4" mount
  mount="$target:/cache"
  if [[ "$mode" == verify ]]; then mount="$mount:ro"; fi
  timed "$label-$name-inventory" docker run --rm --network none \
    --volume "$PWD:/benchmark" --volume "$mount" "$inventory_image" \
    node /benchmark/.buildkite/steps/backstage-cache-inventory.mjs \
    "$mode" /cache "/benchmark/$results" \
    "Go $name; benchmark manifest and seed marker excluded"
  mv "$results/file-profile.json" "$results/$label-$name-file-profile.json"
  mv "$results/file-inventory.jsonl.gz" "$results/$label-$name-file-inventory.jsonl.gz"
}

scan_caches() {
  scan_cache "$1" "$2" target-cache "$GOCACHE"
  scan_cache "$1" "$2" module-cache "$GOMODCACHE"
  scan_cache "$1" "$2" acknowledgements-cache "$support"
}

verify_restored() {
  [[ "$(cat "$GOCACHE/.cache-benchmark-seed")" == "$CACHE_BENCHMARK_REVISION" ]]
  scan_caches verify "$1"
}

build_agent() {
  local label="$1" reuse=false
  local build_env=(--env 'GOPROXY=https://proxy.golang.org,direct')
  if [[ "$phase" == seed ]]; then
    # go-licenses needs the embed file to load the package, then replaces it
    # with real OSS attributions. Never reuse this bootstrap as the output.
    gzip -c LICENSE.txt > clicommand/ACKNOWLEDGEMENTS.md.gz
  else
    cp "$support/ACKNOWLEDGEMENTS.md.gz" clicommand/ACKNOWLEDGEMENTS.md.gz
    reuse=true
    build_env=(--network none --env GOPROXY=off --env GOSUMDB=off)
  fi
  timed "$label-build" docker run --rm \
    --volume "$PWD:/work" --workdir /work \
    --volume "$GOCACHE:/root/.gocache-target" \
    --volume "$GOMODCACHE:/root/.gomodcache" \
    --env GOCACHE=/root/.gocache-target --env GOMODCACHE=/root/.gomodcache \
    --env "ACKNOWLEDGEMENTS_REUSE_EXISTING=$reuse" \
    "${build_env[@]}" "$image" \
    bash -ec 'go mod download && bash scripts/build-binary.sh linux amd64 0'
  ./pkg/buildkite-agent-linux-amd64 --version > "$results/$label-binary-version.txt"
}

if [[ "$phase" == seed ]]; then
  cache_log registry-miss restore
  [[ ! -e "$GOCACHE/.cache-benchmark-seed" ]]
  mkdir -p "$GOCACHE" "$GOMODCACHE" "$support"
  build_agent seed
  cp clicommand/ACKNOWLEDGEMENTS.md.gz "$support/ACKNOWLEDGEMENTS.md.gz"
  scan_caches seed seed
  printf '%s\n' "$CACHE_BENCHMARK_REVISION" > "$GOCACHE/.cache-benchmark-seed"
else
  # Record actual snapshot reuse separately from the controlled warm comparison.
  cache_log first-restore restore
  verify_restored first
  hits="$(grep -c 'Archive tier: volume hit' "$results/first-restore.log" || true)"
  printf 'first_restore_volume_hits=%s\ncache_entries=3\n' "$hits" >> "$results/context.txt"

  BUILDKITE_AGENT_CACHE_ARCHIVE_PATH='' cache_log remote-restore restore
  verify_restored remote
  build_agent remote-offline

  # The first restore populated any missing archives. Reject downloads here
  # while preserving the registry and normal remote retention refreshes.
  real_nsc="$(command -v nsc)"
  guard="$PWD/$results/no-download"
  mkdir -p "$guard"
  cat > "$guard/nsc" <<'GUARD'
#!/usr/bin/env bash
set -euo pipefail
if [[ "${1:-}" == artifact && "${2:-}" == download ]]; then
  echo 'POC forbids remote artifact download for this warm restore' >&2
  exit 93
fi
exec "$ARCHIVE_POC_REAL_NSC" "$@"
GUARD
  chmod +x "$guard/nsc"
  ARCHIVE_POC_REAL_NSC="$real_nsc" PATH="$guard:$PATH" cache_log volume-restore restore
  [[ "$(grep -c 'Archive tier: volume hit' "$results/volume-restore.log")" == 3 ]]
  verify_restored volume
  build_agent volume-offline
fi

du -sb "$GOCACHE" "$GOMODCACHE" "$support" > "$results/cache-bytes-after.txt"
find -H "$BUILDKITE_AGENT_CACHE_ARCHIVE_PATH" -maxdepth 1 -type f -printf '%f %s\n' > "$results/volume-before-save.txt"
cat "$results/context.txt" "$results/timings.csv"
# Final workload operation: publish all three entries, then successful job
# completion lets hosted compute snapshot the archive volume. Warm saves skip
# existing keys, retaining cache-benchmark's original immutable seed entries.
cache_log final-save save
