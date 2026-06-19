#!/bin/bash
# Tests for lib/run-tool.sh
#
# Sources the helper and asserts the contract documented in README.md:
# slug derivation, stdout/stderr capture, graceful-degrade on missing tools,
# parsed-JSON shape, status validation.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
LIB="$CHECKUP_HOME/lib/run-tool.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

export RAW_DIR="$TMP/raw"
export PARSED_DIR="$TMP/parsed"

# shellcheck source=../lib/run-tool.sh
source "$LIB"

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

assert_file_exists()     { [ -f "$2" ] && ok "$1" || notok "$1 (missing: $2)"; }
assert_file_missing()    { [ ! -f "$2" ] && ok "$1" || notok "$1 (should not exist: $2)"; }
assert_json_field()      {
    local name="$1" file="$2" path="$3" expected="$4"
    local actual; actual=$(jq -r "$path" "$file" 2>/dev/null || echo "<jq-error>")
    assert_eq "$name" "$expected" "$actual"
}

echo "slug derivation"
assert_eq "lowercase + single space"  "code-quality"             "$(slug "Code Quality")"
assert_eq "special chars stripped"    "funky-123"                "$(slug "  Funky! 123  ")"
assert_eq "collapses repeated dashes" "all-caps-label"           "$(slug "ALL  CAPS--LABEL")"

echo ""
echo "run_tool happy path"
run_tool "Echo OK" echo "hello" >/dev/null
assert_eq        "LAST_EXIT == 0"        "0"            "$LAST_EXIT"
assert_eq        "LAST_SLUG"             "echo-ok"      "$LAST_SLUG"
assert_file_exists "stdout captured"     "$LAST_RAW"
assert_file_missing "empty stderr removed" "$LAST_STDERR"

echo ""
echo "run_tool stderr capture + exit code in LAST_EXIT"
set -e   # prove run_tool does not abort under set -e
run_tool "Mixed Output" bash -c 'echo out; echo err >&2; exit 7' >/dev/null
set +e
assert_eq          "tool exit in LAST_EXIT"    "7"       "$LAST_EXIT"
assert_file_exists "stderr captured"           "$LAST_STDERR"

echo ""
echo "run_tool missing tool → graceful skip (no abort under set -e)"
set -e
run_tool "Missing" nonexistent_tool_xyz_$$ >/dev/null
set +e
assert_eq "LAST_EXIT == 127 when tool absent" "127" "$LAST_EXIT"

echo ""
echo 'run_tool — `npm run <missing-script>` is promoted to LAST_EXIT=127'
# Fake an `npm` binary that mimics the real npm's missing-script error.
# Without the promotion, sections parse an empty stdout and misclassify
# the missing wire-up as a real finding.
FAKE_PATH="$TMP/fake-npm-bin"
mkdir -p "$FAKE_PATH"
# Cover BOTH npm diagnostic formats — npm < 9 ("npm ERR! Missing script") and
# npm ≥ 9 ("npm error Missing script"). Keying only on the old prefix regressed
# silently on modern npm and reported a fail on any package.json without the
# script (#80); both must promote to the honest skip path.
for fmt in 'npm ERR! Missing script: "missing-fixture-script"' \
           'npm error Missing script: "missing-fixture-script"'; do
    cat > "$FAKE_PATH/npm" <<NPMEOF
#!/bin/bash
echo '$fmt' >&2
exit 1
NPMEOF
    chmod +x "$FAKE_PATH/npm"
    PATH="$FAKE_PATH:$PATH" run_tool "Fake NPM Missing" npm run missing-fixture-script >/dev/null
    assert_eq "missing npm script ($fmt) → LAST_EXIT=127" "127" "$LAST_EXIT"
done

echo ""
echo "run_tool — npm exit-1 WITHOUT 'Missing script' is left unchanged"
# Regression guard: a real npm failure (e.g. tests failed) must NOT be
# promoted to 127, otherwise we'd silently downgrade real findings to
# skips. Only the specific "Missing script" diagnostic triggers promotion.
cat > "$FAKE_PATH/npm" <<'NPMEOF'
#!/bin/bash
echo "some real failure output" >&2
exit 1
NPMEOF
PATH="$FAKE_PATH:$PATH" run_tool "Fake NPM Real Fail" npm run whatever >/dev/null
assert_eq "real npm failure → LAST_EXIT preserved (1)" "1" "$LAST_EXIT"
rm -rf "$FAKE_PATH"

echo ""
echo "write_parsed emits the documented shape"
write_parsed "demo" "warn" 3 "3 issues" \
    '[{"file":"a.ts","line":1,"code":"X","severity":"warning","message":"m"}]' \
    '{"purpose":"demo","pass_means":"zero","fail_means":"one+"}'
