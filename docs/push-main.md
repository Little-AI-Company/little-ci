---
title: "Push to main"
summary: "How a change lands in Little-CI: scripts/push_main.sh checks one commit (syntax, ShellCheck, tests, app tests), writes Tested: trailers for the tree that passed, and fast-forwards main."
docType: "guide"
status: "active"
read_when:
  - "A change is done and you land it on main."
  - "You revert a commit on main."
  - "You land an outside contributor's pull request."
  - "push_main.sh exited with a code other than 0."
---

# Push to main

There are no branches, pull request reviews or required checks in this
repository (Parker, 2026-10-30). Maintainers and their agents commit on `main`
and land the commit with `scripts/push_main.sh`. It is the small version of
little-worker's
[Push to main](https://github.com/Little-AI-Company/little-worker/blob/main/docs/push-main.md):
no commit status, no required check, no proof loop.

## Landing a change

```bash
git pull --rebase origin main
# edit, then one commit:
git commit -m "fix(uninstall): keep the cleanup record when unregister fails"
scripts/push_main.sh
```

The script:

1. Refuses a dirty tree, fetches `origin/main`, and needs exactly one commit
   ahead of it. Squash several with `git reset --soft origin/main && git commit`.
2. Rebases that commit onto `origin/main`. A conflict aborts the rebase and
   exits 3.
3. Runs the checks on that exact commit:
   - `bash -n` and `shellcheck --severity=warning` on `./*.sh`, `lib/*.sh`,
     `tests/*.sh`, `app/scripts/*.sh` and `scripts/*.sh`;
   - `./tests/run.sh`. As root (a cloud session) it runs the suite as
     `nobody`, because several scripts refuse root by design; the checkout
     must be readable by `nobody`;
   - `swift test --package-path app` when the commit touches `app/` and Swift
     is installed. Without Swift (Linux, cloud) it records `not-run`, and the
     macOS job in `ci.yml` runs the app tests after the push.
4. Writes the results as `Tested:` trailers. They change the message, not the
   tree, so the tree they name is the tree that was checked.
5. Runs `git push origin <sha>:main`. When `main` moved, it fetches, rebases,
   checks again and retries, 3 tries in all.

ShellCheck must be on `PATH`: `brew install shellcheck`, `apt install
shellcheck`, or `pip install shellcheck-py` into a virtual environment.

## Trailers

```
Tested: scripts pass (syntax, shellcheck, 127 tests) tree 3f2a9c1d7e0b
Tested: app pass (swift test) tree 3f2a9c1d7e0b
Tested: app not-run (no swift; ci.yml runs it on main) tree 3f2a9c1d7e0b
```

Only the script writes `Tested:` lines; it replaces any it finds. The format
matches little-worker's:
`^Tested: (\S+) (pass|fail|skipped|not-run)(?: \(([^)]*)\))? tree ([0-9a-f]{12,40})$`.
This repository has no changelog, so commits need no `Customer-note:`.

## Reverting

```bash
scripts/push_main.sh --revert <sha>
```

It reverts the commit on a detached `origin/main`, checks the revert and
pushes it. A red `main` is fixed or reverted within the hour by whoever pushed
it. Nobody waits for anyone.

## After the push

`.github/workflows/ci.yml` runs the same checks on GitHub-hosted runners for
every push to `main`, including the app tests on macOS 15. Nothing waits for
it, and no rule requires it. A red run means the pusher fixes or reverts.

## Outside contributors

This repository is public. Someone without push access can still open a pull
request from a fork. A maintainer reads every line, then lands it as one
commit:

```bash
git fetch origin pull/<n>/head
git switch --detach origin/main
git cherry-pick FETCH_HEAD      # or: git merge --squash FETCH_HEAD && git commit
scripts/push_main.sh
```

Keep the contributor as the commit author (cherry-pick does), then close the
pull request with a link to the commit on `main`.

## Exit codes

The last line on standard output is `PUSH: <state> <sha>`.

| Code | Meaning | Next |
|---|---|---|
| 0 | pushed (or checked, with `--dry-run`) | report the SHA |
| 1 | usage, a missing tool, or a git error | read the message |
| 2 | a check failed; main is unchanged | fix the cause, amend, run again |
| 3 | rebase conflict; the rebase was aborted | rebase by hand, run again |
| 4 | main moved on every try | run again |
| 5 | not pushable: dirty tree, nothing to push, several commits | fix the commit, run again |

## The main ruleset

`main` has one ruleset: no deletion, no force-push, linear history. No
required status and no pull request rule, so `git push` from the script lands.
Only Parker changes it.
