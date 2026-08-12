#!/usr/bin/env bash
# bin/fm-bosun.sh - Scheduled supervisory chores for firstmate.
#
# Performs routine supervisory checks WITHOUT needing a firstmate LLM turn.
# Designed to run every 5-10 minutes via a scheduler (see docs/fm-bosun.md).
#
# Hard safety boundaries:
#   - NEVER merges, approves, dispatches, tears down, or force-pushes.
#   - NEVER touches anything under projects/ beyond reading.
#   - Steers ONLY from a fixed repertoire: commit, push, re-read PR comments.
#
# Usage: fm-bosun.sh
# Environment:
#   FM_HOME                    firstmate home (defaults to repo root)
#   FM_BOSUN_DRY_RUN           1 to log without sending (default 0)
#   FM_BOSUN_COMMIT_AGE_SECS   uncommitted-work age threshold (default 900)
#   FM_BOSUN_PUSH_AGE_SECS     unpushed-commits age threshold (default 900)
#   FM_BOSUN_PARKED_AGE_SECS   parked-work initial threshold (default 3600)
#   FM_BOSUN_PARKED_BACKOFF_BASE  initial re-escalation backoff (default 600)
#   FM_BOSUN_PARKED_BACKOFF_MAX  max re-escalation backoff (default 86400)
#   FM_BOSUN_STEER_INTERVAL    rate cap for steers in seconds (default 600)
#   FM_BOSUN_LOG_MAX_BYTES     log rotation threshold (default 1048576)
#   FM_BOSUN_STALL_SECS        stalled run-step quiet threshold (default 1800)
#   FM_BOSUN_NPROGRESS_SECS    no-progress worktree-stale threshold (default 1800)
#   FM_BOSUN_NM_TIMEOUT        no-mistakes cli call timeout in seconds (default 10)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

: "${FM_BOSUN_DRY_RUN:=0}"
: "${FM_BOSUN_COMMIT_AGE_SECS:=900}"
: "${FM_BOSUN_PUSH_AGE_SECS:=900}"
: "${FM_BOSUN_PARKED_AGE_SECS:=3600}"
: "${FM_BOSUN_PARKED_BACKOFF_BASE:=600}"
: "${FM_BOSUN_PARKED_BACKOFF_MAX:=86400}"
: "${FM_BOSUN_STEER_INTERVAL:=600}"
: "${FM_BOSUN_LOG_MAX_BYTES:=1048576}"
: "${FM_BOSUN_STALL_SECS:=1800}"
: "${FM_BOSUN_NPROGRESS_SECS:=1800}"
: "${FM_BOSUN_NM_TIMEOUT:=10}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"

BOSUN_LOCK="$STATE/.bosun.lock"
BOSUN_LOG="$STATE/.bosun.log"
BOSUN_STATE_DIR="$STATE/.bosun-state"

mkdir -p "$BOSUN_STATE_DIR" 2>/dev/null || true

# --- Singleton lock: exit 0 quietly if another instance holds it. ---
if ! fm_lock_try_acquire "$BOSUN_LOCK"; then
  exit 0
fi
trap 'fm_lock_release "$BOSUN_LOCK" 2>/dev/null || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# --- Bounded action log (survives across runs, rotated on size) ---
bosun_log() {
  printf '%s\t%s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" >> "$BOSUN_LOG" 2>/dev/null || true
}

bosun_trim_log() {
  [ -f "$BOSUN_LOG" ] || return 0
  local size
  size=$(wc -c < "$BOSUN_LOG" 2>/dev/null | tr -d '[:space:]') || return 0
  case "$size" in ''|*[!0-9]*) return 0 ;; esac
  [ "$size" -lt "$FM_BOSUN_LOG_MAX_BYTES" ] && return 0
  tail -1000 "$BOSUN_LOG" > "${BOSUN_LOG}.tmp" 2>/dev/null \
    && mv "${BOSUN_LOG}.tmp" "$BOSUN_LOG" 2>/dev/null || true
}

# --- Per-task state: mtime of state/<id>.<key> is the "since" timestamp ---
bosun_state_age() {  # <id> <key> -> seconds since the state file's mtime
  fm_path_age "$BOSUN_STATE_DIR/$1.$2"
}

bosun_state_set() {  # <id> <key> <value>
  printf '%s\n' "$3" > "$BOSUN_STATE_DIR/$1.$2" 2>/dev/null || true
}

# --- Fixed steer repertoire (never content-specific) ---
# shellcheck disable=SC2034  # used by check_* functions
STEER_COMMIT='Commit your uncommitted changes so they are safe while you continue.'
# shellcheck disable=SC2034  # used by check_* functions
STEER_PUSH='Push your unpushed commits upstream so they are backed up.'
# shellcheck disable=SC2034  # used by check_* functions
STEER_REREAD_PR='New reviewer activity on your PR is older than the current head - re-read the PR comments.'

