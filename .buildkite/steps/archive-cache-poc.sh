#!/usr/bin/env bash
set -euo pipefail

phase="${1:?Specify build, seed, exercise, verify-skip, force, verify-force, or warm}"
if [[ "${BUILDKITE_ORGANIZATION_SLUG:-}" != jamie-test ]]; then
  echo 'This POC runs only in jamie-test.' >&2
  exit 1
fi

if [[ "$phase" == build ]]; then
  image=a2086-archive-poc-builder:go1.26.5
  docker build --load --progress=plain --tag "$image" --file .buildkite/Dockerfile-compile .buildkite
  docker run --rm --volume "$PWD:/work" --workdir /work "$image" \
    bash -ec '
      # Bootstrap go:embed so go-licenses can load the package. The normal
      # build script replaces this with full generated OSS attributions.
      gzip -c LICENSE > clicommand/ACKNOWLEDGEMENTS.md.gz
      go test ./internal/cache -run "^TestArchiveTier$" -count=1
      bash scripts/build-binary.sh linux amd64 0
    '
  mkdir -p archive-cache-poc-bin
  cp pkg/buildkite-agent-linux-amd64 archive-cache-poc-bin/buildkite-agent
  exit 0
fi

case "$phase" in
  seed|exercise|verify-skip|force|verify-force|warm) ;;
  *) echo "Unknown phase: $phase" >&2; exit 1 ;;
esac

buildkite-agent artifact download 'archive-cache-poc-bin/buildkite-agent' . --step poc-binary
binary="$PWD/archive-cache-poc-bin/buildkite-agent"
chmod +x "$binary"
export ARCHIVE_POC_KEY="${ARCHIVE_POC_KEY:-$BUILDKITE_BUILD_ID}"
export BUILDKITE_AGENT_CACHE_ARCHIVE_PATH="$HOME/.buildkite-archive-poc"
archive_path="$BUILDKITE_AGENT_CACHE_ARCHIVE_PATH"
data=archive-cache-poc-data
results="archive-cache-poc-results/$phase"
mkdir -p "$archive_path" "$results"
printf 'operation,milliseconds\n' > "$results/timings.csv"
printf 'phase=%s\nbuild=%s\njob=%s\ncommit=%s\nkey=%s\narchive_path=%s\n' \
  "$phase" "$BUILDKITE_BUILD_URL" "$BUILDKITE_JOB_ID" "$BUILDKITE_COMMIT" \
  "$ARCHIVE_POC_KEY" "$archive_path" > "$results/context.txt"
find "$archive_path" -maxdepth 1 -type f -printf '%f %s\n' > "$results/volume-before.txt"
findmnt -T "$archive_path" > "$results/mount.txt"

cache() {
  "$binary" cache "$@" --registry '~' \
    --cache-config-file .buildkite/cache.archive-poc.yml --cache-fail-on-error
}

timed_cache() {
  local label="$1" start
  shift
  start="$(date +%s%N)"
  cache "$@" 2>&1 | tee "$results/$label.log"
  printf '%s,%s\n' "$label" "$(( ($(date +%s%N) - start) / 1000000 ))" >> "$results/timings.csv"
}

manifest() {
  find "$data" -type f ! -name manifest.sha256 -print0 | sort -z | xargs -0 sha256sum > "$data/manifest.sha256"
}

verify() {
  local version="$1" label="$2"
  sha256sum --check "$data/manifest.sha256" > "$results/$label-integrity.txt"
  [[ "$(cat "$data/version.txt")" == "$version" ]]
  [[ -d "$data/empty" && -L "$data/link" && "$(readlink "$data/link")" == nested/small-0001 ]]
  [[ "$(stat -c '%a' "$data/executable")" == 755 ]]
  if [[ "$version" == forced ]]; then
    [[ -f "$data/force-only" && ! -e "$data/original-only" ]]
  else
    [[ -f "$data/original-only" && ! -e "$data/force-only" ]]
  fi
}

