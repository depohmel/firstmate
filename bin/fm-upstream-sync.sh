#!/usr/bin/env bash
# bin/fm-upstream-sync.sh
#
# Automatic upstream sync for the firstmate repo.
#
# Fetches upstream/main; if it has advanced since the last sync, creates a
# branch from origin/main, merges upstream/main into it, and on a clean merge
# pushes the branch and opens a PR against main. On a conflicting merge, aborts
# the merge, deletes the branch, and leaves the repo exactly as found.
#
# Idempotent: the last synced upstream/main SHA is recorded under state/
# (state/upstream-sync-last-sha); if upstream/main hasn't advanced, exits 0
# silently.
#
# NEVER: merges to main directly, force-pushes, stashes, rebases, or discards
# local work. The captain reviews and merges the PR.
#
# Recommended cron (daily, run from the firstmate repo root):
#   0 3 * * * cd /path/to/firstmate && bin/fm-upstream-sync.sh >> state/upstream-sync.log 2>&1
#
# Usage: bin/fm-upstream-sync.sh [--help]
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LAST_SHA_FILE="$STATE/upstream-sync-last-sha"

usage() {
    echo "usage: fm-upstream-sync.sh [--help]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
    usage
    echo "
Fetches upstream and, if upstream/main has advanced since the last sync, creates
a branch from origin/main, merges upstream/main into it, and on a clean merge
pushes the branch and opens a PR against main. On conflict, aborts and leaves
the repo untouched.

Idempotent: the last synced upstream/main SHA is recorded in:
  $LAST_SHA_FILE

Recommended cron (daily, run from the firstmate repo root):
  0 3 * * * cd /path/to/firstmate && bin/fm-upstream-sync.sh >> state/upstream-sync.log 2>&1
"
    exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

"$FM_ROOT/bin/fm-guard.sh" || true

# --- preflight -------------------------------------------------------------

if ! git -C "$FM_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "error: $FM_ROOT is not a git repository" >&2
    exit 1
fi

if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
    echo "error: 'upstream' remote is not configured in $FM_ROOT" >&2
    exit 1
fi

mkdir -p "$STATE"

# --- step 1: fetch upstream ------------------------------------------------

git -C "$FM_ROOT" fetch upstream >/dev/null 2>&1 || {
    echo "error: git fetch upstream failed" >&2
    exit 1
}

# --- step 2: check if upstream/main advanced -------------------------------

if ! git -C "$FM_ROOT" rev-parse --verify upstream/main >/dev/null 2>&1; then
    echo "error: upstream/main does not exist after fetch" >&2
    exit 1
fi

UPSTREAM_HEAD=$(git -C "$FM_ROOT" rev-parse upstream/main)
LAST_SHA=$(cat "$LAST_SHA_FILE" 2>/dev/null || true)

if [ "$UPSTREAM_HEAD" = "$LAST_SHA" ]; then
    # Nothing new since last run - exit silently.
    exit 0
fi

# --- step 3: record original state, create branch from origin/main ----------

ORIGINAL_REF=$(git -C "$FM_ROOT" symbolic-ref --quiet --short HEAD 2>/dev/null \
    || git -C "$FM_ROOT" rev-parse HEAD)

TIMESTAMP=$(date -u +%Y%m%dT%H%M%SZ)
SYNC_BRANCH="fm/upstream-sync-${TIMESTAMP}"

if ! git -C "$FM_ROOT" branch "$SYNC_BRANCH" origin/main 2>/dev/null; then
    echo "error: could not create branch $SYNC_BRANCH from origin/main" >&2
    exit 1
fi
if ! git -C "$FM_ROOT" checkout "$SYNC_BRANCH" >/dev/null 2>&1; then
    echo "error: could not checkout $SYNC_BRANCH" >&2
    git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true
    exit 1
fi

# --- step 4: merge upstream/main --------------------------------------------

set +e
git -C "$FM_ROOT" merge --no-edit upstream/main
MERGE_RC=$?
set -e

if [ "$MERGE_RC" -ne 0 ]; then
    # Conflict! Capture conflicting paths before aborting.
    CONFLICTS=$(git -C "$FM_ROOT" diff --name-only --diff-filter=U 2>/dev/null || true)

    # Abort merge, return to original state, delete branch. Leave repo as found.
    git -C "$FM_ROOT" merge --abort 2>/dev/null || true
    git -C "$FM_ROOT" checkout "$ORIGINAL_REF" 2>/dev/null || true
    git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true

    # Report conflicts loudly on stdout (cron mail + log).
    echo "CONFLICT: upstream/main merge has conflicts."
    echo "Conflicting paths:"
    if [ -n "$CONFLICTS" ]; then
        printf '%s\n' "$CONFLICTS"
    else
        echo "(could not determine conflicting paths)"
    fi
    echo "The repository has been left exactly as found."
    exit 1
fi

# --- step 5: clean merge - count commits, push, open PR --------------------

COMMIT_COUNT=$(git -C "$FM_ROOT" rev-list --count origin/main..upstream/main)
COMMIT_LOG=$(git -C "$FM_ROOT" log --oneline origin/main..upstream/main)

# Push the branch to origin. Never force.
if ! git -C "$FM_ROOT" push origin "$SYNC_BRANCH" 2>&1; then
    echo "error: git push of $SYNC_BRANCH failed" >&2
    git -C "$FM_ROOT" checkout "$ORIGINAL_REF" 2>/dev/null || true
    git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true
    exit 1
fi

# Build PR body.
BODY=$(printf '%s\n' \
    "Automatic sync of upstream/main into firstmate." \
    "" \
    "${COMMIT_COUNT} commit(s) merged from upstream/main:" \
    "" \
    '```' \
    "${COMMIT_LOG}" \
    '```' \
    "" \
    "This PR is created by \`bin/fm-upstream-sync.sh\`. The captain reviews and merges.")

PR_TITLE="Sync upstream/main (${COMMIT_COUNT} commits)"

# Parse owner/repo from origin remote for explicit -R.
REPO=""
origin_url=$(git -C "$FM_ROOT" remote get-url origin 2>/dev/null || true)
case "$origin_url" in
    git@github.com:*) path="${origin_url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${origin_url#ssh://git@github.com/}" ;;
    https://github.com/*) path="${origin_url#https://github.com/}" ;;
    http://github.com/*) path="${origin_url#http://github.com/}" ;;
    *) path="" ;;