# --- Steer dispatcher: rate-capped, dry-run aware ---
bosun_send_steer() {  # <id> <action-key> <steer-text>
  if ! [ "$(bosun_state_age "$1" "$2")" -ge "$FM_BOSUN_STEER_INTERVAL" ]; then
    bosun_log "steer:$1:$2:rate-capped"
    return 0
  fi
  if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
    bosun_log "steer:$1:$2:WOULD-send:$3"
    return 0
  fi
  if FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
    "$SCRIPT_DIR/fm-send.sh" "fm-$1" "$3" >/dev/null 2>&1; then
    bosun_log "steer:$1:$2:sent"
  else
    bosun_log "steer:$1:$2:FAILED"
  fi
  bosun_steer_record "$1" "$2"
}

bosun_steer_record() {  # <id> <action-key>
  bosun_state_set "$1" "$2" "1"
}

# --- Checks (implemented in subsequent commits) ---
check_pr_readiness() {  # <id> <meta>
  local id=$1 meta=$2 pr owner_repo number
  local head_sha head_ts review_ts ts changes_requested verdict

  pr=$(fm_meta_get "$meta" pr) || true
  [ -n "$pr" ] || return 0

  case "$pr" in
    https://github.com/*) : ;;
    *) bosun_log "pr-readiness:$id:skip:non-github-url"; return 0 ;;
  esac

  command -v gh >/dev/null 2>&1 || { bosun_log "pr-readiness:$id:skip:gh-missing"; return 0; }

  # Parse https://github.com/<owner>/<repo>/pull/<number>
  owner_repo=$(printf '%s' "$pr" | sed 's|https://github.com/||; s|/pull/[^/]*$||')
  number=$(printf '%s' "$pr" | sed 's|.*/pull/||')
  case "$number" in ''|*[!0-9]*) bosun_log "pr-readiness:$id:skip:bad-pr-number"; return 0 ;; esac

  # Head commit SHA via gh pr view
  head_sha=$(gh pr view "$pr" --json headRefOid -q .headRefOid 2>/dev/null) || head_sha=""
  [ -n "$head_sha" ] || { bosun_log "pr-readiness:$id:skip:no-head-sha"; return 0; }

  # Head commit timestamp
  head_ts=$(gh api "repos/$owner_repo/commits/$head_sha" --jq '.commit.committer.date' 2>/dev/null) || head_ts=""
  [ -n "$head_ts" ] || { bosun_log "pr-readiness:$id:skip:no-head-ts"; return 0; }

  # Latest reviewer activity: max of review submissions and review comments
  review_ts=""
  for endpoint in \
    "repos/$owner_repo/pulls/$number/reviews" \
    "repos/$owner_repo/pulls/$number/comments" \
    "repos/$owner_repo/issues/$number/comments"
  do
    ts=$(gh api "$endpoint" --jq '[.[] | (.submitted_at // .created_at // empty)] | max // ""' 2>/dev/null) || ts=""
    if [ -n "$ts" ] && { [ -z "$review_ts" ] || [[ "$ts" > "$review_ts" ]]; }; then
      review_ts=$ts
    fi
  done

  # Outstanding findings: changes-requested reviews
  changes_requested=$(gh api "repos/$owner_repo/pulls/$number/reviews" --jq '[.[] | select(.state == "CHANGES_REQUESTED")] | length' 2>/dev/null) || changes_requested=0
  case "$changes_requested" in ''|*[!0-9]*) changes_requested=0 ;; esac

  # Verdict: lexical compare of ISO-8601 UTC timestamps
  if [ -z "$review_ts" ]; then
    verdict="NO-reviews-yet"
  elif [[ "$review_ts" > "$head_ts" ]]; then
    verdict="reviewed-against-current-head"
  elif [[ "$review_ts" < "$head_ts" ]]; then
    verdict="NOT-reviewed-against-current-head"
  else
    verdict="reviewed-at-same-time"
  fi

  # Persistent status trail: report the pair explicitly, never a bare "green"
  bosun_log "pr-readiness:$id:verdict=$verdict review_ts=${review_ts:-none} head_ts=$head_ts changes_requested=$changes_requested"

  # --- Classification of reviewer comment bodies ---
  # This reviewer (famclaw) posts findings as comments on the GitHub issues
  # endpoint and posts NO formal pull-request review when a PR passes.
  # An empty /pulls/<n>/reviews array does NOT mean unreviewed. Collect
  # bodies from all three endpoints and classify into one of:
  #   clean                     non-pointer bodies contain both "No major
  #                             issues detected" and "No code suggestions
  #                             found"
  #   unreviewed                no reviewer comments at all
  #   findings=N                N = count of "Suggestion importance" in
  #                             non-pointer comments
  #   reviewed, verdict unknown only "Persistent review updated" pointer
  #                             comments, no substantive bodies
  # "Pointer" comments contain "Persistent review updated"; they are excluded
  # from the findings count. Clean is checked before findings because a
  # passing PR may have zero "Suggestion importance" occurrences.
  local total_comments=0 has_nonpointer=0 findings classifier
  local nonpointer_text="" endpoint_bodies body
  for endpoint in \
    "repos/$owner_repo/pulls/$number/reviews" \
    "repos/$owner_repo/pulls/$number/comments" \
    "repos/$owner_repo/issues/$number/comments"
  do
    endpoint_bodies=$(gh api "$endpoint" --jq '[.[] | .body // ""] | .[]' 2>/dev/null) || endpoint_bodies=""
    if [ -n "$endpoint_bodies" ]; then
      while IFS= read -r body; do
        [ -z "$body" ] && continue
        total_comments=$((total_comments + 1))
        if [[ "$body" != *"Persistent review updated"* ]]; then
          has_nonpointer=1
          nonpointer_text="${nonpointer_text}${body}"$'\n'
        fi
      done <<< "$endpoint_bodies"
    fi
  done

  findings=$(printf '%s' "$nonpointer_text" | grep -o 'Suggestion importance' 2>/dev/null | wc -l | tr -d '[:space:]')
  case "$findings" in ''|*[!0-9]*) findings=0 ;; esac

  if [ "$total_comments" -eq 0 ]; then
    classifier="unreviewed"
  elif [ "$has_nonpointer" -eq 0 ]; then
    classifier="reviewed, verdict unknown"
  elif [[ "$nonpointer_text" == *"No major issues detected"* && "$nonpointer_text" == *"No code suggestions found"* ]]; then
    classifier="clean"
  else
    classifier="findings=$findings"
  fi

  bosun_log "pr-readiness:$id:reviewer-classification=$classifier total=$total_comments findings=$findings"

  # Steer only when review predates head (rate-capped)
  if [ "$verdict" = "NOT-reviewed-against-current-head" ]; then
    bosun_send_steer "$id" "pr-reread" "$STEER_REREAD_PR"
  fi
}
check_uncommitted_work() {  # <id> <meta>
  local id=$1 meta=$2 wt changes age

  wt=$(fm_meta_get "$meta" worktree) || true
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0

  changes=$(git -C "$wt" status --porcelain 2>/dev/null)
  if [ -z "$changes" ]; then
    # No uncommitted changes; clear the since-marker so a future change
    # starts the timer fresh.
    rm -f "$BOSUN_STATE_DIR/$id.commit-since" 2>/dev/null || true
    return 0
  fi

  # First detection: record and wait for the age threshold
  if [ ! -e "$BOSUN_STATE_DIR/$id.commit-since" ]; then
    bosun_state_set "$id" commit-since "1"
    bosun_log "uncommitted:$id:first-commit-since"
    return 0
  fi

  age=$(bosun_state_age "$id" commit-since)
  if [ "$age" -ge "$FM_BOSUN_COMMIT_AGE_SECS" ]; then
    bosun_send_steer "$id" "commit" "$STEER_COMMIT"
    bosun_log "uncommitted:$id:age=${age}s threshold=$FM_BOSUN_COMMIT_AGE_SECS steer-dispatched"
  else
    bosun_log "uncommitted:$id:age=${age}s threshold=$FM_BOSUN_COMMIT_AGE_SECS waiting"
  fi
}
check_unpushed_commits() {  # <id> <meta>
  local id=$1 meta=$2 wt ahead age

  wt=$(fm_meta_get "$meta" worktree) || true
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0

  # Commits ahead of upstream. HEAD@{upstream} silently returns zero when a
  # branch has no upstream (the common case here, since the pipeline pushes
  # without setting tracking). Instead, ask whether HEAD exists on ANY remote
  # ref: if it does not, there are unpushed commits. This check can actually
  # fail, unlike HEAD@{upstream} which swallows the no-upstream error.
  if git -C "$wt" branch -r --contains HEAD 2>/dev/null | grep -q .; then
    ahead=0
  else
    ahead=1
  fi

  if [ "$ahead" -eq 0 ]; then
    rm -f "$BOSUN_STATE_DIR/$id.push-since" 2>/dev/null || true
    return 0
  fi

  # First detection: record and wait for the age threshold
  if [ ! -e "$BOSUN_STATE_DIR/$id.push-since" ]; then
    bosun_state_set "$id" push-since "1"
    bosun_log "unpushed:$id:first ahead=$ahead"
    return 0
  fi

  age=$(bosun_state_age "$id" push-since)
  if [ "$age" -ge "$FM_BOSUN_PUSH_AGE_SECS" ]; then
    bosun_send_steer "$id" "push" "$STEER_PUSH"
    bosun_log "unpushed:$id:age=${age}s threshold=$FM_BOSUN_PUSH_AGE_SECS ahead=$ahead steer-dispatched"
  else
    bosun_log "unpushed:$id:age=${age}s threshold=$FM_BOSUN_PUSH_AGE_SECS ahead=$ahead waiting"
  fi
}
check_parked_work() {  # <id>
  local id=$1 last_line verb since_age backoff esc_count

  last_line=$(last_status_line "$STATE/$id.status") || last_line=""
  [ -n "$last_line" ] || { _clear_parked_state "$id"; return 0; }

  verb=$(status_line_verb "$last_line")
  case "$verb" in
    blocked|needs-decision) ;;
    *) _clear_parked_state "$id"; return 0 ;;
  esac

  # First detection: record and wait for the initial threshold
  if [ ! -e "$BOSUN_STATE_DIR/$id.parked-since" ]; then
    bosun_state_set "$id" parked-since "1"
    bosun_log "parked:$id:first verb=$verb"
    return 0
  fi

  since_age=$(bosun_state_age "$id" parked-since)
  if [ "$since_age" -lt "$FM_BOSUN_PARKED_AGE_SECS" ]; then
    return 0
  fi

  # Past initial threshold; compute exponential backoff for re-escalation
  esc_count=$(cat "$BOSUN_STATE_DIR/$id.esc-count" 2>/dev/null || echo 0)
  case "$esc_count" in ''|*[!0-9]*) esc_count=0 ;; esac

  backoff=$FM_BOSUN_PARKED_BACKOFF_BASE
  i=0
  while [ "$i" -lt "$esc_count" ] && [ "$backoff" -lt "$FM_BOSUN_PARKED_BACKOFF_MAX" ]; do
    backoff=$((backoff * 2))
    i=$((i + 1))
  done
  [ "$backoff" -gt "$FM_BOSUN_PARKED_BACKOFF_MAX" ] && backoff=$FM_BOSUN_PARKED_BACKOFF_MAX

  # Check backoff since last escalation
  if [ "$(bosun_state_age "$id" esc-last)" -ge "$backoff" ]; then
    if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
      bosun_log "parked:$id:WOULD-escalate verb=$verb age=${since_age}s esc=$((esc_count + 1)) backoff=${backoff}s"
    else
      fm_wake_append "stale" "$id.status" \
        "BOSUN-ESCALATION: parked on ${verb} for ${since_age}s: ${last_line}" 2>/dev/null || true
      bosun_log "parked:$id:escalated verb=$verb age=${since_age}s esc=$((esc_count + 1)) backoff=${backoff}s"
    fi
    bosun_state_set "$id" esc-last "1"
    bosun_state_set "$id" esc-count "$((esc_count + 1))"
  fi
}

