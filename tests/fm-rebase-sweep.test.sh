#!/usr/bin/env bash
# Behavior tests for bin/fm-rebase-sweep.sh.
#
# The sweep lists open PRs for a project, reads each PR's mergeable state via
# gh-axiom, and reports one line per PR that needs a rebase (conflicting or
# behind the base). It is silent when all PRs are clean, and a gh-axiom failure
# degrades to a single skip line rather than an error.
#
# Tests mock gh-axiom with a fakebin that responds to the real gh-axiom
# interface:
#   pr list --state open -R owner/repo --limit N   (returns gh-axiom text format)
#   api  /repos/owner/repo/pulls/<num>             (returns text PR details)
#   api  /repos/owner/repo/compare/<base>...<head>  (returns behind_by)
# TEST_REBASE_GH_FAIL=1 makes pr list fail to exercise the graceful-failure path.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_git_identity fmtest fmtest@example.invalid

SWEEP="$ROOT/bin/fm-rebase-sweep.sh"
TMP_ROOT=$(fm_test_tmproot fm-rebase-sweep-tests)

# --- fixtures ---------------------------------------------------------------

# Each test gets its own isolated home directory. A file-based counter is
# used because new_home is called in a command substitution subshell, so a
# shell variable would not survive across calls. This isolation matters
# because git init does not clear existing remotes, so a shared projects/
# dir would let one test's origin bleed into another.
new_home() {
  # fm_test_tmproot runs in a $(...) subshell whose EXIT trap may have already
  # removed $TMP_ROOT; recreate it so subsequent writes succeed.
  mkdir -p "$TMP_ROOT"
  local counter_file="$TMP_ROOT/.counter" n
  if [ -f "$counter_file" ]; then
    n=$(cat "$counter_file")
  else
    n=0
  fi
  n=$((n + 1))
  echo "$n" > "$counter_file"
  local h="$TMP_ROOT/home-$n"
  rm -rf "$h"
  mkdir -p "$h/projects"
  printf '%s\n' "$h"
}

# build_clone <home> <name> <remote_url>: create projects/<name> as a clone of
# a fresh bare repo, then override the origin remote to <remote_url> so the
# sweep can parse owner/repo from it. Echoes the clone path.
build_clone() {
  local home=$1 name=$2 remote_url=$3 work clone remote remote_abs
  work="$home/work-$name"
  remote="$home/remotes/$name.git"
  clone="$home/projects/$name"
  mkdir -p "$home/remotes"

  git init -q "$work"
  git -C "$work" symbolic-ref HEAD refs/heads/main
  git -C "$work" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m C0
  git clone --quiet --bare "$work" "$remote"
  remote_abs=$(CDPATH='' cd "$remote" && pwd)
  git -C "$work" remote add origin "file://$remote_abs"

  git clone --quiet "file://$remote_abs" "$clone"
  git -C "$clone" remote set-url origin "$remote_url"
  printf '%s\n' "$clone"
}

