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
# Immutable linux/amd64 Python 3.12.15 image; no build image is needed.
export PYTORCH_PYTHON_IMAGE=python:3.12-slim-bookworm@sha256:2ed6491b93cd49272ee6de2b5a38440c3448360322c089fc23e370722d74179d
wheels="$HOME/.pytorch-wheels"
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

echo '--- Prepare the pinned Python download environment'
timed image-preparation docker pull "$PYTORCH_PYTHON_IMAGE"
docker run --rm --network none "$PYTORCH_PYTHON_IMAGE" \
  sh -c 'python -VV && python -m pip --version' > "$results/python-version.txt"

# Hosted cache commands run on the agent host, outside the Python container.
if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Restore PyTorch wheels'
  timed wheels-cache-restore buildkite-agent cache restore \
    --registry '~' --cache-config-file .buildkite/cache.pytorch.yml \
    --cache-fail-on-error --name pytorch_wheels
fi

hit=false
if [[ -f "$wheels/.cache-benchmark-seed" && -s "$wheels/SHA256SUMS" && \
      "$(cat "$wheels/.cache-benchmark-seed")" == "$CACHE_BENCHMARK_REVISION" ]]; then
  hit=true
fi
printf 'workload=pytorch-wheels\nbackend=%s\ncommit=%s\npython_image=%s\nagent_version=%s\ntarget_cache_hit=%s\n' \
  "$backend" "$CACHE_BENCHMARK_REVISION" "$PYTORCH_PYTHON_IMAGE" \
  "$(buildkite-agent --version)" "$hit" > "$results/readiness.txt"
if [[ "${CACHE_BENCHMARK_REQUIRE_HIT:-false}" == true && "$hit" != true ]]; then
  cat "$results/readiness.txt"
  echo 'Expected populated PyTorch wheels, but this job missed.' >&2
  exit 1
fi

mkdir -p "$wheels"
du -sb "$wheels" > "$results/cache-bytes-before.txt"
container=(docker run --rm --volume "$PWD:/work" --workdir /work
  --volume "$wheels:/wheels" --env PIP_DISABLE_PIP_VERSION_CHECK=1)
pip_args=(python -m pip download --no-cache-dir --only-binary=:all:
  --dest /wheels --requirement .buildkite/requirements.pytorch.txt)

if [[ "$hit" == true ]]; then
  echo '--- Verify restored wheel checksums'
  timed wheel-hashes bash -c 'cd "$1"; sha256sum --check SHA256SUMS' _ "$wheels"
  echo '--- Resolve all dependencies offline from the restored wheels'
  timed offline-download "${container[@]}" --network none "$PYTORCH_PYTHON_IMAGE" \
    "${pip_args[@]}" --no-index --find-links /wheels
else
  echo '--- Download pinned PyTorch ROCm wheels and dependencies (no tests)'
  timed pip-download "${container[@]}" "$PYTORCH_PYTHON_IMAGE" \
    "${pip_args[@]}" --index-url https://download.pytorch.org/whl/rocm6.4
  echo '--- Record checksums of every downloaded wheel'
  timed wheel-hashes bash -c 'cd "$1"; sha256sum *.whl > SHA256SUMS' _ "$wheels"
  printf '%s\n' "$CACHE_BENCHMARK_REVISION" > "$wheels/.cache-benchmark-seed"
fi

cp "$wheels/SHA256SUMS" "$results/wheel-sha256.txt"
find "$wheels" -maxdepth 1 -name '*.whl' -printf '%f\t%s\n' | sort > "$results/wheel-files.txt"
du -sb "$wheels" > "$results/cache-bytes-after.txt"
"${container[@]}" --network none "$PYTORCH_PYTHON_IMAGE" python -c '
from email.parser import BytesParser
from pathlib import Path
from zipfile import ZipFile
packages = []
for path in sorted(Path("/wheels").glob("*.whl")):
    with ZipFile(path) as wheel:
        name = next(n for n in wheel.namelist() if n.endswith(".dist-info/METADATA"))
        metadata = BytesParser().parsebytes(wheel.read(name))
        packages.append("{}=={}".format(metadata["Name"], metadata["Version"]))
print("\n".join(sorted(packages)))
' > "$results/resolved-requirements.txt"

if [[ "$backend" == buildkite-cache ]]; then
  echo '--- Save PyTorch wheels'
  timed wheels-cache-save buildkite-agent cache save \
    --registry '~' --cache-config-file .buildkite/cache.pytorch.yml \
    --cache-fail-on-error --name pytorch_wheels
fi

cat "$results/readiness.txt" "$results/timings.csv" "$results/cache-bytes-after.txt"
buildkite-agent annotate --context cache-benchmark --style info \
  "Workload: **PyTorch wheels**. Cache backend: **$backend**. Cache hit: **$hit**. Wheel checksums, package versions, sizes, and timings are attached as build artifacts."