_clear_parked_state() {  # <id>
  rm -f "$BOSUN_STATE_DIR/$1.parked-since" "$BOSUN_STATE_DIR/$1.esc-last" \
    "$BOSUN_STATE_DIR/$1.esc-count" 2>/dev/null || true
}
check_deploy_drift() {
  if [ ! -x "$SCRIPT_DIR/fm-deploy-drift.sh" ]; then
    # Not present yet; skip silently in normal mode, log in dry-run
    if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
      bosun_log "deploy-drift:skipped:fm-deploy-drift.sh-not-present"
    fi
    return 0
  fi

  local output
  output=$("$SCRIPT_DIR/fm-deploy-drift.sh" 2>&1)
  if [ -n "$output" ]; then
    if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
      bosun_log "deploy-drift:WOULD-escalate:$output"
    else
      fm_wake_append "stale" "deploy-drift" \
        "BOSUN-ESCALATION: deploy drift: $output" 2>/dev/null || true
      bosun_log "deploy-drift:escalated:$output"
    fi
  else
    bosun_log "deploy-drift:ok:no-drift"
  fi
}
check_stale_teardown() {  # <id> <meta>
  local id=$1 meta=$2 wt pr merged

  wt=$(fm_meta_get "$meta" worktree) || true
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0

  pr=$(fm_meta_get "$meta" pr) || true
  [ -n "$pr" ] || return 0

  case "$pr" in
    https://github.com/*) : ;;
    *) return 0 ;;
  esac

  command -v gh >/dev/null 2>&1 || return 0

  merged=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || merged=""
  case "$merged" in
    MERGED) ;;
    *) return 0 ;;
  esac

  # PR is merged but the worktree still exists - record for firstmate,
  # do NOT tear it down ourselves.
  if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
    bosun_log "stale-teardown:$id:PR-merged worktree-exists wt=$wt"
  else
    fm_wake_append "stale" "$id.status" \
      "BOSUN-ESCALATION: PR merged but worktree still exists, needs cleanup: $wt" 2>/dev/null || true
    bosun_log "stale-teardown:$id:escalated wt=$wt"
  fi
}

