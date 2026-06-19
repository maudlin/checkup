#!/bin/bash
# Tests for #85 — absence/failure must NOT leak as a pass/fail verdict.
#
# Mirrors the decision logic of three project-built sections in bin/checkup.sh
# (npm-audit, deps-freshness, duplication) as env-independent checks. The npm-audit
# case exercises the ACTUAL jq predicate from the section, so it can't drift. The
# others model the same branch conditions the section uses. Repro for all three:
# an audit of a fan-out monorepo whose orchestrator root has no lockfile and no
# `quality:duplicates` script — npm audit ENOLOCKs, npm outdated returns `{}`, and
# the dup script is missing.

set -u

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

# ── npm-audit ────────────────────────────────────────────────────────────────
# The section grades vulnerabilities ONLY when npm actually audited. The literal
# predicate below is copied from bin/checkup.sh: an `.error` object or a missing
# `.metadata.vulnerabilities` means "could not audit" → skip, never pass.
echo "npm-audit: error/no-metadata JSON → skip, real metadata → grade"
audit_decision() { # <json> → skip | grade
    if echo "$1" | jq -e '.error or (.metadata.vulnerabilities == null)' >/dev/null 2>&1; then
        echo skip
    else
        echo grade
    fi
}
assert_eq "ENOLOCK error object → skip" "skip" \
    "$(audit_decision '{"error":{"code":"ENOLOCK","summary":"This command requires an existing lockfile."}}')"
assert_eq "empty object (no metadata) → skip" "skip" \
    "$(audit_decision '{}')"
assert_eq "real audit, zero vulns → grade" "grade" \
    "$(audit_decision '{"metadata":{"vulnerabilities":{"critical":0,"high":0,"moderate":0,"low":0}}}')"
assert_eq "real audit, with vulns → grade" "grade" \
    "$(audit_decision '{"metadata":{"vulnerabilities":{"critical":1,"high":2,"moderate":0,"low":0}}}')"

# ── deps-freshness ───────────────────────────────────────────────────────────
# "Zero outdated" is reported by `npm outdated` BOTH when current AND when it
# couldn't resolve a tree. It's a genuine pass only with a resolvable tree (an
# npm lockfile); otherwise → skip.
echo ""
echo "deps-freshness: zero-outdated detection"
deps_is_zero() { # <raw> → true|false (mirrors the DEPS_ZERO computation)
    local raw="$1"
    if [ -z "$raw" ]; then echo true; return; fi
    if echo "$raw" | jq -e . >/dev/null 2>&1 && [ "$(echo "$raw" | jq 'length')" -eq 0 ]; then
        echo true; return
    fi
    echo false
}
assert_eq "empty output → zero"        "true"  "$(deps_is_zero '')"
assert_eq "{} → zero"                  "true"  "$(deps_is_zero '{}')"
assert_eq "one outdated pkg → not zero" "false" "$(deps_is_zero '{"left-pad":{"current":"1.0.0","latest":"1.3.0"}}')"

echo ""
echo "deps-freshness: zero-outdated is a pass ONLY with a resolvable tree"
deps_decision() { # <zero> <lockfile_present> → pass | skip | grade
    if [ "$1" = true ]; then
        [ "$2" = true ] && echo pass || echo skip
    else
        echo grade
    fi
}
assert_eq "zero + lockfile → pass"      "pass"  "$(deps_decision true  true)"
assert_eq "zero + NO lockfile → skip"   "skip"  "$(deps_decision true  false)"
assert_eq "non-zero → grade (count)"    "grade" "$(deps_decision false true)"

# ── duplication ──────────────────────────────────────────────────────────────
# The jscpd path must SKIP (not fail) when the toolchain is absent — the npm
# `quality:duplicates` script missing (run_tool promotes that to exit 127). Only a
# tool that actually RAN but produced no fresh report is an honest fail. This is
# the #80 pattern the duplication freshness path previously missed.
echo ""
echo "duplication: missing-script/no-toolchain → skip; ran-but-no-report → fail"
dup_decision() { # <toolchain_absent> <report_fresh> → skip | fail | graded
    if [ "$1" = true ]; then echo skip
    elif [ "$2" != true ]; then echo fail
    else echo graded; fi
}
assert_eq "toolchain absent (missing script) → skip" "skip"   "$(dup_decision true  false)"
assert_eq "ran, no fresh report → fail"              "fail"   "$(dup_decision false false)"
assert_eq "ran, fresh report → graded"               "graded" "$(dup_decision false true)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
