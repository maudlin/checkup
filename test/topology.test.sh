#!/bin/bash
# Tests for lib/detect-topology.sh (#78) — "the scan root is a hypothesis".
#
# Env-independent (jq + a temp tree only; no npm/scc/git). Drives the pure
# classifier hard, plus the thin filesystem gatherers against synthetic trees.
# The load-bearing assertions: an undeclared fan-out is detected, and a DECLARED
# workspace must NOT be mistaken for one (don't cry wolf).

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
# shellcheck source=../lib/detect-topology.sh
source "$CHECKUP_HOME/lib/detect-topology.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"
    fi
}
assert_glue()    { if topology_script_is_glue "$2"; then ok "$1"; else notok "$1 (expected glue)"; fi; }
assert_real()    { if topology_script_is_glue "$2"; then notok "$1 (expected real)"; else ok "$1"; fi; }

echo "topology_script_is_glue — glue (delegation) vs real work"
assert_glue "cd into sub-dir"          "cd backend && npm run dev"
assert_glue "leading whitespace + cd"  "   cd frontend && vite"
assert_glue "npm run delegation"       "npm run dev:backend & npm run dev:frontend & wait"
assert_glue "concurrently"             "concurrently \"npm:dev:*\""
assert_glue "turbo"                    "turbo run build"
assert_glue "pnpm -r"                  "pnpm -r build"
assert_glue "empty script"             ""
assert_real "real build (vite)"        "vite build"
assert_real "real tsc"                 "tsc -p tsconfig.json"
assert_real "real jest"               "jest --coverage"
assert_real "real rimraf chain"        "rimraf dist && tsc"

echo ""
echo "classify_topology — the four shapes"
#                       pkg   ws    wstool lock  real  children
assert_eq "undeclared fan-out" "undeclared-fan-out" "$(classify_topology true  false "" false false 3)"
assert_eq "single (lockfile)"  "single"             "$(classify_topology true  false "" true  true  0)"
assert_eq "single (1 child)"   "single"             "$(classify_topology true  false "" false true  1)"
assert_eq "orphan root"        "orphan-root"        "$(classify_topology true  false "" false false 0)"
assert_eq "no root package"    "n/a"                "$(classify_topology false false "" false false 0)"

echo ""
echo "classify_topology — declared workspaces must NOT alarm (don't cry wolf)"
# Even with self-contained children present, a declared workspace is healthy.
assert_eq "workspaces array → declared" "declared-workspace" "$(classify_topology true true  ""      false false 3)"
assert_eq "pnpm tool → declared"        "declared-workspace" "$(classify_topology true false "pnpm"  false false 3)"
assert_eq "nx tool → declared"          "declared-workspace" "$(classify_topology true false "nx"    false false 3)"
assert_eq "turbo tool → declared"       "declared-workspace" "$(classify_topology true false "turbo" false false 3)"
assert_eq "lerna tool → declared"       "declared-workspace" "$(classify_topology true false "lerna" false false 3)"
# Hoisted single lockfile + many children but NO workspace decl → not the smell.
assert_eq "root lockfile + children → single" "single" "$(classify_topology true false "" true false 3)"

echo ""
echo "filesystem gatherers on a synthetic undeclared fan-out"
FAN="$TMP/fan"
mkdir -p "$FAN/backend" "$FAN/frontend" "$FAN/tests" "$FAN/node_modules/dep" "$FAN/docs"
# Orchestrator root: glue scripts, no lockfile, no workspaces.
cat > "$FAN/package.json" <<'JSON'
{ "name": "root", "workspaces": null, "scripts": { "dev": "npm run dev:backend & npm run dev:frontend", "dev:backend": "cd backend && npm run dev" } }
JSON
for c in backend frontend tests; do
    echo '{"name":"'"$c"'","scripts":{"build":"tsc"}}' > "$FAN/$c/package.json"
    echo '{}' > "$FAN/$c/package-lock.json"
done
# A node_modules package + a non-package dir must NOT count as children.
echo '{"name":"dep"}' > "$FAN/node_modules/dep/package.json"
echo '{}' > "$FAN/node_modules/dep/package-lock.json"

( cd "$FAN" || exit 1
  if topology_has_workspaces package.json; then echo HASWS; else echo NOWS; fi
  topology_has_lockfile . && echo ROOTLOCK || echo NOROOTLOCK
  topology_has_real_scripts package.json && echo REAL || echo NOREAL
  printf 'children:%s\n' "$(topology_children . | paste -sd, -)"
) > "$TMP/fan.out"
assert_eq "root has no workspaces"        "NOWS"        "$(sed -n 1p "$TMP/fan.out")"
assert_eq "root has no lockfile"          "NOROOTLOCK"  "$(sed -n 2p "$TMP/fan.out")"
assert_eq "root scripts are all glue"     "NOREAL"      "$(sed -n 3p "$TMP/fan.out")"
assert_eq "children = backend,frontend,tests (node_modules/docs excluded)" \
          "children:backend,frontend,tests" "$(sed -n 4p "$TMP/fan.out")"

echo ""
echo "filesystem gatherers on a declared workspace"
WS="$TMP/ws"
mkdir -p "$WS/packages/a"
cat > "$WS/package.json" <<'JSON'
{ "name": "ws-root", "workspaces": ["packages/*"], "scripts": { "build": "turbo run build" } }
JSON
echo '{}' > "$WS/package-lock.json"
( cd "$WS" || exit 1; topology_has_workspaces package.json && echo HASWS || echo NOWS ) > "$TMP/ws.out"
assert_eq "declared workspaces detected" "HASWS" "$(cat "$TMP/ws.out")"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
