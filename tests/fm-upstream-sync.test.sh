#!/usr/bin/env bash
# Behavior tests for fm-upstream-sync.sh.
#
# Pins the fork-model sync contract: fetch upstream, attempt a clean merge of
# upstream/<default> into <default>, push to origin/<default> only on a clean
# result. On conflict, git merge --abort and notify. If a clean merge would
# modify bin/ or AGENTS.md while crews are in flight (any state/*.meta exists),
# reset the merge and defer instead of pushing.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh

fm_git_identity fmtest fmtest@example.invalid

TMP_ROOT=$(fm_test_tmproot fm-upstream-sync-tests)
ROOT=${ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}

# new_home: each call gets a unique isolated FM_HOME with projects/ and state/.
# mkdir -p recreates TMP_ROOT if the subshell trap removed it.
new_home() {
  mkdir -p "$TMP_ROOT"
  local h="$TMP_ROOT/home-$$-${RANDOM}"
  mkdir -p "$h/projects" "$h/state"
  printf '%s\n' "$h"
}

# build_fork <home>: create a primary checkout with origin and upstream remotes,
# on main with one initial commit. Echoes the repo path.
build_fork() {
  local home=$1
  local repo="$home/projects/fork"
  local ub="$home/remotes/upstream.git"
  local ob="$home/remotes/origin.git"
  local tmp
  mkdir -p "$home/remotes"

  # Build upstream bare repo with one commit.
  git init -q "$ub" --bare
  git -C "$ub" symbolic-ref HEAD refs/heads/main
  tmp="$home/tmp-init"
  rm -rf "$tmp"
  git init -q "$tmp"
  git -C "$tmp" symbolic-ref HEAD refs/heads/main
  printf '# fork\n' > "$tmp/README.md"
  git -C "$tmp" add README.md
  git -C "$tmp" commit -qm "initial"
  git -C "$tmp" remote add up "file://$(cd "$ub" && pwd)"
  git -C "$tmp" push -q up main
  git -C "$ub" symbolic-ref HEAD refs/heads/main

  # Clone upstream bare to create origin (our fork remote).
  git clone --quiet --bare "$ub" "$ob"

  # Clone from origin to create the working repo.
  git clone --quiet "$ob" "$repo"
  git -C "$repo" remote add upstream "file://$(cd "$ub" && pwd)"

  rm -rf "$tmp"
  printf '%s\n' "$repo"
}

# push_to_upstream <home> <msg> <file> <content>: push a new commit to upstream.
push_to_upstream() {
  local home=$1
  local msg=$2
  local file=$3
  local content=$4
  local tmp="$home/tmp-push"
  rm -rf "$tmp"
  git clone --quiet "$home/remotes/upstream.git" "$tmp"
  mkdir -p "$tmp/$(dirname "$file")"
  printf '%s\n' "$content" > "$tmp/$file"
  git -C "$tmp" add "$file"
  git -C "$tmp" commit -qm "$msg"
  git -C "$tmp" push -q origin main
  rm -rf "$tmp"
}

# push_to_origin <repo> <msg> <file> <content>: commit and push to origin.
push_to_origin() {
  local repo=$1
  local msg=$2
  local file=$3
  local content=$4
  mkdir -p "$repo/$(dirname "$file")"
  printf '%s\n' "$content" > "$repo/$file"
  git -C "$repo" add "$file"
  git -C "$repo" commit -qm "$msg"
  git -C "$repo" push -q origin main
}

# run_sync <home> [args...]: run the script against an isolated home/repo.
run_sync() {
  local home=$1
  shift
  FM_ROOT_OVERRIDE="$home/projects/fork" FM_STATE_OVERRIDE="$home/state" \
    bash "$ROOT/bin/fm-upstream-sync.sh" "$@" 2>/dev/null
}

# mark_crews <home>: touch a .meta file to simulate in-flight crews.
mark_crews() {
  local home=$1
  touch "$home/state/test-crew.meta"
}

# --- tests ------------------------------------------------------------------

test_already_current() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  out=$(run_sync "$home")
  assert_contains "$out" "already current" "already current when upstream == HEAD"
  pass "already current reported when no new commits"
}

test_clean_merge_and_push() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  # Upsteam gains a commit that does not touch bin/ or AGENTS.md.
  push_to_upstream "$home" "upstream docs" "docs/note.md" "upstream note"
  out=$(run_sync "$home")
  assert_contains "$out" "pushed" "clean merge results in push"
  pass "clean merge pushes to origin"
}

