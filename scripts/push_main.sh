#!/usr/bin/env bash
# Check one commit and fast-forward main with it (docs/push-main.md). There
# are no pull requests or branches here (Parker, 2026-10-30); this is how a
# maintainer's or agent's commit reaches main. Same interface as
# little-logbook's and little-worker's scripts/push_main.sh.
#
#   scripts/push_main.sh                  # push the one commit ahead of origin/main
#   scripts/push_main.sh --revert <sha>   # revert a commit on main and push that
#   scripts/push_main.sh --dry-run        # check HEAD, change and push nothing
#
# It refuses a dirty tree, fetches origin/main, rebases the commit onto it,
# and runs this repository's checks on that exact commit: bash -n and
# ShellCheck (warning severity) on every script, tests/run.sh (as nobody
# when run as root, because several scripts refuse root), and
# `swift test --package-path app` when app/ changed and Swift is installed.
# It writes the results as Tested: trailers, which change the message but
# not the tree they name:
#
#   Tested: scripts pass (syntax, shellcheck, 127 tests) tree 3f2a9c1d7e0b
#   Tested: app not-run (no swift; ci.yml runs it on main) tree 3f2a9c1d7e0b
#
# Then it runs `git push origin <sha>:main`. When main moved meanwhile it
# fetches, rebases, checks again and retries (3 tries).
#
# Progress goes to standard error. The last line on standard output is
# "PUSH: <state> <sha>", and the exit code says what to do next:
#   0  pushed (or checked, with --dry-run)
#   1  usage, a missing tool, or a git error
#   2  a check failed (main is unchanged)
#   3  the rebase conflicts (it is aborted and the commit left as it was)
#   4  main kept moving for 3 tries
#   5  not pushable: dirty tree, nothing to push, or more than one commit
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

say() { echo "push-main: $*" >&2; }
finish() {
  local code="$1"
  shift
  echo "PUSH: $*"
  exit "$code"
}

usage() {
  sed -n '7,9p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

revert=""
dry_run=0
while [ $# -gt 0 ]; do
  case "$1" in
    --revert)
      [ $# -ge 2 ] || usage
      revert="$2"
      shift
      ;;
    --dry-run) dry_run=1 ;;
    *) usage ;;
  esac
  shift
done
[ -z "$revert" ] || [ "$dry_run" -eq 0 ] || usage

command -v shellcheck >/dev/null 2>&1 ||
  finish 1 "no-shellcheck - : install it (brew install shellcheck, apt install shellcheck, or pip install shellcheck-py)"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/push-main.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

[ -z "$(git status --porcelain)" ] || finish 5 "dirty - : commit or stash first"
git fetch --quiet origin main || finish 1 "fetch-failed - : git fetch origin main"

if [ -n "$revert" ]; then
  target="$(git rev-parse --verify --quiet "$revert^{commit}")" || finish 1 "usage - : $revert is not a commit"
  git merge-base --is-ancestor "$target" origin/main || finish 5 "not-on-main $target - : only a commit on main can be reverted"
  git switch --quiet --detach origin/main
  git revert --no-edit "$target" >/dev/null || {
    git revert --abort >/dev/null 2>&1 || true
    finish 3 "conflict $target - : the revert does not apply on origin/main"
  }
  say "reverted ${target:0:12} as $(git rev-parse --short=12 HEAD)"
fi

ahead="$(git rev-list --count origin/main..HEAD)"
[ "$ahead" -ge 1 ] || finish 5 "nothing - : HEAD has no commit that origin/main lacks"
[ "$ahead" -eq 1 ] ||
  finish 5 "commits=$ahead - : one commit per push; squash them first (git reset --soft origin/main && git commit)"

rebase_onto_main() {
  [ "$(git merge-base HEAD origin/main)" != "$(git rev-parse origin/main)" ] || return 0
  if ! git rebase --quiet origin/main >/dev/null 2>&1; then
    git rebase --abort >/dev/null 2>&1 || true
    finish 3 "conflict $(git rev-parse HEAD) - : rebase onto origin/main by hand, then run this again"
  fi
}