# build_fakebin <home>: create a fakebin/gh-axi mock that emulates the real
# gh-axiom text-based interface. Reads env:
#   TEST_REBASE_PR_LIST       (tab-separated rows: number state base head)
#   TEST_REBASE_BEHIND_<head> (behind count for that head SHA)
#   TEST_REBASE_GH_FAIL=1     (make pr list fail)
build_fakebin() {
  local home=$1 fakebin="$1/fakebin"
  mkdir -p "$fakebin"
  cat > "$fakebin/gh-axi" <<'SH'
#!/usr/bin/env bash
cmd="${1:-}"
subcmd="${2:-}"

if [ "$cmd" = "pr" ] && [ "$subcmd" = "list" ]; then
  if [ "${TEST_REBASE_GH_FAIL:-0}" = "1" ]; then
    echo "error: gh-axi not configured" >&2
    exit 1
  fi

  count=0
  while IFS=$'\t' read -r _n _s _b _h; do
    [ -n "$_n" ] || continue
    count=$((count + 1))
  done <<< "${TEST_REBASE_PR_LIST:-}"

  printf 'count: %d\n' "$count"
  printf 'pull_requests[%d]{number,title,state,author,draft,review}:\n' "$count"
  while IFS=$'\t' read -r number _s _b _h; do
    [ -n "$number" ] || continue
    printf '  %s,"Test PR #%s",open,depohmel,no,none\n' "$number" "$number"
  done <<< "${TEST_REBASE_PR_LIST:-}"
  printf 'help[0]:\n'
  exit 0
fi

if [ "$cmd" = "api" ]; then
  case "$2" in
    GET|POST|PUT|PATCH|DELETE|HEAD) url="${3:-}" ;;
    *) url="${2:-}" ;;
  esac
  case "$url" in
    */pulls/[0-9]*)
      number="${url##*/pulls/}"
      while IFS=$'\t' read -r pnum pstate pbase phead; do
        [ -n "$pnum" ] || continue
        if [ "$pnum" = "$number" ]; then
          printf 'number: %s\n' "$number"
          printf 'mergeable_state: %s\n' "$(printf '%s' "$pstate" | tr '[:upper:]' '[:lower:]')"
          printf 'base:\n'
          printf '  ref: %s\n' "$pbase"
          printf '  sha: 0000000000000000000000000000000000000000\n'
          printf 'head:\n'
          printf '  ref: test-branch\n'
          printf '  sha: %s\n' "$phead"
          exit 0
        fi
      done <<< "${TEST_REBASE_PR_LIST:-}"
      exit 0
      ;;
    */compare/*)
      compare_part="${url##*/compare/}"
      head="${compare_part#*...}"
      var="TEST_REBASE_BEHIND_${head}"
      printf 'behind_by: %s\n' "${!var:-0}"
      exit 0
      ;;
  esac
  exit 0
fi

exit 0
SH
  chmod +x "$fakebin/gh-axi"
  printf '%s\n' "$fakebin"
}

# run_sweep <home> <fakebin> <project-arg> [var=value pairs...]:
# Run the sweep with the fakebin on PATH. Extra args are var=value pairs
# passed to env(1) so they reach the sweep subprocess and its gh-axi mock.
run_sweep() {
  local home=$1 fakebin=$2 proj=$3
  shift 3
  env PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$@" "$SWEEP" "$proj" 2>/dev/null
}

# helper to build a tab-separated PR list row
pr_row() { printf '%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4"; }

# --- tests ------------------------------------------------------------------

test_conflicting_pr_reported() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" alpha "https://github.com/testorg/alpha.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "alpha" \
    "TEST_REBASE_PR_LIST=$(pr_row 323 DIRTY main abc123def456)" \
    "TEST_REBASE_BEHIND_abc123def456=0")

  assert_contains "$out" "alpha: PR #323 DIRTY behind=0 rebase-needed" \
    "conflicting PR should be reported with DIRTY state and behind=0"
  pass "PR reported as conflicting (DIRTY) with behind count"
}

test_behind_but_clean_pr_reported() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" beta "https://github.com/testorg/beta.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "beta" \
    "TEST_REBASE_PR_LIST=$(pr_row 322 BEHIND main xyz789abc123)" \
    "TEST_REBASE_BEHIND_xyz789abc123=5")

  assert_contains "$out" "beta: PR #322 BEHIND behind=5 rebase-needed" \
    "behind-but-clean PR should be reported with BEHIND state and behind=5"
  pass "PR reported as behind base (BEHIND) with behind count"
}

test_clean_pr_is_silent() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" gamma "https://github.com/testorg/gamma.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "gamma" \
    "TEST_REBASE_PR_LIST=$(pr_row 324 CLEAN main ghi321jkl654)" \
    "TEST_REBASE_BEHIND_ghi321jkl654=0")

  [ -z "$out" ] || fail "clean PR should produce no output, got: $out"
  pass "PR needing nothing (CLEAN) produces no output"
}

