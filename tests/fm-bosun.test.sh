#!/usr/bin/env bash
# Contract tests for bin/fm-bosun.sh - the scheduled supervisory chores helper.
#
# Covers: uncommitted-work threshold, steer rate-cap, lock preventing concurrent
# runs, unpushed-commits detection, PR-readiness verdict (review predates
# head / review newer than head / no reviews yet) via a minimal fake gh,
# stalled run-step, no-progress crew, inflight sibling conflicts, and idle-fleet
# detection (empty fleet + ready work fires; empty fleet + nothing ready, only
# held/blocked, or busy fleet stay silent) via a fake tmux and tasks-axi.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

BOSUN="$ROOT/bin/fm-bosun.sh"
TMP_ROOT=$(fm_test_tmproot fm-bosun)

# --- Helpers ---------------------------------------------------------------

# make_home <name>: create a temp home with state/, fakebin/, gh-fixtures/.
make_home() {
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/fakebin" "$home/gh-fixtures"
  mkdir -p "$home/nm-fixtures"
  printf '#!/usr/bin/env bash
exit 0
' > "$home/fakebin/no-mistakes"
  chmod +x "$home/fakebin/no-mistakes"
  printf '%s\n' "$home"
}

# run_bosun <home>: run fm-bosun.sh in dry-run against <home>.
run_bosun() {
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_FAKE_GH_DIR="$home/gh-fixtures" \
    FM_BOSUN_FAKE_NM_DIR="$home/nm-fixtures" \
    FM_BOSUN_FAKE_TMUX_DIR="$home/gh-fixtures" \
    FM_BOSUN_DRY_RUN=1 "$BOSUN"
}

# write_fake_nm <home>: create a fake no-mistakes that cats the fixture file.
write_fake_nm() {  # <home>
  local home=$1
  cat > "$home/fakebin/no-mistakes" <<'FAKENM'
#!/usr/bin/env bash
cat "$FM_BOSUN_FAKE_NM_DIR/axi_status" 2>/dev/null
FAKENM
  chmod +x "$home/fakebin/no-mistakes"
}

# write_fake_gh <home> <head_oid> <commit_date> <review_ts> <changes_count> [pr_state] [issue_comment_bodies] [issue_comment_ts]
# Creates a fake gh that dispatches on arguments, reading canned output from
# one fixture file per case. The fixture files hold the already-filtered output
# (what gh would return after applying --jq / -q). When $4 (the --jq filter)
# contains "body", body fixtures are returned instead of timestamp fixtures.
write_fake_gh() {
  local home=$1 head_oid=$2 commit_date=$3 review_ts=$4 changes_count=$5
  local pr_state=${6:-OPEN}
  local issue_bodies=${7:-}
  local issue_ts=${8:-}
  local gh="$home/fakebin/gh"
  cat >"$gh" <<'FAKEGH'
#!/usr/bin/env bash
# Fake gh for fm-bosun tests. One fixture file per case; just cats.
# The jq filter ($4) is inspected to dispatch between timestamp and body
# extraction on the same endpoint.
case "$1" in
  pr)
    case "$2" in
      list)
        cat "$FM_BOSUN_FAKE_GH_DIR/open_prs"
        ;;
      view)
        _snum="${3##*/pull/}"
        case "$5" in
          headRefOid) cat "$FM_BOSUN_FAKE_GH_DIR/head_oid" ;;
          state) cat "$FM_BOSUN_FAKE_GH_DIR/pr_state" ;;
          mergeable) cat "$FM_BOSUN_FAKE_GH_DIR/sibling_mergeable_${_snum}" 2>/dev/null || printf 'MERGEABLE\n' ;;
          behindBase) cat "$FM_BOSUN_FAKE_GH_DIR/sibling_behind_${_snum}" 2>/dev/null || printf 'false\n' ;;
        esac
        ;;
    esac
    ;;
  api)
    case "$2" in
      */commits/*)
        cat "$FM_BOSUN_FAKE_GH_DIR/commit_date" ;;
      */reviews)
        case "$4" in
          *CHANGES_REQUESTED*) cat "$FM_BOSUN_FAKE_GH_DIR/changes_count" ;;
          *body*) cat "$FM_BOSUN_FAKE_GH_DIR/review_bodies" ;;
          *) cat "$FM_BOSUN_FAKE_GH_DIR/review_ts" ;;
        esac ;;
      *issues*comments)
        case "$4" in
          *body*) cat "$FM_BOSUN_FAKE_GH_DIR/issue_comment_bodies" ;;
          *) cat "$FM_BOSUN_FAKE_GH_DIR/issue_comment_ts" ;;
        esac ;;
      *pulls*comments)
        case "$4" in
          *body*) cat "$FM_BOSUN_FAKE_GH_DIR/pull_comment_bodies" ;;
          *) cat "$FM_BOSUN_FAKE_GH_DIR/comment_ts" ;;
        esac ;;
      */comments)
        cat "$FM_BOSUN_FAKE_GH_DIR/comment_ts" ;;
    esac ;;
esac
FAKEGH
  chmod +x "$gh"
  printf '%s\n' "$head_oid" >"$home/gh-fixtures/head_oid"
  printf '%s\n' "$commit_date" >"$home/gh-fixtures/commit_date"
  printf '%s\n' "$review_ts" >"$home/gh-fixtures/review_ts"
  printf '\n' >"$home/gh-fixtures/comment_ts"
  printf '%s\n' "$changes_count" >"$home/gh-fixtures/changes_count"
  printf '%s\n' "$pr_state" >"$home/gh-fixtures/pr_state"
  : >"$home/gh-fixtures/review_bodies"
  : >"$home/gh-fixtures/pull_comment_bodies"
  printf '%s\n' "$issue_bodies" >"$home/gh-fixtures/issue_comment_bodies"
  printf '%s\n' "$issue_ts" >"$home/gh-fixtures/issue_comment_ts"
  : >"$home/gh-fixtures/open_prs"
}

