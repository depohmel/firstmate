#!/usr/bin/env bash
# tests/fm-afk-wedge-fix.test.sh - regression tests for the supervision blackout
# fix in bin/fm-supervise-daemon.sh (afk-invx-i5: a 9.4h away-mode escalation
# blackout caused by the max-defer escape retrying the exact injm_msg that was
# stuck on a pane_input_pending false positive).
#
# Three contracts:
#   1. Tier-1 (FM_MAX_DEFER_SECS) force-pending delivery bypasses a stuck-pending
#      composer and delivers anyway (the core regression).
#   2. Tier-2 (FM_FORCE_INJECT_SECS) hard ceiling writes state/AFK-WEDGED.txt when
#      even force delivery cannot land, and clears it on a successful flush.
#   3. pane_input_pending false-positive detection counts unchanged-pending
#      observations past the threshold.
set -u

# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

DAEMON="$ROOT/bin/fm-supervise-daemon.sh"
# Source the daemon's pure functions once. Its main loop is skipped under sourcing
# via a BASH_SOURCE guard, so only classify_*/housekeeping/escalate_*/afk_* and the
# pane/submit helpers become defined.
if [ -z "${FM_TEST_DAEMON_SOURCED:-}" ]; then
  export FM_TEST_DAEMON_SOURCED=1
  # shellcheck source=bin/fm-supervise-daemon.sh
  . "$DAEMON"
fi

TMP_ROOT=$(fm_test_tmproot fm-afk-wedge-fix)

# --- Tier 1: max-defer force-pending bypasses a stuck-pending composer ----------
# THE incident: pane_input_pending false-positives on an IDLE pane and never
# stops. The OLD escape retried escalate_flush -> inject_msg, which re-checked
# the SAME stuck pane_input_pending, so the blackout went on for 9.4h. Tier-1
# force-pending now bypasses the composer guard and delivers anyway. This test
# fails against the unmodified daemon (it alarms instead of delivering).
test_max_defer_bypasses_stuck_pending_delivers() {
  local dir state fakebin sent
  dir=$(make_bordered_case forced-pending-bypass)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick A"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  (
    # Stub pane_input_pending to ALWAYS report pending = the incident.
    pane_input_pending() { return 0; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
      FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
      housekeeping "$state"
  ) || fail "tier-1 force-pending housekeeping failed"
  [ "$(grep -c 'Supervisor escalate' "$sent" 2>/dev/null || true)" -eq 1 ] \
    || fail "max-defer did NOT deliver despite pane_input_pending always reporting pending"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "buffer not cleared after force-pending bypass"
  [ ! -e "$state/.subsuper-inject-wedged" ] \
    || fail "wedge alarm fired on a deliverable force-pending flush"
  pass "tier-1: max-defer force-pending bypasses a stuck-pending composer and delivers"
}

# --- Tier 1 still respects the busy guard (never inject mid-turn) -------------
test_max_defer_busy_composer_still_alarms() {
  local dir state fakebin sent
  dir=$(make_bordered_case forced-pending-busy)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  # Composer shows a busy footer (agent mid-turn): force-pending MUST still
  # defer at tier 1, and the wedge alarm fires instead.
  printf 'esc to interrupt\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick B"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"
  PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
    FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=60 FM_INJECT_CONFIRM_SLEEP=0.05 \
    housekeeping "$state"
  [ ! -s "$sent" ] || fail "max-defer typed into a busy pane"
  [ -s "$state/.subsuper-inject-wedged" ] || fail "busy composer did not raise a wedge alarm marker"
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost while composer was busy"
  pass "tier-1: max-defer on a busy composer still defers (busy guard respected) and alarms"
}

