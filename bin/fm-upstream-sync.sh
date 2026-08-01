#!/usr/bin/env bash
# bin/fm-upstream-sync.sh - sync this repo's main from upstream.
#
# Fetch upstream, fast-forward main to upstream/main when clean, push to
# origin/main only on a clean result, and log a summary. On conflict abort
# the merge, restore the previous main, and notify - never leave the live
# checkout in a conflicted or dirty state.
#
# Designed for the fork model where upstream=kunchenguid/firstmate.git and
# origin=depohmel/firstmate.git.
#
# Usage: fm-upstream-sync.sh [--dry-run] [--force-dirty]
#   --dry-run      fetch and check whether a clean merge is possible without
#                  modifying main; exit 0 when clean, 1 when conflicts.
#   --force-dirty  allow the operation when the working tree has uncommitted
#                  changes; use with extreme caution - intended for scripted
#                  use (crontab replacement) where the script runs in its own
#                  isolated worktree.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

usage() {
  echo "usage: fm-upstream-sync.sh [--dry-run] [--force-dirty]" >&2
}

DRY_RUN=no
FORCE_DIRTY=no

while [ $# -gt 0 ]; do
  case "$1" in
    --dry-run)  DRY_RUN=yes   ;;
    --force-dirty) FORCE_DIRTY=yes ;;
    --help|-h)  usage; exit 0 ;;
    *) echo "unknown option: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

# --- helpers ----------------------------------------------------------------

DEFAULT="main"
LOG_FILE="${FM_UPSTREAM_LOG:-/home/dep/.cache/fm-upstream-sync.log}"
LOG_DIR="$(dirname "$LOG_FILE")"
LOCK_FILE="/tmp/fm-upstream-sync.lock"
LOCK_FD=200

log_msg() {
  local ts
  ts="$(date -u +%Y-%m-%dT%H:%MZ)"
  printf '%s %s\n' "$ts" "$1"
}

# --- lock -------------------------------------------------------------------

acquire_lock() {
  exec 200>"$LOCK_FILE"
  if ! flock -n 200; then
    echo "another instance is running" >&2
    exit 1
  fi
}

release_lock() {
  flock -u 200 2>/dev/null || true
  rm -f "$LOCK_FILE"
}
trap release_lock EXIT

acquire_lock

# --- guard: must be on main ------------------------------------------------

on_branch() {
  git -C "$ROOT" symbolic-ref --short HEAD 2>/dev/null || echo ""
}

current_branch=$(on_branch)
if [ "$current_branch" != "$DEFAULT" ]; then
  echo "not on $DEFAULT (on $current_branch)" >&2
  log_msg "upstream-sync: skipped - not on $DEFAULT (on $current_branch)" >> "$LOG_FILE"
  exit 1
fi

# --- guard: no uncommitted changes unless forced ----------------------------

dirty_check() {
  [ -z "$(git -C "$ROOT" status --porcelain 2>/dev/null | head -1)" ]
}

if ! dirty_check && [ "$FORCE_DIRTY" != yes ]; then
  echo "working tree has uncommitted changes - abort" >&2
  log_msg "upstream-sync: skipped - dirty working tree" >> "$LOG_FILE"
  exit 1
fi

# --- save previous main SHA ------------------------------------------------

before_sha=$(git -C "$ROOT" rev-parse "$DEFAULT")

# --- fetch upstream ---------------------------------------------------------

if ! git -C "$ROOT" fetch --quiet upstream "$DEFAULT" >/dev/null 2>&1; then
  echo "fetch upstream failed" >&2
  log_msg "upstream-sync: fetch upstream failed" >> "$LOG_FILE"
  exit 1
fi

upstream_sha=$(git -C "$ROOT" rev-parse "upstream/$DEFAULT^{commit}" 2>/dev/null) || {
  echo "cannot resolve upstream/$DEFAULT" >&2
  log_msg "upstream-sync: cannot resolve upstream/main" >> "$LOG_FILE"
  exit 1
}

# --- fast-forward check ----------------------------------------------------