# old_mtime <file>: set a file's mtime to one hour ago.
old_mtime() {
  touch -d '1 hour ago' "$1" 2>/dev/null || touch "$1"
}

# write_fake_tmux <home> [alive-target...]: create a fake tmux that reports a
# target as alive iff it appears (one per line) in
# $FM_BOSUN_FAKE_TMUX_DIR/alive_targets. With no alive targets, every endpoint
# is dead (idle fleet). For other subcommands, exits 0 silently.
write_fake_tmux() {  # <home> [alive-target...]
  local home=$1 target
  cat > "$home/fakebin/tmux" <<'FAKETMUX'
#!/usr/bin/env bash
# Fake tmux for idle-fleet tests: reports a target as alive iff it appears
# (one per line) in $FM_BOSUN_FAKE_TMUX_DIR/alive_targets.
if [ "${1:-}" = "display-message" ]; then
  target=""
  while [ "$#" -gt 0 ]; do
    case "$1" in
      -t) shift; target="${1:-}" ;;
    esac
    shift
  done
  if [ -n "$target" ] && \
     [ -f "${FM_BOSUN_FAKE_TMUX_DIR:-/nonexistent}/alive_targets" ] && \
     grep -Fxq "$target" "${FM_BOSUN_FAKE_TMUX_DIR}/alive_targets" 2>/dev/null; then
    printf '%%pane-0\n'
    exit 0
  fi
  exit 1
fi
exit 0
FAKETMUX
  chmod +x "$home/fakebin/tmux"
  : > "$home/gh-fixtures/alive_targets"
  shift
  for target in "$@"; do
    printf '%s\n' "$target" >> "$home/gh-fixtures/alive_targets"
  done
}

# setup_backlog_config <home>: copy .tasks.toml and create data/ so tasks-axi
# can read/write the backlog in the test home.
setup_backlog_config() {  # <home>
  local home=$1
  mkdir -p "$home/data"
  cp "$ROOT/.tasks.toml" "$home/.tasks.toml"
}

# add_backlog_task <home> <id> <title>: add a queued, unblocked, unheld task.
add_backlog_task() {  # <home> <id> <title>
  local home=$1 id=$2 title=$3
  (cd "$home" && tasks-axi add "$id" "$title" >/dev/null 2>&1)
}

# hold_backlog_task <home> <id> <reason>: place a task on captain-hold so
# tasks-axi ready excludes it.
hold_backlog_task() {  # <home> <id> <reason>
  local home=$1 id=$2 reason=$3
  (cd "$home" && tasks-axi hold "$id" --reason "$reason" --kind captain >/dev/null 2>&1)
}

# --- Subshell helper: acquire the bosun lock and hold it briefly.
# Takes <home> as $1 to avoid shellcheck SC2031 on local variables.
_bosun_hold_lock() {
  local home=$1
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    . "$ROOT/bin/fm-wake-lib.sh"
  fm_lock_try_acquire "$home/state/.bosun.lock" || exit 1
  sleep 3
}

# --- Tests: uncommitted-work threshold -------------------------------------

test_uncommitted_work_threshold_triggers_steer() {
  local home worktree repo id log
  home=$(make_home uncommitted-threshold)
  repo="$TMP_ROOT/repo-uncommitted"
  worktree="$TMP_ROOT/wt-uncommitted"

  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  printf 'uncommitted\n' >"$worktree/scratch.txt"

  id=test-uncommitted
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  # commit-since marker is old enough to exceed the default 900s threshold
  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.commit-since"
  old_mtime "$home/state/.bosun-state/$id.commit-since"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "uncommitted:$id" "$log" "uncommitted-work check should run for task"
  assert_grep "WOULD-send" "$log" "should steer commit when threshold exceeded"
  pass "uncommitted-work threshold triggers commit steer"
}

test_uncommitted_work_below_threshold_does_not_steer() {
  local home worktree repo id log
  home=$(make_home uncommitted-below)
  repo="$TMP_ROOT/repo-below"
  worktree="$TMP_ROOT/wt-below"

  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  printf 'uncommitted\n' >"$worktree/scratch.txt"

  id=test-below
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  # commit-since marker is fresh (just created); threshold not exceeded
  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.commit-since"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "waiting" "$log" "should log waiting state when below threshold"
  assert_grep "uncommitted:$id" "$log" "uncommitted check should still run"
  assert_no_grep "WOULD-send" "$log" "should not steer when below threshold"
  pass "uncommitted-work below threshold does not steer"
}

test_uncommitted_work_no_changes_clears_marker() {
  local home worktree repo id log
  home=$(make_home uncommitted-clean)
  repo="$TMP_ROOT/repo-clean"
  worktree="$TMP_ROOT/wt-clean"

  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  # No uncommitted changes

  id=test-clean
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  # Pre-existing commit-since marker should be removed when no changes
  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.commit-since"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  # No "WOULD-send" and no "first-commit-since" (changes were never present)
  assert_no_grep "WOULD-send" "$log" "should not steer with no changes"
  assert_no_grep "first-commit-since" "$log" "should not re-arm marker with no changes"
  pass "uncommitted-work with no changes clears marker and does not steer"
}

# --- Tests: steer rate-cap -------------------------------------------------

test_steer_rate_cap_prevents_repeat() {
  local home worktree repo id log
  home=$(make_home rate-cap)
  repo="$TMP_ROOT/repo-ratecap"
  worktree="$TMP_ROOT/wt-ratecap"

  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  printf 'uncommitted\n' >"$worktree/scratch.txt"

  id=test-ratecap
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  # commit-since is old (threshold exceeded)
  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.commit-since"
  old_mtime "$home/state/.bosun-state/$id.commit-since"

  # Manually create the commit steer-state file with a fresh mtime to
  # simulate a recent send within the steer interval (default 600s).
  touch "$home/state/.bosun-state/$id.commit"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "rate-capped" "$log" "should be rate-capped when state file is recent"
  assert_no_grep "WOULD-send" "$log" "should not would-send when rate-capped"
  pass "steer rate-cap prevents repeat sends within interval"
}

