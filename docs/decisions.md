---
title: "Decisions and constraints"
summary: "Why Little-CI's scripts and app do the unusual things they do: the constraints and decisions that used to live in code comments."
docType: "reference"
status: "active"
read_when:
  - "You are about to change a script or app behaviour that looks odd or overcautious."
---

# Decisions and constraints

Code comments were removed on 2026-10-31 (Parker). The constraints and decisions
they carried are kept here, grouped by script or app area. How to run each
script is in the [README](../README.md) and the [app README](../app/README.md).

## install-runners.sh

- Matching local registrations are kept, and server-side labels and organization
  runner groups are never changed implicitly.
- The runner user needs passwordless sudo on a generic host because `svc.sh`
  installs a systemd unit.
- `RUNNER_ARCH`, `SKIP_SERVICE_INSTALL`, `RUNNER_HOME` and `RUNNER_NAME_PREFIX`
  set in the environment win over `config.env`. The OrbStack wrapper depends on
  this.
- Run `provision-box.sh` first: the installer binds each generated service to
  the per-fleet scratch path that `provision-box.sh` creates.

## provision-box.sh

- Each runner gets its own scratch directory so runners do not contend on one
  shared `/tmp`.
- The `systemd-tmpfiles` reaper ages `/tmp` and fleet scratch (default 6h) so
  dead job workspaces cannot fill the disk.
- OrbStack guests use OrbStack-managed zram and swap, never swapfiles.
- Removing the numbered `/swapfileN` entries written by older releases is opt-in
  (`REMOVE_LEGACY_SWAPFILES=1`): an fstab line of the exact old shape is not
  proof that this fleet owns the file.

## provision-job-dependencies.sh

- `config.env` is sourced before anything else is defined, so it cannot replace
  the fixed package lists or the functions that install them. The script reads
  no setting from it.
- `ffmpeg` and `ripgrep` are in Ubuntu's `universe` component, so on OrbStack
  this script runs only after `provision-orbstack.sh` has enabled `universe`.
- npm falls back to node-gyp when a native module has no prebuilt binary for the
  job's exact Node ABI and architecture (better-sqlite3 12.x on Node 20 arm64,
  for one). node-gyp needs make, a C/C++ compiler and pkg-config. GitHub-hosted
  images have them; a bare Ubuntu guest does not.
