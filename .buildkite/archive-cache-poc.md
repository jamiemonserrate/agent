# A-2086: cached-archive tier POC

This experiment adds an optional local archive tier to the existing cache
commands. `.buildkite/cache.yml` keys, registry policies, fallback ordering,
target replacement, and save/`--force` semantics remain authoritative.

Run the manual-only [jamie-test pipeline](https://buildkite.com/jamie-test/agent-tiered-cache-poc)
on `codex/a-2086-cached-archives-poc`. Its default workload is the real Go agent
build from `cache-benchmark`, using `pipeline.archive-cache-go-poc.yml`.
It builds the experimental agent and attaches a 20 GB hosted cache volume
explicitly to each workload job. Set `ARCHIVE_POC_WORKLOAD=synthetic` to run the
earlier correctness experiment in `pipeline.archive-cache-poc.yml` instead.

## Behaviour

Set `BUILDKITE_AGENT_CACHE_ARCHIVE_PATH` (or `--cache-archive-path`) to a directory
on the manually attached volume. With neither set, behaviour is unchanged.

1. Restore resolves and authorizes the entry through the registry.
2. It tries that entry's archive digest locally, verifying SHA-256 before use.
3. A missing, unreadable, or corrupt local archive falls back to the remote
   store. A verified download is copied into the local tier for future use.
4. Extraction and target cleanup use the existing restore implementation.
5. Save retains the generated archive locally only after the remote upload and
   registry commit succeed. An existing-key save skips both tiers; `--force`
   publishes the replacement digest. Save is the final workload operation.
6. Successful job completion snapshots the volume using the existing hosted
   lifecycle. If a job fails after an archive commit, the remote archive remains
   available but that job's volume changes are discarded.

Exact restores retain the existing registry confirmation and remote-object
retention refresh; fallback matches retain their existing no-refresh behaviour.

## Real Go cache workload

The default pipeline uses the same workload, target paths, Go 1.26.5 image,
Node inventory image, and unchanged exhaustive inventory verifier as
`codex/cache-benchmark` at `101cf7afc34605fd98b7b56988e7fad92f34719d`.
There is no generated random payload in this workload.

| Entry | Target | Contents |
| --- | --- | --- |
| `target_gocache` | `~/.gocache-target` | Actual Go compilation cache from building this agent |
| `gomodcache` | `~/.gomodcache` | Downloaded Go modules and their sources |
| `acknowledgements` | `~/.agent-cache-benchmark` | Generated OSS acknowledgements reused by offline builds |

These use the existing Buildkite Cache format and registry/store. New key
prefixes and the experiment build UUID isolate the run from previous benchmark
entries. They rebuild the same kinds of cache, rather than reusing archives
compiled from the old benchmark source revision.

Only `~/.buildkite-archive-go-poc` is mounted on the volume. It holds one
digest-addressed compressed archive per entry, including every target in that
entry. Expanded Go caches are ordinary directories in each job. Restore cleans
and replaces targets as usual. Repeated saves of an existing key skip; `--force`
would publish a replacement digest. There is no local archive eviction, so old
digests can accumulate across new keys and forced replacements.

The seed job builds the Linux AMD64 agent and records every cache file's hash,
directory mode, and symlink target before saving all three entries as its last
workload operation. Two later jobs each:

1. Restore with tiering enabled and record how many of the three entries came
   from an existing volume snapshot. Missing archives fall back to Buildkite Cache.
2. Restore the same entries with the volume tier disabled, verify their complete
   inventories, and compile the agent with Docker networking disabled.
3. Restore again from the now-populated archive tier, with remote archive
   downloads blocked. Verify the complete inventories and compile offline again.
4. Finish with ordinary cache save, which preserves the original seed entries.

Restore, full inventory verification, image preparation, and compilation are
timed separately. This is an ordered paired comparison: remote runs before
local. Controlled warm restores do not imply that every newly attached volume
was already populated. The first-restore logs report actual cross-job reuse.
Results are under `archive-cache-poc-results/go-*`; sizes are measured from the
real caches rather than selected in advance.

## Real Go results: 15 October 2026

[Build #6](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/6)
passed at `b227b6e070df222ba04ed128f1d660af94bb3d47` using the real workload.
The seed produced these payloads; file counts and bytes exclude the verifier's
manifest and seed marker, while the archives include them.

| Entry | Regular files | Regular-file bytes | Archive bytes |
| --- | ---: | ---: | ---: |
| Go build cache | 5,599 | 846,984,453 | 168,365,152 |
| Go module cache | 27,284 | 985,819,902 | 364,634,409 |
| Acknowledgements | 1 | 26,055 | 22,263 |
| **Total** | **32,884** | **1,832,830,410** | **533,021,824** |

The seed build took 57.736 s; saving all three entries took 5.105 s. All four
offline verification builds succeeded with networking disabled and the output
executable removed before each invocation. All 18 restored inventories matched
the seed, including every regular file's content, directory modes, and symlinks.
Both final ordinary saves skipped all three existing entries, as intended.

| Job | First restore: volume hits / entries | First restore (s) | Remote baseline (s) | Controlled warm volume (s) | Offline build after remote / volume (s) |
| --- | ---: | ---: | ---: | ---: | ---: |
| [Compare](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/6#01a13e18-7999-408e-b4fb-b1232c3861cb) | 0 / 3 | 3.673 | 3.578 | 2.178 | 1.880 / 1.697 |
| [Repeat](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/6#01a13e18-799d-411b-a408-e7d1c51774ba) | 3 / 3 | 2.082 | 3.836 | 3.087 | 2.546 / 2.130 |

The compare job received an older snapshot containing build #5's archives;
it downloaded the current digests and retained them locally. The repeat job
then found all three current archives in its attached snapshot, proving
cross-job reuse after successful completion. Controlled warm restores blocked
remote archive downloads explicitly. These whole restore-command timings include
registry work, local copy or remote download, digest verification, cleanup,
extraction, and retention refresh; full-file inventory scans are separate.

Remote runs precede local runs within each job, so filesystem and Docker state
are warmer for the second build. This small sample demonstrates the paths and
records timings; it does not establish a general performance improvement.

[Build #5](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/5)
also passed the real-cache integrity and offline checks. Its second build could
reuse the first executable, so build #6 corrected the output state before each
build. The results above use only that corrected run. The build #6 seed and
compare inventories also show the older build #5 digests remaining on the volume:
the POC deliberately has no archive eviction.

## Synthetic correctness experiment

Each build uses its build UUID in the cache key to avoid older experiment entries.
The seed contains 256 MiB of random data, 2,048 small files, an executable, an
empty directory, and a symlink. `ARCHIVE_POC_MIB` can select 1–1,024 MiB.

To repeat warm measurements without reseeding, set `ARCHIVE_POC_REUSE_KEY` to
the cache key from a completed run's `context.txt`. This skips seeding and
mutation scenarios and runs only the binary build and final two comparisons.
Use a completed run that reached the forced version; ordinary runs still use
fresh keys. Reuse runs provide additional opportunities to observe a volume
snapshot being reused across jobs and builds, without assuming an attachment
or replication-time guarantee.

The jobs verify:

- Remote seeding plus local retention, followed by volume snapshots on success.
- Cross-job volume hits, recorded separately from best-effort volume misses.
- Remote and warm-local restore timings for the same entry and full file hashes.
- A warm local restore with `nsc artifact download` explicitly blocked.
- Remote fallback and repair after local corruption or archive eviction.
- Registry misses preserving targets despite the local archive being present.
- A mutated working tree plus ordinary save preserving the original entry.
- `--force` replacing the entry, including removing a file, across later jobs.

Logs, timings, mount details, SHA-256 verification output, and volume inventories
are uploaded under `archive-cache-poc-results/`. A successful first restore is
not proof of a cross-job volume hit; read `cross_job_volume_hit` in `context.txt`.

For example, run the full experiment, then reuse its key:

```bash
BUILDKITE_ORGANIZATION_SLUG=jamie-test bk build create \
  -p agent-tiered-cache-poc -b codex/a-2086-cached-archives-poc \
  -e ARCHIVE_POC_WORKLOAD=synthetic -y

BUILDKITE_ORGANIZATION_SLUG=jamie-test bk build create \
  -p agent-tiered-cache-poc -b codex/a-2086-cached-archives-poc \
  -e ARCHIVE_POC_WORKLOAD=synthetic \
  -e ARCHIVE_POC_REUSE_KEY=01a13d30-0c57-4a68-bf13-d13b1aa2af21 -y
```

The example reuse key is from the runs below and will expire under the normal
registry lifecycle. Use a fresh completed run's key for later experiments.

## Synthetic results: 15 October 2026

[Build #2](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/2)
passed the complete experiment at `a83e059e82171e0feaea5a8e4693ba2047bd74bb`.
Remote seeding, empty-volume fallback, corrupted-local-archive repair, registry
misses, blocked remote downloads, skipped saves, and forced replacement all
passed. The original archive was 268,999,555 bytes; the forced replacement was
268,999,545 bytes. Initial save took 3.054 s; forced replacement took 2.299 s.

[Build #4](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/4)
passed the warm-only pipeline at `3775aa8a4a274fb8db0033ee4f2c821546e4c763`.
[Build #3](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/3)
also passed after retrying its verification job once its binary was available.
Both of its comparison jobs received an already-populated volume on their first
restore, confirming that successful earlier jobs had persisted reusable archives.
These first volume restores took 2.307 s and 1.480 s and selected the forced
digest `a770f3c3110eb4804df7f0aab0328f57e405544b3618e621638fb88dcc2e2cf9`.

Each of the eight comparisons restored its selected approximately 269 MB archive
through both paths. The local measurement explicitly blocked remote archive
downloads; registry requests and retention refreshes remained enabled.

| Build / comparison | First restore used existing volume | Remote baseline (s) | Warm local archive (s) |
| --- | --- | ---: | ---: |
| [#2 exercise](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/2#01a13d30-30a9-49ed-8e65-9d5cecf5aabf) | No | 2.202 | 1.182 |
| [#2 verify skipped save](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/2#01a13d30-30af-4b2a-b4a9-80dee631f059) | No | 2.258 | 1.356 |
| [#2 verify force](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/2#01a13d30-30b7-4893-aa03-d378263e1239) | No | 2.743 | 1.290 |
| [#2 repeat](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/2#01a13d30-30bb-4661-ab3f-713485532fdc) | No | 2.519 | 1.092 |
| [#4 verify force](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/4#01a13d37-107a-40fb-9b4e-8749ab490ee2) | No | 2.364 | 1.045 |
| [#4 repeat](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/4#01a13d37-107c-401e-b367-e89dc6fb85b8) | No | 2.349 | 1.049 |
| [#3 retried verification](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/3#01a13d39-9f21-44b9-8e31-7cd2ef204e8b) | Yes | 4.089 | 0.895 |
| [#3 repeat](https://buildkite.com/jamie-test/agent-tiered-cache-poc/builds/3#01a13d34-8b60-4a14-a142-4a10ee977dfd) | Yes | 2.440 | 1.057 |
| **Median** | | **2.402** | **1.075** |

These are whole cache-restore command timings, including registry resolution,
transfer or local copy, digest verification, cleanup, extraction, and retention
work. The separate full-file integrity checks are outside the timed commands.
Each job ran its remote baseline before its warm local measurement. The two
first restores from existing volume snapshots are distinct from those later
warm measurements. The six cold first restores, which also populated the volume,
had a median of 2.979 s. This small, ordered, retry-inclusive sample is not a
general speedup or volume-availability estimate.

Setup failures are retained in Buildkite: build #1 referenced `LICENSE` instead
of `LICENSE.txt`; build #3 initially let verification start before compilation
because its mutation dependencies were skipped. The filename and direct binary
dependency are fixed in the branch, and the corrected warm pipeline passed in
build #4. No cache scenario failed in the complete build #2 run.

## Scope

This is for trusted test jobs only. The mounted directory is directly readable
by a job; registry lookup does not provide filesystem isolation between jobs
sharing that volume. There is no local eviction or capacity manager. The POC
uses the existing local blob store's copy-and-verify path, so local restore still
copies an archive to a temporary file and pays decompression/extraction costs.
These controlled timings are not production workload speedup claims.

Checks: `go test ./internal/cache ./internal/cache/store`,
`go test ./clicommand -run '^TestCache'`, shellcheck, and
`bk pipeline validate --file .buildkite/pipeline.archive-cache-poc.yml`.