# --- Check: inflight sibling PRs after a merge ---------------------------
#
# When a task's PR is merged, every other open PR in that repo was validated
# against the old base and may now be CONFLICTING or behind the base, silently
# stalling its pipeline (famclaw #334/338 → #341; image-understanding #206,
# #202). This check lists the repo's open PRs and surfaces the ones that need
# a rebase. It reports only — never rebases, pushes, or otherwise writes to any
# branch. Firstmate owns the rebase decision.
check_inflight_conflicts() {  # <id> <meta>
  local id=$1 meta=$2 pr owner_repo number merged open_prs
  local sibling_num mergeable behind conflicts=""

  pr=$(fm_meta_get "$meta" pr) || true
  [ -n "$pr" ] || return 0

  case "$pr" in
    https://github.com/*) : ;;
    *) bosun_log "conflicting-siblings:$id:skip:non-github-url"; return 0 ;;
  esac

  command -v gh >/dev/null 2>&1 || { bosun_log "conflicting-siblings:$id:skip:gh-missing"; return 0; }

  owner_repo=$(printf '%s' "$pr" | sed 's|https://github.com/||; s|/pull/[^/]*$||')
  number=$(printf '%s' "$pr" | sed 's|.*/pull/||')

  # Only check siblings when this task's PR is merged. A non-merged PR means
  # its siblings are still validated against the current base.
  merged=$(gh pr view "$pr" --json state -q .state 2>/dev/null) || merged=""
  case "$merged" in
    MERGED) ;;
    *) bosun_log "conflicting-siblings:$id:skip:not-merged state=${merged:-none}"; return 0 ;;
  esac

  # List open PRs for the repo. The merged PR is excluded by definition.
  open_prs=$(gh pr list -R "$owner_repo" --state open --json number -q '.[].number' 2>/dev/null) || open_prs=""
  [ -n "$open_prs" ] || { bosun_log "conflicting-siblings:$id:no-open-siblings"; return 0; }

  # For each open PR, check whether it needs a rebase.
  #   mergeable  — CONFLICTING means GitHub cannot merge cleanly.
  #   behindBase — true means the PR branch is behind the base branch.
  # Either condition means a rebase is needed.
  while IFS= read -r sibling_num; do
    [ -n "$sibling_num" ] || continue
    [ "$sibling_num" = "$number" ] && continue

    mergeable=$(gh pr view "https://github.com/$owner_repo/pull/$sibling_num" \
      --json mergeable -q .mergeable 2>/dev/null) || mergeable="UNKNOWN"
    behind=$(gh pr view "https://github.com/$owner_repo/pull/$sibling_num" \
      --json behindBase -q .behindBase 2>/dev/null) || behind="false"

    case "$mergeable" in
      CONFLICTING)
        conflicts="${conflicts} PR#${sibling_num}(CONFLICTING"
        [ "$behind" = "true" ] && conflicts="${conflicts},behind=true"
        conflicts="${conflicts})"
        ;;
      MERGEABLE)
        [ "$behind" = "true" ] && conflicts="${conflicts} PR#${sibling_num}(behind=true)"
        ;;
      *)
        conflicts="${conflicts} PR#${sibling_num}(mergeable=${mergeable})"
        ;;
    esac
  done <<< "$open_prs"

  if [ -n "$conflicts" ]; then
    if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
      bosun_log "conflicting-siblings:$id:WOULD-escalate:$conflicts"
    else
      fm_wake_append "stale" "$id.status" \
        "BOSUN-ESCALATION: merged PR <$pr> has in-flight siblings needing rebase:${conflicts}" 2>/dev/null || true
      bosun_log "conflicting-siblings:$id:escalated:$conflicts"
    fi
  else
    bosun_log "conflicting-siblings:$id:no-conflicts"
  fi
}