- The Playwright lists are what Playwright v1.59.1 `install-deps chromium`
  installs on ubuntu24.04-x64 and ubuntu24.04-arm64 (the lists are identical):
  the `chromium` group plus the `tools` group that `install-deps` always adds.
  Refresh both together from
  [nativeDeps.ts](https://github.com/microsoft/playwright/blob/v1.59.1/packages/playwright-core/src/server/registry/nativeDeps.ts)
  when consuming projects move to a Playwright release that changes them.
- `/etc/os-release` is a shell fragment; it is sourced only in subshells.
- Package maintenance must not restart a runner mid-job. `provision-orbstack.sh`
  writes the same `needrestart` policy before its base packages; generic hosts
  get it from this script.
- Tool versions are captured into variables instead of piped to `head`, so
  `pipefail` cannot fail on SIGPIPE.

## provision-orbstack.sh

- Isolated machines have no Mac bind mount, so the guest runtime archive is
  streamed over stdin.
- Some workflows expect Ubuntu's deb822 `ubuntu.sources`, and OrbStack's image
  may still ship only the classic `/etc/apt/sources.list`. The deb822 step runs
  before any guest apt command so malformed sources stop provisioning first.
- The classic `/etc/apt/sources.list` is never removed: an existing deb822 file
  may have no active Ubuntu binary archive, and the classic list may be the
  machine's only source.
- The deb822 parser is POSIX awk because it runs before base packages are
  installed, when python3 may not exist yet.
- The parser follows apt 2.7's deb822 rules: every stanza needs a `Types` field
  limited to `deb` and `deb-src`; an empty `Types` or a false `Enabled` makes a
  stanza inert; enabled stanzas need `URIs` (each containing `:`) and `Suites`;
  exact-path suites (ending in `/`) must omit `Components`, other suites require
  it, and one stanza cannot mix the two. A repeated field replaces the earlier
  one, as in apt.
- `Enabled` follows apt's StringToBool: a false word, or a whole value that
  `strtol(..., 0)` reads as zero (octal, `0x` hex, or Ubuntu 24.04 glibc's `0b`
  binary, with an optional sign).
- `universe` is added only to stanzas whose every URI is a known Ubuntu archive;
  custom mirrors and mixed stanzas keep their components. Scheme and authority
  are normalized only for that comparison.
- Every line other than the first `Components` line stays byte-identical,
  including continuation lines and earlier copies of a repeated field.
- The temp file gets the original's mode (and owner, as root) with `cp -p`, then
  awk rewrites its contents. `cp -p` works on GNU and BSD, unlike
  `chown --reference`, so the test suite can run this on a Mac.
- `LITTLE_CI_APT_SOURCES_DIR` and `LITTLE_CI_APT_SOURCES_LIST` are test hooks
  only; `orbctl` does not forward the Mac environment into the guest.
- Docker group membership is root-equivalent, so the runner user gets Docker
  access for container jobs and loses its sudo grant.

## provision-postgres.sh

- One small native Postgres (default `shared_buffers` 128MB) is shared by all
  runners. Runs are isolated by a per-run schema
  ([ci-per-run-schema.yml](../examples/ci-per-run-schema.yml)), not by one
  server per runner or a container per job, which costs more RAM and time.
- The CI role owns the database, so a per-run `CREATE SCHEMA` needs no
  `CREATEDB`. `PG_PASSWORD` is a local-only credential.
- `shared_buffers` and `max_connections` take effect only after a restart.

## lib/github-target.sh

- A manual `RUNNER_NAME_PREFIX` is still accepted for existing installations and
  advanced operators. Otherwise the prefix is derived as
  `little-ci-<target>-<FLEET_ID>` so fleets do not collide.

## App: monitoring and assessment

- Observations older than `Assessor.staleAfter` are shown with their age, never
  read as offline or healthy.
- Some thresholds clear higher than they raise; the assessor reads the previous
  assessment's finding IDs for that. Finding IDs stay stable while a condition
  lasts, so the journal records its start and end once.
- Volumes in one APFS container (or one filesystem) report the same numbers, so
  they get one disk finding, named by the macOS Data volume or else the shortest
  mount point.
- Simulator runtimes and other read-only images are always full by design.
- Disk use is df's capacity, used / (used + available), which ignores space
  reserved for root.
- `df -k -P` filesystem names and mount points may contain spaces, so the parser
  matches from the numbers.
- An OrbStack machine is `absent` only when `orbctl info` says "machine not
  found"; any other unreadable answer fails closed.
- The VM identity in `/etc/little-ci/identity` (written by
  `lib/orbstack-machine.sh`) must match every field the inventory knows, and
  `home` must be present.
- In organization scope a runner counts as the fleet's only when it sits in the
  configured runner group; unknown membership counts as outside it.
- Service levels count only jobs on this fleet's declared runners: hosted runners
  and other fleets would skew failure shares and queue waits.
- Red-main detection reads only main runs of the check workflow that passed or
  failed: a cancelled run says nothing.
- A probe without the power log keeps the power events from the last probe that
  had one.
- The event history covers only the time the app ran; it cannot reconstruct what
  happened between observations.
- At launch, history already on disk counts as announced, so old events do not
  notify again.
- The failure signatures and the service-level targets come from the
  2026-10-20 Phase 1 measurement (`reports/phase1-measurement.md`, kept locally,
  not in git).

## App: GitHub API

- Completed runs are backfilled newest first across the reporting window, so a
  busy hour or a stopped app leaves no gap; paging stops at a page with nothing
  new, so after the first backfill a minute costs one page.
- A rerun updates its run, so a run's jobs are read again only when its update
  time changed. Skipped runs never took a runner and are not read.
- A rerun attempt copies the jobs it did not rerun, with the old start time.
  Those copies are not new work.
- Workflows are matched by ID: two workflows can share a display name.
- A fork's head repository name differs from the base repository's.
- Runs carry `pull_requests` for only some PR runs (99 of 317 on 2026-10-20), so
  the head branch is the link to a pull request.
- Some failures, such as a full disk that stops the log, appear only in the
  job's check-run annotations.
- GitHub's job log echoes each step's script (in cyan) and its header. Error
  text inside a script is not an error, so those lines are dropped before
  classifying.
- Job logs redirect to blob storage. Forwarding GitHub's token there leaks it,
  and blob storage rejects it with 401, so a redirect to another host drops the
  `Authorization` header.
- Only the URL and runner name are read from a runner's `.runner` file, never
  credentials.

## App: plans and execution

- Every inventory value that reaches a shell command is validated when the
  inventory loads, and names are quoted again in each command, so no observed
  text runs as shell code.
- An SSH destination may not start with `-`, which ssh would read as an option.
- little-ci's OrbStack wrappers run on the Mac that owns the VM, which must be
  the Mac running the app.
- Plans that start, stop or retire a launchd runner require the local `.runner`
  to name this target and this exact runner.
- GitHub's busy flag lags the moment a runner accepts a job, so a launchd stop
  checks the runner's worker process on the host last (exit 75: busy, nothing
  changed).
