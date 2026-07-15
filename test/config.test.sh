#!/bin/bash
# Tests for the .checkup.yml override parser (lib/config.sh).
#
# Feeds fixture YAML through load_checkup_config (the real parser bin/checkup.sh
# uses) and asserts the override variables it sets — env-independent (no yq
# needed; the bash path is exercised directly). Covers each capability, the
# missing-file no-op, malformed-input tolerance, and the disable/enable toggles.
# Each case parses in a subshell so override state can't leak between cases.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# shellcheck source=../lib/config.sh
source "$CHECKUP_HOME/lib/config.sh"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}
# Write $1 to a temp file and echo its path.
yml() { local f; f="$TMP/c$RANDOM.yml"; printf '%s\n' "$1" > "$f"; printf '%s' "$f"; }

echo "missing file is a pure no-op"
( load_checkup_config "$TMP/does-not-exist.yml"
  [ "${CHECKUP_OVERRIDDEN:-unset}" = "false" ] ) && ok "absent → overridden=false" || notok "absent → overridden=false"

echo ""
echo "stack.force / stack.suppress"
F=$(yml 'stack:
  force: dotnet
  suppress: [node, go]')
assert_eq "force"    "dotnet"   "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_FORCE_STACK" )"
assert_eq "suppress" "node go " "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_SUPPRESS_STACKS" )"
assert_eq "overridden flips" "true" "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_OVERRIDDEN" )"

echo ""
echo "commands override map to CHECKUP_CMD_* (incl. explicit empty = disable)"
F=$(yml 'commands:
  test: "deno test"
  typeaware: npx eslint .
  coverage: ""')
assert_eq "test"      "deno test"   "$( load_checkup_config "$F"; printf '%s' "${CHECKUP_CMD_TEST:-UNSET}" )"
assert_eq "typeaware" "npx eslint ." "$( load_checkup_config "$F"; printf '%s' "${CHECKUP_CMD_TYPEAWARE:-UNSET}" )"
assert_eq "coverage empty (set, not unset)" "" "$( load_checkup_config "$F"; printf '%s' "${CHECKUP_CMD_COVERAGE-UNSET}" )"

echo ""
echo "checks.disable / enable"
F=$(yml 'checks:
  disable: [mutation, unit-tests]
  enable: [mutation]')
assert_eq "disable list" "mutation unit-tests " "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_DISABLE" )"
assert_eq "enable list"  "mutation "            "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_ENABLE" )"

echo ""
echo "top-level exclude: cross-scanner globs (#18) — incl. quoted directory globs"
F=$(yml 'exclude: [vendor/js/*, "a b/*", build/*]')
assert_eq "exclude → CHECKUP_EXCLUDE" "vendor/js/* a b/* build/*" \
    "$( unset CHECKUP_EXCLUDE; load_checkup_config "$F"; printf '%s' "$CHECKUP_EXCLUDE" )"
assert_eq "exclude flips overridden" "true" \
    "$( unset CHECKUP_EXCLUDE; load_checkup_config "$F"; printf '%s' "$CHECKUP_OVERRIDDEN" )"
assert_eq "exclude MERGES with env CHECKUP_EXCLUDE (additive)" "*.min.js vendor/js/* a b/* build/*" \
    "$( CHECKUP_EXCLUDE='*.min.js'; load_checkup_config "$F"; printf '%s' "$CHECKUP_EXCLUDE" )"
# A single bare glob (no brackets) is accepted too.
F=$(yml 'exclude: vendor/*')
assert_eq "bare single glob" "vendor/*" \
    "$( unset CHECKUP_EXCLUDE; load_checkup_config "$F"; printf '%s' "$CHECKUP_EXCLUDE" )"
# Empty list is a no-op (must NOT flip overridden).
F=$(yml 'exclude: []')
assert_eq "empty exclude → no-op (overridden stays false)" "false" \
    "$( unset CHECKUP_EXCLUDE; CHECKUP_OVERRIDDEN=false; load_checkup_config "$F"; printf '%s' "$CHECKUP_OVERRIDDEN" )"

echo ""
echo "apply_check_toggles empties a disabled check's command, enables mutation"
out=$( CHECKUP_DISABLE="unit-tests"; CHECKUP_ENABLE="mutation"; CHECKUP_CMD_TEST="npm test"
       apply_check_toggles
       printf '%s|%s' "${CHECKUP_CMD_TEST-UNSET}" "${MUTATION_TEST:-UNSET}" )
assert_eq "disabled unit-tests → empty TEST, mutation enabled" "|1" "$out"