test_multiple_prs_mixed_states() {
  local home fakebin out rows
  home=$(new_home)
  build_clone "$home" delta "https://github.com/testorg/delta.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  rows="$(pr_row 322 BEHIND main abc111)"$'\n'"$(pr_row 323 DIRTY main abc222)"$'\n'"$(pr_row 324 CLEAN main abc333)"

  out=$(run_sweep "$home" "$fakebin" "delta" \
    "TEST_REBASE_PR_LIST=$rows" \
    "TEST_REBASE_BEHIND_abc111=3" \
    "TEST_REBASE_BEHIND_abc222=0" \
    "TEST_REBASE_BEHIND_abc333=0")

  assert_contains "$out" "delta: PR #322 BEHIND behind=3 rebase-needed" \
    "behind PR should be reported"
  assert_contains "$out" "delta: PR #323 DIRTY behind=0 rebase-needed" \
    "dirty PR should be reported"
  assert_not_contains "$out" "324" \
    "clean PR #324 should not appear"
  pass "multiple PRs: conflicting and behind are reported, clean is silent"
}

test_gh_failure_degrades_gracefully() {
  local home fakebin out rc
  home=$(new_home)
  build_clone "$home" epsilon "https://github.com/testorg/epsilon.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  set +e
  out=$(run_sweep "$home" "$fakebin" "epsilon" \
    "TEST_REBASE_GH_FAIL=1" \
    "TEST_REBASE_PR_LIST=$(pr_row 329 CLEAN main abc999)")
  rc=$?
  set -e

  [ "$rc" -eq 0 ] || fail "gh-axiom failure should not cause non-zero exit, got $rc"
  assert_contains "$out" "epsilon: skipped: gh-axi pr list failed" \
    "gh-axiom failure should produce a skip line, not an error"
  pass "gh-axiom failure degrades to a skip line without erroring the sweep"
}

test_non_github_origin_skipped() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" zeta "https://gitlab.com/testorg/zeta.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "zeta" \
    "TEST_REBASE_PR_LIST=$(pr_row 330 DIRTY main abc330)")

  assert_contains "$out" "zeta: skipped: non-github origin" \
    "non-GitHub origin should be skipped"
  pass "non-GitHub origin is skipped (best-effort)"
}

test_no_open_prs_is_silent() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" eta "https://github.com/testorg/eta.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "eta" \
    "TEST_REBASE_PR_LIST=")

  [ -z "$out" ] || fail "no open PRs should produce no output, got: $out"
  pass "no open PRs produces no output"
}

test_unknown_state_behind_count_drives_report() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" theta "https://github.com/testorg/theta.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "theta" \
    "TEST_REBASE_PR_LIST=$(pr_row 325 UNKNOWN main unk777head)" \
    "TEST_REBASE_BEHIND_unk777head=4")

  assert_contains "$out" "theta: PR #325 UNKNOWN behind=4 rebase-needed" \
    "UNKNOWN state with behind>0 should be reported"
  pass "PR with UNKNOWN state and positive behind count is reported"
}

test_unknown_state_zero_behind_is_silent() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" iota "https://github.com/testorg/iota.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "iota" \
    "TEST_REBASE_PR_LIST=$(pr_row 326 UNKNOWN main unk000head)" \
    "TEST_REBASE_BEHIND_unk000head=0")

  [ -z "$out" ] || fail "UNKNOWN state with behind=0 should be silent, got: $out"
  pass "PR with UNKNOWN state and behind=0 is silent"
}

test_local_only_project_skipped() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" kappa "https://github.com/testorg/kappa.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  mkdir -p "$home/data"
  printf -- '- kappa [local-only] - test project (added 2026-06-27)\n' > "$home/data/projects.md"

  out=$(run_sweep "$home" "$fakebin" "kappa" \
    "TEST_REBASE_PR_LIST=$(pr_row 331 DIRTY main abc331)")

  assert_contains "$out" "kappa: skipped: local-only project" \
    "local-only project should be skipped"
  pass "local-only project is skipped"
}