# --- no-mistakes axi status helpers ---------------------------------------

NM_AXI_CACHE_ID=""
NM_AXI_CACHE_OUT=""
NM_AXI_STATUS=""

# Run `no-mistakes axi status` in the worktree for <id>/<meta>, caching the
# result so multiple checks share one call. Only runs for kind=ship tasks on
# a branch with no-mistakes installed.
bosun_get_axi_status() {  # <id> <meta>
  local id=$1 meta=$2 wt kind branch
  if [ "${NM_AXI_CACHE_ID:-}" = "$id" ]; then
    return 0
  fi
  NM_AXI_CACHE_ID="$id" NM_AXI_CACHE_OUT="" NM_AXI_STATUS=""
  wt=$(fm_meta_get "$meta" worktree) || true
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0
  kind=$(fm_meta_get "$meta" kind) || true
  [ -n "$kind" ] || kind=ship
  [ "$kind" = ship ] || return 0
  branch=$(git -C "$wt" symbolic-ref --quiet --short HEAD 2>/dev/null || true)
  [ -n "$branch" ] || return 0
  command -v no-mistakes >/dev/null 2>&1 || return 0
  if command -v timeout >/dev/null 2>&1; then
    NM_AXI_CACHE_OUT=$(cd "$wt" && timeout "$FM_BOSUN_NM_TIMEOUT" no-mistakes axi status 2>/dev/null) || NM_AXI_CACHE_OUT=""
  else
    NM_AXI_CACHE_OUT=$(cd "$wt" && no-mistakes axi status 2>/dev/null) || NM_AXI_CACHE_OUT=""
  fi
  if [ -n "$NM_AXI_CACHE_OUT" ]; then
    NM_AXI_STATUS=$(printf '%s\n' "$NM_AXI_CACHE_OUT" | sed -n 's/^[[:space:]]*status:[[:space:]]*//p' | head -1)
    case "$NM_AXI_STATUS" in *'"'*) NM_AXI_STATUS=${NM_AXI_STATUS#'"'}; NM_AXI_STATUS=${NM_AXI_STATUS%'"'} ;; esac
    NM_AXI_STATUS="${NM_AXI_STATUS#"${NM_AXI_STATUS%%[![:space:]]*}"}"
    NM_AXI_STATUS="${NM_AXI_STATUS%"${NM_AXI_STATUS##*[![:space:]]}"}"
  fi
}

# Extract a scalar field from axi status output.
_nm_axi_field() {  # <output> <field>
  local out=$1 field=$2 val
  val=$(printf '%s\n' "$out" | sed -n "s/^[[:space:]]*${field}:[[:space:]]*//p" | head -1)
  case "$val" in *'"'*) val=${val#'"'}; val=${val%'"'} ;; esac
  val="${val#"${val%%[![:space:]]*}"}"
  val="${val%"${val##*[![:space:]]}"}"
  printf '%s' "$val"
}

# Parse the active_steps table from axi status output.
# Prints one line per step: step|status|active_for|last_activity|agent_pid
_nm_parse_active_steps() {  # <output>
  local in_table=0 line
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    if [[ "$line" == *'active_steps['* ]]; then
      in_table=1
      continue
    fi
    if [ "$in_table" = 1 ]; then
      if [[ ! "$line" =~ ^[[:space:]]{4} ]]; then
        in_table=0
        continue
      fi
      if [[ "$line" =~ ^[[:space:]]*([^,]+),([^,]+),([^,]+),\"([^\"]*)\",\"([^\"]*)\" ]]; then
        printf '%s|%s|%s|%s|%s\n' \
          "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}" \
          "${BASH_REMATCH[3]}" "${BASH_REMATCH[4]}" "${BASH_REMATCH[5]}"
      fi
    fi
  done < <(printf '%s\n' "$1")
}

# Convert a Go-style duration (4h01m, 14s, 30m) to seconds.
_nm_duration_to_secs() {  # <dur>
  local dur=$1 secs=0 val
  if [[ "$dur" =~ ([0-9]+)h ]]; then val=${BASH_REMATCH[1]}; secs=$((secs + val * 3600)); fi
  if [[ "$dur" =~ ([0-9]+)m ]]; then val=${BASH_REMATCH[1]}; secs=$((secs + val * 60));  fi
  if [[ "$dur" =~ ([0-9]+)s ]]; then val=${BASH_REMATCH[1]}; secs=$((secs + val));       fi
  printf '%s' "$secs"
}

# Extract a duration token from a last_activity string.
# "14s ago: log: ..." -> 14s ; "quiet 3h58m ago" -> 3h58m
_nm_extract_activity_dur() {  # <last_activity>
  local la=$1 dur
  la=${la#quiet }
  if [[ "$la" =~ ^([0-9]+h)?([0-9]+m)?([0-9]+s)? ]]; then
    dur="${BASH_REMATCH[1]}${BASH_REMATCH[2]}${BASH_REMATCH[3]}"
  else
    dur=""
  fi
  printf '%s' "$dur"
}

# --- Check: stalled run-step ----------------------------------------------

# A no-mistakes step whose status is "running" but whose last_activity is
# older than FM_BOSUN_STALL_SECS, or which has an empty agent_pid, is
# escalated the same way parked work is (stale-kind wake, rate-capped).
check_stalled_runstep() {  # <id> <meta>
  local id=$1 meta=$2 out status
  bosun_get_axi_status "$id" "$meta"
  out="$NM_AXI_CACHE_OUT"
  [ -n "$out" ] || return 0
  status="$NM_AXI_STATUS"
  [ "$status" = running ] || return 0

  local step fstatus active_for last_activity pid dur secs
  # shellcheck disable=SC2034  # active_for is read to advance fields, not used
  while IFS='|' read -r step fstatus active_for last_activity pid; do
    [ -n "$step" ] || continue
    case "$fstatus" in
      running|fixing) ;; *) continue ;;
    esac
    if [ -z "$pid" ]; then
      _escalate_stalled "$id" "no-agent-pid step=$step"
      continue
    fi
    dur=$(_nm_extract_activity_dur "$last_activity")
    if [ -n "$dur" ]; then
      secs=$(_nm_duration_to_secs "$dur")
      if [ "$secs" -ge "$FM_BOSUN_STALL_SECS" ]; then
        _escalate_stalled "$id" "quiet=${secs}s step=$step threshold=$FM_BOSUN_STALL_SECS"
      fi
    fi
  done < <(_nm_parse_active_steps "$out")
}

_escalate_stalled() {  # <id> <reason>
  local id=$1 reason=$2
  if [ "$(bosun_state_age "$id" stalled)" -lt "$FM_BOSUN_STEER_INTERVAL" ]; then
    bosun_log "stalled:$id:rate-capped reason=$reason"
    return 0
  fi
  if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
    bosun_log "stalled:$id:WOULD-escalate reason=$reason"
  else
    fm_wake_append "stale" "$id.status" \
      "BOSUN-ESCALATION: stalled run-step: $reason" 2>/dev/null || true
    bosun_log "stalled:$id:escalated reason=$reason"
  fi
  bosun_state_set "$id" stalled "1"
}

# --- Check: no-progress crew ---------------------------------------------

# A crew whose worktree has had no file modification (excluding .git) and no
# new commit for longer than FM_BOSUN_NPROGRESS_SECS (default 1800), while
# the crew is still busy (running step or non-terminal status), is escalated
# the same way parked work is. This catches crews that look alive but are
# producing nothing - conflict-marker loops, long generation stalls, etc.

# Newest file mtime under <wt> excluding .git and its contents.
worktree_newest_mtime() {  # <wt>
  local wt=$1 mtime
  mtime=$(find "$wt" -mindepth 1 \
    -not -name ".git" -not -path "*/.git/*" \
    -type f -printf '%T@\n' 2>/dev/null | sort -rn | head -1 | cut -d. -f1)
  case "$mtime" in ''|*[!0-9]*) mtime=0 ;; esac
  printf '%s' "$mtime"
}

# HEAD commit time as epoch seconds (0 if no commits).
worktree_head_commit_time() {  # <wt>
  local wt=$1 ct
  ct=$(git -C "$wt" log -1 --format=%ct 2>/dev/null) || ct=""
  case "$ct" in ''|*[!0-9]*) ct=0 ;; esac
  printf '%s' "$ct"
}

# True (0) if the crew is currently busy: either NM_AXI_STATUS=running
# (from cached axi status) or the status log's last line is non-terminal
# and not a declared pause.
bosun_crew_is_busy() {  # <id>
  local id=$1 last_line verb
  [ "$NM_AXI_STATUS" = running ] && return 0
  last_line=$(last_status_line "$STATE/$id.status") || last_line=""
  [ -n "$last_line" ] || return 1
  verb=$(status_line_verb "$last_line")
  case "$verb" in
    done|needs-decision|blocked|failed) return 1 ;;
    paused) return 1 ;;
  esac
  return 0
}