# --- Tests: lock prevents concurrent runs ----------------------------------

test_lock_prevents_concurrent_runs() {
  local home rc
  home=$(make_home concurrent-lock)

  # Acquire the lock in a background subshell so the parent sees it held.
  _bosun_hold_lock "$home" &
  local bg_pid=$!

  # Give the background subshell time to acquire the lock.
  sleep 1

  set +e
  FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_DRY_RUN=1 \
    "$BOSUN" >"$home/lock.out" 2>"$home/lock.err"
  rc=$?
  set -e

  wait "$bg_pid"

  [ "$rc" -eq 0 ] || fail "concurrent run should exit 0 when lock is held, got $rc"
  assert_absent "$home/state/.bosun.log" "should not write log when lock is held"
  pass "lock prevents concurrent runs"
}

# --- Tests: unpushed-commits ------------------------------------------------

test_unpushed_commits_no_remote() {
  local home worktree repo id log
  home=$(make_home unpushed-noremote)
  repo="$TMP_ROOT/repo-noremote"
  worktree="$TMP_ROOT/wt-noremote"

  fm_git_identity
  fm_git_init_commit "$repo"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  # No remote configured: HEAD cannot be on any remote ref

  id=test-unpushed-noremote
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.push-since"
  old_mtime "$home/state/.bosun-state/$id.push-since"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "unpushed:$id" "$log" "unpushed check should run"
  assert_grep "WOULD-send" "$log" "should steer push when no remote contains HEAD"
  pass "unpushed-commits with no remote triggers push steer"
}

test_unpushed_commits_pushed_to_remote() {
  local home worktree repo remote id log
  home=$(make_home unpushed-pushed)
  repo="$TMP_ROOT/repo-pushed"
  remote="$TMP_ROOT/remote-pushed"
  worktree="$TMP_ROOT/wt-pushed"

  fm_git_identity
  fm_git_init_commit "$repo"
  fm_git_add_origin "$repo" "$remote"
  git -C "$repo" worktree add --quiet -b feature "$worktree"
  # Push the worktree branch so HEAD is on a remote ref
  git -C "$worktree" push -q origin feature 2>/dev/null

  id=test-unpushed-pushed
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" \
    "project=$repo"

  mkdir -p "$home/state/.bosun-state"
  touch "$home/state/.bosun-state/$id.push-since"
  old_mtime "$home/state/.bosun-state/$id.push-since"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  # When HEAD is on a remote ref, ahead=0 and check_unpushed_commits returns
  # early without logging. Verify no push steer was sent.
  assert_no_grep "steer:$id:push" "$log" "should not steer push when HEAD is on a remote"
  pass "unpushed-commits with pushed HEAD does not steer"
}

# --- Tests: PR readiness (fake gh) -----------------------------------------

test_pr_readiness_review_predates_head() {
  local home id log
  home=$(make_home pr-predates)
  id=test-pr-predates

  # head commit is newer than the latest review
  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T15:00:00Z" \
    "2026-08-03T10:00:00Z" \
    "1" \
    "OPEN"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/1"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "NOT-reviewed-against-current-head" "$log" \
    "review predating head must be detected"
  assert_grep "review_ts=2026-08-03T10:00:00Z" "$log" "review_ts must be logged explicitly"
  assert_grep "head_ts=2026-08-03T15:00:00Z" "$log" "head_ts must be logged explicitly"
  assert_grep "steer:$id:pr-reread:WOULD-send" "$log" \
    "should steer re-read when review predates head"
  pass "PR readiness: review predates head is detected and steered"
}

test_pr_readiness_review_newer_than_head() {
  local home id log
  home=$(make_home pr-newer)
  id=test-pr-newer

  # head commit is older than the latest review
  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T10:00:00Z" \
    "2026-08-03T15:00:00Z" \
    "0" \
    "OPEN"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/1"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "reviewed-against-current-head" "$log" \
    "review newer than head must be detected"
  assert_grep "review_ts=2026-08-03T15:00:00Z" "$log" "review_ts must be logged explicitly"
  assert_grep "head_ts=2026-08-03T10:00:00Z" "$log" "head_ts must be logged explicitly"
  assert_no_grep "WOULD-send" "$log" "should not steer when review is current"
  pass "PR readiness: review newer than head is detected and not steered"
}

test_pr_readiness_no_reviews_yet() {
  local home id log
  home=$(make_home pr-noreviews)
  id=test-pr-noreviews

  # No reviews at all (empty review_ts)
  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T15:00:00Z" \
    "" \
    "0" \
    "OPEN"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/1"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "NO-reviews-yet" "$log" "no reviews must be detected"
  assert_grep "review_ts=none" "$log" "review_ts must be logged as none"
  assert_grep "head_ts=2026-08-03T15:00:00Z" "$log" "head_ts must be logged explicitly"
  pass "PR readiness: no reviews yet is detected"
}

# --- Tests: reviewer classification from issue comments --------------------
#
# The famclaw reviewer posts findings as issue comments and does NOT create
# a formal pull-request review when a PR passes. So an empty
# /pulls/<n>/reviews array does NOT mean unreviewed.

# Fixture: 7 issue comments, each containing "Suggestion importance".
# No reviews, no pulls comments.
findings_issue_bodies() {
  printf 'Suggestion importance: finding %d\n' 1 2 3 4 5 6 7
}

# Fixture: one issue comment that is a clean pass.
# No reviews, no pulls comments.
clean_issue_body() {
  printf 'No major issues detected. No code suggestions found.\n'
}

test_pr_readiness_findings_in_issue_comments() {
  local home id log issue_bodies
  home=$(make_home pr-findings-issues)
  id=test-pr-findings-issues

  # 7 findings posted as issue comments; no formal reviews, no pulls
  # comments. This is the famclaw pattern proven by PR 334.
  issue_bodies=$(findings_issue_bodies)

  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T14:00:00Z" \
    "" \
    "0" \
    "OPEN" \
    "$issue_bodies" \
    "2026-08-03T13:00:00Z"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/1"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "reviewer-classification=findings=7" "$log" \
    "findings from issue comments must be counted"
  assert_grep "total=7" "$log" "total comment count must include issue comments"
  pass "PR readiness: findings seen only in issue comments classified correctly"
}

