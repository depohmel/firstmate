#!/usr/bin/env bash
# Tests for bin/fm-upstream-sync.sh: automatic upstream sync.
#
# Matrix:
#   (a) no-new-commits: exits 0 silently when upstream/main hasn't advanced
#   (b) clean merge: creates branch, pushes, opens PR, records last synced SHA
#   (c) conflicting merge: aborts, deletes branch, leaves repo unchanged,
#       reports conflicting paths on stdout, exits non-zero
#   (d) idempotence: running twice does not create a second branch or PR
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SCRIPT="$ROOT/bin/fm-upstream-sync.sh"
TMP_ROOT=$(fm_test_tmproot fm-upstream-sync)

# --- fixture builders -------------------------------------------------------

# setup_fork <tmpdir>: create origin.git and upstream.git bare repos that share
# a common ancestor commit, plus a work clone with both remotes. Echoes the
# work clone path.
setup_fork() {
    local tmp=$1 origin_bare upstream_bare seed
    origin_bare="$tmp/origin.git"
    upstream_bare="$tmp/upstream.git"
    seed="$tmp/seed"

    git init -q -b main "$seed"
    printf 'common\n' > "$seed/file.txt"
    git -C "$seed" add file.txt
    git -C "$seed" commit -q -m "common ancestor"

    git clone --quiet --bare "$seed" "$origin_bare"
    git clone --quiet --bare "$seed" "$upstream_bare"

    git clone -q "$origin_bare" "$tmp/work"
    git -C "$tmp/work" remote add upstream "$upstream_bare"

    printf '%s\n' "$tmp/work"
}

# add_commit_to <repo> <remote> <msg> <file> <content>: commit a change in the
# work clone and push to the named remote (origin or upstream).
add_commit_to() {
    local repo=$1 remote=$2 msg=$3 file=$4 content=$5
    printf '%s\n' "$content" > "$repo/$file"
    git -C "$repo" add "$file"
    git -C "$repo" commit -q -m "$msg"
    git -C "$repo" push -q "$remote" main
}

# add_upstream_commit <tmpdir> <msg> <file> <content>: add a commit to upstream
# via a fresh clone of the upstream bare repo (so the work clone stays clean).
add_upstream_commit() {
    local tmp=$1 msg=$2 file=$3 content=$4 w
    w="$tmp/upstream-work"
    rm -rf "$w"
    mkdir -p "$w"
    git clone -q "$tmp/upstream.git" "$w"
    printf '%s\n' "$content" > "$w/$file"
    git -C "$w" add "$file"
    git -C "$w" commit -q -m "$msg"
    git -C "$w" push -q origin main
    rm -rf "$w"
}

# make_fake_gh_axi <dir> <log>: drop a fake gh-axi into <dir> that records every
# invocation to <log> and prints a fake PR URL when pr create is called.
make_fake_gh_axi() {
    local dir=$1 log=$2
    cat > "$dir/gh-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$log"
case "\${1:-} \${2:-}" in
    "pr create")
        printf 'https://github.com/example/repo/pull/42\n'
        ;;
esac
exit 0
SH
    chmod +x "$dir/gh-axi"
}

# make_test_dir <name>: create a fresh subdirectory under TMP_ROOT. Echoes the path.
make_test_dir() {
    local name=$1
    local dir="$TMP_ROOT/$name"
    rm -rf "$dir"
    mkdir -p "$dir"
    printf '%s\n' "$dir"
}

# run_sync <work> <fakebin> [args...]: run the script from <work> with <fakebin>
# on PATH, capturing combined stdout+stderr.
run_sync() {
    local work=$1 fakebin=$2; shift 2
    ( cd "$work" && env -u FM_HOME -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
        "FM_ROOT_OVERRIDE=$work" "FM_STATE_OVERRIDE=$work/state" \
        "PATH=$fakebin:$PATH" "$@" \
        "$SCRIPT" ) 2>&1
}

# count_remote_sync_branches <work>: count remote FM upstream-sync branches.
count_remote_sync_branches() {
    git -C "$1" branch -r --list 'origin/fm/upstream-sync-*' 2>/dev/null | wc -l | tr -d ' '
}

# --- test (a): no-new-commits exits silently -------------------------------

test_no_new_commits_exits_silently() {
    local tmp work state fakebin out rc upstream_sha
    tmp=$(make_test_dir no-new)
    work=$(setup_fork "$tmp")
    state="$work/state"
    mkdir -p "$state"
    fakebin=$(fm_fakebin "$tmp")

    # Record the current upstream HEAD to simulate a prior sync.
    git -C "$work" fetch upstream >/dev/null 2>&1
    upstream_sha=$(git -C "$work" rev-parse upstream/main)
    printf '%s\n' "$upstream_sha" > "$state/upstream-sync-last-sha"

    out=$(run_sync "$work" "$fakebin") || true
    rc=$?

    expect_code 0 "$rc" "no-new-commits: must exit 0"
    [ -z "$out" ] || fail "no-new-commits: must exit silently, got: $out"
    pass "no-new-commits: exits 0 silently when upstream/main hasn't advanced"
}

# --- test (b): clean merge creates branch and opens PR ---------------------

