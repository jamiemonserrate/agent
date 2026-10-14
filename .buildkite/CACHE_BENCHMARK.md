# Agent cache comparison (A-2086)

These manual pipelines run against the `jamiemonserrate/agent` fork in
`jamie-test`, on the same hosted Linux AMD64 queue (4 vCPU, 16 GB RAM):

- `agent-cache-volumes` uploads `.buildkite/pipeline.cache-volumes.yml`.
- `agent-buildkite-cache` uploads `.buildkite/pipeline.buildkite-cache.yml`.

The current workload builds the Go agent binary and adds the same exhaustive
inventory verifier used in the Backstage experiment. It scans all three cached
directories: `~/.gocache-target`, `~/.gomodcache`, and
`~/.agent-cache-benchmark` (generated acknowledgements). No project tests run.

The Go image remains pinned to Go 1.26.5. Inventory scans use the same immutable
Node 24 Linux AMD64 image as Backstage. Its image preparation is timed separately
as `inventory-image-preparation`, and the three scans have separate timing phases.
Hosted archive commands run outside containers, on the agent host.

Earlier experiments remain reproducible using the same pipeline entry points:

- PyTorch wheels (4.79 GB): `01aff0bc4001e64ae56b2c9eee0257ffd3eb56cd`.
- Go binary build without exhaustive scanning: `d46cd119a7f6eb059e7a2f7285fb28ce59c002f2`.
- Backstage dependencies: `8e22612f9d8848807976258d071927c580fa01de`.

Their scripts and cache definitions are retained.

## Seed and verify

Run each pipeline once at the same commit to seed its caches. The seed builds
the binary, then records each cache directory's full inventory. Run it again
with `CACHE_BENCHMARK_REQUIRE_HIT=true` to require a matching seed marker and all
three inventory manifests. Before the warm build, the verifier reads every
regular file and compares its SHA-256, path, size and mode; it also checks
directory modes and symlink targets. Verification mounts cache directories read
only and runs without networking. A changed, missing or extra entry fails.

After integrity verification, the Go binary build runs in a container with
networking disabled, `GOPROXY=off`, and `GOSUMDB=off`. Inventory and binary build
are separate phases. Warm builds can change Go caches after verification; these
changes are not silently substituted for the original seed inventory.

Volume misses fail before scanning/building and are recorded separately. Keep
retriggering the required-hit verification until a confirmed hit; cache volumes
are best effort and a successful seed does not guarantee the next job receives it.

```sh
bk build create -y -i -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD
bk build create -y -i -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD

bk build create -y -i -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
bk build create -y -i -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
```

`-i` explicitly triggers a build even though automatic branch builds are disabled.

Cache volumes and all three archive keys include the commit so a changed experiment
starts with a fresh target cache. The `a2086` archive key prefixes keep entries
separate from other pipelines in the test cluster's default registry.

## Results

Each workload job uploads `cache-benchmark-results/*`, including readiness,
directory sizes, image preparation, scan/build and archive save/restore timings.
For each of `target-cache`, `module-cache`, and `acknowledgements-cache`, artifacts
include `<name>-file-profile.json` and `<name>-file-inventory.jsonl.gz`. Profiles
record regular-file bytes, file/directory/symlink counts, median and percentile
sizes, size buckets, largest files, and the inventory SHA-256. The compressed
JSONL inventory preserves every path, hash, mode, and symlink target.

Manifest and marker files are excluded from the scanned payload and included in
logical directory size. Volume attachment and persistence are runner managed and
not individually timed. Use the workload job's platform timeline when examining
startup. This experiment still does not isolate attachment or persistence cost.

Check the inventory implementation locally with
`node .buildkite/steps/backstage-cache-inventory.mjs --self-check`. This check is
not part of either benchmark pipeline.