test_pr_readiness_clean_pass_in_issue_comments() {
  local home id log
  home=$(make_home pr-clean-issues)
  id=test-pr-clean-issues

  # Clean pass: one issue comment with both clean markers. No formal review.
  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T14:00:00Z" \
    "" \
    "0" \
    "OPEN" \
    "$(clean_issue_body)" \
    "2026-08-03T13:00:00Z"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/1"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "reviewer-classification=clean" "$log" \
    "clean pass with no formal review must be classified as clean"
  pass "PR readiness: clean pass in issue comments classified as clean"
}

# --- Tests: stalled run-step (fake no-mistakes) -------------------------

# Fixture: axi status with a running ci step, quiet 3h58m, agent pid present.
stale_axi_status() {
  cat <<'EOF'
run:
  id: "test-run-id"
  branch: feat-test
  status: running
  head: abc1234
  findings: none
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,4h01m,"quiet 3h58m ago","12345",1
EOF
}

# Fixture: axi status with a running ci step, 14s ago, agent pid present.
fresh_axi_status() {
  cat <<'EOF'
run:
  id: "test-run-id"
  branch: feat-test
  status: running
  head: abc1234
  findings: none
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,14s,"14s ago: log: working","12345",1
EOF
}

# Fixture: axi status with a running ci step, 14s ago, empty agent pid.
nopid_axi_status() {
  cat <<'EOF'
run:
  id: "test-run-id"
  branch: feat-test
  status: running
  head: abc1234
  findings: none
  active_steps[1]{step,status,active_for,last_activity,agent_pid,round}:
    ci,running,14s,"14s ago: log: working","",1
EOF
}

test_stalled_runstep_detected() {
  local home repo worktree id log
  home=$(make_home stalled-runstep)
  repo="$TMP_ROOT/repo-stalled"
  worktree="$TMP_ROOT/wt-stalled"

  fm_git_identity
  fm_git_worktree "$repo" "$worktree" feat-stalled

  id=test-stalled
  fm_write_meta "$home/state/$id.meta"     "worktree=$worktree" "project=$repo" "kind=ship"

  stale_axi_status > "$home/nm-fixtures/axi_status"
  write_fake_nm "$home"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "stalled:$id:WOULD-escalate" "$log" "stalled run-step must be escalated in dry-run"
  pass "stalled run-step detected and escalated"
}

test_stalled_runstep_fresh_step_not_flagged() {
  local home repo worktree id log
  home=$(make_home stalled-fresh)
  repo="$TMP_ROOT/repo-fresh"
  worktree="$TMP_ROOT/wt-fresh"

  fm_git_identity
  fm_git_worktree "$repo" "$worktree" feat-fresh

  id=test-fresh
  fm_write_meta "$home/state/$id.meta"     "worktree=$worktree" "project=$repo" "kind=ship"

  fresh_axi_status > "$home/nm-fixtures/axi_status"
  write_fake_nm "$home"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_no_grep "stalled:$id:WOULD-escalate" "$log" "fresh run-step must not be escalated"
  pass "fresh run-step not flagged"
}

test_stalled_runstep_no_agent_pid() {
  local home repo worktree id log
  home=$(make_home stalled-nopid)
  repo="$TMP_ROOT/repo-nopid"
  worktree="$TMP_ROOT/wt-nopid"

  fm_git_identity
  fm_git_worktree "$repo" "$worktree" feat-nopid

  id=test-nopid
  fm_write_meta "$home/state/$id.meta"     "worktree=$worktree" "project=$repo" "kind=ship"

  nopid_axi_status > "$home/nm-fixtures/axi_status"
  write_fake_nm "$home"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "stalled:$id:WOULD-escalate" "$log" "empty agent_pid must be escalated"
  pass "stalled run-step with no agent pid detected"
}

test_stalled_runstep_threshold_override() {
  local home repo worktree id log
  home=$(make_home stalled-threshold)
  repo="$TMP_ROOT/repo-threshold"
  worktree="$TMP_ROOT/wt-threshold"

  fm_git_identity
  fm_git_worktree "$repo" "$worktree" feat-threshold

  id=test-threshold
  fm_write_meta "$home/state/$id.meta"     "worktree=$worktree" "project=$repo" "kind=ship"

  stale_axi_status > "$home/nm-fixtures/axi_status"
  write_fake_nm "$home"

  # 3h58m (13080s) exceeds 3600s threshold -> flagged
  FM_BOSUN_STALL_SECS=3600     PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"     FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_FAKE_GH_DIR="$home/gh-fixtures"     FM_BOSUN_FAKE_NM_DIR="$home/nm-fixtures"     FM_BOSUN_DRY_RUN=1 "$BOSUN"

  log="$home/state/.bosun.log"
  assert_grep "stalled:$id:WOULD-escalate" "$log" "3h58m quiet should exceed 3600s threshold"

  # 13080s does NOT exceed 99999s threshold -> not flagged
  rm -f "$home/state/.bosun.log" "$home/state/.bosun-state/$id.stalled"
  FM_BOSUN_STALL_SECS=99999     PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state"     FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_FAKE_GH_DIR="$home/gh-fixtures"     FM_BOSUN_FAKE_NM_DIR="$home/nm-fixtures"     FM_BOSUN_DRY_RUN=1 "$BOSUN"

  log="$home/state/.bosun.log"
  assert_no_grep "stalled:$id:WOULD-escalate" "$log" "threshold override: large threshold should prevent flagging"
  pass "threshold override honoured"
}

# --- Tests: no-progress crew ------------------------------------------------

# Helper: set mtime of a file to N seconds ago.
set_mtime_ago() {  # <file> <secs>
  local file=$1 secs=$2 epoch
  epoch=$(( $(date +%s) - secs ))
  touch -d "@$epoch" "$file" 2>/dev/null || touch "$file"
}