test_clean_merge_creates_branch_and_pr() {
    local tmp work state fakebin out rc before_sha upstream_sha
    tmp=$(make_test_dir clean)
    work=$(setup_fork "$tmp")
    state="$work/state"
    mkdir -p "$state"
    fakebin=$(fm_fakebin "$tmp")
    make_fake_gh_axi "$fakebin" "$tmp/gh-axi.log"

    # Diverge: origin gets one commit, upstream gets two (different files).
    add_commit_to "$work" origin "origin fork" "origin.txt" "origin content"
    add_upstream_commit "$tmp" "upstream commit 1" "upstream.txt" "upstream content 1"
    add_upstream_commit "$tmp" "upstream commit 2" "upstream.txt" "upstream content 2"

    before_sha=$(git -C "$work" rev-parse HEAD)

    set +e
    out=$(run_sync "$work" "$fakebin")
    rc=$?
    set -e

    expect_code 0 "$rc" "clean-merge: must exit 0"
    assert_contains "$out" "Created PR" "clean-merge: must report PR creation"

    # gh-axi pr create must have been called.
    assert_grep "pr create" "$tmp/gh-axi.log" "clean-merge: gh-axi pr create should be called"

    # Last synced SHA must be recorded.
    upstream_sha=$(git -C "$work" rev-parse upstream/main)
    [ "$(cat "$state/upstream-sync-last-sha")" = "$upstream_sha" ] \
        || fail "clean-merge: last-sha not updated to upstream HEAD"

    # A remote sync branch must exist.
    [ "$(count_remote_sync_branches "$work")" -ge 1 ] \
        || fail "clean-merge: sync branch must be pushed to origin"

    # Repo must be back on the original commit (script returns to original branch).
    [ "$(git -C "$work" rev-parse HEAD)" = "$before_sha" ] \
        || fail "clean-merge: repo must return to original commit"

    pass "clean merge creates branch, pushes, opens PR, records last synced SHA"
}

# --- test (c): conflicting merge aborts and leaves repo unchanged -----------

test_conflicting_merge_aborts() {
    local tmp work state fakebin out rc before_sha
    tmp=$(make_test_dir conflict)
    work=$(setup_fork "$tmp")
    state="$work/state"
    mkdir -p "$state"
    fakebin=$(fm_fakebin "$tmp")
    make_fake_gh_axi "$fakebin" "$tmp/gh-axi.log"

    # Diverge with conflicting changes to the same file.
    add_commit_to "$work" origin "origin change" "file.txt" "origin content"
    add_upstream_commit "$tmp" "upstream change" "file.txt" "upstream content"

    before_sha=$(git -C "$work" rev-parse HEAD)

    set +e
    out=$(run_sync "$work" "$fakebin")
    rc=$?
    set -e

    expect_code 1 "$rc" "conflict: must exit non-zero"

    # Conflicting paths must be on stdout.
    assert_contains "$out" "CONFLICT" "conflict: stdout must report conflict"
    assert_contains "$out" "file.txt" "conflict: stdout must list conflicting paths"

    # No PR should be created.
    [ ! -s "$tmp/gh-axi.log" ] || fail "conflict: must not call gh-axi: $(cat "$tmp/gh-axi.log")"

    # No remote sync branch.
    [ "$(count_remote_sync_branches "$work")" = "0" ] \
        || fail "conflict: sync branch must not exist on origin"

    # Repo must be at the original commit.
    [ "$(git -C "$work" rev-parse HEAD)" = "$before_sha" ] \
        || fail "conflict: repo must be at original commit"

    # Working tree must be clean.
    local wt
    wt=$(git -C "$work" status --porcelain 2>/dev/null)
    [ -z "$wt" ] || fail "conflict: working tree must be clean, got: $wt"

    pass "conflicting merge aborts and leaves the repo unchanged"
}

# --- test (d): idempotence skip ---------------------------------------------

test_idempotence_skip() {
    local tmp work state fakebin1 fakebin2 out1 rc1 out2 rc2
    tmp=$(make_test_dir idem)
    work=$(setup_fork "$tmp")
    state="$work/state"
    mkdir -p "$state"
    fakebin1=$(fm_fakebin "$tmp")
    fakebin2=$(fm_fakebin "$tmp/idem2")
    make_fake_gh_axi "$fakebin1" "$tmp/gh-axi.log"
    make_fake_gh_axi "$fakebin2" "$tmp/gh-axi2.log"

    add_commit_to "$work" origin "origin fork" "origin.txt" "origin content"
    add_upstream_commit "$tmp" "upstream commit" "upstream.txt" "upstream content"

    # First run: creates branch and PR.
    set +e
    out1=$(run_sync "$work" "$fakebin1")
    rc1=$?
    set -e
    expect_code 0 "$rc1" "idempotence: first run must exit 0"
    assert_contains "$out1" "Created PR" "idempotence: first run must report PR creation"
    assert_grep "pr create" "$tmp/gh-axi.log" "idempotence: first run must call gh-axi"

    [ "$(count_remote_sync_branches "$work")" = "1" ] \
        || fail "idempotence: first run should create 1 branch, got $(count_remote_sync_branches "$work")"

    # Second run: should skip silently.
    set +e
    out2=$(run_sync "$work" "$fakebin2")
    rc2=$?
    set -e
    expect_code 0 "$rc2" "idempotence: second run must exit 0"
    [ -z "$out2" ] || fail "idempotence: second run must exit silently, got: $out2"

    [ "$(count_remote_sync_branches "$work")" = "1" ] \
        || fail "idempotence: must not create second branch, got $(count_remote_sync_branches "$work")"

    [ ! -s "$tmp/gh-axi2.log" ] || fail "idempotence: second run must not call gh-axi: $(cat "$tmp/gh-axi2.log")"

    pass "idempotence: running twice does not create a second branch or PR"
}

test_no_new_commits_exits_silently
test_clean_merge_creates_branch_and_pr
test_conflicting_merge_aborts
test_idempotence_skip
