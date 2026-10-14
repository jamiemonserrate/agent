# Agent cache comparison (A-2086)

These manual pipelines run against the `jamiemonserrate/agent` fork in
`jamie-test`, on the same hosted Linux AMD64 queue (4 vCPU, 16 GB RAM):

- `agent-cache-volumes` uploads `.buildkite/pipeline.cache-volumes.yml`.
- `agent-buildkite-cache` uploads `.buildkite/pipeline.buildkite-cache.yml`.

The current workload installs Backstage dependencies with
`yarn install --immutable --mode=skip-build`, using Yarn 4.18.0, an immutable
Node 24 Linux AMD64 image, and Backstage commit
`50407b790c6f668e0c00e1dcec336409eb5e55a8`. Neither dependency build scripts nor
project tests run.

The cache payload is **Backstage's expanded root `node_modules` directory**,
mounted from `~/.backstage-node-modules`. Source checkout and Yarn's download ZIP
cache are outside this payload. Workspace-local `node_modules` directories are
excluded and listed in seed artifacts; restoring the root tree alone is not a
complete monorepo installation for building Backstage.

Hosted cache commands run on the host. The archive variant uses a single
`backstage_node_modules` entry. Both variants prepare the same pinned source
checkout and mount the cached dependencies at `/backstage/node_modules` so
workspace symlinks resolve in the same layout.

Earlier experiments remain reproducible using the same pipeline entry points:

- PyTorch wheels (4.79 GB): `01aff0bc4001e64ae56b2c9eee0257ffd3eb56cd`.
- Go binary build: `d46cd119a7f6eb059e7a2f7285fb28ce59c002f2`.

Their scripts and cache definitions are retained.

## Seed and verify

Run each pipeline once at the same commit to seed its caches. Then run it again
with `CACHE_BENCHMARK_REQUIRE_HIT=true`. Verification requires a matching seed
marker, checks every cached file's SHA-256 and mode, checks directory modes and
symlink targets, and resolves TypeScript, YAML, and React with the container's
network disabled. Verification does not reinstall packages. A volume miss fails
verification instead of being counted as a warm sample. Volumes are best effort;
a successful seed does not guarantee an immediate hit in a later job. Record
misses separately, and reseed or retry a verification as appropriate.

```sh
bk build create -y -i -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD
bk build create -y -i -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD

bk build create -y -i -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
bk build create -y -i -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
```

`-i` explicitly triggers a build even though automatic branch builds are disabled.

Cache volumes and target archive keys include the commit so a changed experiment
starts with a fresh target cache. The `a2086` archive key prefixes keep entries
separate from other pipelines in the test cluster's default registry.

## Results

Each workload job uploads `cache-benchmark-results/*`, including hit/miss evidence,
directory sizes, image/source preparation, install/offline resolution, inventory,
and archive save/restore timings. `file-profile.json` records regular-file bytes,
file/directory/symlink counts, median and percentile sizes, size buckets, largest
files, and the inventory SHA-256. A compressed JSONL inventory preserves every
path, hash, mode, and symlink target. Benchmark inventory/marker files are excluded
from the dependency profile but included in the cached directory size. Volume
attachment happens before the command starts: its
attachment time is not reported as a zero-second restore. Use platform startup
logs when comparing that overhead. Registry archive size and logical directory
size can differ. This pilot does not yet answer the 1 GB versus 10 GB comparison.

Check the inventory implementation locally with
`node .buildkite/steps/backstage-cache-inventory.mjs --self-check`. This check is
not part of either benchmark pipeline.
