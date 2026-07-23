#!/usr/bin/env bash
# Sync the primary firstmate checkout's default branch with upstream via the
# fork model.
# Fetches from upstream, attempts a clean merge of upstream/<default> into
# <default>, and pushes to origin/<default> only on a clean result.
# Replaces the interim crontab entry "15 6 * * * fetch+log divergence".
#
# Safety:
#   - Refuses to run outside the primary checkout (linked worktrees are not
#     the live checkout).
#   - Refuses if the working tree is dirty or not on the default branch.
#   - On a merge conflict, always runs git merge --abort so the checkout is
#     never left conflicted/dirty.
#   - If a clean merge would modify bin/ or AGENTS.md while crews are in
#     flight (any state/*.meta exists), it resets the merge and defers - so
#     bin/AGENTS.md is never changed unattended under running crews.
#   - Pushes to origin/<default> only after a clean, safe merge.
#
# Usage: fm-upstream-sync.sh [--help]
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
LOG="${STATE}/upstream-sync.log"

"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-upstream-sync.sh [--help]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -eq 0 ] || { usage; exit 1; }

# --- helpers ---------------------------------------------------------------

# Resolve the default branch name of the repo at FM_ROOT.
default_branch() {
  local ref branch
  ref=$(git -C "$FM_ROOT" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$FM_ROOT" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

# True when FM_ROOT is the primary (main) worktree, not a linked worktree.
is_primary_worktree() {
  local git_dir git_common_dir
  git_dir=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-dir 2>/dev/null || true)
  git_common_dir=$(git -C "$FM_ROOT" rev-parse --path-format=absolute --git-common-dir 2>/dev/null || true)
  [ -n "$git_dir" ] && [ "$git_dir" = "$git_common_dir" ]
}

# True when any state/*.meta file exists (crews in flight).
crews_in_flight() {
  [ -d "$STATE" ] || return 1
  local meta
  for meta in "$STATE"/*.meta; do
    [ -f "$meta" ] || continue
    return 0
  done
  return 1
}

# Log a timestamped line to the summary log and echo it to stdout.
log_line() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date)
  printf '%s %s\n' "$ts" "$1" | tee -a "$LOG"
}

# Append a raw output block to the summary log.
log_output() {
  [ -n "$1" ] || return 0
  printf '%s\n' "$1" >> "$LOG"
}

# --- main ------------------------------------------------------------------

main() {
  mkdir -p "$STATE" 2>/dev/null || true

  # Refuse unless we are in the primary checkout.
  if ! is_primary_worktree; then
    log_line "refused: not in the primary checkout (linked worktree)"
    return 1
  fi

  # Validate remotes.
  if ! git -C "$FM_ROOT" remote get-url upstream >/dev/null 2>&1; then
    log_line "refused: no upstream remote"
    return 1
  fi
  if ! git -C "$FM_ROOT" remote get-url origin >/dev/null 2>&1; then
    log_line "refused: no origin remote"
    return 1
  fi

  DEFAULT=$(default_branch) || {
    log_line "refused: cannot determine default branch"
    return 1
  }

  # Must be on the default branch.
  cur=$(git -C "$FM_ROOT" symbolic-ref --short HEAD 2>/dev/null || echo "")
  if [ -z "$cur" ] || [ "$cur" != "$DEFAULT" ]; then
    log_line "refused: on ${cur:-detached HEAD}, expected $DEFAULT"
    return 1
  fi

  # Working tree must be clean.
  if [ -n "$(git -C "$FM_ROOT" status --porcelain 2>/dev/null | head -1)" ]; then
    log_line "refused: dirty working tree"
    return 1
  fi

  # Fetch upstream.
  local fetch_out
  if ! fetch_out=$(git -C "$FM_ROOT" fetch upstream --prune 2>&1); then
    log_output "$fetch_out"
    log_line "failed: upstream fetch failed"
    return 1
  fi

  # Bail out if upstream/$DEFAULT does not exist after fetch.
  if ! git -C "$FM_ROOT" rev-parse --verify --quiet "upstream/$DEFAULT^{commit}" >/dev/null 2>&1; then
    log_line "skipped: upstream/$DEFAULT does not exist"
    return 0
  fi

  # Already current - no new commits to merge.
  if [ "$(git -C "$FM_ROOT" rev-parse HEAD)" = "$(git -C "$FM_ROOT" rev-parse "upstream/$DEFAULT")" ]; then
    log_line "already current: $DEFAULT at $(git -C "$FM_ROOT" rev-parse --short HEAD)"
    return 0
  fi

  # Attempt the clean merge.
  local merge_out
  if ! merge_out=$(git -C "$FM_ROOT" merge --no-edit "upstream/$DEFAULT" 2>&1); then
    # Conflict: abort and notify.
    # Never leave the checkout conflicted/dirty.
    log_output "$merge_out"
    git -C "$FM_ROOT" merge --abort 2>/dev/null || true
    log_line "conflict: aborted, needs attention"
    return 1
  fi

  log_output "$merge_out"

  # Clean merge succeeded.
  # Safety: if the merge touched bin/ or AGENTS.md while crews are in flight,
  # reset the merge and defer.
  # bin/AGENTS.md is the instruction surface that running crews read.
  local instr_changed
  instr_changed=$(git -C "$FM_ROOT" diff --name-only "HEAD@{1}" HEAD -- bin/ AGENTS.md 2>/dev/null || true)
  if [ -n "$instr_changed" ]; then
    if crews_in_flight; then
      git -C "$FM_ROOT" reset --hard "HEAD@{1}" 2>/dev/null || true
      log_line "deferred: instruction-surface change while crews in flight"
      return 0
    fi
  fi

  # Safe clean merge: push to origin.
  local push_out
  if ! push_out=$(git -C "$FM_ROOT" push origin "$DEFAULT" 2>&1); then
    log_output "$push_out"
    log_line "failed: push to origin/$DEFAULT failed"
    return 1
  fi
  log_output "$push_out"
  log_line "pushed: origin/$DEFAULT at $(git -C "$FM_ROOT" rev-parse --short "$DEFAULT")"
  return 0
}

main
