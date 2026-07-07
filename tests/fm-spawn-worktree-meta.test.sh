#!/usr/bin/env bash
# Regression tests for fm-spawn.sh worktree= meta accuracy.
#
# Verifies that state/<id>.meta records the actual treehouse-leased worktree
# path and NOT the FM_HOME primary root (the bug: treehouse get --lease was
# previously done by polling pane_current_path, which raced with the window's
# initial CWD, causing FM_HOME to be recorded when tmux fell back to its
# session start-directory).
#
# These tests use a real isolated git worktree (for validate_spawn_worktree),
# a fake treehouse that outputs a controlled lease path, and a fake tmux that
# silently accepts all commands. FM_HOME is set to a temp dir that differs
# from the lease path so the regression is detectable.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-meta)

make_meta_test_fakebin() {
  local dir=$1 lease_path=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  # Fake treehouse: output the controlled lease path for "get --lease".
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
for arg in "\$@"; do
  if [ "\$arg" = "--lease" ]; then
    printf '%s\n' "$(printf '%s' "$lease_path")"
    exit 0
  fi
done
exit 0
SH
  chmod +x "$fakebin/treehouse"
  # Fake tmux: accept all commands silently; no pane CWD queries needed.
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"
  printf '%s\n' "$fakebin"
}

# test_worktree_meta_records_lease_path: after a successful ship spawn the
# worktree= line in meta must equal the path treehouse returned, not FM_HOME.
test_worktree_meta_records_lease_path() {
  local id home proj wt fakebin out status wt_in_meta
  id=wt-meta-lease-z1
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  wt="$TMP_ROOT/wt-$id"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_worktree "$proj" "$wt" "wt-$id"

  fakebin=$(make_meta_test_fakebin "$TMP_ROOT/fake-$id" "$wt")

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" 2>&1
  )
  status=$?
  expect_code 0 "$status" "ship spawn should succeed: $out"

  wt_in_meta=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ "$wt_in_meta" = "$wt" ] \
    || fail "worktree= in meta should be the leased path '$wt', got '$wt_in_meta'"

  # Regression: must NOT be FM_HOME (the primary root).
  [ "$wt_in_meta" != "$home" ] \
    || fail "worktree= in meta must not be FM_HOME '$home' (old polling-race bug)"

  pass "worktree= in meta matches treehouse lease path, not FM_HOME"
}

# test_spawn_fails_gracefully_when_lease_fails: when treehouse get --lease
# returns empty (e.g. pool exhausted), spawn exits non-zero with a useful error.
test_spawn_fails_gracefully_when_lease_fails() {
  local id home proj wt fakebin_dir fakebin out status
  id=wt-meta-fail-z2
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  wt="$TMP_ROOT/wt-$id"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_worktree "$proj" "$wt" "wt-$id"

  fakebin_dir="$TMP_ROOT/fake-$id"
  fakebin=$(fm_fakebin "$fakebin_dir")
  # Fake treehouse that returns empty output (simulates pool exhausted).
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn should fail when treehouse get --lease returns empty"
  assert_contains "$out" "treehouse get --lease failed" \
    "error message should mention treehouse get --lease"
  assert_absent "$home/state/$id.meta" "meta must not be written on lease failure"
  pass "spawn exits non-zero with useful error when treehouse lease fails"
}

# test_lease_released_when_validation_aborts: when the leased path is not an
# isolated worktree, validate_spawn_worktree aborts the spawn; the durable
# lease must be returned on exit so the pool slot is not leaked forever.
test_lease_released_when_validation_aborts() {
  local id home proj bad fakebin_dir fakebin out status
  id=wt-meta-leak-z3
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  bad="$TMP_ROOT/bad-$id"

  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config" "$bad"
  printf 'claude\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"

  fm_git_worktree "$proj" "$TMP_ROOT/wt-$id" "wt-$id"

  fakebin_dir="$TMP_ROOT/fake-$id"
  fakebin=$(fm_fakebin "$fakebin_dir")
  # Fake treehouse: lease a NON-worktree path (validate_spawn_worktree rejects
  # it), and record a return --force call to a marker file.
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
if [ "\$1" = return ]; then
  printf 'returned %s\n' "\$*" >> "$fakebin_dir/return.log"
  exit 0
fi
for arg in "\$@"; do
  if [ "\$arg" = "--lease" ]; then
    printf '%s\n' "$bad"
    exit 0
  fi
done
exit 0
SH
  chmod +x "$fakebin/treehouse"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
exit 0
SH
  chmod +x "$fakebin/tmux"

  out=$(
    FM_ROOT_OVERRIDE='' FM_HOME="$home" \
      FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
      FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
      FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" PATH="$fakebin:$PATH" \
      "$SPAWN" "$id" "$proj" 2>&1
  )
  status=$?
  expect_code 1 "$status" "spawn should abort when leased path is not isolated: $out"
  [ -f "$fakebin_dir/return.log" ] \
    || fail "lease must be returned on abort; no treehouse return recorded"
  grep -qF "$bad" "$fakebin_dir/return.log" \
    || fail "treehouse return should target the leased path '$bad', got: $(cat "$fakebin_dir/return.log")"
  assert_absent "$home/state/$id.meta" "meta must not be written on validation abort"
  pass "durable lease is returned when spawn aborts after acquiring it"
}

test_worktree_meta_records_lease_path
test_spawn_fails_gracefully_when_lease_fails
test_lease_released_when_validation_aborts
