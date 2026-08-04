#!/usr/bin/env bash
# fm-rebase-sweep.sh [<project-dir-or-name>]
#
# For the given project (or every project under projects/), list open PRs and
# report which are conflicting or behind the base. Reports one line per PR that
# needs attention and is silent when all PRs are clean. Does NOT rebase, push,
# or otherwise write to any branch: it only reports; a crew owns its own branch.
#
# Like fm-fleet-sync.sh, this sweep is best-effort and never blocks teardown on
# its success: a gh-axiom failure degrades to a single skip line rather than an
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
# This sweep is read-only: it never writes to branches. It is safe to invoke
# from any cwd, including inside a worktree, so it does not call fm-guard.sh.

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
  local result
  result=$(gh-axi api "/repos/${owner}/${repo}/compare/${base}...${head}" 2>/dev/null \
    | awk '/^behind_by:/ {print $2}')
  [ -n "$result" ] || return 1
  printf '%s\n' "$result"
}

# report_pr <label> <number> <state> <behind>: print one actionable line for a
# PR that needs a rebase.
report_pr() {
  printf '%s: PR #%s %s behind=%s rebase-needed\n' "$1" "$2" "$3" "$4"
}

# extract_field <details> <field>: extract a top-level field value from
# gh-axi api text output (e.g., "mergeable_state" from "mergeable_state: clean").
extract_field() {
  printf '%s\n' "$1" | awk -v f="$2" '$0 ~ "^"f":" {sub(/^[^:]*:[[:space:]]*/, ""); print; exit}'
}

# extract_nested_field <details> <parent> <field>: extract a nested field value
# from gh-axiom api text output (e.g., "base" "ref" for base.ref).
extract_nested_field() {
  printf '%s\n' "$1" | awk -v p="$2" -v f="$3" '
    $0 ~ "^"p":" {in_p=1; next}
    in_p && $0 ~ "^  "f":" {sub(/^  [^:]*:[[:space:]]*/, ""); print; exit}
    in_p && $0 !~ /^  / {in_p=0}
  '
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

  # List all open PRs. gh-axiom's text format puts each PR row on a line
  # like "  324," in the pull_requests section. Extract just the numbers.
  pr_listing=$(gh-axi pr list --state open -R "${owner}/${repo}" --limit 1000 2>/dev/null) || {
    echo "$label: skipped: gh-axi pr list failed"
    return 0
  }
  [ -n "$pr_listing" ] || return 0

  pr_numbers=$(printf '%s\n' "$pr_listing" \
    | awk '/^[[:space:]]*[0-9]+,/ {split($0, a, ","); gsub(/[[:space:]]/, "", a[1]); print a[1]}')

  [ -n "$pr_numbers" ] || return 0

  # For each PR, get details via gh-axiom api and check if it needs a rebase.
  while IFS= read -r number; do
    [ -n "$number" ] || continue

    details=$(gh-axi api "/repos/${owner}/${repo}/pulls/${number}" 2>/dev/null) || continue
    [ -n "$details" ] || continue

    # mergeable_state from gh-axiom api is lowercase (e.g., "clean", "dirty").
    # Normalize to uppercase for reporting.
    state=$(extract_field "$details" "mergeable_state" | tr '[:lower:]' '[:upper:]')
    if [ -z "$state" ]; then
      state="UNKNOWN"
    fi
    base=$(extract_nested_field "$details" "base" "ref")
    head=$(extract_nested_field "$details" "head" "sha")

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
  done <<<"$pr_numbers"
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
