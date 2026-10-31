#!/usr/bin/env bash
# Check one commit and fast-forward main with it (docs/push-main.md). There
# are no pull requests or branches here (Parker, 2026-10-30); this is how a
# maintainer's or agent's commit reaches main. Same interface as
# little-logbook's and little-worker's scripts/push_main.sh.
#
#   scripts/push_main.sh                  # push the one commit ahead of origin/main
#   scripts/push_main.sh --revert <sha>   # revert a commit on main and push that
#   scripts/push_main.sh --dry-run        # check HEAD, change and push nothing
#   scripts/push_main.sh --skip-checks "<why>"   # push without running any check
#
# It refuses a dirty tree, fetches origin/main, rebases the commit onto it,
# and runs this repository's checks on that exact commit: bash -n and
# ShellCheck (warning severity) on every script, tests/run.sh (as nobody
# when run as root, because several scripts refuse root), and
# `swift test --package-path app` when app/ changed. The app tests run here on
# a Mac with Swift; otherwise (Linux, a cloud session) on the M4 over `ssh m4`:
# the commit is uploaded as a tarball, run detached with nohup, and polled with
# short ssh calls, so no ssh session stays open for the whole run. Without
# `ssh m4` it warns and records `not-run`; it never blocks the push.
#
# No check runs longer than 10 minutes (PUSH_MAIN_CAP_SECONDS=600). On the cap
# it ends the check, warns, records `not-run` and pushes anyway.
#
# It writes the results as Tested: trailers, which change the message but
# not the tree they name:
#
#   Tested: scripts pass (syntax, shellcheck, 127 tests) tree 3f2a9c1d7e0b
#   Tested: app pass (swift test, m4, macOS 26.7.2, Xcode 27.1, 41s) tree 3f2a9c1d7e0b
#   Tested: app not-run (no swift here, ssh m4 unavailable) tree 3f2a9c1d7e0b
#
# --skip-checks "<why>" runs none of them and writes one trailer instead,
# `Tested: skipped: <why>`, so the history says the commit was not checked.
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

# No check runs longer than this; on the cap the script warns and pushes anyway.
CHECK_CAP_SECONDS="${PUSH_MAIN_CAP_SECONDS:-600}"
# Without Swift here, the app tests run on this host (`ssh m4`).
M4_HOST="${PUSH_MAIN_M4:-m4}"
M4_POLL_SECONDS="${PUSH_MAIN_M4_POLL_SECONDS:-10}"
M4_DIR=""

say() { echo "push-main: $*" >&2; }
finish() {
  local code="$1"
  shift
  echo "PUSH: $*"
  exit "$code"
}

usage() {
  sed -n '7,10p' "$0" | sed 's/^# \{0,1\}//' >&2
  exit 1
}

revert=""
dry_run=0
skip_checks=0
skip_why=""
while [ $# -gt 0 ]; do
  case "$1" in
    --revert)
      [ $# -ge 2 ] || usage
      revert="$2"
      shift
      ;;
    --dry-run) dry_run=1 ;;
    --skip-checks)
      [ $# -ge 2 ] || usage
      skip_checks=1
      skip_why="$2"
      shift
      ;;
    *) usage ;;
  esac
  shift
done
[ -z "$revert" ] || [ "$dry_run" -eq 0 ] || usage
if [ "$skip_checks" -eq 1 ]; then
  [ -n "${skip_why//[[:space:]]/}" ] && [[ "$skip_why" != *$'\n'* ]] ||
    finish 1 "usage - : --skip-checks needs a one-line reason"
else
  command -v shellcheck >/dev/null 2>&1 ||
    finish 1 "no-shellcheck - : install it (brew install shellcheck, apt install shellcheck, or pip install shellcheck-py)"
fi

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/push-main.XXXXXX")"
trap '[ -z "$M4_DIR" ] || m4_cleanup; rm -rf "$work_dir"' EXIT
trap 'exit 130' INT TERM

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

# Runs a command with its output in a log, and ends it (and everything it
# started) when it is still running after the cap. Returns its exit code, or
# 124 on the cap.
#   run_capped <seconds> <log> <command...>
run_capped() {
  local cap="$1" log="$2" pid waited=0 code=0
  shift 2
  perl -e 'setpgrp(0, 0); exec @ARGV or exit 127' -- "$@" >"$log" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge "$cap" ]; then
      kill -TERM -- "-$pid" 2>/dev/null || true
      sleep 2
      kill -KILL -- "-$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      return 124
    fi
    sleep 1
    waited=$((waited + 1))
  done
  wait "$pid" || code=$?
  return "$code"
}

# Sets TESTS_COMMAND to the command that runs tests/run.sh.
tests_command() {
  if [ "$(id -u)" -ne 0 ]; then
    TESTS_COMMAND=(./tests/run.sh)
  elif command -v runuser >/dev/null 2>&1; then
    # A cloud session runs as root. The checkout must be readable by nobody;
    # the tests write only to their own sandbox under /tmp.
    TESTS_COMMAND=(runuser -u nobody -- env HOME=/tmp TMPDIR=/tmp ./tests/run.sh)
  else
    echo "tests/run.sh must not run as root, and runuser is missing" >&2
    return 1
  fi
}