# Helper: create a worktree with a file at <secs> old.
make_stale_worktree() {  # <repo> <worktree> <branch> <secs>
  local repo=$1 worktree=$2 branch=$3 secs=$4 epoch
  epoch=$(( $(date +%s) - secs ))
  fm_git_identity
  fm_git_worktree "$repo" "$worktree" "$branch"
  printf 'worktree content\n' > "$worktree/file.txt"
  git -C "$worktree" add file.txt 2>/dev/null
  GIT_AUTHOR_DATE="@$epoch" GIT_COMMITTER_DATE="@$epoch" \
    git -C "$worktree" commit -qm "add file" 2>/dev/null
  # Set all worktree file mtimes (excluding .git) to <secs> ago
  find "$worktree" -mindepth 1 \
    -not -name ".git" -not -path "*/.git/*" \
    -type f -exec touch -d "@$epoch" {} + 2>/dev/null || true
}

test_no_progress_crew_detected() {
  local home repo worktree id log
  home=$(make_home no-progress)
  repo="$TMP_ROOT/repo-noprog"
  worktree="$TMP_ROOT/wt-noprog"

  # Worktree with a file 2 hours old; no-mistakes not running (no fake NM).
  # Status file says working: so crew_is_busy returns true.
  make_stale_worktree "$repo" "$worktree" feat-noprog 7200

  id=test-noprog
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: working on task\n' > "$home/state/$id.status"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" "no-progress crew must be escalated"
  pass "no-progress crew detected"
}

test_no_progress_crew_active_not_flagged() {
  local home repo worktree id log
  home=$(make_home no-progress-fresh)
  repo="$TMP_ROOT/repo-noprog-fresh"
  worktree="$TMP_ROOT/wt-noprog-fresh"

  # Worktree with a file 5 minutes old; well within threshold.
  make_stale_worktree "$repo" "$worktree" feat-noprog-fresh 300

  id=test-noprog-fresh
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: working on task\n' > "$home/state/$id.status"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_no_grep "no-progress:$id:WOULD-escalate" "$log" "active crew must not be flagged"
  pass "actively-editing crew not flagged"
}
test_no_progress_threshold_override() {
  local home repo worktree id log
  home=$(make_home no-progress-thr)
  repo="$TMP_ROOT/repo-noprog-thr"
  worktree="$TMP_ROOT/wt-noprog-thr"

  # 600s old, below 1800 default but above 300 override.
  make_stale_worktree "$repo" "$worktree" feat-noprog-thr 600

  id=test-noprog-thr
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: working on task\n' > "$home/state/$id.status"

  # With threshold 1800, 600s is below -> not flagged.
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_no_grep "no-progress:$id:WOULD-escalate" "$log" "600s below 1800s threshold should not flag"

  # With threshold 300, 600s exceeds it -> flagged.
  rm -f "$home/state/.bosun.log" "$home/state/.bosun-state/$id.no-progress"
  FM_BOSUN_NPROGRESS_SECS=300 \
    PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_FAKE_GH_DIR="$home/gh-fixtures" \
    FM_BOSUN_FAKE_NM_DIR="$home/nm-fixtures" \
    FM_BOSUN_DRY_RUN=1 "$BOSUN"
  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" "600s exceeds 300s threshold should flag"
  pass "no-progress threshold override honoured"
}
test_no_progress_crew_not_flagged_when_idle() {
  local home repo worktree id log
  home=$(make_home no-progress-idle)
  repo="$TMP_ROOT/repo-noprog-idle"
  worktree="$TMP_ROOT/wt-noprog-idle"

  make_stale_worktree "$repo" "$worktree" feat-noprog-idle 7200

  id=test-noprog-idle
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  # Status file says done: -> crew_is_busy returns false -> not checked.
  printf 'done: all work complete\n' > "$home/state/$id.status"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_no_grep "no-progress:$id:WOULD-escalate" "$log" "idle (done) crew must not be flagged"
  pass "no-progress not flagged when crew is idle"
}

# --- Tests: inflight sibling conflicts after a merge ---------------------
#
# When a task's PR is merged, every other open PR in that repo was validated
# against the old base and may now be CONFLICTING or behind the base, silently
# stalling its pipeline. The bosun's check_inflight_conflicts surfaces these
# without ever rebasing. Uses gh pr view --json mergeable (CONFLICTING) and
# behindBase, plus gh pr list to enumerate open PRs for the repo.

test_conflicting_sibling_reported() {
  local home id log
  home=$(make_home conflicting-sibling)
  id=test-conflicting-sibling

  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T15:00:00Z" \
    "" \
    "0" \
    "MERGED"

  printf '341\n' >"$home/gh-fixtures/open_prs"
  printf 'CONFLICTING\n' >"$home/gh-fixtures/sibling_mergeable_341"
  printf 'true\n' >"$home/gh-fixtures/sibling_behind_341"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/338"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "conflicting-siblings:$id" "$log" "conflicting-siblings check should run"
  assert_grep "WOULD-escalate" "$log" "should escalate conflicting sibling in dry-run"
  assert_grep "341" "$log" "should name the conflicting sibling PR #341"
  pass "conflicting sibling PR is reported"
}

test_up_to_date_sibling_not_reported() {
  local home id log
  home=$(make_home up-to-date-sibling)
  id=test-up-to-date-sibling

  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T15:00:00Z" \
    "" \
    "0" \
    "MERGED"

  printf '341\n' >"$home/gh-fixtures/open_prs"
  printf 'MERGEABLE\n' >"$home/gh-fixtures/sibling_mergeable_341"
  printf 'false\n' >"$home/gh-fixtures/sibling_behind_341"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/338"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "conflicting-siblings:$id" "$log" "conflicting-siblings check should run"
  assert_grep "no-conflicts" "$log" "should report no conflicts for up-to-date sibling"
  assert_no_grep "WOULD-escalate" "$log" "should not escalate up-to-date sibling"
  pass "up-to-date sibling is not reported"
}

