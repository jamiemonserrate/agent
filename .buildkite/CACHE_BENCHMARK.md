# Agent cache comparison (A-2086)

These manual pipelines run against the `jamiemonserrate/agent` fork in
`jamie-test`, on the same hosted Linux AMD64 queue (4 vCPU, 16 GB RAM):

- `agent-cache-volumes` uploads `.buildkite/pipeline.cache-volumes.yml`.
- `agent-buildkite-cache` uploads `.buildkite/pipeline.buildkite-cache.yml`.

Both build only the Linux AMD64 binary using the repository's pinned Go 1.26.5
compile image and `scripts/build-binary.sh`, with build number `0`. They do not
run tests, lint, packaging, release steps, or the default `.buildkite/pipeline.yml`.
Cache commands run on the host, with the Go cache directories mounted into the
build container. The target cache is `~/.gocache-target`; modules and generated
acknowledgements are cached separately to keep the build reproducible.

## Seed and verify

Run each pipeline once at the same commit to seed its caches. Then run it again
with `CACHE_BENCHMARK_REQUIRE_HIT=true`. Verification requires a matching seed
marker and compiled Go cache data before the build, and builds with module and
checksum network lookups disabled. A volume miss fails verification; rerun a
normal build to seed the host that received it, then verify again.

```sh
bk build create -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD
bk build create -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD

bk build create -p jamie-test/agent-cache-volumes -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
bk build create -p jamie-test/agent-buildkite-cache -b codex/cache-benchmark -c HEAD \
  -e CACHE_BENCHMARK_REQUIRE_HIT=true
```

Cache volumes and target archive keys include the commit so a changed experiment
starts with a fresh target cache. The `a2086` archive key prefixes keep entries
separate from other pipelines in the test cluster's default registry.

## Results

Each binary job uploads `cache-benchmark-results/*`, including hit/miss evidence,
logical directory sizes, image preparation time, build time, and archive
save/restore time. Volume attachment happens before the command starts: its
attachment time is not reported as a zero-second restore. Use platform startup
logs when comparing that overhead. Registry archive size and logical directory
size can differ. This pilot does not yet answer the 1 GB versus 10 GB comparison.