# Syntax, ShellCheck and tests/run.sh on HEAD. Sets SCRIPTS_RESULT (pass, fail
# or capped) and SCRIPTS_DETAIL.
check_scripts() {
  local files code count capped=""
  mapfile -t files < <(shell_files)
  SCRIPTS_RESULT=pass

  say "bash -n and shellcheck on ${#files[@]} scripts"
  code=0
  run_capped "$CHECK_CAP_SECONDS" "$work_dir/syntax.log" bash -n "${files[@]}" || code=$?
  [ "$code" -ne 124 ] || capped="$capped bash -n"
  [ "$code" -eq 0 ] || [ "$code" -eq 124 ] || SCRIPTS_RESULT=fail
  code=0
  run_capped "$CHECK_CAP_SECONDS" "$work_dir/shellcheck.log" shellcheck --severity=warning "${files[@]}" || code=$?
  [ "$code" -ne 124 ] || capped="$capped shellcheck"
  [ "$code" -eq 0 ] || [ "$code" -eq 124 ] || SCRIPTS_RESULT=fail

  say "running tests/run.sh"
  code=0
  if tests_command; then
    run_capped "$CHECK_CAP_SECONDS" "$work_dir/tests.log" "${TESTS_COMMAND[@]}" || code=$?
  else
    code=1
  fi
  [ "$code" -ne 124 ] || capped="$capped tests/run.sh"
  [ "$code" -eq 0 ] || [ "$code" -eq 124 ] || SCRIPTS_RESULT=fail

  count="$(sed -nE 's/^([0-9]+) tests, ([0-9]+) failures$/\1 tests, \2 failures/p' "$work_dir/tests.log" 2>/dev/null | tail -1)"
  SCRIPTS_DETAIL="syntax, shellcheck, ${count:-no test count}"
  SCRIPTS_DETAIL="${SCRIPTS_DETAIL/, 0 failures/}"
  if [ "$SCRIPTS_RESULT" = fail ]; then
    cat "$work_dir/syntax.log" "$work_dir/shellcheck.log" >&2
    grep -E 'FAIL|^    ' "$work_dir/tests.log" | tail -30 >&2 || tail -30 "$work_dir/tests.log" >&2
  elif [ -n "$capped" ]; then
    SCRIPTS_RESULT=capped
    SCRIPTS_DETAIL="hit the ${CHECK_CAP_SECONDS}s cap in:$capped"
    say "WARNING: $SCRIPTS_DETAIL; pushing anyway"
  fi
}

# The job the M4 runs for the app tests. It is started detached (nohup, its own
# process group) and the pusher polls it with short ssh calls, so no ssh session
# stays open for the whole run. Its own watchdog ends it if nobody collects it.
m4_job_script() {
  cat <<JOB
export PATH="/opt/homebrew/bin:/usr/local/bin:\$PATH"
(sleep $((CHECK_CAP_SECONDS + 120)); echo "push-main: M4 job watchdog fired" >>job.log; kill -TERM -- -\$\$) &
watchdog=\$!
echo "HOSTINFO m4, macOS \$(sw_vers -productVersion), \$(xcodebuild -version 2>/dev/null | head -1)"
cd src
code=0
swift test --package-path app || code=\$?
cd ..
echo "\$code" >exit.tmp
mv exit.tmp exit
kill "\$watchdog" 2>/dev/null || true
JOB
}

m4_ssh() { ssh -o BatchMode=yes -o ConnectTimeout=10 -o ServerAliveInterval=5 -o ServerAliveCountMax=3 "$M4_HOST" "$@"; }

# Ends the job and removes this run's scratch directory on the M4.
m4_cleanup() {
  [ -n "$M4_DIR" ] || return 0
  m4_ssh "p=\$(cat '$M4_DIR/job.pid' 2>/dev/null || true); [ -z \"\$p\" ] || kill -TERM -- \"-\$p\" 2>/dev/null || true; sleep 1; rm -rf '$M4_DIR'; rmdir .push-main 2>/dev/null || true" \
    >/dev/null 2>&1 || say "WARNING: could not remove $M4_HOST:~/$M4_DIR; remove it by hand"
  M4_DIR=""
}

