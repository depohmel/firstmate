#!/usr/bin/env bash
# fm-rebase-sweep.sh [<project-dir-or-name>]
#
# For the given project (or every project under projects/), list open PRs and
# report which are conflicting or behind the base. Reports one line per PR that
# needs attention and is silent when all PRs are clean. Does NOT rebase, push,
# or otherwise write to any branch: it only reports; a crew owns its own branch.
#
# Like fm-fleet-sync.sh, this sweep is best-effort and never blocks teardown on
# its success: a gh-axi failure degrades to a single skip line rather than an
# error.
#
# Usage: fm-rebase-sweep.sh [<project-dir-or-name>]
#   The single-project form accepts either a path (absolute, or relative to the
#   caller's cwd) or a bare "<name>"/"projects/<name>" form, resolved against
#   this home's projects dir ($FM_HOME/projects, or $FM_PROJECTS_OVERRIDE),
#   matching bin/fm-fleet-sync.sh's resolution rules.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
"$FM_ROOT/bin/fm-guard.sh" || true

usage() {
  echo "usage: fm-rebase-sweep.sh [<project-dir-or-name>]" >&2
}

if [ "${1:-}" = "--help" ] || [ "${1:-}" = "-h" ]; then
  usage
  exit 0
fi
[ $# -le 1 ] || { usage; exit 1; }

project_label() {
  case "$PROJ" in
    "$PROJECTS"/*) basename "$PROJ" ;;
    projects/*) basename "$PROJ" ;;
    *) printf '%s\n' "$PROJ" ;;
  esac
}

# resolve_project_arg <arg>: accept a path (used as-is when it already exists)
# or a bare/"projects/<name>" project name, resolved against $PROJECTS. Falls
# back to the original argument unresolved so a genuinely bad path still hits
# sweep_project's existing "not a directory" skip. Matches fm-fleet-sync.sh.
resolve_project_arg() {
  local arg=$1 candidate
  case "$arg" in
    projects/*)
      candidate="$PROJECTS/${arg#projects/}"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      ;;
    */*)
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
    *)
      candidate="$PROJECTS/$arg"
      if [ -d "$candidate" ]; then
        printf '%s\n' "$candidate"
        return 0
      fi
      if [ -d "$arg" ]; then
        printf '%s\n' "$arg"
        return 0
      fi
      ;;
  esac
  printf '%s\n' "$arg"
}

# Parse owner/repo from a git remote URL. Only github.com URLs are supported;
# others return non-zero so the caller skips the project (best-effort).
remote_to_owner_repo() {
  local url=$1 path
  case "$url" in
    git@github.com:*) path="${url#git@github.com:}" ;;
    ssh://git@github.com/*) path="${url#ssh://git@github.com/}" ;;
    https://github.com/*|http://github.com/*)
      path="${url#https://github.com/}"
      path="${path#http://github.com/}"
      ;;
    git://github.com/*) path="${url#git://github.com/}" ;;
    *) return 1 ;;
  esac
  path="${path%.git}"
  case "$path" in
    */*) printf '%s\n' "$path"; return 0 ;;
    *) return 1 ;;
  esac
}

# behind_by_count <owner> <repo> <base> <head>: echo the commit count the PR head
# is behind the base branch. Returns non-zero on any gh-axi/api failure, so the
# caller treats it as "unknown" rather than erroring the sweep.
behind_by_count() {
  local owner=$1 repo=$2 base=$3 head=$4
  [ -n "$base" ] && [ -n "$head" ] || return 1
  gh-axi api "/repos/${owner}/${repo}/compare/${base}...${head}" -q '.behind_by' 2>/dev/null
}

# report_pr <label> <number> <state> <behind>: print one actionable line for a
# PR that needs a rebase.
report_pr() {
  printf '%s: PR #%s %s behind=%s rebase-needed\n' "$1" "$2" "$3" "$4"
}

sweep_project() {
  PROJ=$1
  label=$(project_label)

  if [ ! -d "$PROJ" ]; then
    echo "$label: skipped: not a directory"
    return 0
  fi
  if ! git -C "$PROJ" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    echo "$label: skipped: not a git repo"
    return 0
  fi
  mode_line=$("$FM_ROOT/bin/fm-project-mode.sh" "$label" 2>/dev/null || echo "no-mistakes off")
  mode=${mode_line%% *}
  if [ "$mode" = "local-only" ]; then
    echo "$label: skipped: local-only project"
    return 0
  fi
  remote_url=$(git -C "$PROJ" remote get-url origin 2>/dev/null) || {
    echo "$label: skipped: no origin remote"
    return 0
  }
  if ! owner_repo=$(remote_to_owner_repo "$remote_url"); then
    echo "$label: skipped: non-github origin ($remote_url)"
    return 0
  fi
  owner=${owner_repo%%/*}
  repo=${owner_repo#*/}

  if ! command -v gh-axi >/dev/null 2>&1; then
    echo "$label: skipped: gh-axi not found"
    return 0
  fi

  # List all open PRs with the fields we need. Each line is tab-separated:
  # number<TAB>mergeableState<TAB>baseRefName<TAB>headRefOid
  # mergeableState is "UNKNOWN" when GitHub hasn't computed it yet.
  pr_listing=$(gh-axi pr list --state open --repo "${owner}/${repo}" \
    --limit 1000 \
    --json number,mergeable,mergeableState,baseRefName,headRefOid \
    --jq '.[] | [.number, (.mergeableState // "UNKNOWN"), (.baseRefName // ""), (.headRefOid // "")] | @tsv' \
    2>/dev/null) || {
    echo "$label: skipped: gh-axi pr list failed"
    return 0
  }
  [ -n "$pr_listing" ] || return 0

  while IFS=$'\t' read -r number state base head; do
    [ -n "$number" ] || continue
    case "$state" in
      # DIRTY or BEHIND: GitHub has confirmed the PR conflicts or is behind the
      # base. A rebase is needed; report it with the behind count.
      DIRTY|BEHIND)
        behind=$(behind_by_count "$owner" "$repo" "$base" "$head") || behind="unknown"
        report_pr "$label" "$number" "$state" "$behind"
        ;;
      # UNKNOWN: GitHub hasn't computed the merge state yet. Fall back to the
      # behind count from the compare API; only report if it is positive.
      UNKNOWN)
        behind=$(behind_by_count "$owner" "$repo" "$base" "$head") || behind="unknown"
        case "$behind" in
          ''|*[!0-9]*) : ;;  # unknown or non-numeric: cannot determine
          *) [ "$behind" != "0" ] && report_pr "$label" "$number" "$state" "$behind" ;;
        esac
        ;;
      # CLEAN, UNSTABLE, BLOCKED, HAS_HOOKS: no rebase needed. Be silent.
      *) : ;;
    esac
  done <<<"$pr_listing"
}

if [ $# -eq 1 ]; then
  sweep_project "$(resolve_project_arg "$1")"
  exit 0
fi

[ -d "$PROJECTS" ] || exit 0
for proj in "$PROJECTS"/*; do
  [ -e "$proj" ] || continue
  [ -d "$proj" ] || continue
  sweep_project "$proj"
done