- Before a plan runs, the executor reads GitHub (bypassing every cache) and each
  host again and derives the plan again. A runner it cannot read counts as busy.
- Before an OrbStack or Linux-server fleet plan changes anything, a check loads
  the checkout's `config.env` the way the scripts do (`lib/github-target.sh`)
  and exits 1 when the effective scope, target, prefix, user, runner group or
  machine differs from the reviewed plan.
- No plan is offered for a VM while it fails its identity checks.
- A timed-out command gets SIGTERM, then SIGKILL after 5 s, and the runner
  returns only once the process has exited, so a retry never overlaps a step
  that is still running.
- Probe scripts print each section as a command's exit code and its output in
  base64, so arbitrary text crosses the boundary intact. Their inputs are shell
  assignments at the top of the script on stdin, never command-line arguments.

## App: interface

- The plan review's Run button has no default-button shortcut: Return must
  never run a plan, some of which cannot be undone.
- The app sets the accessory activation policy so it has no Dock icon, also when
  run outside its bundle.
- The menu bar glyph is a static symbol; nothing repaints continuously.
- The menu bar label is the one view that always renders, so it opens the
  windows that the launch flags ask for.
- Ages are written as "just now" or "3 min. ago" and stay fixed until new state
  arrives: Text's relative style re-renders every second, and the formatter
  writes zero as "in 0 sec.".
- The schema decoder overrides the `decodeIfPresent` overloads because the
  protocol's default versions call `decode`, which would mark the key required.

## Tests

- `tests/run.sh` unsets every `config.env` variable before the first test, so
  the caller's environment cannot leak in: GitHub Actions, for one, exports
  `RUNNER_ARCH=X64`.
- `expected_job_dependency_packages` is a copy of the job package list kept
  apart from `provision-job-dependencies.sh`, so a drifted list fails the
  tests. Its Playwright entries are the v1.59.1 `install-deps chromium` set for
  ubuntu24.04 (the `chromium` group plus the `tools` group it always adds);
  refresh it with the script's lists.
- `rewrite_matching_lines` edits fixtures with `awk -v` instead of `sed -i`:
  BSD `sed -i` needs a backup suffix and ignores `\n` in replacements, while
  `awk -v` expands `\n` on GNU and BSD, so fixture edits behave the same on a
  Mac and on Linux.
- The deb822 cases pin apt's StringToBool for `Enabled`:
  `disabled-numeric-zeros` covers whole values that `strtol(..., 0)` reads as
  zero, including the C23 `0b` prefix that Ubuntu 24.04 glibc accepts; the
  `enabled-token-*` cases are nonzero or partly parsed numbers, which leave the
  stanza enabled, so its missing `URIs` must still be rejected.
- `duplicate-components` and `duplicate-continued-components` pin that apt
  uses the last occurrence of a field, with its continuation lines.
- The OrbStack job dependency test checks that `provision-job-dependencies.sh`
  runs after the deb822 source step (the last stdin script) and the runtime
  copy, because `ffmpeg` and `ripgrep` need Ubuntu `universe`.