test_no_open_siblings_reports_nothing() {
  local home id log
  home=$(make_home no-siblings)
  id=test-no-siblings

  write_fake_gh "$home" \
    "abc123def456" \
    "2026-08-03T15:00:00Z" \
    "" \
    "0" \
    "MERGED"

  : >"$home/gh-fixtures/open_prs"

  fm_write_meta "$home/state/$id.meta" \
    "project=$home" \
    "harness=echo" \
    "pr=https://github.com/testowner/testrepo/pull/338"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "conflicting-siblings:$id" "$log" "conflicting-siblings check should run"
  assert_grep "no-open-siblings" "$log" "should report no open siblings"
  assert_no_grep "WOULD-escalate" "$log" "should not escalate with no open siblings"
  pass "no open siblings reports nothing"
}

# --- Tests: idle fleet with queued ready work ------------------------------

test_idle_fleet_fires_with_ready_work() {
  local home id log
  home=$(make_home idle-fires)
  id=test-idle-fires

  setup_backlog_config "$home"
  add_backlog_task "$home" "ready-task-1" "ready task one"
  add_backlog_task "$home" "ready-task-2" "ready task two"

  # Fake tmux: no alive targets -> fleet is idle (endpoint is dead).
  write_fake_tmux "$home"

  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "project=$home" \
    "harness=echo"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "idle-fleet:WOULD-escalate" "$log" \
    "idle fleet with ready work must escalate in dry-run"
  assert_grep "ready=2" "$log" "must report count of ready items"
  assert_grep "ready-task-1" "$log" "must list top ids"
  assert_grep "ready-task-2" "$log" "must list top ids"
  pass "idle fleet + ready work fires"
}

test_idle_fleet_silent_without_ready_work() {
  local home id log
  home=$(make_home idle-none)
  id=test-idle-none

  setup_backlog_config "$home"
  # No tasks added: backlog is empty, nothing ready.

  write_fake_tmux "$home"

  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "project=$home" \
    "harness=echo"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "idle-fleet" "$log" "idle-fleet check should still run"
  assert_no_grep "WOULD-escalate" "$log" \
    "should not escalate when idle fleet has no ready work"
  pass "idle fleet + nothing ready stays silent"
}

test_idle_fleet_silent_when_all_held() {
  local home id log
  home=$(make_home idle-held)
  id=test-idle-held

  setup_backlog_config "$home"
  add_backlog_task "$home" "held-task-1" "held task one"
  hold_backlog_task "$home" "held-task-1" "captain decision pending"

  write_fake_tmux "$home"

  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "project=$home" \
    "harness=echo"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "idle-fleet" "$log" "idle-fleet check should still run"
  assert_no_grep "WOULD-escalate" "$log" \
    "should not escalate when only held/blocked items exist"
  pass "idle fleet + only held/blocked items stays silent"
}

test_idle_fleet_silent_when_busy() {
  local home id log
  home=$(make_home idle-busy)
  id=test-idle-busy

  setup_backlog_config "$home"
  add_backlog_task "$home" "ready-task-1" "ready task one"
  add_backlog_task "$home" "ready-task-2" "ready task two"

  # Fake tmux: endpoint is alive -> fleet is busy.
  write_fake_tmux "$home" "firstmate:fm-$id"

  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "project=$home" \
    "harness=echo"

  run_bosun "$home"

  log="$home/state/.bosun.log"
  assert_grep "idle-fleet:silent:live-crew=1" "$log" \
    "busy fleet should be detected as having live crew"
  assert_no_grep "WOULD-escalate" "$log" \
    "should not escalate when fleet is busy even with ready work"
  pass "busy fleet + ready work stays silent"
}

# --- Tests: parked conditions (captain-held re-alarm suppression) ---------
#
# The bosun idle checks must not re-alarm a condition that is already parked
# with the captain: a declared paused: status, an armed merge poll against
# the recorded pr=, or an open captain decision hold covering the subject.
# Once the park condition clears, the checks alarm again from first sight.

