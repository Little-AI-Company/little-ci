# Little CI menu bar app

A native macOS menu bar app that watches self-hosted GitHub Actions runners and the machines
they run on, says where CI time and failures come from, and changes things only through plans
you review.

- **Menu bar:** the glyph shows the worst current finding (a static symbol). The panel shows
  service levels, the worst findings, and a switch for each lendable host.
- **Details window:** Overview (service levels against targets, every finding with its
  evidence), Hosts, Runners, Queue (by lane: main, PRs into main, platform and parity, perf
  lanes) and Events.
- **Read-only monitoring:** GitHub every 20 s; each host every 60 s through one versioned probe
  script per host kind, run locally or over one SSH session. Nothing is installed on hosts.
- **Plans:** start, stop (idle only), retire (unregister, then remove), cancel superseded or
  closed-PR runs, delete stale registrations, start OrbStack, and bring up or tear down
  little-ci OrbStack and Linux-server fleets through little-ci's own scripts.
- **Local API:** read-only JSON on `http://127.0.0.1:47623` with an OpenAPI 3.1 contract
  generated from the same models.

## Build and run

Requires macOS 15 and Xcode 16 or newer (Swift 6).

```bash
app/scripts/build-app.sh
```

```bash
open "app/build/Little CI.app"
```

`app/scripts/build-app.sh --install` also copies it to `/Applications` (quit the app first).

## Setup

The app reads `~/Library/Application Support/LittleCI/inventory.json`. Start from the example:

```bash
mkdir -p ~/Library/Application\ Support/LittleCI
```

```bash
cp app/inventory.example.json ~/Library/Application\ Support/LittleCI/inventory.json
```

- `github`: `scope` (`repository` or `organization`), `owner`, `repository`, and `runnerGroup`
  (required for organization scope, rejected for repository scope).
- `hosts[]`: `id`, `name`, `access` (`local` or `ssh:user@host`), `lendable`, optional
  `maxConcurrentJobs`, `runners[]` with exact names and labels, and `kind`:
  - `macLaunchd`: `user`, `runnerRoot`, `serviceLabelPrefix` (launchd agents
    `<prefix><runner>`, runner folders `<runnerRoot>/<runner>` with `.env` and `.path`).
  - `orbstackVM`: `parentHost`, `machine`, `runnerUser`, `fleetPrefix`, `littleCICheckout` (a
    little-ci checkout on the parent Mac whose `config.env` describes this fleet).
  - `linuxServer`: `runnerUser`, `fleetPrefix`, `littleCICheckout` (on the server).
- `serviceLevels`: the targets; `queue`: branch prefixes for the lanes, the check workflow and
  its runner label.

GitHub access uses your `gh` login (`gh auth status`); the token is read with `gh auth token`
and kept in memory. Repository reads need Administration read; plans need Administration
write. Organization fleets need Self-hosted runners read and write.

SSH hosts must already be reachable in batch mode with trusted host keys. The app runs
OpenSSH with `BatchMode=yes`, `StrictHostKeyChecking=yes`, `ForwardAgent=no` and
`ClearAllForwardings=yes`.

## Safety

- Monitoring only reads. Every change is a plan showing its exact commands, effect and
  preconditions. Nothing runs until you press Run.
- A review expires after 15 minutes and is single use. Before running, the app reads GitHub
  and the host again, derives the plan again, and refuses if it changed.
- A runner GitHub reports busy is never stopped, retired or restarted.
- A lendable host that is not lent never gets a start plan.
- Retire unregisters on GitHub first (`config.sh remove` deletes the credentials), then removes
  the launchd agent. The runner folder and `_work` stay.
- Registration and removal tokens are fetched in memory and written to one command's stdin;
  output is scrubbed of them. They never appear in a command line, log, file or API response.
- A failed step stops the plan and shows the exact commands that did not run.
- Machine deletion is a separate plan that asks twice. little-ci's identity, isolation and busy
  checks still apply inside its scripts.

## Local API

```bash
curl -s localhost:47623/
```

```bash
curl -s localhost:47623/v1/findings
```

Routes: `/v1/summary`, `/v1/hosts`, `/v1/runners`, `/v1/queue`, `/v1/findings`, `/v1/plans`,
`/v1/events?limit=1..200`, `/v1/service-levels`, `/v1/openapi.json`. Loopback clients only;
requests with an `Origin` header or a non-loopback `Host` are rejected; only GET and HEAD are
accepted. Every response carries `apiVersion`, `source` (`live` or `demo`) and `generatedAt`.
Set `LITTLE_CI_API_PORT` to use another port.

## Data on this Mac

In `~/Library/Application Support/LittleCI/` (or `$LITTLE_CI_HOME`):

- `settings.json`: lent hosts, notification pauses, API and notification switches.
- `events.jsonl`: observed transitions, at most 30 days and 5,000 events.
- `jobs.jsonl`: finished jobs with their failure class (machine, code, unsure), the source of the
  service levels.

Demo data (toolbar, or ⇧⌘D) shows a fictional fleet through the same assessment; plans are
disabled while it is on.

## Command line

```bash
"app/build/Little CI.app/Contents/MacOS/LittleCI" probe m1
```

Prints one host's probe facts as JSON (`--raw` for the probe's own output). Use it to compare the
app's facts with `df`, `docker info` and `launchctl print` run by hand.

## Tests

```bash
swift test --package-path app
```

The tests replay the 2026-10-20 incidents from recorded output (`Tests/LittleCICoreTests/Fixtures`)
and check the plan safety rules and the API contract. They contact no host and no GitHub API.
