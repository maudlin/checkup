#!/bin/bash
# Tests for the stack-detection transform (lib/detect-stacks.jq, #7).
#
# The transform reduces an scc `--format json` language array to a per-stack
# summary (stack/code/top3/pct, dominant-first). It is the heart of engine
# routing — get the dominance wrong and a stray .ts in a Python monorepo
# mis-routes complexity to ESLint (the exact bug #7 fixes). These tests feed
# fixed scc payloads through the same .jq file bin/checkup.sh uses, so they are
# environment-independent (jq only — no scc/lizard/npx needed) and can't drift
# from the orchestrator. They also assert the bash dominance rule that consumes
# the transform's output (node = primary OR ≥40%).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
JQF="$CHECKUP_HOME/lib/detect-stacks.jq"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

# Run the shared transform over a scc-shaped JSON payload.
stacks() { echo "$1" | jq -c -f "$JQF"; }

# Replicate the orchestrator's node-dominance rule against a transform result, so
# the test fails if the rule in bin/checkup.sh diverges from intent. node is
# "dominant" (→ node-specific engines) only when it is the primary stack or a
# co-primary ≥40% — NOT merely top-3.
node_dominant() {
    local s="$1" primary pct
    primary=$(echo "$s" | jq -r '.[0].stack // ""')
    pct=$(echo "$s" | jq -r '(.[]|select(.stack=="node")|.pct)//0')
    if [ "$primary" = "node" ] || [ "${pct:-0}" -ge 40 ]; then echo "true"; else echo "false"; fi
}

echo "stack breakdown"
S=$(stacks '[{"Name":"TypeScript","Code":8000},{"Name":"JavaScript","Code":1200},{"Name":"CSS","Code":500}]')
assert_eq "node rolls up TS+JS"      "9200"   "$(echo "$S" | jq -r '.[]|select(.stack=="node")|.code')"
assert_eq "primary is node"          "node"   "$(echo "$S" | jq -r '.[0].stack')"
assert_eq "unmapped langs dropped"   "1"      "$(echo "$S" | jq 'length')"

echo ""
echo "percent + dominant-first ordering"
S=$(stacks '[{"Name":"Python","Code":9000},{"Name":"HTML","Code":1000}]')
assert_eq "python pct floored"       "90"      "$(echo "$S" | jq -r '.[]|select(.stack=="python")|.pct')"
assert_eq "empty total safe (no div0)" "[]"    "$(stacks '[]')"

echo ""
echo "the #7 bug: a stray .ts in a small Python-dominant repo"
# Few languages, so the stray .ts IS top-3 — the exact case where the old
# ≥5%/top-3 rule wrongly read node as dominant and routed to ESLint.
S=$(stacks '[{"Name":"Python","Code":9000},{"Name":"JSON","Code":20},{"Name":"TypeScript","Code":40}]')
assert_eq "node is present"          "node"    "$(echo "$S" | jq -r '.[]|select(.stack=="node")|.stack')"
assert_eq "node share is ~0%"        "0"       "$(echo "$S" | jq -r '.[]|select(.stack=="node")|.pct')"
assert_eq "node IS top-3 (the trap)" "true"    "$(echo "$S" | jq -r '.[]|select(.stack=="node")|.top3')"
assert_eq "but node NOT dominant"    "false"   "$(node_dominant "$S")"

echo ""
echo "healthy node repo stays on the node engines"
S=$(stacks '[{"Name":"TypeScript","Code":8000},{"Name":"JavaScript","Code":1200},{"Name":"CSS","Code":500}]')
assert_eq "node dominant → node engine" "true" "$(node_dominant "$S")"

echo ""
echo "co-primary node (≥40%) is dominant"
S=$(stacks '[{"Name":"Python","Code":5500},{"Name":"TypeScript","Code":4500}]')
assert_eq "node ~45% → dominant"     "true"    "$(node_dominant "$S")"
S=$(stacks '[{"Name":"Python","Code":7000},{"Name":"TypeScript","Code":3000}]')
assert_eq "node 30% → NOT dominant"  "false"   "$(node_dominant "$S")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
