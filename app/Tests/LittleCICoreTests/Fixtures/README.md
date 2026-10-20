# Fixtures

Recorded on 2026-10-20 from real output. little-ci is public and the CI it watched is
private, so every fixture went through one replacement pass:

- user names: `builder1`, `builder2`, `builder3`
- host names: `studio-m1`, `studio-m4`; private addresses: `192.0.2.x`
- repository: `example-owner/example-repo`; its labels: `example-repo-*`; launchd prefix `com.example.ci-runner.`
- package names: `@app/package`; package paths: `packages/example/...`; product words in test output: `app`
- runner names: `ci-m1-*`, `ci-m4-*`; database job names: `Database suite N`; failing test names: `test N`
- branch names: `feature/branch-N`, keeping the `platform`, `parity` and perf prefixes

Nothing else was edited. Logs are cut to the lines a test needs.

| File | Source |
| --- | --- |
| `probes/m1-macos.json`, `probes/m4-macos.json` | `LittleCI probe m1 --raw` and `probe m4 --raw` on the two Macs |
| `sections/orbstack-vmgr-mount-failure.txt` | the probe's `grep` over the M1's `~/.orbstack/log/vmgr.2.log` (15:02 UTC start that failed) |
| `sections/docker-socket-missing.txt` | `ls -lL` of a socket path that does not exist |
| `sections/docker-info-socket-missing.txt` | the Docker error line from a failed database-suite job on the M1 |
| `sections/node-v22.txt` | `node --version` of the M1's installed Node 22 |
| `logs/*.log`, `logs/*.job.json` | failed job logs and job records from GitHub's API |
| `logs/disk-full.annotations.json` | the check-run annotations of the M4 job that hit `No space left on device` |
| `github/runners-2026-10-20.json` | `GET repos/.../actions/runners` |
| `github/queue-2026-10-20T0100Z.json`, `…T0930Z.json` | CI runs rebuilt at that moment from the backfill (see each file's `note`) |

Two incidents had no recorded output in the incident state, so the test sets the values on real
output and says so in the test:

- **Boot disk at 98%:** the real `df` line for `/System/Volumes/Data` with its available space
  set to 2% of its size.
- **Offline and busy while unloaded:** the M4's real `launchctl print` output for its unloaded
  runner, applied to `ci-m4-check-2`; GitHub's real runner list with that runner set offline
  and busy.