test_single_project_by_bare_name() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" lambda "https://github.com/testorg/lambda.git" >/dev/null
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "lambda" \
    "TEST_REBASE_PR_LIST=$(pr_row 327 DIRTY main xyz327abc)" \
    "TEST_REBASE_BEHIND_xyz327abc=0")

  assert_contains "$out" "lambda: PR #327 DIRTY behind=0 rebase-needed" \
    "bare project name resolves against the home's projects dir"
  pass "single-project form accepts a bare project name"
}

test_ssh_remote_url_parsed() {
  local home fakebin out
  home=$(new_home)
  build_clone "$home" mu "https://github.com/testorg/mu.git" >/dev/null
  git -C "$home/projects/mu" remote set-url origin "git@github.com:testorg/mu.git"
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "mu" \
    "TEST_REBASE_PR_LIST=$(pr_row 328 BEHIND main ssh328head)" \
    "TEST_REBASE_BEHIND_ssh328head=2")

  assert_contains "$out" "mu: PR #328 BEHIND behind=2 rebase-needed" \
    "SSH remote URL should be parsed for owner/repo"
  pass "SSH remote URL (git@github.com:owner/repo.git) is parsed"
}

test_no_origin_skipped() {
  local home fakebin out clone
  home=$(new_home)
  clone="$home/projects/nu"
  git init -q "$clone"
  git -C "$clone" symbolic-ref HEAD refs/heads/main
  git -C "$clone" -c user.name='Firstmate Tests' -c user.email='tests@example.invalid' \
    commit -q --allow-empty -m C0
  fakebin=$(build_fakebin "$home")

  out=$(run_sweep "$home" "$fakebin" "nu" \
    "TEST_REBASE_PR_LIST=$(pr_row 332 DIRTY main abc332)")

  assert_contains "$out" "nu: skipped: no origin remote" \
    "missing origin should be skipped"
  pass "no origin remote is skipped (best-effort)"
}

test_help_flag() {
  local home fakebin rc
  home=$(new_home)
  fakebin=$(build_fakebin "$home")

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWEEP" "--help" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "help flag should exit 0"
  pass "--help flag exits 0"
}

test_too_many_args_refuses() {
  local home fakebin rc
  home=$(new_home)
  fakebin=$(build_fakebin "$home")

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWEEP" "one" "two" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 1 "$rc" "too many args should exit 1"
  pass "too many arguments is refused"
}

test_fm_home_resolved_from_environment() {
  # When FM_HOME is set in the environment, the sweep must use it rather than
  # falling back to FM_ROOT (the script's own parent dir). This makes the
  # sweep safe to invoke from anywhere, including inside a worktree on a
  # feature branch, without tripping the tangle guard.
  local home fakebin rc
  home=$(new_home)
  fakebin=$(build_fakebin "$home")
  build_clone "$home" phi "https://github.com/testorg/phi.git" >/dev/null

  set +e
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_ROOT_OVERRIDE="$ROOT" \
    "$SWEEP" "phi" >/dev/null 2>&1
  rc=$?
  set -e

  expect_code 0 "$rc" "sweep should use FM_HOME from environment"
  pass "FM_HOME resolved from environment (worktree-safe)"
}

test_conflicting_pr_reported
test_behind_but_clean_pr_reported
test_clean_pr_is_silent
test_multiple_prs_mixed_states
test_gh_failure_degrades_gracefully
test_non_github_origin_skipped
test_no_open_prs_is_silent
test_unknown_state_behind_count_drives_report
test_unknown_state_zero_behind_is_silent
test_local_only_project_skipped
test_single_project_by_bare_name
test_ssh_remote_url_parsed
test_no_origin_skipped
test_fm_home_resolved_from_environment
test_help_flag
test_too_many_args_refuses