assert_file_exists "parsed file written"      "$PARSED_DIR/demo.json"
assert_json_field  "slug field"               "$PARSED_DIR/demo.json" ".slug"                 "demo"
assert_json_field  "status field"             "$PARSED_DIR/demo.json" ".status"               "warn"
assert_json_field  "count field"              "$PARSED_DIR/demo.json" ".count"                "3"
assert_json_field  "top[0].file"              "$PARSED_DIR/demo.json" ".top[0].file"          "a.ts"
assert_json_field  "intent.purpose"           "$PARSED_DIR/demo.json" ".intent.purpose"       "demo"

echo ""
echo "write_skipped always writes a parsed JSON"
write_skipped "missing-x" "x not installed"
assert_json_field "skipped status"   "$PARSED_DIR/missing-x.json" ".status"  "skip"
assert_json_field "skipped summary"  "$PARSED_DIR/missing-x.json" ".summary" "x not installed"

echo ""
echo "write_failed for ran-but-unusable output"
write_failed "broken-tool" "tool produced unparseable JSON" '{"purpose":"test"}'
assert_json_field "failed status"     "$PARSED_DIR/broken-tool.json" ".status"            "fail"
assert_json_field "failed summary"    "$PARSED_DIR/broken-tool.json" ".summary"           "tool produced unparseable JSON"
assert_json_field "failed intent"     "$PARSED_DIR/broken-tool.json" ".intent.purpose"    "test"

echo ""
echo "write_skipped passes intent through"
write_skipped "missing-y" "y not installed" '{"purpose":"why y matters","pass_means":"y was installed"}'
assert_json_field "skipped intent purpose"     "$PARSED_DIR/missing-y.json" ".intent.purpose"     "why y matters"
assert_json_field "skipped intent pass_means"  "$PARSED_DIR/missing-y.json" ".intent.pass_means"  "y was installed"

echo ""
echo "write_parsed coerces invalid status to fail"
write_parsed "bad-status" "weird" 0 "x" 2>/dev/null
assert_json_field "invalid status → fail" "$PARSED_DIR/bad-status.json" ".status" "fail"

echo ""
echo "is_valid_json"
echo "not json" > "$RAW_DIR/bad.txt"
if is_valid_json "$PARSED_DIR/demo.json"; then ok "valid JSON accepted"; else notok "valid JSON accepted"; fi
if is_valid_json "$RAW_DIR/bad.txt"; then notok "invalid JSON rejected"; else ok "invalid JSON rejected"; fi
if is_valid_json "$RAW_DIR/nonexistent.txt"; then notok "missing file rejected"; else ok "missing file rejected"; fi

echo ""
echo "write_parsed under SLUG_NS — topology recover namespacing (#78)"
# When SLUG_NS is set (a section running inside a sub-package) the record is
# namespaced: flat filename `<ns>-<slug>.json`, `.slug` field `<ns>/<slug>`, and
# finding paths re-prefixed to TARGET-relative so the by-file join stays coherent.
SLUG_NS="backend"
write_parsed "npm-audit" "fail" 1 "1 critical" \
    '[{"file":"package.json","severity":"critical","code":"x","message":"m"}]' '{}'
assert_file_exists "flat filename <ns>-<slug>.json" "$PARSED_DIR/backend-npm-audit.json"
assert_json_field  "namespaced .slug field"        "$PARSED_DIR/backend-npm-audit.json" ".slug"         "backend/npm-audit"
assert_json_field  "literal package.json prefixed" "$PARSED_DIR/backend-npm-audit.json" ".top[0].file"  "backend/package.json"

write_parsed "typecheck" "fail" 1 "err" \
    '[{"file":"src/a.ts","severity":"error","code":"TS","message":"m"}]' '{}'
assert_json_field  "cwd-relative path prefixed"    "$PARSED_DIR/backend-typecheck.json" ".top[0].file"  "backend/src/a.ts"

# A path already TARGET-relative (a section that stripped $TARGET → starts with
# the ns) or absolute must NOT be double-prefixed.
write_parsed "lint" "warn" 2 "x" \
    '[{"file":"backend/src/b.ts","severity":"warning","code":"L","message":"m"},{"file":"/abs/c.ts","severity":"low","code":"L","message":"m"}]' '{}'
assert_json_field  "already-ns path left alone"    "$PARSED_DIR/backend-lint.json" ".top[0].file"  "backend/src/b.ts"
assert_json_field  "absolute path left alone"      "$PARSED_DIR/backend-lint.json" ".top[1].file"  "/abs/c.ts"
unset SLUG_NS

# With SLUG_NS unset, behaviour is unchanged (flat slug, no path prefix).
write_parsed "npm-audit" "pass" 0 "ok" '[{"file":"package.json","severity":"info","code":"x","message":"m"}]' '{}'
assert_json_field  "no-ns slug unchanged"          "$PARSED_DIR/npm-audit.json" ".slug"        "npm-audit"
assert_json_field  "no-ns path unchanged"          "$PARSED_DIR/npm-audit.json" ".top[0].file" "package.json"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
