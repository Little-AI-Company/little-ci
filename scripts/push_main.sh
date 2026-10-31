#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

CHECK_CAP_SECONDS="${PUSH_MAIN_CAP_SECONDS:-600}"
M4_HOST="${PUSH_MAIN_M4:-m4}"
M4_POLL_SECONDS="${PUSH_MAIN_M4_POLL_SECONDS:-10}"
M4_DIR=""

COMMENT_RULES=(
  '*.sh' '^[[:space:]]*#'
  '*.swift' '^[[:space:]]*(//|/[*]|[*]([[:space:]/]|$))'
)
COMMENT_EXCLUDE=(':!.agents/' ':!.claude/' ':!examples/' ':!config.env.example')
COMMENT_DIRECTIVE='^[[:space:]]*(#!|# shellcheck (disable|source)=|// MARK:|// swift-tools-version)'

say() { echo "push-main: $*" >&2; }
finish() {
  local code="$1"
  shift
  echo "PUSH: $*"
  exit "$code"
}

usage() {
  cat >&2 <<'USAGE'
Check one commit and fast-forward main with it (docs/push-main.md).

  scripts/push_main.sh                         push the one commit ahead of origin/main
  scripts/push_main.sh --revert <sha>          revert a commit on main and push that
  scripts/push_main.sh --dry-run               check HEAD, change and push nothing
  scripts/push_main.sh --skip-checks "<why>"   push without running any check

Progress goes to standard error. The last line on standard output is
"PUSH: <state> <sha>", and the exit code says what to do next:
  0  pushed (or checked, with --dry-run)
  1  usage, a missing tool, or a git error
  2  a check failed (main is unchanged)
  3  the rebase conflicts (it is aborted and the commit left as it was)
  4  main kept moving for 3 tries
  5  not pushable: dirty tree, nothing to push, more than one commit, or the
     commit adds comment lines to code files
USAGE
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

tests_command() {
  if [ "$(id -u)" -ne 0 ]; then
    TESTS_COMMAND=(./tests/run.sh)
  elif command -v runuser >/dev/null 2>&1; then
    TESTS_COMMAND=(runuser -u nobody -- env HOME=/tmp TMPDIR=/tmp ./tests/run.sh)
  else
    echo "tests/run.sh must not run as root, and runuser is missing" >&2
    return 1
  fi
}

check_scripts() {
  local files code count capped="" no_tests=0
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

  code=0
  : >"$work_dir/tests.log"
  if [ ! -f tests/run.sh ]; then
    say "no tests/run.sh; skipping the tests"
    no_tests=1
  else
    say "running tests/run.sh"
    if tests_command; then
      run_capped "$CHECK_CAP_SECONDS" "$work_dir/tests.log" "${TESTS_COMMAND[@]}" || code=$?
    else
      code=1
    fi
  fi
  [ "$code" -ne 124 ] || capped="$capped tests/run.sh"
  [ "$code" -eq 0 ] || [ "$code" -eq 124 ] || SCRIPTS_RESULT=fail

  count="$(sed -nE 's/^([0-9]+) tests, ([0-9]+) failures$/\1 tests, \2 failures/p' "$work_dir/tests.log" 2>/dev/null | tail -1)"
  SCRIPTS_DETAIL="syntax, shellcheck, ${count:-no test count}"
  SCRIPTS_DETAIL="${SCRIPTS_DETAIL/, 0 failures/}"
  [ "$no_tests" -eq 0 ] || SCRIPTS_DETAIL="syntax, shellcheck, no tests/run.sh"
  if [ "$SCRIPTS_RESULT" = fail ]; then
    cat "$work_dir/syntax.log" "$work_dir/shellcheck.log" >&2
    grep -E 'FAIL|^    ' "$work_dir/tests.log" | tail -30 >&2 || tail -30 "$work_dir/tests.log" >&2
  elif [ -n "$capped" ]; then
    SCRIPTS_RESULT=capped
    SCRIPTS_DETAIL="hit the ${CHECK_CAP_SECONDS}s cap in:$capped"
    say "WARNING: $SCRIPTS_DETAIL; pushing anyway"
  fi
}

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

m4_cleanup() {
  [ -n "$M4_DIR" ] || return 0
  m4_ssh "p=\$(cat '$M4_DIR/job.pid' 2>/dev/null || true); [ -z \"\$p\" ] || kill -TERM -- \"-\$p\" 2>/dev/null || true; sleep 1; rm -rf '$M4_DIR'; rmdir .push-main 2>/dev/null || true" \
    >/dev/null 2>&1 || say "WARNING: could not remove $M4_HOST:~/$M4_DIR; remove it by hand"
  M4_DIR=""
}

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

check_app() {
  local tree="$1" code=0 where started=$SECONDS
  git diff --name-only origin/main HEAD | grep -q '^app/' || return 0
  if [ ! -d app/Tests ]; then
    say "no app/Tests; skipping the app tests"
    TESTED+=("Tested: app not-run (no app/Tests) tree $tree")
    return 0
  fi

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

comment_count() {
  local rev="$1" i
  for ((i = 0; i < ${#COMMENT_RULES[@]}; i += 2)); do
    git grep -h -I -E -e "${COMMENT_RULES[i + 1]}" "$rev" -- "${COMMENT_RULES[i]}" "${COMMENT_EXCLUDE[@]}" || true
  done | grep -c -v -E "$COMMENT_DIRECTIVE" || true
}

new_comment_lines() {
  local i
  for ((i = 0; i < ${#COMMENT_RULES[@]}; i += 2)); do
    git diff -U0 --no-color --no-ext-diff origin/main HEAD -- "${COMMENT_RULES[i]}" "${COMMENT_EXCLUDE[@]}" |
      awk -v comment="${COMMENT_RULES[i + 1]}" -v directive="$COMMENT_DIRECTIVE" '
        /^\+\+\+ / { file = substr($0, 7); next }
        /^@@ / { split($3, start, ","); line = substr(start[1], 2) + 0; next }
        /^\+/ {
          text = substr($0, 2)
          if (text ~ comment && text !~ directive) print file ":" line ": " text
          line++
        }
      '
  done
}

comment_ratchet() {
  local before after
  before="$(comment_count origin/main)"
  after="$(comment_count HEAD)"
  if [ "$after" -le "$before" ]; then
    say "comment lines in code files: $before on origin/main, $after here"
    return 0
  fi
  say "comment lines in code files rose from $before on origin/main to $after; new ones:"
  new_comment_lines >&2
  finish 5 "comments-rose $(git rev-parse HEAD) - : remove the new comment lines (AGENTS.md, Comments) and amend"
}

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

  comment_ratchet
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