check_no_progress_crew() {  # <id> <meta>
  local id=$1 meta=$2 wt mtime commit_time newest_age now
  wt=$(fm_meta_get "$meta" worktree) || true
  [ -n "$wt" ] || return 0
  [ -d "$wt" ] || return 0

  bosun_get_axi_status "$id" "$meta"
  if ! bosun_crew_is_busy "$id"; then
    return 0
  fi

  mtime=$(worktree_newest_mtime "$wt")
  commit_time=$(worktree_head_commit_time "$wt")
  now=$(date +%s)

  if [ "$mtime" -ge "$commit_time" ]; then
    newest_age=$((now - mtime))
  else
    newest_age=$((now - commit_time))
  fi

  if [ "$newest_age" -ge "$FM_BOSUN_NPROGRESS_SECS" ]; then
    _escalate_no_progress "$id" "no-change-for=${newest_age}s threshold=$FM_BOSUN_NPROGRESS_SECS"
  fi
}

_escalate_no_progress() {  # <id> <reason>
  local id=$1 reason=$2
  if [ "$(bosun_state_age "$id" no-progress)" -lt "$FM_BOSUN_STEER_INTERVAL" ]; then
    bosun_log "no-progress:$id:rate-capped reason=$reason"
    return 0
  fi
  if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
    bosun_log "no-progress:$id:WOULD-escalate reason=$reason"
  else
    fm_wake_append "stale" "$id.status" \
      "BOSUN-ESCALATION: no-progress crew: $reason" 2>/dev/null || true
    bosun_log "no-progress:$id:escalated reason=$reason"
  fi
  bosun_state_set "$id" no-progress "1"
}

