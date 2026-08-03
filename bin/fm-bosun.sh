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
#   FM_BOSUN_STEER_INTERVAL    rate cap for steers in seconds (default 600)
#   FM_BOSUN_LOG_MAX_BYTES     log rotation threshold (default 1048576)
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

: "${FM_BOSUN_DRY_RUN:=0}"
: "${FM_BOSUN_STEER_INTERVAL:=600}"
: "${FM_BOSUN_LOG_MAX_BYTES:=1048576}"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"

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
check_pr_readiness()    { return 0; }  # <id> <meta>
check_uncommitted_work() { return 0; }  # <id> <meta>
check_unpushed_commits() { return 0; }  # <id> <meta>
check_parked_work()     { return 0; }  # <id>
check_deploy_drift()    { return 0; }
check_stale_teardown()  { return 0; }  # <id> <meta>

# --- Main ---
main() {
  bosun_log "cycle:start dry-run=$FM_BOSUN_DRY_RUN"

  if [ "$FM_BOSUN_DRY_RUN" != 1 ]; then
    if ! command -v gh >/dev/null 2>&1; then
      bosun_log "warn:gh CLI not found; PR-related checks will skip"
    fi
  fi

  local meta id
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || continue
    id=$(basename "$meta" .meta)
    check_pr_readiness "$id" "$meta"
    check_uncommitted_work "$id" "$meta"
    check_unpushed_commits "$id" "$meta"
    check_parked_work "$id"
    check_stale_teardown "$id" "$meta"
  done

  check_deploy_drift
  bosun_trim_log
  bosun_log "cycle:end"
}

main "$@"
