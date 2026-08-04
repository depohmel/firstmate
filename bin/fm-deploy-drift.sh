#!/usr/bin/env bash
# fm-deploy-drift.sh - report projects whose MERGED code is not RUNNING.
#
# A merge is not a result. A built binary is not a result. Only a RUNNING
# PROCESS carrying the new code is a result. This gate measures that, and
# nothing cheaper - each earlier proxy (merged / pulled / built) was silent
# while the family still talked to stale code.
#
# Reads config/deploy-targets.tsv:
#   <project>\t<ssh-host>\t<remote-checkout>\t<binary-path>\t<process-pattern>
#
# Three independent staleness checks per target, each able to say NO:
#   1. checkout behind origin/main      -> merged code not even fetched
#   2. binary older than checkout HEAD  -> fetched but not rebuilt
#   3. process started before binary    -> rebuilt but not restarted  <-- the one
#                                          that was silently passing before
# Exit 0 always (advisory). Silent only when what is merged is what is running.
set -uo pipefail
FM_ROOT="${FM_HOME:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
TARGETS="$FM_ROOT/config/deploy-targets.tsv"
[ -f "$TARGETS" ] || exit 0

while IFS=$'\t' read -r proj host path bin pat; do
  case "$proj" in ''|'#'*) continue;; esac
  [ -n "${host:-}" ] && [ -n "${path:-}" ] || continue
  bin="${bin:-}"; pat="${pat:-}"

  out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$host" "
    cd $path 2>/dev/null || { echo 'ERR|nocheckout'; exit 0; }
    git fetch -q origin 2>/dev/null
    behind=\$(git rev-list --count HEAD..origin/main 2>/dev/null)
    bmt=0; [ -n '$bin' ] && [ -f $bin ] && bmt=\$(stat -f %m $bin 2>/dev/null || stat -c %Y $bin 2>/dev/null)
    pid=''; pst=0
    if [ -n '$pat' ]; then
      pid=\$(pgrep -f '$pat' 2>/dev/null | head -1)
      [ -n \"\$pid\" ] && pst=\$(ps -o lstart= -p \"\$pid\" 2>/dev/null | xargs -0 date -j -f '%a %b %d %T %Y' +%s 2>/dev/null)
      [ -z \"\$pst\" ] && pst=0
    fi
    echo \"OK|\${behind:-x}|\${bmt:-0}|\${pid:-none}|\${pst:-0}\"
  " 2>/dev/null)

  case "$out" in
    OK\|*) : ;;
    *) echo "DEPLOY_DRIFT: $proj: UNKNOWN - could not read $host:$path (check ssh)"; continue ;;
  esac
  IFS='|' read -r _ behind bmt pid pst <<<"$out"

  case "$behind" in
    ''|*[!0-9]*) echo "DEPLOY_DRIFT: $proj: UNKNOWN - unreadable commit count on $host" ;;
    0) : ;;
    *) echo "DEPLOY_DRIFT: $proj: $behind commit(s) merged but NOT PULLED on $host:$path" ;;
  esac

  [ -n "$bin" ] || continue
  if [ "${bmt:-0}" -eq 0 ]; then
    echo "DEPLOY_DRIFT: $proj: UNKNOWN - binary $bin not found on $host"
    continue
  fi

  if [ "$pid" = none ]; then
    echo "DEPLOY_DRIFT: $proj: NOT RUNNING - no process matching '$pat' on $host"
    continue
  fi
  if [ "${pst:-0}" -eq 0 ]; then
    echo "DEPLOY_DRIFT: $proj: UNKNOWN - could not read start time of pid $pid on $host"
    continue
  fi
  if [ "$pst" -lt "$bmt" ]; then
    age=$(( (bmt - pst) / 60 ))
    echo "DEPLOY_DRIFT: $proj: STALE PROCESS - pid $pid started ${age}min BEFORE the current binary was built; new code is on disk but NOT RUNNING on $host"
  fi
done < "$TARGETS"
