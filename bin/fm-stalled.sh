#!/usr/bin/env bash
# fm-stalled.sh - name every task that is BURNING WALL CLOCK doing nothing.
#
# The 9.5-hour failure was not a detection failure: the watcher escalated the
# parked crew 75 consecutive times and firstmate absorbed every one. So this
# gate does not signal - it ACCUSES, with the elapsed time and who owes the
# next move, and it rides bin/fm-guard.sh so it appears in output firstmate
# already reads before touching the fleet.
#
# A task is stalled when EITHER:
#   - its last status line is blocked:/needs-decision:  (a DECISION is owed)
#   - its endpoint has not changed in FM_STALL_SECS     (nobody is moving it)
# Threshold: FM_STALL_SECS, default 1800 (30 min).
set -uo pipefail
FM_ROOT="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
STATE="${FM_STATE_OVERRIDE:-$FM_ROOT/state}"
BIN="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
THRESH="${FM_STALL_SECS:-1800}"
now=$(date +%s)
found=0
out=""

for meta in "$STATE"/*.meta; do
  [ -e "$meta" ] || continue
  id=$(basename "$meta" .meta)
  st="$STATE/$id.status"

  owed=""; last=""
  if [ -f "$st" ]; then
    last=$(grep -vE '^\s*$' "$st" 2>/dev/null | tail -1)
    case "$last" in
      blocked:*)        owed="CAPTAIN/FIRSTMATE - a decision is owed" ;;
      needs-decision:*) owed="CAPTAIN/FIRSTMATE - a decision is owed" ;;
    esac
  fi

  # Idle age: newest of status / turn-ended markers, else meta mtime.
  newest=0
  for f in "$st" "$STATE/$id.turn-ended" "$meta"; do
    [ -f "$f" ] || continue
    m=$(stat -c %Y "$f" 2>/dev/null || stat -f %m "$f" 2>/dev/null || echo 0)
    [ "${m:-0}" -gt "$newest" ] && newest=$m
  done
  age=$(( now - newest ))

  if [ -n "$owed" ]; then
    out="$out
●  $id: PARKED ${age}s ($((age/60))min) - $owed
●     last said: ${last:0:90}"
    found=1
  elif [ "$age" -ge "$THRESH" ]; then
    # Only accuse when it is not provably working - reuse the real state read.
    s=$("$BIN/fm-crew-state.sh" "$id" 2>/dev/null | head -1)
    case "$s" in
      *working*) : ;;
      *) out="$out
●  $id: NO MOVEMENT for $((age/60))min - $s"
         found=1 ;;
    esac
  fi
done

[ "$found" -eq 1 ] || exit 0
printf '●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
printf '●  STALLED WORK - WALL CLOCK IS BURNING\n%s\n' "$out"
printf '●  Do not absorb this. Decide, steer, or tear down - now.\n'
printf '●━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━\n'
exit 0
