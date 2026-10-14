# Agent cache comparison (A-2086)

These manual pipelines run against the `jamiemonserrate/agent` fork in
`jamie-test`, on the same hosted Linux AMD64 queue (4 vCPU, 16 GB RAM):

- `agent-cache-volumes` uploads `.buildkite/pipeline.cache-volumes.yml`.
- `agent-buildkite-cache` uploads `.buildkite/pipeline.buildkite-cache.yml`.

The current workload downloads PyTorch ROCm wheels into `~/.pytorch-wheels`,
using an immutable Python 3.12.15 Linux AMD64 image. Top-level packages are pinned
to Torch 2.9.1, torchvision 0.24.1, and torchaudio 2.9.1; downloaded transitive
versions and every wheel's SHA-256 are recorded as artifacts. Pip's HTTP cache
is disabled so the payload contains one copy of the wheels.

These jobs run no tests or GPU workloads. Hosted cache commands run on the host,
with the wheel directory mounted into the Python container. The archive variant
uses a single `pytorch_wheels` cache, making its restore/save timings independent
of the Go experiment's supporting caches.

The earlier Go binary-build experiment remains reproducible at commit
`d46cd119a7f6eb059e7a2f7285fb28ce59c002f2`, using these same pipeline entry points.
Its scripts and cache definitions are retained.

## Seed and verify

Run each pipeline once at the same commit to seed its caches. Then run it again
with `CACHE_BENCHMARK_REQUIRE_HIT=true`. Verification requires a matching seed
marker, validates every downloaded wheel against its saved SHA-256, and runs
`pip download --no-index --find-links /wheels` with the container's network
disabled. This checks that all dependencies are present without installing or
copying the large wheels to another directory. A volume miss fails verification;
rerun a normal build to seed the host that received it, then verify again.

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
directory sizes, image preparation, download/offline resolution, checksum, and
archive save/restore timings. Wheel filenames, byte sizes, checksums, resolved
package versions, and the Python/pip versions are also preserved. Volume
attachment happens before the command starts: its
attachment time is not reported as a zero-second restore. Use platform startup
logs when comparing that overhead. Registry archive size and logical directory
size can differ. This pilot does not yet answer the 1 GB versus 10 GB comparison.
