#!/bin/bash
# Tests for the command-profile layer (lib/profile.sh + profiles/node.sh, #6).
#
# Proves: (1) the default Node profile resolves to the exact commands the
# orchestrator hardcoded before profiles existed (the byte-identical guarantee);
# (2) an environment CHECKUP_CMD_* overrides a profile default; (3) an explicit
# empty value disables a command; (4) an unset command routes run_profiled through
# the LAST_EXIT=127 skip path. Each scenario runs in a subshell so CHECKUP_CMD_*
# state can't leak between cases. Env-independent (no npm/npx needed).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export RAW_DIR="$TMP/raw"
export PARSED_DIR="$TMP/parsed"
mkdir -p "$RAW_DIR" "$PARSED_DIR"

# shellcheck source=../lib/run-tool.sh
source "$CHECKUP_HOME/lib/run-tool.sh"
# shellcheck source=../lib/profile.sh
source "$CHECKUP_HOME/lib/profile.sh"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

echo "default Node profile == the previously-hardcoded commands"
# The canonical name → command map the orchestrator used before #6. If this
# drifts from profiles/node.sh, a Node repo's behaviour changed — fail loudly.
while IFS='|' read -r name expected; do
    [ -z "$name" ] && continue
    actual=$( unset "CHECKUP_CMD_$name"; load_profile "" "$CHECKUP_HOME"; cmd_for "$name" )
    assert_eq "$name → $expected" "$expected" "$actual"
done <<'EOF'
TYPECHECK|npm run typecheck
TEST|npm test
FORMAT|npm run format:check
LINT|npm run lint
TYPEAWARE|npx eslint -c eslint.config.type-aware.js
BUILD|npm run build
DEPS|npm run quality:deps
UNUSED|npm run quality:unused
COVERAGE|npm run test:coverage:report
MUTATION|npx stryker run
SECURITY|npm run quality:security
AUDIT|npm audit --json
OUTDATED|npm outdated --json
EOF

echo ""
echo "environment override wins over the profile default"
actual=$( export CHECKUP_CMD_TEST="deno test"; load_profile "" "$CHECKUP_HOME"; cmd_for TEST )
assert_eq "CHECKUP_CMD_TEST overrides" "deno test" "$actual"

echo ""
echo "explicit empty value disables a command (not overwritten by the default)"
actual=$( export CHECKUP_CMD_COVERAGE=""; load_profile "" "$CHECKUP_HOME"; cmd_for COVERAGE )
assert_eq "empty COVERAGE stays empty" "" "$actual"

echo ""
echo "a stack profile is preferred; absence falls back to Node defaults"
actual=$( unset CHECKUP_CMD_TEST; load_profile "no-such-stack" "$CHECKUP_HOME"; cmd_for TEST )
assert_eq "unknown stack → Node default" "npm test" "$actual"

echo ""
echo "run_profiled routes an unset command through the 127 (skip) path"
( unset CHECKUP_CMD_TEST; export CHECKUP_CMD_TEST=""; load_profile "" "$CHECKUP_HOME"
  run_profiled TEST "Unit Tests"
  [ "${LAST_EXIT:-0}" = "127" ] ) && ok "unset command → LAST_EXIT 127" || notok "unset command → LAST_EXIT 127"

echo ""
echo "run_profiled with a set command dispatches it (LAST_EXIT 0 for a real tool)"
( load_profile "" "$CHECKUP_HOME"; export CHECKUP_CMD_TEST="true"
  run_profiled TEST "Unit Tests"
  [ "${LAST_EXIT:-1}" = "0" ] ) && ok "set command → run via run_tool" || notok "set command → run via run_tool"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