test_conflict_aborts() {
  local home out rc repo
  home=$(new_home)
  repo=$(build_fork "$home")
  # Diverge: both modify README.md differently.
  push_to_upstream "$home" "upstream change" "README.md" "upstream version"
  push_to_origin "$repo" "fork change" "README.md" "fork version"
  rc=0
  out=$(run_sync "$home") || rc=$?
  assert_contains "$out" "conflict" "conflict is reported"
  [ "$rc" -eq 1 ] || fail "conflict should exit 1"
  # Working tree must be clean after abort.
  [ -z "$(git -C "$repo" status --porcelain 2>/dev/null | head -1)" ] \
    || fail "working tree dirty after aborted merge"
  pass "conflict aborts merge and exits 1 with clean tree"
}

test_deferred_when_crews_in_flight() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  mark_crews "$home"
  # Upsteam changes bin/ - the instruction surface.
  push_to_upstream "$home" "upstream bin change" "bin/foo.sh" "#!/bin/bash"
  out=$(run_sync "$home")
  assert_contains "$out" "deferred" "deferred when crews in flight and bin/ changed"
  pass "merge deferred when bin/ changes and crews in flight"
}

test_pushes_when_instr_changed_no_crews() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  # No crews in flight.
  push_to_upstream "$home" "upstream bin change" "bin/foo.sh" "#!/bin/bash"
  out=$(run_sync "$home")
  assert_contains "$out" "pushed" "pushes when bin/ changes and no crews in flight"
  pass "merge that changes bin/ pushed when no crews in flight"
}

test_pushes_when_instr_unchanged_with_crews() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  mark_crews "$home"
  # Upsteam changes docs/ only.
  push_to_upstream "$home" "upstream docs" "docs/note.md" "upstream note"
  out=$(run_sync "$home")
  assert_contains "$out" "pushed" "pushes when bin/ unchanged even with crews in flight"
  pass "merge that does not change bin/ pushed even with crews in flight"
}

test_refuses_dirty() {
  local home out rc repo
  home=$(new_home)
  repo=$(build_fork "$home")
  printf 'uncommitted\n' >> "$repo/README.md"
  rc=0
  out=$(run_sync "$home") || rc=$?
  assert_contains "$out" "refused" "refuses dirty working tree"
  [ "$rc" -eq 1 ] || fail "dirty working tree should exit 1"
  pass "dirty working tree is refused"
}

test_refuses_not_on_main() {
  local home out rc
  home=$(new_home)
  build_fork "$home" >/dev/null
  git -C "$home/projects/fork" checkout -q -b feature
  rc=0
  out=$(run_sync "$home") || rc=$?
  assert_contains "$out" "refused" "refuses not on default branch"
  [ "$rc" -eq 1 ] || fail "not on default branch should exit 1"
  pass "not on default branch is refused"
}

test_refuses_no_upstream_remote() {
  local home out rc repo
  home=$(new_home)
  repo=$(build_fork "$home")
  git -C "$repo" remote remove upstream
  rc=0
  out=$(run_sync "$home") || rc=$?
  assert_contains "$out" "refused" "refuses when no upstream remote"
  [ "$rc" -eq 1 ] || fail "no upstream remote should exit 1"
  pass "no upstream remote is refused"
}

test_refuses_no_origin_remote() {
  local home out rc repo
  home=$(new_home)
  repo=$(build_fork "$home")
  git -C "$repo" remote remove origin
  rc=0
  out=$(run_sync "$home") || rc=$?
  assert_contains "$out" "refused" "refuses when no origin remote"
  [ "$rc" -eq 1 ] || fail "no origin remote should exit 1"
  pass "no origin remote is refused"
}

test_no_upstream_branch_skipped() {
  local home out repo
  home=$(new_home)
  repo=$(build_fork "$home")
  git -C "$home/remotes/upstream.git" update-ref -d refs/heads/main
  out=$(run_sync "$home")
  assert_contains "$out" "skipped" "skipped when upstream/main does not exist"
  pass "upstream branch missing is skipped, not an error"
}

test_agents_md_change_triggers_deferral() {
  local home out
  home=$(new_home)
  build_fork "$home" >/dev/null
  mark_crews "$home"
  push_to_upstream "$home" "upstream AGENTS change" "AGENTS.md" "# agents"
  out=$(run_sync "$home")
  assert_contains "$out" "deferred" "deferred when AGENTS.md changes and crews in flight"
  pass "AGENTS.md change with crews in flight is deferred"
}

test_already_current
test_clean_merge_and_push
test_conflict_aborts
test_deferred_when_crews_in_flight
test_pushes_when_instr_changed_no_crews
test_pushes_when_instr_unchanged_with_crews
test_refuses_dirty
test_refuses_not_on_main
test_refuses_no_upstream_remote
test_refuses_no_origin_remote
test_no_upstream_branch_skipped
test_agents_md_change_triggers_deferral
