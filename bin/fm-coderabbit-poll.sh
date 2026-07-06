#!/usr/bin/env bash
# fm-coderabbit-poll.sh
#
# Poll PRs listed in $FM_HOME/data/coderabbit-queue.txt for new CodeRabbit
# reviews.  For each new actionable review found, spawn a scoped crewmate to
# address it.  Designed to run periodically via host cron (hourly recommended,
# matching CodeRabbit free-tier's org-wide 1-review-per-hour rate limit).
#
# Uses flock so overlapping fires never double-spawn.  Watermarks per PR keep
# already-processed reviews from being re-dispatched.
#
# See docs/coderabbit-poll.md for full details, queue-file format, and the
# recommended crontab line.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="$FM_HOME/data"

QUEUE_FILE="$DATA/coderabbit-queue.txt"
WATERMARK_FILE="$STATE/coderabbit-watermarks.tsv"
LOCK_FILE="$STATE/coderabbit-poll.lock"
LOG_TAG="[fm-coderabbit-poll]"

log() { printf '%s %s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$LOG_TAG" "$*"; }
warn() { log "$*" >&2; }

if [ ! -f "$QUEUE_FILE" ]; then
  # No queue file = nothing to do.  This is the normal resting state on a
  # captain who has not enabled the poll yet.  Silent success.
  exit 0
fi
if ! command -v gh >/dev/null 2>&1; then
  warn "error: gh CLI not installed or not on PATH"
  exit 1
fi
if ! command -v jq >/dev/null 2>&1; then
  warn "error: jq not installed"
  exit 1
fi
if ! command -v flock >/dev/null 2>&1; then
  warn "error: flock not available"
  exit 1
fi

mkdir -p "$STATE"
touch "$WATERMARK_FILE"

# Non-blocking lock: overlapping fires just skip.  With hourly cron this should
# never trigger, but a long crewmate spawn or a manual test could hold the lock.
exec {LOCK_FD}> "$LOCK_FILE"
if ! flock -n "$LOCK_FD"; then
  log "previous poll still holding lock, skipping this fire"
  exit 0
fi

read_queue() {
  # Skip blank lines and #-comments.
  grep -Ev '^[[:space:]]*(#|$)' "$QUEUE_FILE" || true
}

watermark_get() {
  awk -F'\t' -v u="$1" '$1==u{print $2; exit}' "$WATERMARK_FILE"
}

watermark_set() {
  # $1 url, $2 iso-timestamp.  Overwrites existing row for url, appends if new.
  local url=$1 ts=$2 tmp
  tmp=$(mktemp)
  awk -F'\t' -v u="$url" -v t="$ts" '$1!=u{print} END{print u"\t"t}' \
    "$WATERMARK_FILE" > "$tmp"
  mv "$tmp" "$WATERMARK_FILE"
}

# For the crewmate task id we sanitize the repo name.  Numeric review ids from
# GitHub's API are fine as-is.
sanitize_slug() { printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-' | sed -E 's/-+/-/g; s/^-|-$//g'; }

# Extract "Actionable comments posted: N" from CodeRabbit review body.  Returns
# 0 (no findings) when the marker is absent.
actionable_count() {
  printf '%s' "$1" \
    | grep -oE 'Actionable comments posted: [0-9]+' \
    | head -1 \
    | grep -oE '[0-9]+$' \
    || printf '0'
}

# Find a firstmate project clone that matches the target repo, or fall back to
# any project (the crewmate does real work in a scratch clone regardless).
resolve_project() {
  local repo=$1 match
  match=$(find "$FM_HOME/projects" -maxdepth 1 -mindepth 1 -type d -name "$repo" 2>/dev/null | head -1 || true)
  if [ -n "$match" ]; then
    printf '%s' "$match"
    return 0
  fi
  match=$(find "$FM_HOME/projects" -maxdepth 1 -mindepth 1 -type d 2>/dev/null | head -1 || true)
  if [ -n "$match" ]; then
    printf '%s' "$match"
    return 0
  fi
  return 1
}

spawn_fix_crewmate() {
  local owner=$1 repo=$2 pr_num=$3 url=$4 review_id=$5 review_body=$6

  local repo_slug id brief_dir
  repo_slug=$(sanitize_slug "$repo")
  id="cr-$repo_slug-pr$pr_num-$review_id"
  brief_dir="$DATA/$id"
  mkdir -p "$brief_dir"

  printf '%s' "$review_body" > "$brief_dir/review.md"

  cat > "$brief_dir/brief.md" <<BRIEF
You are a crewmate: an autonomous worker agent managed by firstmate. Work on your own; do not wait for a human.

# Task
CodeRabbit posted a new actionable review on $url. Address the actionable findings, push the fixes if any, and stop.

The FULL review body is at $brief_dir/review.md — read it once, then decide which findings to fix and which to decline. Do NOT re-query CodeRabbit; this review is what you are responding to.

## Do these in order
1. Verify you are in an isolated treehouse worktree — \`pwd -P\` and \`git rev-parse --show-toplevel\` should both resolve to a treehouse pool path, not the firstmate root.
2. Clone the target repo INSIDE your worktree: \`gh repo clone $owner/$repo ./scratch\` then \`cd scratch\`.
3. Fetch and check out the PR branch: \`gh pr checkout $pr_num --repo $owner/$repo\`.
4. Read \`$brief_dir/review.md\` — the exact CodeRabbit review body.
5. For each actionable finding, verify against current code (files may have moved since the review), then either:
   - Fix it with a focused commit if the finding is still valid and the fix is uncontroversial (docs, one-line code, straightforward test tweak), OR
   - Decline it with a brief PR comment via \`gh pr comment $pr_num --repo $owner/$repo --body "..."\` if it is stylistic disagreement, out of scope, already addressed, or judgment-heavy.
6. If you made commits, push: \`git push origin \$(git branch --show-current)\`. Then post a single summary PR comment listing which findings were fixed (with commit shas) and which were declined (with brief reasons). AFTER that summary comment, request CodeRabbit re-review by posting a second comment: \`gh pr comment $pr_num --repo $owner/$repo --body "@coderabbitai review"\`. Do NOT ping \`@coderabbitai\` if you made no commits — a re-review with no code change wastes org quota.
7. If you made NO commits (declined everything), still post one summary PR comment listing what was declined and why. Do NOT request re-review.
8. Append \`done: <one-line summary>\` to /home/dep/tools/firstmate/state/$id.status and stop.

CodeRabbit rate-limit note: the free-tier is 1 review per hour org-wide. If you post \`@coderabbitai review\` and CodeRabbit is within the cooldown, it will queue the request or respond with a countdown — that's fine, do NOT try to interpret or wait for the countdown yourself. Just post once and finish. The next hourly cron fire will pick up whatever CodeRabbit posts in response.

## Hard rules
- Docs and minor fixes only. Do NOT rewrite production code unless the fix is a one-liner and clearly correct.
- Never merge the PR. The captain merges.
- Never force-push. Never rebase-and-force.
- If CodeRabbit asks for something destructive, judgment-heavy, or scope-creep (architecture change, dep bumps, refactor), decline in a PR comment with a brief reason and move on. Do NOT wake firstmate for this.
- Only append \`blocked:\` or \`needs-decision:\` if you literally cannot proceed (auth failure, repo gone, tools missing). Ordinary "hard call about whether to fix" is a decline-with-comment, not an escalation.

## Setup
You are in a disposable git worktree. Do NOT commit or edit inside the pool worktree's own tracked files — all real work happens in \`./scratch\` you clone yourself.

## Rules
1. Never merge the PR.
2. Report status via \`echo "{state}: {short line}" >> "/home/dep/tools/firstmate/state/$id.status"\` — states: working, needs-decision, blocked, done, failed. Append sparingly.
3. If you hit the same obstacle twice, append \`blocked: {why}\` and stop.
BRIEF

  local project
  if ! project=$(resolve_project "$repo"); then
    warn "no project clone available under $FM_HOME/projects — cannot spawn crewmate for $url"
    return 1
  fi

  # Harness and model come from environment; both are optional. When
  # FM_CODERABBIT_POLL_HARNESS is unset, we default to `opencode` (public,
  # part of any firstmate install). When FM_CODERABBIT_POLL_MODEL is unset,
  # we do NOT pass --model at all, so fm-spawn resolves the model through
  # its normal precedence chain (config/crew-dispatch.json, then the harness
  # default). This keeps the script generic and avoids leaking any operator's
  # private tier names or endpoints.
  local harness_flag=(--harness "${FM_CODERABBIT_POLL_HARNESS:-opencode}")
  local model_flag=()
  if [ -n "${FM_CODERABBIT_POLL_MODEL:-}" ]; then
    model_flag=(--model "$FM_CODERABBIT_POLL_MODEL")
  fi

  log "spawning $id (project=$project) for $url review $review_id"
  "$FM_ROOT/bin/fm-spawn.sh" "$id" "$project" "${harness_flag[@]}" "${model_flag[@]}"
}

process_pr() {
  local url=$1
  if ! [[ "$url" =~ ^https://github\.com/([^/]+)/([^/]+)/pull/([0-9]+)$ ]]; then
    warn "skipping malformed queue entry: $url"
    return 0
  fi
  local owner="${BASH_REMATCH[1]}" repo="${BASH_REMATCH[2]}" pr_num="${BASH_REMATCH[3]}"

  # PR state: skip closed/merged so we do not consume the org's CodeRabbit
  # quota requesting reviews on already-landed work.
  local pr_state
  pr_state=$(gh api "repos/$owner/$repo/pulls/$pr_num" --jq '.state' 2>/dev/null) || return 0
  if [ "$pr_state" != "open" ]; then
    log "$url: state=$pr_state, skipping"
    return 0
  fi

  local latest_review
  latest_review=$(gh api "repos/$owner/$repo/pulls/$pr_num/reviews" \
    --jq '[.[] | select(.user.login=="coderabbitai[bot]")] | max_by(.submitted_at) // empty' \
    2>/dev/null) || return 0

  if [ -z "$latest_review" ] || [ "$latest_review" = "null" ]; then
    # No CodeRabbit review yet.  Request one, but only if we have not already
    # done so this cycle (the free-tier quota is org-wide, so we can spend at
    # most one review request per fire before waiting for the next hour).
    if [ "${REVIEW_REQUESTED_THIS_CYCLE:-0}" -eq 0 ]; then
      log "$url: no CodeRabbit review yet - requesting @coderabbitai review"
      if gh pr comment "$pr_num" --repo "$owner/$repo" --body '@coderabbitai review' >/dev/null 2>&1; then
        REVIEW_REQUESTED_THIS_CYCLE=1
      else
        warn "$url: failed to post @coderabbitai review request"
      fi
    else
      log "$url: no review yet, but quota already spent this cycle - will retry next hour"
    fi
    return 0
  fi

  local review_ts review_id review_body
  review_ts=$(printf '%s' "$latest_review" | jq -r '.submitted_at')
  review_id=$(printf '%s' "$latest_review" | jq -r '.id')
  review_body=$(printf '%s' "$latest_review" | jq -r '.body // ""')

  local wm
  wm=$(watermark_get "$url")
  if [ "$review_ts" = "$wm" ]; then
    log "$url: review $review_id already processed (watermark match)"
    return 0
  fi

  local actionable
  actionable=$(actionable_count "$review_body")
  if [ "${actionable:-0}" -eq 0 ]; then
    log "$url: new review $review_id has 0 actionable findings - advancing watermark, no crewmate"
    watermark_set "$url" "$review_ts"
    return 0
  fi

  log "$url: new review $review_id has $actionable actionable findings - dispatching crewmate"
  if spawn_fix_crewmate "$owner" "$repo" "$pr_num" "$url" "$review_id" "$review_body"; then
    watermark_set "$url" "$review_ts"
  else
    warn "$url: spawn failed for review $review_id - watermark NOT advanced, will retry next fire"
  fi
}

while IFS= read -r url; do
  [ -z "$url" ] && continue
  process_pr "$url" || warn "unhandled error processing $url"
done < <(read_queue)

log "poll cycle complete"