restore() {
  local label="$1" version="$2"
  rm -rf "$data"
  timed_cache "$label" restore
  verify "$version" "$label"
}

compare() {
  local version="$1" digest real_nsc guard
  restore first-restore "$version"
  if grep -Fq 'Archive tier: volume hit' "$results/first-restore.log"; then
    echo 'cross_job_volume_hit=true' | tee -a "$results/context.txt"
  else
    echo 'cross_job_volume_hit=false' | tee -a "$results/context.txt"
  fi

  # Compare with an ordinary remote restore of the identical entry.
  BUILDKITE_AGENT_CACHE_ARCHIVE_PATH='' restore remote-baseline "$version"

  # Prove the warm local restore cannot download remotely. Retention refreshes
  # still go to the real nsc, preserving normal exact-restore retention.
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
  ARCHIVE_POC_REAL_NSC="$real_nsc" PATH="$guard:$PATH" restore local-with-download-blocked "$version"
  grep -Fq 'Archive tier: volume hit' "$results/local-with-download-blocked.log"
  digest="$(sed -nE 's/.*digest=([0-9a-f]{64}).*/\1/p' "$results/local-with-download-blocked.log" | tail -n 1)"
  [[ ${#digest} == 64 ]]
  printf '%s\n' "$digest" > "$results/digest.txt"
}

case "$phase" in
  seed)
    rm -rf "$data"
    timed_cache registry-miss restore
    [[ ! -e "$data" ]]
    mib="${ARCHIVE_POC_MIB:-256}"
    [[ "$mib" =~ ^[0-9]+$ && "$mib" -ge 1 && "$mib" -le 1024 ]]
    mkdir -p "$data/nested" "$data/empty"
    dd if=/dev/urandom of="$data/payload.bin" bs=1M count="$mib" status=none
    for ((i=1; i<=2048; i++)); do
      printf -v file '%s/nested/small-%04d' "$data" "$i"
      printf 'cached-archive-poc-file-%04d\n' "$i" > "$file"
    done
    printf 'original\n' > "$data/version.txt"
    printf 'original only\n' > "$data/original-only"
    printf '#!/bin/sh\necho cache-poc\n' > "$data/executable"
    chmod 755 "$data/executable"
    ln -s nested/small-0001 "$data/link"
    manifest
    verify original seed
    timed_cache final-save save
    ;;
  exercise)
    compare original
    digest="$(cat "$results/digest.txt")"
    printf 'corrupt local archive\n' > "$archive_path/$digest"
    restore corrupt-volume-fallback original
    grep -Fq 'Archive tier: remote download' "$results/corrupt-volume-fallback.log"
    restore repaired-volume original
    grep -Fq 'Archive tier: volume hit' "$results/repaired-volume.log"
    rm "$archive_path/$digest"
    restore empty-volume-fallback original
    grep -Fq 'Archive tier: remote download' "$results/empty-volume-fallback.log"

    # A local blob cannot override a registry miss, and a miss preserves targets.
    printf 'untouched\n' > "$data/sentinel"
    ARCHIVE_POC_KEY="$ARCHIVE_POC_KEY-absent" timed_cache absent-key restore
    [[ "$(cat "$data/sentinel")" == untouched ]]
    ! grep -Fq 'Cache restored using' "$results/absent-key.log"
    printf 'unsaved\n' > "$data/version.txt"
    manifest
    timed_cache final-save-skipped save
    ;;
  verify-skip)
    compare original
    timed_cache final-save-skipped save
    ;;
  force)
    restore before-force original
    printf 'forced\n' > "$data/version.txt"
    rm "$data/original-only"
    printf 'forced only\n' > "$data/force-only"
    manifest
    verify forced force
    timed_cache final-save-force save --force
    ;;
  verify-force|warm)
    compare forced
    timed_cache final-save-skipped save
    ;;
esac