# --- Tier 2: hard ceiling writes/clears state/AFK-WEDGED.txt ------------------
# Past FM_FORCE_INJECT_SECS, force-ALL delivery bypasses BOTH guards. When even
# that cannot land (send fails / pane gone), the alarm must reach outside the
# wedged pane via state/AFK-WEDGED.txt. A subsequent successful flush must clear
# it. Fails against the unmodified daemon (no FM_FORCE_INJECT_SECS / no
# AFK-WEDGED.txt path at all).
test_hard_ceiling_writes_and_clears_afk_wedged() {
  local dir state fakebin sent
  dir=$(make_bordered_case hard-ceiling-wedge)
  state="$dir/state"; fakebin="$dir/fakebin"
  sent="$dir/sent.log"; : > "$sent"
  printf '│ > │\n' > "$dir/composer"
  escalate_add "$state" "needs-decision: pick C"
  echo $(( $(date +%s) - 600 )) > "$state/.subsuper-escalations.since"
  afk_enter "$state"

  # Disable tier 1 so only the hard ceiling fires; stub the submit primitive to
  # ALWAYS fail = delivery impossible even with both guards bypassed.
  (
    pane_input_pending() { return 0; }
    fm_backend_send_text_submit() { printf 'send-failed'; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
      FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=99999 FM_FORCE_INJECT_SECS=60 \
      FM_INJECT_CONFIRM_SLEEP=0.05 housekeeping "$state"
  ) || fail "hard-ceiling housekeeping failed"
  [ -s "$state/AFK-WEDGED.txt" ] \
    || fail "AFK-WEDGED.txt not written when hard-ceiling delivery is impossible"
  grep -F "$sent" "$state/AFK-WEDGED.txt" >/dev/null 2>&1 && \
    fail "AFK-WEDGED.txt must contain the newest escalation line, not the sent-log path"
  grep -F 'needs-decision: pick C' "$state/AFK-WEDGED.txt" >/dev/null \
    || fail "AFK-WEDGED.txt missing the newest escalation line"
  grep -qE 'AFK WEDGED: [0-9]+s undelivered' "$state/AFK-WEDGED.txt" \
    || fail "AFK-WEDGED.txt missing the undelivered duration"
  [ -s "$state/.subsuper-escalations" ] \
    || fail "buffer dropped while hard-ceiling delivery was impossible"

  # Now let delivery succeed: force-ALL flush clears the buffer AND the alarm.
  (
    pane_input_pending() { return 0; }
    fm_backend_send_text_submit() { printf 'empty'; }
    PATH="$fakebin:$PATH" FM_FAKE_COMPOSER="$dir/composer" FM_FAKE_SENT="$sent" \
      FM_ESCALATE_BATCH_SECS=99999 FM_MAX_DEFER_SECS=99999 FM_FORCE_INJECT_SECS=60 \
      FM_INJECT_CONFIRM_SLEEP=0.05 housekeeping "$state"
  ) || fail "hard-ceiling recovery housekeeping failed"
  [ -e "$state/AFK-WEDGED.txt" ] \
    && fail "AFK-WEDGED.txt not removed after a successful force-all flush"
  [ ! -s "$state/.subsuper-escalations" ] \
    || fail "buffer not cleared after a successful force-all flush"
  pass "tier-2: hard ceiling writes AFK-WEDGED.txt when delivery is impossible, clears on success"
}

# --- False-positive detection (requirement 4) ---------------------------------
# When pane_input_pending reports pending while the pane capture is UNCHANGED
# across consecutive checks, the consecutive-unchanged counter climbs. Past the
# threshold it would log a distinct WARNING (here: the count file reflects it).
test_pending_false_positive_counters_unchanged_pane() {
  local dir state fakebin i count
  dir=$(make_supercase false-positive)
  state="$dir/state"; fakebin="$dir/fakebin"
  # A pending composer (real text on the cursor line) that never changes.
  printf 'human draft text\n' > "$dir/pane.txt"
  escalate_add "$state" "needs-decision: pick D"
  afk_enter "$state"
  for i in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21; do
    PATH="$fakebin:$PATH" FM_FAKE_TMUX_CAPTURE="$dir/pane.txt" FM_FAKE_TMUX_CURSOR_Y=0 \
      escalate_flush "$state" 2>/dev/null || true
  done
  count=$(cat "$state/.subsuper-pending-count" 2>/dev/null || echo 0)
  case "$count" in ''|*[!0-9]*) count=0 ;; esac
  [ "$count" -gt 20 ] \
    || fail "unchanged-pending counter did not exceed 20 (got $count after 21 observations)"
  # The buffer is preserved across every deferral (no delivery possible).
  [ -s "$state/.subsuper-escalations" ] || fail "buffer lost during false-positive observation loop"
  pass "false-positive detection: unchanged-pending counter exceeds the threshold ($count)"
}

test_max_defer_bypasses_stuck_pending_delivers
test_max_defer_busy_composer_still_alarms
test_hard_ceiling_writes_and_clears_afk_wedged
test_pending_false_positive_counters_unchanged_pane