ahead_of_upstream=$(git -C "$ROOT" rev-list --count "upstream/$DEFAULT..$DEFAULT" 2>/dev/null) || ahead_of_upstream=0
behind_upstream=$(git -C "$ROOT" rev-list --count "$DEFAULT..upstream/$DEFAULT" 2>/dev/null) || behind_upstream=0

if [ "$behind_upstream" -eq 0 ] && [ "$ahead_of_upstream" -eq 0 ]; then
  # Already at upstream/main - nothing to do.
  echo "already at upstream/$DEFAULT ($upstream_sha)"
  log_msg "upstream-sync: already current at $upstream_sha" >> "$LOG_FILE"
  exit 0
fi

# --- dry-run: just check if merge is clean ---------------------------------

if [ "$DRY_RUN" = yes ]; then
  # Try a merge in a temporary stash-less state: git merge --no-commit would
  # leave a dirty tree on conflict, which we detect and abort.
  if git -C "$ROOT" merge --no-commit --no-ff upstream/"$DEFAULT" >/dev/null 2>&1; then
    git -C "$ROOT" merge --abort >/dev/null 2>&1 || true
    echo "dry-run: clean merge possible (behind by $behind_upstream commits)"
    log_msg "upstream-sync: dry-run clean, behind by $behind_upstream" >> "$LOG_FILE"
    exit 0
  fi
  git -C "$ROOT" merge --abort >/dev/null 2>&1 || true
  echo "dry-run: conflicts detected (behind by $behind_upstream commits)" >&2
  log_msg "upstream-sync: dry-run conflict, behind by $behind_upstream" >> "$LOG_FILE"
  exit 1
fi

# --- fast-forward to upstream/main ------------------------------------------

# Verify upstream/main is an ancestor of current main (pure ff).
if ! git -C "$ROOT" merge-base --is-ancestor "$DEFAULT" "upstream/$DEFAULT" 2>/dev/null; then
  # Not a fast-forward. Fall back to a non-ff merge with conflict handling.
  :
else
  # Pure fast-forward: just move main forward.
  if ! git -C "$ROOT" update-ref refs/heads/"$DEFAULT" "upstream/$DEFAULT"; then
    echo "fast-forward update-ref failed" >&2
    log_msg "upstream-sync: fast-forward update-ref failed" >> "$LOG_FILE"
    exit 1
  fi
  after_sha=$(git -C "$ROOT" rev-parse "$DEFAULT")
  echo "fast-forwarded $before_sha..$after_sha"
  log_msg "upstream-sync: fast-forward $before_sha..$after_sha ($behind_upstream commits)" >> "$LOG_FILE"
  exit 0
fi

# Non-fast-forward: attempt merge. On conflict abort and notify.
if ! git -C "$ROOT" merge --no-edit upstream/"$DEFAULT" 2>/dev/null; then
  # Merge conflict - abort and restore.
  git -C "$ROOT" merge --abort >/dev/null 2>&1 || true
  # Restore main to where it was.
  git -C "$ROOT" reset --hard "$before_sha" >/dev/null 2>&1 || true
  echo "merge conflict - aborting, main restored to $before_sha" >&2
  log_msg "upstream-sync: CONFLICT - abort, main restored to $before_sha, upstream behind by $behind_upstream" >> "$LOG_FILE"
  exit 1
fi

# --- push to origin/main ----------------------------------------------------

after_sha=$(git -C "$ROOT" rev-parse "$DEFAULT")
if [ "$before_sha" != "$after_sha" ]; then
  # Only push when main actually advanced.
  if ! git -C "$ROOT" push origin "$DEFAULT" 2>/dev/null; then
    echo "push to origin failed (main advanced to $after_sha)" >&2
    log_msg "upstream-sync: main advanced to $after_sha but push to origin failed" >> "$LOG_FILE"
    exit 1
  fi
  echo "merged $before_sha..$after_sha, pushed to origin/$DEFAULT"
  log_msg "upstream-sync: merged $before_sha..$after_sha ($behind_upstream commits), pushed to origin/$DEFAULT" >> "$LOG_FILE"
else
  echo "main already at upstream/$DEFAULT ($after_sha)"
  log_msg "upstream-sync: no-op, already at $after_sha" >> "$LOG_FILE"
fi

exit 0
