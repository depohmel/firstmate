#!/usr/bin/env bash
# Contract tests for bin/fm-bosun.sh - the scheduled supervisory chores helper.
#
# Covers: uncommitted-work threshold, steer rate-cap, lock preventing concurrent
# runs, unpushed-commits detection, and PR-readiness verdict (review predates
# head / review newer than head / no reviews yet) via a minimal fake gh.
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
  printf '%s\n' "$home"
}

# run_bosun <home>: run fm-bosun.sh in dry-run against <home>.
run_bosun() {
  local home=$1
  PATH="$home/fakebin:$PATH" FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" \
    FM_ROOT_OVERRIDE="$ROOT" FM_BOSUN_FAKE_GH_DIR="$home/gh-fixtures" \
    FM_BOSUN_DRY_RUN=1 "$BOSUN"
}

# write_fake_gh <home> <head_oid> <commit_date> <review_ts> <changes_count> [pr_state]
# Creates a fake gh that dispatches on arguments, reading canned output from
# one fixture file per case. The fixture files hold the already-filtered output
# (what gh would return after applying --jq / -q).
write_fake_gh() {
  local home=$1 head_oid=$2 commit_date=$3 review_ts=$4 changes_count=$5
  local pr_state=${6:-OPEN}
  local gh="$home/fakebin/gh"
  cat >"$gh" <<'FAKEGH'
#!/usr/bin/env bash
# Fake gh for fm-bosun tests. One fixture file per case; just cats.
case "$1" in
  pr)
    case "$5" in
      headRefOid) cat "$FM_BOSUN_FAKE_GH_DIR/head_oid" ;;
      state) cat "$FM_BOSUN_FAKE_GH_DIR/pr_state" ;;
    esac
    ;;
  api)
    case "$2" in
      */commits/*)
        cat "$FM_BOSUN_FAKE_GH_DIR/commit_date" ;;
      */reviews)
        case "$4" in
          *CHANGES_REQUESTED*) cat "$FM_BOSUN_FAKE_GH_DIR/changes_count" ;;
          *) cat "$FM_BOSUN_FAKE_GH_DIR/review_ts" ;;
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
}

# old_mtime <file>: set a file's mtime to one hour ago.
old_mtime() {
  touch -d '1 hour ago' "$1" 2>/dev/null || touch "$1"
}

# Subshell helper: acquire the bosun lock and hold it briefly.
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

# --- Run all tests ---

test_uncommitted_work_threshold_triggers_steer
test_uncommitted_work_below_threshold_does_not_steer
test_uncommitted_work_no_changes_clears_marker
test_steer_rate_cap_prevents_repeat
test_lock_prevents_concurrent_runs
test_unpushed_commits_no_remote
test_unpushed_commits_pushed_to_remote
test_pr_readiness_review_predates_head
test_pr_readiness_review_newer_than_head
test_pr_readiness_no_reviews_yet