# --- Check: idle fleet with queued ready work ------------------------------
#
# WHY IT MATTERS: firstmate repeatedly finishes a wave of work, retires the
# last worker, and stops dispatching while dozens of ready items sit in the
# backlog. It has happened at least four times in two days, including a
# ten-hour stretch with 97 ready items and an empty fleet. The captain has
# had to notice and say so every single time. Nothing in the fleet currently
# detects "fleet empty but work waiting" - there are 8 per-task checks and
# none looks at fleet-wide dispatch starvation.
#
# The bosun already runs every 10 minutes on cron, so this check turns a human
# catching it into the machine catching it within 10 minutes.
#
# Condition: no live crew (no state/<id>.meta with a live endpoint) AND the
# backlog has ready dispatchable work (tasks-axi ready, which excludes held
# and blocked items). When both hold, report LOUDLY with the count and top
# ids.
#
# An empty fleet is NOT always wrong: do NOT fire when the backlog has nothing
# ready, when everything ready is blocked or held (tasks-axi ready already
# excludes those), or when away mode is active (state/.afk) - those are
# legitimate quiet states.
check_idle_fleet() {
  local live_count=0 meta backend target
  local ready_output ready_count ready_ids

  # Away mode = legitimate quiet state. The captain is stepped away;
  # dispatch will resume when they return.
  if [ -e "$STATE/.afk" ]; then
    bosun_log "idle-fleet:skip:away-mode"
    return 0
  fi

  # Count metas with a live backend endpoint. A meta without a window/target
  # has no endpoint and is not a live crew member.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    backend=$(fm_backend_of_meta "$meta")
    target=$(fm_backend_target_of_meta "$meta")
    [ -n "$target" ] || continue
    if fm_backend_target_exists "$backend" "$target"; then
      live_count=$((live_count + 1))
    fi
  done

  # Fleet has live crew: not idle, nothing to report.
  if [ "$live_count" -gt 0 ]; then
    bosun_log "idle-fleet:silent:live-crew=$live_count"
    return 0
  fi

  # Fleet is idle. Check for ready (unblocked, unheld) dispatchable work.
  command -v tasks-axi >/dev/null 2>&1 || { bosun_log "idle-fleet:skip:tasks-axi-missing"; return 0; }

  ready_output=$(cd "$FM_HOME" && tasks-axi ready 2>/dev/null) || ready_output=""
  ready_count=$(printf '%s\n' "$ready_output" | sed -n 's/^count: //p' | head -1)
  case "$ready_count" in ''|*[!0-9]*) ready_count=0 ;; esac

  if [ "$ready_count" -gt 0 ]; then
    # Extract top 5 dispatchable ids from the ready[...] section.
    ready_ids=$(printf '%s\n' "$ready_output" \
      | sed -n '/^ready\[/,/^ready_public_followups/p' \
      | sed 's/^[[:space:]]*//' \
      | grep -E '^[A-Za-z0-9._-]+,' \
      | cut -d, -f1 \
      | head -5 | tr '\n' ' ' | sed 's/[[:space:]]*$//')
    if [ "$FM_BOSUN_DRY_RUN" = 1 ]; then
      bosun_log "idle-fleet:WOULD-escalate:ready=$ready_count top-ids=$ready_ids"
    else
      fm_wake_append "stale" "idle-fleet" \
        "BOSUN-ESCALATION: idle fleet with $ready_count ready work items, top ids: $ready_ids" 2>/dev/null || true
      bosun_log "idle-fleet:escalated:ready=$ready_count top-ids=$ready_ids"
    fi
  else
    bosun_log "idle-fleet:silent:no-ready-work"
  fi
}

# --- Main ---
main() {
  bosun_log "cycle:start dry-run=$FM_BOSUN_DRY_RUN"

  local meta id
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    check_pr_readiness "$id" "$meta"
    check_uncommitted_work "$id" "$meta"
    check_unpushed_commits "$id" "$meta"
    check_parked_work "$id"
    check_stale_teardown "$id" "$meta"
    check_inflight_conflicts "$id" "$meta"
    check_stalled_runstep "$id" "$meta"
    check_no_progress_crew "$id" "$meta"
  done

  check_deploy_drift
  check_idle_fleet
  bosun_trim_log
  bosun_log "cycle:end"
}

main "$@"