echo ""
echo "comments, blank lines, and CRLF are tolerated"
F=$(yml '# a comment
stack:
  force: python   # inline comment

')
assert_eq "force despite comments" "python" "$( load_checkup_config "$F"; printf '%s' "$CHECKUP_FORCE_STACK" )"

echo ""
echo "malformed / unknown keys warn but never abort or false-pass"
F=$(yml 'stack:
  nonsense: 1
commands:
  bogus: x
wat: true')
( load_checkup_config "$F" 2>/dev/null
  # parser returns 0, applies nothing harmful, leaves known vars unset
  [ -z "${CHECKUP_FORCE_STACK:-}" ] ) && ok "unknown keys ignored, no abort" || notok "unknown keys ignored, no abort"

echo ""
echo "mark_disabled_skips rewrites a disabled check's reason honestly"
PD="$TMP/parsed"; mkdir -p "$PD"
printf '{"slug":"unit-tests","status":"skip","count":0,"summary":"no package.json at the target","top":[],"intent":{}}' > "$PD/unit-tests.json"
printf '{"slug":"gitleaks","status":"pass","count":0,"summary":"clean","top":[],"intent":{}}' > "$PD/gitleaks.json"
( CHECKUP_DISABLE="unit-tests gitleaks"; mark_disabled_skips "$PD" )
assert_eq "disabled+skipped → honest reason" "disabled in .checkup.yml" "$(jq -r '.summary' "$PD/unit-tests.json")"
assert_eq "a check that RAN is untouched"    "clean"                    "$(jq -r '.summary' "$PD/gitleaks.json")"

echo ""
echo "thresholds: per-check warn/fail banding (#72)"
TH=$(yml 'thresholds:
  complexity_ccn_warn: 15
  complexity_ccn_fail: 25
  duplication_warn_pct: 4
  duplication_fail_pct: 8')
assert_eq "complexity_ccn_warn"  "15"   "$( load_checkup_config "$TH"; printf '%s' "${CHECKUP_CPLX_CCN_WARN:-}" )"
assert_eq "complexity_ccn_fail"  "25"   "$( load_checkup_config "$TH"; printf '%s' "${CHECKUP_CPLX_CCN_FAIL:-}" )"
assert_eq "duplication_warn_pct" "4"    "$( load_checkup_config "$TH"; printf '%s' "${CHECKUP_DUP_WARN_PCT:-}" )"
assert_eq "duplication_fail_pct" "8"    "$( load_checkup_config "$TH"; printf '%s' "${CHECKUP_DUP_FAIL_PCT:-}" )"
assert_eq "thresholds flip overridden" "true" "$( load_checkup_config "$TH"; printf '%s' "$CHECKUP_OVERRIDDEN" )"

# Ownership / bus-factor thresholds (ADR-0010, #127)
TO=$(yml 'thresholds:
  ownership_keyperson_pct_warn: 60
  ownership_sole_author_pct_warn: 40
  ownership_orphan_months: 9')
assert_eq "ownership_keyperson_pct_warn"   "60" "$( load_checkup_config "$TO"; printf '%s' "${CHECKUP_OWNERSHIP_KEYPERSON_PCT:-}" )"
assert_eq "ownership_sole_author_pct_warn" "40" "$( load_checkup_config "$TO"; printf '%s' "${CHECKUP_OWNERSHIP_SOLE_PCT:-}" )"
assert_eq "ownership_orphan_months"        "9"  "$( load_checkup_config "$TO"; printf '%s' "${CHECKUP_OWNERSHIP_ORPHAN_MONTHS:-}" )"

echo ""
echo "thresholds: non-integer warns + is ignored (default preserved), siblings still parse"
TG=$(yml 'thresholds:
  complexity_ccn_warn: abc
  duplication_fail_pct: 8')
assert_eq "garbage value → var stays unset" "unset" "$( load_checkup_config "$TG" 2>/dev/null; printf '%s' "${CHECKUP_CPLX_CCN_WARN:-unset}" )"
assert_eq "sibling valid value still set"    "8"     "$( load_checkup_config "$TG" 2>/dev/null; printf '%s' "${CHECKUP_DUP_FAIL_PCT:-unset}" )"
assert_eq "garbage emits a warning"          "1"     "$( load_checkup_config "$TG" 2>&1 >/dev/null | grep -c 'must be a non-negative integer' )"

echo ""
echo "thresholds: unknown key warns + is ignored"
TU=$(yml 'thresholds:
  complexity_ccn_budget: 12')
assert_eq "unknown threshold key warns" "1" "$( load_checkup_config "$TU" 2>&1 >/dev/null | grep -c "unknown key .thresholds.complexity_ccn_budget" )"

echo ""
echo "_cfg_int: use-site guard (integer in, default on garbage)"
assert_eq "valid integer passes through" "15" "$(_cfg_int "15" 10)"
assert_eq "empty → default"              "10" "$(_cfg_int "" 10)"
assert_eq "non-integer → default"        "30" "$(_cfg_int "10x" 30)"
assert_eq "negative → default"           "5"  "$(_cfg_int "-2" 5)"

echo ""
echo ".checkup.yml.example stays in sync with the parser (no unknown keys)"
EX="$CHECKUP_HOME/.checkup.yml.example"
if [ -f "$EX" ]; then
    # Uncomment only the commented key lines (`  # key: …`), leave prose comments.
    UNC="$TMP/example-uncommented.yml"
    sed -E 's/^( *)# ([a-z_]+:)/\1\2/' "$EX" > "$UNC"
    warns=$( load_checkup_config "$UNC" 2>&1 >/dev/null | grep -c '⚠️' || true )
    assert_eq "example parses with no warnings" "0" "$warns"
else
    notok "example present (.checkup.yml.example missing)"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
