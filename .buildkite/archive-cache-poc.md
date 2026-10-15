# A-2086: cached-archive tier POC

This experiment adds an optional local archive tier to the existing cache
commands. `.buildkite/cache.yml` keys, registry policies, fallback ordering,
target replacement, and save/`--force` semantics remain authoritative.

Run the manual-only [jamie-test pipeline](https://buildkite.com/jamie-test/agent-tiered-cache-poc)
on `codex/a-2086-cached-archives-poc`. Its initial step uploads
`pipeline.archive-cache-poc.yml`, builds the experimental agent, and attaches a
20 GB hosted cache volume explicitly to each workload job.

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

## Experiment

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
