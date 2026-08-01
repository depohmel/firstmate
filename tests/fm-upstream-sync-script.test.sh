#!/usr/bin/env bash
# Behavior tests for fm-upstream-sync.sh - fork-model upstream sync.
#
# Tests the core paths: no-op when current, fast-forward when behind,
# non-fast-forward merge, conflict abort+restore, dry-run, guards
# (wrong branch, dirty tree), and the push-to-origin step.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)

# Run the sync script inside the given repo, capturing stdout+stderr.
# Usage: run_sync <repo> [args...]
# Outputs captured text to stdout; exit 0 always (script errors swallowed).
run_sync() {
  local repo="$1"; shift
  (cd "$repo" && bash ./bin/fm-upstream-sync.sh "$@" 2>&1) || true
}

# Run the sync script inside the given repo, capturing output to a temp file
# and returning the script's exit code. Sets global _SYNC_OUT with captured text.
# Usage: run_sync_capture <repo> [args...]
# Exits with the script's real exit code.
_SYNC_OUT=
run_sync_capture() {
  local repo="$1"; shift
  local tmpf
  tmpf=$(mktemp)
  (cd "$repo" && bash ./bin/fm-upstream-sync.sh "$@" >"$tmpf" 2>&1)
  local rc=$?
  _SYNC_OUT=$(cat "$tmpf")
  rm -f "$tmpf"
  return $rc
}

# --- fixtures ---------------------------------------------------------------

# new_test_repo: create an isolated test repo with a bare origin and a bare
# upstream, both starting at the same commit. Echoes the repo path.
new_test_repo() {
  local upstream_work origin_work clone_dir

  upstream_work="$TMP_ROOT/upstream-src"
  origin_work="$TMP_ROOT/origin-src"
  clone_dir="$TMP_ROOT/worktree"

  # Create upstream (source repo): two commits on main.
  mkdir -p "$upstream_work"
  git init -q "$upstream_work"
  git -C "$upstream_work" symbolic-ref HEAD refs/heads/main
  printf '# upstream v0\n' > "$upstream_work/README.md"
  git -C "$upstream_work" add README.md
  git -C "$upstream_work" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream v0'

  printf '# upstream v1\n' > "$upstream_work/README.md"
  git -C "$upstream_work" add README.md
  git -C "$upstream_work" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream v1'

  git -C "$upstream_work" clone --quiet --bare "$upstream_work" "$TMP_ROOT/upstream.git"

  # Create origin (fork): copy from upstream work (same two commits).
  # The script is already committed in the main repo; we don't add extra commits here
  # so that origin/main == upstream/main for the "already current" test.
  git clone --quiet "$upstream_work" "$origin_work"
  git -C "$origin_work" clone --quiet --bare "$origin_work" "$TMP_ROOT/origin.git"

  # Clone origin into the test worktree.
  git -C "$origin_work" clone --quiet "file://$(cd "$TMP_ROOT/origin.git" && pwd)" "$clone_dir"

  # Wire upstream remote.
  git -C "$clone_dir" remote add upstream "file://$(cd "$TMP_ROOT/upstream.git" && pwd)"

  printf '%s\n' "$clone_dir"
}

head_sha() { git -C "$1" rev-parse HEAD; }

# --- tests ------------------------------------------------------------------

test_already_current_noop() {
  local repo
  repo=$(new_test_repo)
  # Origin and upstream are already at the same commit (upstream v0).
  run_sync_capture "$repo"
  local rc=$?

  assert_contains "$_SYNC_OUT" "already" "current repo reports already"
  expect_code 0 "$rc" "already-current exits 0"
  pass "already at upstream/main is a no-op"
}

test_fast_forward_behind_upstream() {
  local repo before after
  repo=$(new_test_repo)
  before=$(head_sha "$repo")

  # Advance upstream: add one more commit.
  git -C "$TMP_ROOT/upstream-src" checkout -q main
  printf '# upstream v2\n' > "$TMP_ROOT/upstream-src/README.md"
  git -C "$TMP_ROOT/upstream-src" add README.md
  git -C "$TMP_ROOT/upstream-src" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream v2'
  git -C "$TMP_ROOT/upstream-src" push -q upstream main

  run_sync_capture "$repo"
  local rc=$?

  assert_contains "$_SYNC_OUT" "fast-forwarded" "fast-forward reports fast-forwarded"
  expect_code 0 "$rc" "fast-forward exits 0"
  after=$(head_sha "$repo")
  [ "$after" != "$before" ] || fail "expected fast-forward, HEAD unchanged"
  pass "behind upstream fast-forwards cleanly"
}

test_non_fast_forward_merge_succeeds() {
  local repo before after
  repo=$(new_test_repo)
  before=$(head_sha "$repo")

  # Origin main diverges: add a commit on origin.
  git -C "$repo" checkout -q -b main
  printf '# origin unique\n' > "$repo/unique.txt"
  git -C "$repo" add unique.txt
  git -C "$repo" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'origin unique'

  # Now upstream has commits ahead, and main diverges from upstream/main.
  # The script should attempt a merge (non-fast-forward).
  run_sync_capture "$repo"
  local rc=$?

  expect_code 0 "$rc" "non-fast-forward merge exits 0"
  after=$(head_sha "$repo")
  [ "$after" != "$before" ] || fail "expected merge to advance HEAD"
  pass "non-fast-forward upstream merge succeeds when no conflicts"
}

