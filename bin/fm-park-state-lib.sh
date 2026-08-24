#!/usr/bin/env bash
# fm-park-state-lib.sh - shared predicates for "is this condition already
# parked with the captain?", used by the bosun re-alarm checks to suppress
# noise on expected external waits.
#
# A condition is PARKED (its idle state is expected) while ANY of these holds:
#   1. the task's last status line declares a pause
#      (paused: <reason>) - the external-wait vocabulary owned by
#      bin/fm-classify-lib.sh, reused here so the verb cannot drift;
#   2. the task has an armed merge poll against its recorded pr=
#      (state/<id>.pr-poll-registration plus the state/<id>.pr-poll sidecar,
#      armed transactionally by bin/fm-pr-check.sh and read back through
#      bin/fm-pr-lib.sh's own record parsers) - the watcher owns the real
#      merge watch, so an idle pane is expected;
#   3. an open captain decision hold covers the subject - a tasks-axi item
#      with kind=captain currently held, whose identity is
#      <subject-id>-decision-<key> for a task subject, or whose repo field
#      (or identity/title) names the project for a fleet-wide subject.
#
# While any marker holds, the FIRST occurrence of the underlying condition has
# already alarmed, so the bosun re-alarm is suppressed. When the last marker
# goes away (decision answered, poll retired, pause dropped), the condition
# re-alarms from first occurrence exactly as before.
#
# Read-only: this lib never mutates task state, poll records, or the backlog.
# Suppression is FAIL-OPEN FOR ALARMS: when the held list cannot be read
# (tasks-axi absent or erroring), the hold predicates report "no hold" and the
# checks alarm as before. A missing dependency must never silence a supervisor.

_PARK_STATE_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)" || _PARK_STATE_LIB_DIR="."
# shellcheck source=bin/fm-classify-lib.sh
. "$_PARK_STATE_LIB_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$_PARK_STATE_LIB_DIR/fm-pr-lib.sh"

# Per-process cache of open captain decision holds: one "<id>\t<repo>\t<title>"
# line per hold. `tasks-axi list` already carries the title, so the whole cache
# costs one subprocess per process - never one lookup per hold per query.
# Empty means none open (or none readable - both suppress nothing).
_PARKED_HOLDS_HOME=""
_PARKED_HOLDS_LOADED=0
_PARKED_HOLDS=""

# Load the home's open captain decision holds once per process: tasks-axi
# items with kind=captain currently held. <fm-home> holds .tasks.toml and
# data/backlog.md. Every failure path leaves the cache empty so callers fail
# open to alarming.
parked_load_holds() {  # <fm-home>
  local home=$1 out
  [ -n "$home" ] || return 0
  if [ "$_PARKED_HOLDS_LOADED" = 1 ] && [ "$_PARKED_HOLDS_HOME" = "$home" ]; then
    return 0
  fi
  _PARKED_HOLDS_LOADED=1
  _PARKED_HOLDS_HOME="$home"
  _PARKED_HOLDS=""
  [ -d "$home" ] || return 0
  command -v tasks-axi >/dev/null 2>&1 || return 0
  out=$(cd "$home" && tasks-axi list --kind captain --state held 2>/dev/null) || return 0
  _PARKED_HOLDS=$(printf '%s\n' "$out" \
    | sed -n 's/^  \([^,]*\),\([^,]*\),captain,\([^,]*\),\(.*\)$/\1\t\3\t\4/p')
  return 0
}

# 0 if the task's last status line declares an external-wait pause.
task_status_is_paused() {  # <state-dir> <task-id>
  local state=$1 id=$2 last
  last=$(last_status_line "$state/$id.status") || last=""
  [ -n "$last" ] && status_is_paused "$last"
}

