---
title: "Push to main"
summary: "How a change lands in Little-CI: scripts/push_main.sh checks one commit (syntax, ShellCheck, tests, app tests, on the M4 when there is no Swift), writes Tested: trailers for the tree that passed, and fast-forwards main."
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
no commit status, no required check, no proof loop. Its interface (options,
`PUSH:` line, exit codes) is the same as little-logbook's and little-worker's
`scripts/push_main.sh`.

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
3. Refuses the commit with exit 5 when it raises the number of comment lines
   in code files (see [Comment ratchet](#comment-ratchet)).
4. Runs the checks on that exact commit:
   - `bash -n` and `shellcheck --severity=warning` on `./*.sh`, `lib/*.sh`,
     `tests/*.sh`, `app/scripts/*.sh` and `scripts/*.sh`;
   - `./tests/run.sh`. As root (a cloud session) it runs the suite as
     `nobody`, because several scripts refuse root by design; the checkout
     must be readable by `nobody`;
   - `swift test --package-path app` when the commit touches `app/`. On a Mac
     with Swift it runs there. Without Swift (Linux, a cloud session) it runs
     on the M4 over `ssh m4`: the commit goes up as a tarball, the job runs
     detached with `nohup` in a scratch directory, the script polls it with
     short ssh calls and removes the directory afterwards. If `ssh m4` is
     unavailable it warns and records `not-run`; it does not block the push.

   A step whose files are gone (no `tests/run.sh`, no `app/Tests`) is skipped
   with a note on standard error instead of failing.

   No check runs longer than 10 minutes (`PUSH_MAIN_CAP_SECONDS`, default
   600). On the cap it ends the check, warns, records `not-run` and pushes
   anyway. The job on the M4 has its own watchdog, which ends it a little
   after the cap if nobody collects it.
5. Writes the results as `Tested:` trailers. They change the message, not the
   tree, so the tree they name is the tree that was checked.
6. Runs `git push origin <sha>:main`. When `main` moved, it fetches, rebases,
   checks again and retries, 3 tries in all.

ShellCheck must be on `PATH`: `brew install shellcheck`, `apt install
shellcheck`, or `pip install shellcheck-py` into a virtual environment.

Options:

- `--dry-run` checks `HEAD` and pushes nothing.
- `--revert <sha>` reverts a commit on main and pushes that (see Reverting).
- `--skip-checks "<why>"` runs no check, not even the comment ratchet, and
  records `Tested: skipped: <why>`.

Any other argument, or an option without its value, prints the usage and the
exit codes and exits 1.

## Comment ratchet

Code comments are banned (Parker, 2026-10-31; AGENTS.md, Comments). Before the
checks, the script counts comment lines in the code files of `origin/main`'s
tree and of the commit's tree with the same rule. When the count rose, it
prints each new comment line as `file:line: text`, taken from the added lines
of `git diff origin/main HEAD`, and stops with
`PUSH: comments-rose <sha>` and exit 5. Remove the lines, amend, run again.

- Code files: `*.sh` and `*.swift`, outside `.agents/`, `.claude/`,
  `examples/` and `config.env.example` (user documentation that keeps its
  explanations).
- A comment line is a full line that starts, after spaces, with `#` in shell,
  or with `//`, `/*`, or `*` followed by a space, `/` or the end of the line
  in Swift. Trailing comments are not counted.
- Directives are not comments and are not counted: `#!` lines,
  `# shellcheck disable=` and `# shellcheck source=`, `// MARK:` and
  `// swift-tools-version`.
- Only a rise counts, so a commit that moves or rewords a comment, or removes
  some, passes. Lines in `tests/run.sh` heredocs that write fixture files (a
  `#` line in a deb822 fixture, say) count on both sides and never trip it.

## Trailers

```
Tested: scripts pass (syntax, shellcheck, 122 tests) tree 3f2a9c1d7e0b
Tested: app pass (swift test) tree 3f2a9c1d7e0b
Tested: app pass (swift test, m4, macOS 26.7.2, Xcode 27.1, 41s) tree 3f2a9c1d7e0b
Tested: app not-run (no swift here, ssh m4 unavailable) tree 3f2a9c1d7e0b
Tested: skipped: the change is a typo in the README
```

Only the script writes `Tested:` lines; it replaces any it finds. Result lines
match little-worker's format:
`^Tested: (\S+) (pass|fail|skipped|not-run)(?: \(([^)]*)\))? tree ([0-9a-f]{12,40})$`.
`--skip-checks "<why>"` is the exception: it skips every check and writes the
single line `Tested: skipped: <why>`, with no tree. Use it only when a check
cannot say anything about the change, and say why. This repository has no
changelog, so commits need no `Customer-note:`.

## Reverting

```bash
scripts/push_main.sh --revert <sha>
```

It reverts the commit on a detached `origin/main`, checks the revert and
pushes it. A red `main` is fixed or reverted within the hour by whoever pushed
it. Nobody waits for anyone.

## After the push

Nothing runs. This repository has no GitHub Actions workflow of its own, so
`scripts/push_main.sh` is the only check, and the `Tested:` trailers are the
record of what it ran. If a bad commit gets through anyway, the pusher fixes
or reverts it (see Reverting).

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

Progress goes to standard error. The last line on standard output is
`PUSH: <state> <sha>`, and the exit code says what to do next.

| Code | Meaning | Next |
|---|---|---|
| 0 | pushed (or checked, with `--dry-run`) | report the SHA |
| 1 | usage, a missing tool, or a git error | read the message |
| 2 | a check failed; main is unchanged | fix the cause, amend, run again |
| 3 | rebase conflict; the rebase was aborted | rebase by hand, run again |
| 4 | main moved on every try | run again |
| 5 | not pushable: dirty tree, nothing to push, several commits, or the commit adds comment lines (`comments-rose`) | fix the commit, run again |

## The main ruleset

`main` has one ruleset: no deletion, no force-push, linear history. No
required status and no pull request rule, so `git push` from the script lands.
Only Parker changes it.