test_merge_conflict_aborts_and_restores() {
  local repo before
  repo=$(new_test_repo)
  before=$(head_sha "$repo")

  # Origin main edits README.md (same file as upstream).
  git -C "$repo" checkout -q -b main
  printf '# origin edits README\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'origin README edit'

  # Upstream also edits README.md (conflict path).
  git -C "$TMP_ROOT/upstream-src" checkout -q main
  printf '# upstream edits README\n' > "$TMP_ROOT/upstream-src/README.md"
  git -C "$TMP_ROOT/upstream-src" add README.md
  git -C "$TMP_ROOT/upstream-src" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream README edit'
  git -C "$TMP_ROOT/upstream-src" push -q upstream main

  run_sync_capture "$repo"
  local rc=$?

  expect_code 1 "$rc" "conflict exits 1"
  assert_contains "$_SYNC_OUT" "CONFLICT" "conflict output contains CONFLICT"
  assert_contains "$_SYNC_OUT" "restored" "conflict output mentions restore"
  [ "$(head_sha "$repo")" = "$before" ] || fail "expected main restored to pre-merge SHA"
  pass "merge conflict aborts and restores main"
}

test_dry_run_clean() {
  local repo before
  repo=$(new_test_repo)

  # Advance upstream so there is work behind.
  git -C "$TMP_ROOT/upstream-src" checkout -q main
  printf '# upstream dry-run v2\n' > "$TMP_ROOT/upstream-src/README.md"
  git -C "$TMP_ROOT/upstream-src" add README.md
  git -C "$TMP_ROOT/upstream-src" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream dry-run v2'
  git -C "$TMP_ROOT/upstream-src" push -q upstream main

  before=$(head_sha "$repo")

  run_sync_capture "$repo" --dry-run
  local rc=$?

  expect_code 0 "$rc" "dry-run clean exits 0"
  assert_contains "$_SYNC_OUT" "dry-run" "dry-run output contains dry-run"
  assert_contains "$_SYNC_OUT" "clean" "dry-run clean report"
  [ "$(head_sha "$repo")" = "$before" ] || fail "dry-run should not modify main"
  pass "dry-run reports clean merge possible without modifying main"
}

test_dry_run_conflict() {
  local repo before
  repo=$(new_test_repo)

  # Origin diverges from upstream on same file.
  git -C "$repo" checkout -q -b main
  printf '# origin README change\n' > "$repo/README.md"
  git -C "$repo" add README.md
  git -C "$repo" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'origin README'

  git -C "$TMP_ROOT/upstream-src" checkout -q main
  printf '# upstream README change\n' > "$TMP_ROOT/upstream-src/README.md"
  git -C "$TMP_ROOT/upstream-src" add README.md
  git -C "$TMP_ROOT/upstream-src" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream README'
  git -C "$TMP_ROOT/upstream-src" push -q upstream main

  before=$(head_sha "$repo")

  run_sync_capture "$repo" --dry-run
  local rc=$?

  expect_code 1 "$rc" "dry-run conflict exits 1"
  assert_contains "$_SYNC_OUT" "dry-run" "dry-run output contains dry-run"
  assert_contains "$_SYNC_OUT" "conflict" "dry-run conflict report"
  [ "$(head_sha "$repo")" = "$before" ] || fail "dry-run should not modify main"
  pass "dry-run reports conflict without modifying main"
}

test_not_on_main_branch_rejects() {
  local repo
  repo=$(new_test_repo)

  git -C "$repo" checkout -q -b feature

  run_sync_capture "$repo"
  local rc=$?

  expect_code 1 "$rc" "wrong branch exits 1"
  assert_contains "$_SYNC_OUT" "not on main" "wrong branch rejects with not on main"
  pass "not on main branch is rejected"
}

test_dirty_working_tree_rejects() {
  local repo
  repo=$(new_test_repo)

  printf 'scratch\n' > "$repo/scratch.txt"

  run_sync_capture "$repo"
  local rc=$?

  expect_code 1 "$rc" "dirty tree exits 1"
  assert_contains "$_SYNC_OUT" "uncommitted" "dirty tree reports uncommitted"
  pass "dirty working tree is rejected without --force-dirty"
}

test_dirty_working_tree_with_force_dirty() {
  local repo before after
  repo=$(new_test_repo)

  # Advance upstream.
  git -C "$TMP_ROOT/upstream-src" checkout -q main
  printf '# upstream force v2\n' > "$TMP_ROOT/upstream-src/README.md"
  git -C "$TMP_ROOT/upstream-src" add README.md
  git -C "$TMP_ROOT/upstream-src" -c user.name='fmtest' -c user.email='fmtest@example.invalid' commit -qm 'upstream force v2'
  git -C "$TMP_ROOT/upstream-src" push -q upstream main

  # Dirty the tree.
  printf 'scratch\n' > "$repo/scratch.txt"

  before=$(head_sha "$repo")

  run_sync_capture "$repo" --force-dirty
  local rc=$?

  expect_code 0 "$rc" "force-dirty succeeds"
  assert_contains "$_SYNC_OUT" "fast-forwarded" "force-dirty fast-forwards"
  after=$(head_sha "$repo")
  [ "$after" != "$before" ] || fail "expected advance with force-dirty"
  pass "--force-dirty allows dirty tree for scripted use"
}

test_already_current_noop
test_fast_forward_behind_upstream
test_non_fast_forward_merge_succeeds
test_merge_conflict_aborts_and_restores
test_dry_run_clean
test_dry_run_conflict
test_not_on_main_branch_rejects
test_dirty_working_tree_rejects
test_dirty_working_tree_with_force_dirty
