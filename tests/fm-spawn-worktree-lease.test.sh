#!/usr/bin/env bash
# Regression tests for fm-spawn.sh's `treehouse get --lease` worktree
# acquisition (bin/fm-spawn.sh, the ship/scout block that leases the worktree
# and then navigates the pane into it).
#
# fm-spawn used to send `treehouse get` to the pane and poll the backend's
# current-path primitive to discover where the pane landed. Every layer of that
# was inference: a brand-new window whose initial cwd is not the project (a tmux
# fallback to the session start-directory, a WSL pane reporting an unrelated
# stale checkout) can settle on a wrong-but-plausible path that
# validate_spawn_worktree still accepts, because it really is a distinct git
# worktree root. state/<id>.meta then records the wrong worktree=, the turn-end
# hook lands outside the task's worktree, and teardown refuses the path as not
# managed by treehouse.
#
# These tests pin the replacement contract: meta records exactly the path
# treehouse leased, a failed lease stops the spawn loudly, and a lease taken
# before an abort is returned rather than leaked (a durable lease outlives this
# process, and with no meta teardown could never find it).
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-worktree-lease)

# make_lease_fakebin <dir> <lease-path> builds a fake tmux that swallows every
# window op and a fake treehouse that answers `get --lease` with <lease-path>,
# mirroring the real binary's contract (only the absolute worktree path on
# stdout; banners go to stderr). Every `treehouse return` call is appended to
# <dir>/return.log so the abort path can be asserted on.
make_lease_fakebin() {
  local dir=$1 lease_path=$2 fakebin
  fakebin=$(fm_fakebin "$dir")
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  list-windows) exit 0 ;;
esac
exit 0
SH
  chmod +x "$fakebin/tmux"
  cat > "$fakebin/treehouse" <<SH
#!/usr/bin/env bash
set -u
if [ "\${1:-}" = return ]; then
  printf 'return %s\\n' "\$*" >> "$dir/return.log"
  exit 0
fi
for arg in "\$@"; do
  if [ "\$arg" = "--lease" ]; then printf '%s\\n' "$lease_path"; exit 0; fi
done
exit 0
SH
  chmod +x "$fakebin/treehouse"
  printf '%s\n' "$fakebin"
}

# make_lease_home <home> <id> prepares a home with a brief and a crew harness.
make_lease_home() {
  local home=$1 id=$2
  mkdir -p "$home/data/$id" "$home/projects" "$home/state" "$home/config"
  printf 'codex\n' > "$home/config/crew-harness"
  printf 'brief for %s\n' "$id" > "$home/data/$id/brief.md"
  touch "$home/state/.last-watcher-beat"
}

run_lease_spawn() {  # <home> <id> <proj> <fakebin>
  local home=$1 id=$2 proj=$3 fakebin=$4
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_PROJECTS_OVERRIDE="$home/projects" FM_CONFIG_OVERRIDE="$home/config" \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" \
    PATH="$fakebin:$PATH" \
    "$SPAWN" "$id" "$proj" 2>&1
}

# The recorded worktree must be the path treehouse leased, and in particular
# must never be FM_HOME - the home is a real git worktree root distinct from the
# project, so the retired poll could record it and still pass every later check.
test_meta_records_the_leased_path() {
  local id home proj wt fakebin out status recorded
  id=lease-meta-z1
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  wt="$TMP_ROOT/wt-$id"
  make_lease_home "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/fake-$id" "$wt")

  out=$(run_lease_spawn "$home" "$id" "$proj" "$fakebin")
  status=$?
  expect_code 0 "$status" "ship spawn should succeed against a leased worktree"$'\n'"$out"
  assert_contains "$out" "worktree=$wt" "spawn summary did not report the leased worktree"
  recorded=$(grep '^worktree=' "$home/state/$id.meta" | cut -d= -f2-)
  [ "$recorded" = "$wt" ] || fail "meta recorded worktree='$recorded', expected the leased '$wt'"
  [ "$recorded" != "$home" ] || fail "meta recorded FM_HOME as the worktree"

  rm -rf "/tmp/fm-$id"
  pass "worktree= records the treehouse-leased path, never the home or an observed pane cwd"
}

# An empty lease (pool exhausted, or a treehouse that printed nothing) must stop
# the spawn with an actionable error rather than launching into an unknown path.
test_failed_lease_stops_the_spawn() {
  local id home proj wt fakebin out status
  id=lease-fail-z2
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  wt="$TMP_ROOT/wt-$id"
  make_lease_home "$home" "$id"
  fm_git_worktree "$proj" "$wt" "wt-$id"
  # An empty lease path: the stub prints nothing for `get --lease`.
  fakebin=$(make_lease_fakebin "$TMP_ROOT/fake-$id" "")

  out=$(run_lease_spawn "$home" "$id" "$proj" "$fakebin")
  status=$?
  expect_code 1 "$status" "spawn should fail when the lease yields no worktree"$'\n'"$out"
  assert_contains "$out" "treehouse get --lease failed" \
    "the failure did not name the lease step"
  assert_absent "$home/state/$id.meta" "meta must not be written when the lease fails"

  rm -rf "/tmp/fm-$id"
  pass "a failed lease stops the spawn with an actionable error and writes no task record"
}

# A lease is durable: it survives with no live process and is skipped by later
# get/prune. Aborting after acquiring it but before meta exists would leak the
# pool slot forever, since teardown reads the worktree from meta.
test_lease_is_returned_when_the_spawn_aborts() {
  local id home proj bad fakebin out status
  id=lease-abort-z3
  home="$TMP_ROOT/home-$id"
  proj="$TMP_ROOT/proj-$id"
  bad="$TMP_ROOT/not-a-worktree-$id"
  make_lease_home "$home" "$id"
  fm_git_worktree "$proj" "$TMP_ROOT/wt-$id" "wt-$id"
  # Lease a path that is not an isolated git worktree, so the isolation guard
  # aborts the spawn after the lease was already taken.
  mkdir -p "$bad"
  fakebin=$(make_lease_fakebin "$TMP_ROOT/fake-$id" "$bad")

  out=$(run_lease_spawn "$home" "$id" "$proj" "$fakebin")
  status=$?
  expect_code 1 "$status" "spawn should abort when the leased path is not isolated"$'\n'"$out"
  assert_grep "return --force $bad" "$TMP_ROOT/fake-$id/return.log" \
    "the durable lease was not returned when the spawn aborted"
  assert_absent "$home/state/$id.meta" "meta must not be written when validation aborts"

  rm -rf "/tmp/fm-$id"
  pass "a lease taken before an abort is returned, not leaked"
}

test_meta_records_the_leased_path
test_failed_lease_stops_the_spawn
test_lease_is_returned_when_the_spawn_aborts

echo "# all fm-spawn-worktree-lease tests passed"