# 0 if the task has an armed merge poll against its recorded pr=. Both halves
# of the transactional record are read back through their owner in
# bin/fm-pr-lib.sh - fm_pr_poll_registration_parse for
# state/<id>.pr-poll-registration and fm_pr_poll_data_parse for the
# state/<id>.pr-poll sidecar - so a truncated, mistyped, symlinked or
# cross-bound record is not mistaken for an armed watch, and the two must
# agree on the same provider-tagged identity.
#
# A published retirement receipt (state/<id>.pr-poll-retirement) means the
# watch is over even while its files survive: retirement is two-phase, the
# receipt is written before the registration and sidecar are removed and the
# recovery between those steps can stall indefinitely. A receipt therefore
# disarms the poll here.
#
# When the meta records a pr= the registration must name that same canonical
# URL. A registration against a different PR than the recorded one does NOT
# arm the expected wait.
task_has_armed_poll() {  # <state-dir> <task-id> <meta-file>
  local state=$1 id=$2 meta=$3
  local retirement="$state/$id.pr-poll-retirement"
  local reg_provider reg_url reg_host reg_path reg_number pr_url
  [ ! -e "$retirement" ] && [ ! -L "$retirement" ] || return 1
  fm_pr_poll_registration_parse "$state/$id.pr-poll-registration" || return 1
  [ "$FM_PR_REG_ID" = "$id" ] || return 1
  reg_provider=$FM_PR_REG_PROVIDER
  reg_url=$FM_PR_REG_URL
  reg_host=$FM_PR_REG_HOST
  reg_path=$FM_PR_REG_PATH
  reg_number=$FM_PR_REG_NUMBER
  fm_pr_poll_data_parse "$state/$id.pr-poll" || return 1
  [ "$FM_PR_DATA_PROVIDER" = "$reg_provider" ] || return 1
  [ "$FM_PR_DATA_URL" = "$reg_url" ] || return 1
  [ "$FM_PR_DATA_HOST" = "$reg_host" ] || return 1
  [ "$FM_PR_DATA_PATH" = "$reg_path" ] || return 1
  [ "$FM_PR_DATA_NUMBER" = "$reg_number" ] || return 1
  pr_url=$(sed -n 's/^pr=//p' "$meta" 2>/dev/null | tail -1)
  [ -n "$pr_url" ] || return 0
  fm_pr_url_parse "$pr_url" || return 1
  [ "$FM_PR_URL" = "$reg_url" ]
}

# 0 if an open captain decision hold covers task subject <task-id>: the hold
# identity is <task-id>-decision-<key> (the bin/fm-decision-hold.sh identity
# contract).
task_has_open_captain_hold() {  # <fm-home> <task-id>
  local home=$1 id=$2 line
  parked_load_holds "$home"
  [ -n "$_PARKED_HOLDS" ] || return 1
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    case "${line%%$'\t'*}" in
      "$id"-decision-*) return 0 ;;
    esac
  done <<< "$_PARKED_HOLDS"
  return 1
}

# 0 when <subject> occurs in <haystack> on a word boundary, case-insensitive.
# Every ERE metacharacter in the subject is escaped, so a project named
# app(v2) or c++ is matched as itself rather than as a pattern.
_parked_subject_mentions() {  # <subject> <haystack>
  local subject=$1 hay=$2 re
  re=$(printf '%s' "$subject" | tr '[:upper:]' '[:lower:]' | sed -e 's/[][\\.^$*+?(){}|]/\\&/g')
  [ -n "$hay" ] || return 1
  printf '%s' "$hay" | grep -qiE "(^|[^a-z0-9])${re}([^a-z0-9]|$)"
}

# 0 if an open captain decision hold covers project subject <project>: the
# hold's repo field names the project, the hold identity references it, or its
# backlog title does. All three read the cached hold list, so this costs no
# subprocess of its own.
project_has_open_captain_hold() {  # <fm-home> <project>
  local home=$1 project=$2 id repo title project_lc
  parked_load_holds "$home"
  [ -n "$_PARKED_HOLDS" ] || return 1
  project_lc=$(printf '%s' "$project" | tr '[:upper:]' '[:lower:]')
  while IFS=$'\t' read -r id repo title; do
    [ -n "$id" ] || continue
    repo=${repo#\"}; repo=${repo%\"}
    if [ "$(printf '%s' "$repo" | tr '[:upper:]' '[:lower:]')" = "$project_lc" ]; then
      return 0
    fi
    _parked_subject_mentions "$project" "$id" && return 0
    title=${title#\"}; title=${title%\"}
    _parked_subject_mentions "$project" "$title" && return 0
  done <<< "$_PARKED_HOLDS"
  return 1
}

# 0 if task <task-id>'s idle condition is parked with the captain: a declared
# pause, an armed merge poll against the recorded pr=, or an open captain
# decision hold covering the task.
task_is_parked() {  # <state-dir> <task-id> <meta-file> <fm-home>
  local state=$1 id=$2 meta=$3 home=$4
  task_status_is_paused "$state" "$id" && return 0
  task_has_armed_poll "$state" "$id" "$meta" && return 0
  task_has_open_captain_hold "$home" "$id" && return 0
  return 1
}