esac
if [ -n "$path" ]; then
    path="${path%.git}"
    case "$path" in
        */*) REPO="$path" ;;
    esac
fi

# Open the PR. Run from the repo root so gh-axi detects the repo.
if [ -n "$REPO" ]; then
    if ! ( cd "$FM_ROOT" && gh-axi pr create \
        --title "$PR_TITLE" \
        --head "$SYNC_BRANCH" \
        --base main \
        --body "$BODY" \
        -R "$REPO" ); then
        echo "warning: gh-axi pr create failed - branch was pushed but PR was not opened" >&2
        printf '%s\n' "$UPSTREAM_HEAD" > "$LAST_SHA_FILE"
        git -C "$FM_ROOT" checkout "$ORIGINAL_REF" 2>/dev/null || true
        git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true
        exit 1
    fi
else
    if ! ( cd "$FM_ROOT" && gh-axi pr create \
        --title "$PR_TITLE" \
        --head "$SYNC_BRANCH" \
        --base main \
        --body "$BODY" ); then
        echo "warning: gh-axi pr create failed - branch was pushed but PR was not opened" >&2
        printf '%s\n' "$UPSTREAM_HEAD" > "$LAST_SHA_FILE"
        git -C "$FM_ROOT" checkout "$ORIGINAL_REF" 2>/dev/null || true
        git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true
        exit 1
    fi
fi

# Record the synced upstream SHA for idempotency.
printf '%s\n' "$UPSTREAM_HEAD" > "$LAST_SHA_FILE"

# Return to original branch and delete the sync branch locally.
# The branch remains on the remote (pushed above) for the PR.
git -C "$FM_ROOT" checkout "$ORIGINAL_REF" >/dev/null 2>&1 || true
git -C "$FM_ROOT" branch -D "$SYNC_BRANCH" 2>/dev/null || true

echo "Created PR: $PR_TITLE ($SYNC_BRANCH, $COMMIT_COUNT commits from upstream/main)" >&2
exit 0