# Runs `swift test --package-path app` on the M4 for HEAD. Returns 0 (passed),
# 1 (failed), 124 (cap) or 125 (the M4 could not be used; nothing was tested).
# Leaves the log in $work_dir/app.log and the host in M4_HOSTINFO.
app_tests_on_m4() {
  local sha started polls_failed=0 state remote
  sha="$(git rev-parse HEAD)"
  started=$SECONDS
  M4_DIR=".push-main/little-ci-$(git rev-parse --short=12 'HEAD^{tree}')-$$"
  M4_HOSTINFO=""

  say "swift test on $M4_HOST: uploading $(git rev-parse --short=12 "$sha")"
  if ! run_capped 120 "$work_dir/upload.log" bash -o pipefail -c \
    'git archive "$1" -- . ":!assets" ":!.agents" | ssh -o BatchMode=yes -o ConnectTimeout=10 "$2" "mkdir -p \"$3/src\" && tar -x -C \"$3/src\""' \
    _ "$sha" "$M4_HOST" "$M4_DIR"; then
    cat "$work_dir/upload.log" >&2
    say "WARNING: could not upload the commit to $M4_HOST"
    return 125
  fi
  remote="cd '$M4_DIR' && echo '$(m4_job_script | base64 | tr -d '\n')' | base64 -d >job.sh && { nohup perl -e 'setpgrp(0, 0); exec @ARGV' bash job.sh >job.log 2>&1 </dev/null & echo \$! >job.pid; } && echo started"
  if ! m4_ssh "$remote" >"$work_dir/start.log" 2>&1; then
    cat "$work_dir/start.log" >&2
    say "WARNING: could not start the job on $M4_HOST"
    return 125
  fi

  while :; do
    if [ $((SECONDS - started)) -ge "$CHECK_CAP_SECONDS" ]; then
      say "WARNING: swift test on $M4_HOST hit the ${CHECK_CAP_SECONDS}s cap; ending it"
      m4_fetch_log
      return 124
    fi
    sleep "$M4_POLL_SECONDS"
    if state="$(m4_ssh "cd '$M4_DIR' && if [ -f exit ]; then echo \"EXIT \$(cat exit)\"; elif kill -0 \"\$(cat job.pid)\" 2>/dev/null; then echo RUNNING; else echo GONE; fi" 2>/dev/null)"; then
      polls_failed=0
      case "$state" in
        "EXIT 0")
          m4_fetch_log
          return 0
          ;;
        EXIT*)
          m4_fetch_log
          return 1
          ;;
        RUNNING) ;;
        *)
          m4_fetch_log
          say "WARNING: the job on $M4_HOST ended without a result"
          return 125
          ;;
      esac
    else
      polls_failed=$((polls_failed + 1))
      if [ "$polls_failed" -ge 6 ]; then
        say "WARNING: $M4_HOST did not answer $polls_failed polls in a row"
        return 125
      fi
    fi
  done
}

m4_fetch_log() {
  m4_ssh "cat '$M4_DIR/job.log'" >"$work_dir/app.log" 2>/dev/null || : >"$work_dir/app.log"
  M4_HOSTINFO="$(sed -n 's/^HOSTINFO //p' "$work_dir/app.log" | head -1 | tr -d '()')"
}

# Adds the app's Tested: line (when app/ changed) to TESTED and fails STATE
# when the tests fail.
check_app() {
  local tree="$1" code=0 where started=$SECONDS
  git diff --name-only origin/main HEAD | grep -q '^app/' || return 0

  if [ "$(uname -s)" = Darwin ] && command -v swift >/dev/null 2>&1; then
    say "running swift test --package-path app"
    where="here"
    run_capped "$CHECK_CAP_SECONDS" "$work_dir/app.log" swift test --package-path app || code=$?
  elif m4_ssh true >/dev/null 2>&1; then
    where="$M4_HOST"
    app_tests_on_m4 || code=$?
    m4_cleanup
    [ -z "$M4_HOSTINFO" ] || where="$M4_HOSTINFO"
  else
    say "WARNING: no Swift on this machine and ssh $M4_HOST is unavailable; the app tests did not run"
    TESTED+=("Tested: app not-run (no swift here, ssh $M4_HOST unavailable) tree $tree")
    return 0
  fi

  case "$code" in
    0) TESTED+=("Tested: app pass (swift test, $where, $((SECONDS - started))s) tree $tree") ;;
    124)
      say "WARNING: the app tests hit the ${CHECK_CAP_SECONDS}s cap; pushing anyway"
      TESTED+=("Tested: app not-run (swift test, $where, hit the ${CHECK_CAP_SECONDS}s cap) tree $tree")
      ;;
    125) TESTED+=("Tested: app not-run (swift test, $M4_HOST did not run it) tree $tree") ;;
    *)
      STATE=failure
      tail -40 "$work_dir/app.log" >&2
      TESTED+=("Tested: app fail (swift test, $where) tree $tree")
      ;;
  esac
  say "${TESTED[-1]#Tested: }"
}

# Sets TESTED (trailer lines) and STATE for HEAD.
run_checks() {
  local tree
  tree="$(git rev-parse --short=12 'HEAD^{tree}')"
  TESTED=()
  STATE=success
  if [ "$skip_checks" -eq 1 ]; then
    TESTED+=("Tested: skipped: $skip_why")
    say "checks skipped: $skip_why"
    return 0
  fi

  check_scripts
  case "$SCRIPTS_RESULT" in
    pass | fail) TESTED+=("Tested: scripts $SCRIPTS_RESULT ($SCRIPTS_DETAIL) tree $tree") ;;
    *) TESTED+=("Tested: scripts not-run ($SCRIPTS_DETAIL) tree $tree") ;;
  esac
  [ "$SCRIPTS_RESULT" != fail ] || STATE=failure
  say "${TESTED[-1]#Tested: }"
  check_app "$tree"
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