# write_armed_poll <home> <id> <pr-url>: write the on-disk shape that
# bin/fm-pr-check.sh leaves when a merge poll is armed - the 11-line
# transactional registration plus its sidecar, both carrying the same
# provider-tagged identity re-derived from <pr-url> exactly as
# bin/fm-pr-lib.sh's parsers require - and record pr= in the task meta.
write_armed_poll() {  # <home> <id> <pr-url>
  local home=$1 id=$2 url=$3 rest path number
  rest=${url#https://github.com/}
  path=${rest%%/pull/*}
  number=${rest##*/pull/}
  printf '%s\n' \
    "fm-pr-poll-registration-v2" "$id" "github" "$url" "github.com" \
    "$path" "$number" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "0000000000000000000000000000000000000000000000000000000000000000" \
    "1:1" "1:1" > "$home/state/$id.pr-poll-registration"
  printf '%s\n' "github" "$url" "github.com" "$path" "$number" \
    > "$home/state/$id.pr-poll"
  printf 'pr=%s\n' "$url" >> "$home/state/$id.meta"
}

# retire_armed_poll <home> <id>: publish the retirement receipt without
# removing the registration or sidecar - the window bin/fm-watch.sh is in
# between fm_pr_poll_retirement_publish and a recovery that has not yet
# (or cannot) delete the artifacts.
retire_armed_poll() {  # <home> <id>
  local home=$1 id=$2
  printf 'merged\n' > "$home/state/$id.pr-poll-retirement"
}

# add_captain_decision_hold <home> <origin-id> <key> [repo] [title]: add a
# tasks-axi item named <origin-id>-decision-<key> (the fm-decision-hold
# identity contract) and place it on captain hold. Prints the hold id.
add_captain_decision_hold() {  # <home> <origin-id> <key> [repo] [title]
  local home=$1 origin=$2 key=$3 repo=${4:-} title=${5:-}
  local hold_id="${origin}-decision-${key}"
  [ -n "$title" ] || title="Decision: $key"
  setup_backlog_config "$home"
  if [ -n "$repo" ]; then
    (cd "$home" && tasks-axi add "$hold_id" "$title" --repo "$repo" \
      --kind captain \
      >/dev/null 2>&1)
  else
    (cd "$home" && tasks-axi add "$hold_id" "$title" --kind captain \
      >/dev/null 2>&1)
  fi
  (cd "$home" && tasks-axi hold "$hold_id" --reason "captain decision pending" \
    --kind captain >/dev/null 2>&1)
  printf '%s\n' "$hold_id"
}

# drop_captain_decision_hold <home> <hold-id>: answer the hold so the item
# is no longer an open captain decision hold.
drop_captain_decision_hold() {  # <home> <hold-id>
  local home=$1 id=$2
  (cd "$home" && tasks-axi "done" "$id" >/dev/null 2>&1)
}

test_no_progress_crew_suppressed_by_armed_poll() {
  local home repo worktree id log
  home=$(make_home no-progress-parked-poll)
  repo="$TMP_ROOT/repo-noprog-poll"
  worktree="$TMP_ROOT/wt-noprog-poll"

  make_stale_worktree "$repo" "$worktree" feat-noprog-poll 7200

  id=test-noprog-poll
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: waiting for CI\n' > "$home/state/$id.status"
  write_fake_gh "$home" "abc1234" "2026-08-20T00:00:00Z" "2026-08-21T00:00:00Z" "0"
  write_armed_poll "$home" "$id" "https://github.com/depohmel/famclaw/pull/4"

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_no_grep "no-progress:$id:WOULD-escalate" "$log" \
    "an armed merge poll must suppress the no-progress re-alarm"
  assert_grep "no-progress:$id:suppressed:parked" "$log" \
    "the suppression must be logged"

  # With the park condition gone, the same idle crew alarms again.
  rm -f "$home/state/$id.pr-poll-registration" "$home/state/$id.pr-poll" "$log"
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" \
    "no-progress must alarm again once the armed poll is retired"
  pass "no-progress crew suppressed by armed merge poll"
}

test_no_progress_crew_alarms_when_poll_is_retired() {
  local home repo worktree id log
  home=$(make_home no-progress-retired-poll)
  repo="$TMP_ROOT/repo-noprog-retired"
  worktree="$TMP_ROOT/wt-noprog-retired"

  make_stale_worktree "$repo" "$worktree" feat-noprog-retired 7200

  id=test-noprog-retired
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: waiting for CI\n' > "$home/state/$id.status"
  write_fake_gh "$home" "abc1234" "2026-08-20T00:00:00Z" "2026-08-21T00:00:00Z" "0"
  write_armed_poll "$home" "$id" "https://github.com/depohmel/famclaw/pull/4"

  # Retirement is two-phase: the receipt is published before the registration
  # and sidecar are removed, and that recovery can stall. A receipt means the
  # merge watch is over, so the idle crew is no longer an expected wait even
  # though both poll files still exist on disk.
  retire_armed_poll "$home" "$id"

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" \
    "a published retirement receipt must not keep the no-progress alarm suppressed"
  assert_no_grep "no-progress:$id:suppressed:parked" "$log" \
    "a retired poll is not an armed poll"
  pass "retired merge poll no longer parks the no-progress crew"
}

test_no_progress_crew_alarms_on_malformed_poll_record() {
  local home repo worktree id log
  home=$(make_home no-progress-bad-poll)
  repo="$TMP_ROOT/repo-noprog-bad"
  worktree="$TMP_ROOT/wt-noprog-bad"

  make_stale_worktree "$repo" "$worktree" feat-noprog-bad 7200

  id=test-noprog-bad
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  printf 'working: waiting for CI\n' > "$home/state/$id.status"
  write_fake_gh "$home" "abc1234" "2026-08-20T00:00:00Z" "2026-08-21T00:00:00Z" "0"
  write_armed_poll "$home" "$id" "https://github.com/depohmel/famclaw/pull/4"

  # A registration whose recorded path does not reconstruct its own URL is not
  # a record bin/fm-pr-lib.sh would ever accept, so no watcher is polling it.
  sed -i.bak '6s#.*#depohmel/other#' "$home/state/$id.pr-poll-registration"
  rm -f "$home/state/$id.pr-poll-registration.bak"

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" \
    "a registration the poll-record parser rejects must not suppress the alarm"
  assert_no_grep "no-progress:$id:suppressed:parked" "$log" \
    "an unparseable registration is not an armed poll"
  pass "malformed poll registration no longer parks the no-progress crew"
}

test_no_progress_crew_suppressed_by_paused_status() {
  local home repo worktree id log
  home=$(make_home no-progress-parked-paused)
  repo="$TMP_ROOT/repo-noprog-paused"
  worktree="$TMP_ROOT/wt-noprog-paused"

  make_stale_worktree "$repo" "$worktree" feat-noprog-paused 7200

  id=test-noprog-paused
  fm_write_meta "$home/state/$id.meta" \
    "worktree=$worktree" "project=$repo" "kind=ship"
  stale_axi_status > "$home/nm-fixtures/axi_status"
  write_fake_nm "$home"
  printf 'paused: awaiting merge of PR 4\n' > "$home/state/$id.status"

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_no_grep "no-progress:$id:WOULD-escalate" "$log" \
    "a declared paused status must suppress the no-progress re-alarm"
  assert_no_grep "stalled:$id:WOULD-escalate" "$log" \
    "a declared paused status must suppress the stalled run-step re-alarm"
  assert_grep "no-progress:$id:suppressed:parked" "$log" \
    "the no-progress suppression must be logged"
  assert_grep "stalled:$id:suppressed:parked" "$log" \
    "the stalled run-step suppression must be logged"

  # With the pause dropped, both checks alarm again from first sight.
  printf 'working: resumed\n' >> "$home/state/$id.status"
  rm -f "$log"
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "no-progress:$id:WOULD-escalate" "$log" \
    "no-progress must alarm again once the pause is dropped"
  assert_grep "stalled:$id:WOULD-escalate" "$log" \
    "the stalled run-step must alarm again once the pause is dropped"
  pass "paused status suppresses no-progress and stalled re-alarms"
}

test_parked_work_suppressed_by_captain_hold() {
  local home hold_id id log
  home=$(make_home parked-work-hold)

  id=test-parked-hold
  fm_write_meta "$home/state/$id.meta" "kind=ship"
  printf 'needs-decision: merge PR when green\n' > "$home/state/$id.status"
  hold_id=$(add_captain_decision_hold "$home" "$id" "merge")

  # Condition first detected long ago and already escalated once; while the
  # hold is open the bosun must not re-alarm.
  mkdir -p "$home/state/.bosun-state"
  touch -d '2 hours ago' "$home/state/.bosun-state/$id.parked-since"
  touch -d '2 hours ago' "$home/state/.bosun-state/$id.esc-last"

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "parked:$id:suppressed:parked" "$log" \
    "an open captain hold must suppress the parked-work re-alarm"
  assert_no_grep "parked:$id:WOULD-escalate" "$log" \
    "no parked-work escalation while the hold is open"
  assert_absent "$home/state/.bosun-state/$id.parked-since" \
    "detection must reset while the hold is open"

  # With the hold answered, the long-parked condition alarms again.
  drop_captain_decision_hold "$home" "$hold_id"
  touch -d '2 hours ago' "$home/state/.bosun-state/$id.parked-since"
  touch -d '2 hours ago' "$home/state/.bosun-state/$id.esc-last"
  rm -f "$log"
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "parked:$id:WOULD-escalate" "$log" \
    "parked work must alarm again once the hold is answered"
  pass "parked work suppressed by open captain hold"
}

test_deploy_drift_suppressed_by_captain_hold() {
  local home hold_id log
  home=$(make_home deploy-drift-held)
  mkdir -p "$home/config"
  printf 'famclaw\thomelab\t/opt/famclaw\t\t\n' > "$home/config/deploy-targets.tsv"

  # Fake ssh: homelab's checkout is 3 merged commits behind, nothing running.
  printf '%s\n' '#!/usr/bin/env bash' 'echo "OK|3|0|none|0"' > "$home/fakebin/ssh"
  chmod +x "$home/fakebin/ssh"

  hold_id=$(add_captain_decision_hold "$home" "famclaw" "mac-deploy" "famclaw")

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_no_grep "deploy-drift:WOULD-escalate" "$log" \
    "an open captain hold must suppress the deploy-drift re-alarm"
  assert_grep "deploy-drift:famclaw:suppressed:captain-hold" "$log" \
    "the deploy-drift suppression must be logged"

  # With the hold answered, the same drift alarms again.
  drop_captain_decision_hold "$home" "$hold_id"
  rm -f "$log"
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "deploy-drift:WOULD-escalate" "$log" \
    "deploy drift must alarm again once the hold is answered"
  assert_grep "NOT PULLED" "$log" "the drift detail must still alarm"
  pass "deploy drift suppressed by open captain hold"
}

test_deploy_drift_suppressed_by_hold_title() {
  local home hold_id log
  home=$(make_home deploy-drift-held-title)
  mkdir -p "$home/config"
  printf 'famclaw\thomelab\t/opt/famclaw\t\t\n' > "$home/config/deploy-targets.tsv"

  printf '%s\n' '#!/usr/bin/env bash' 'echo "OK|3|0|none|0"' > "$home/fakebin/ssh"
  chmod +x "$home/fakebin/ssh"

  # Neither the hold identity nor its repo field names the project; only the
  # backlog title does, and that title now rides the cached hold list.
  hold_id=$(add_captain_decision_hold "$home" "relay" "rollout" "" \
    "Decision: hold the famclaw restart until the captain says go")

  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_no_grep "deploy-drift:WOULD-escalate" "$log" \
    "a hold whose title names the project must suppress the deploy-drift re-alarm"
  assert_grep "deploy-drift:famclaw:suppressed:captain-hold" "$log" \
    "the deploy-drift suppression must be logged"

  drop_captain_decision_hold "$home" "$hold_id"
  rm -f "$log"
  run_bosun "$home"
  log="$home/state/.bosun.log"
  assert_grep "deploy-drift:WOULD-escalate" "$log" \
    "deploy drift must alarm again once the hold is answered"
  pass "deploy drift suppressed by a hold whose title names the project"
}

# --- Run all tests ---

test_no_progress_crew_detected
test_no_progress_crew_active_not_flagged
test_no_progress_threshold_override
test_no_progress_crew_not_flagged_when_idle
test_stalled_runstep_detected
test_stalled_runstep_fresh_step_not_flagged
test_stalled_runstep_no_agent_pid
test_stalled_runstep_threshold_override
test_uncommitted_work_threshold_triggers_steer
test_uncommitted_work_below_threshold_does_not_steer
test_uncommitted_work_no_changes_clears_marker
test_steer_rate_cap_prevents_repeat
test_lock_prevents_concurrent_runs
test_unpushed_commits_no_remote
test_unpushed_commits_pushed_to_remote
test_pr_readiness_review_predates_head
test_pr_readiness_review_newer_than_head
test_pr_readiness_findings_in_issue_comments
test_pr_readiness_clean_pass_in_issue_comments
test_pr_readiness_no_reviews_yet
test_conflicting_sibling_reported
test_up_to_date_sibling_not_reported
test_no_open_siblings_reports_nothing
test_idle_fleet_fires_with_ready_work
test_idle_fleet_silent_without_ready_work
test_idle_fleet_silent_when_all_held
test_idle_fleet_silent_when_busy
test_no_progress_crew_suppressed_by_armed_poll
test_no_progress_crew_alarms_when_poll_is_retired
test_no_progress_crew_alarms_on_malformed_poll_record
test_no_progress_crew_suppressed_by_paused_status
test_parked_work_suppressed_by_captain_hold
test_deploy_drift_suppressed_by_captain_hold
test_deploy_drift_suppressed_by_hold_title
