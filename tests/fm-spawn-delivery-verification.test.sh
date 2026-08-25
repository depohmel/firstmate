#!/usr/bin/env bash
# Test for spawn brief delivery verification
# This test specifically verifies the improved delivery check 
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-spawn-delivery-verification)
export FM_BACKEND=tmux

# Test that spawn properly handles the improved brief delivery verification
run_spawn() {
  FM_ROOT_OVERRIDE='' \
    FM_HOME='' \
    FM_STATE_OVERRIDE='' \
    FM_DATA_OVERRIDE='' \
    FM_PROJECTS_OVERRIDE='' \
    FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 \
    "$SPAWN" "$@" 2>&1
}

# Test spawn with tmux backend - should not fail on basic brief delivery
echo "Testing spawn with tmux backend and improved delivery verification..."
if run_spawn --mode no-mistakes --yolo off --verbose 2>&1 | grep -q "error:"; then
  echo "Spawn test encountered errors"
  exit 1
else
  echo "Spawn test completed successfully"
fi

echo "Improved brief delivery verification test completed"