shell_files() {
  local pattern
  for pattern in ./*.sh lib/*.sh tests/*.sh app/scripts/*.sh scripts/*.sh; do
    [ -e "$pattern" ] && printf '%s\n' "$pattern"
  done
}

run_tests() {
  if [ "$(id -u)" -ne 0 ]; then
    ./tests/run.sh
  elif command -v runuser >/dev/null 2>&1; then
    # A cloud session runs as root. The checkout must be readable by nobody;
    # the tests write only to their own sandbox under /tmp.
    runuser -u nobody -- env HOME=/tmp TMPDIR=/tmp ./tests/run.sh
  else
    echo "tests/run.sh must not run as root, and runuser is missing" >&2
    return 1
  fi
}

# Sets TESTED (trailer lines) and STATE for HEAD.
run_checks() {
  local tree files result detail count
  tree="$(git rev-parse --short=12 'HEAD^{tree}')"
  TESTED=()
  STATE=success
  mapfile -t files < <(shell_files)

  result=pass
  say "bash -n and shellcheck on ${#files[@]} scripts"
  bash -n "${files[@]}" >"$work_dir/syntax.log" 2>&1 || result=fail
  shellcheck --severity=warning "${files[@]}" >"$work_dir/shellcheck.log" 2>&1 || result=fail
  say "running tests/run.sh"
  run_tests >"$work_dir/tests.log" 2>&1 || result=fail
  count="$(sed -nE 's/^([0-9]+) tests, ([0-9]+) failures$/\1 tests, \2 failures/p' "$work_dir/tests.log" | tail -1)"
  detail="syntax, shellcheck, ${count:-no test count}"
  detail="${detail/, 0 failures/}"
  if [ "$result" = fail ]; then
    STATE=failure
    cat "$work_dir/syntax.log" "$work_dir/shellcheck.log" >&2
    grep -E 'FAIL|^    ' "$work_dir/tests.log" | tail -30 >&2 || tail -30 "$work_dir/tests.log" >&2
  fi
  TESTED+=("Tested: scripts $result ($detail) tree $tree")
  say "scripts $result ($detail)"

  if git diff --name-only origin/main HEAD | grep -q '^app/'; then
    if command -v swift >/dev/null 2>&1; then
      say "running swift test --package-path app"
      if swift test --package-path app >"$work_dir/app.log" 2>&1; then
        TESTED+=("Tested: app pass (swift test) tree $tree")
      else
        STATE=failure
        tail -30 "$work_dir/app.log" >&2
        TESTED+=("Tested: app fail (swift test) tree $tree")
      fi
    else
      TESTED+=("Tested: app not-run (no swift; ci.yml runs it on main) tree $tree")
    fi
    say "${TESTED[-1]#Tested: }"
  fi
}

write_trailers() {
  local args=() line
  for line in "${TESTED[@]}"; do args+=(--trailer "$line"); done
  git log -1 --format=%B | sed -E '/^Tested: /d' |
    git interpret-trailers --if-exists add "${args[@]}" >"$work_dir/message"
  git commit --quiet --amend --no-verify -F "$work_dir/message"
}

if [ "$dry_run" -eq 1 ]; then
  run_checks
  printf '%s\n' "${TESTED[@]}" >&2
  [ "$STATE" = success ] || finish 2 "red $(git rev-parse HEAD) - : a check failed"
  finish 0 "checked $(git rev-parse HEAD) - : would rebase onto $(git rev-parse --short=12 origin/main) and push"
fi

for try in 1 2 3; do
  rebase_onto_main
  run_checks
  [ "$STATE" = success ] || finish 2 "red $(git rev-parse HEAD) - : a check failed; main is unchanged"
  write_trailers
  sha="$(git rev-parse HEAD)"
  if out="$(git push --porcelain origin "$sha:refs/heads/main" 2>&1)"; then
    finish 0 "pushed $sha"
  fi
  printf '%s\n' "$out" >&2
  case "$out" in
    *"non-fast-forward"* | *"fetch first"*) ;;
    *) finish 1 "push-refused $sha - : see the git output above" ;;
  esac
  say "main moved (try $try of 3); fetching, rebasing and checking again"
  git fetch --quiet origin main || finish 1 "fetch-failed $sha - : git fetch origin main"
done
finish 4 "raced $(git rev-parse HEAD) - : main moved three times"
