#!/bin/bash
# Tests for per-language complexity routing + merge (#68).
#
# checkup measures complexity per language SLICE — ESLint on the JS/TS slice,
# lizard on the remaining (non-JS) lizard-parseable slice — then merges both into
# one record + one Tornhill CSV. These tests exercise the shared, drift-prone
# pieces directly, so they are environment-independent (jq only — no ESLint/
# lizard/npx needed) and can't diverge from the orchestrator:
#   - lib/complexity-merge.jq : fold N slices → count/highest/status/top
#   - lib/complexity-csv.jq   : findings → Tornhill CSV rows (CCN only)
#   - the bash slice-routing rule (replicated, mirroring detect.test.sh)
# A final lizard-fence check runs end-to-end IF lizard is installed (skipped on
# a runner without it), proving the JS/TS exclusion actually partitions the tree.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
MJQ="$CHECKUP_HOME/lib/complexity-merge.jq"
CJQ="$CHECKUP_HOME/lib/complexity-csv.jq"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

merge() { echo "$1" | jq -c -f "$MJQ"; }
csv()   { echo "$1" | jq -r --arg prefix "$2" -f "$CJQ"; }
finding() { # finding <file> <ccn> <code>
    jq -nc --arg f "$1" --argjson c "$2" --arg code "$3" \
        '{file:$f, line:1, ccn:$c, code:$code, severity:"low", message:($f + " — score " + ($c|tostring))}'
}

echo "merge: empty slice → honest pass"
E=$(merge '[]')
assert_eq "count 0"     "0"    "$(echo "$E" | jq '.count')"
assert_eq "highest 0"   "0"    "$(echo "$E" | jq '.highest')"
assert_eq "status pass" "pass" "$(echo "$E" | jq -r '.status')"
assert_eq "top []"      "[]"   "$(echo "$E" | jq -c '.top')"

echo ""
echo "merge: two slices combine, ranked desc, .ccn sort-key shed"
ES=$(jq -nc --argjson a "$(finding 'src/ts/hot.ts' 14 'CCN-14')" '[$a]')   # ESLint slice
LZ=$(jq -nc --argjson a "$(finding 'src/py/hot.py' 12 'CCN-12')" '[$a]')   # lizard slice
BOTH=$(jq -nc --argjson a "$ES" --argjson b "$LZ" '$a + $b')
M=$(merge "$BOTH")
assert_eq "count is sum"        "2"             "$(echo "$M" | jq '.count')"
assert_eq "highest across both" "14"            "$(echo "$M" | jq '.highest')"
assert_eq "status warn"         "warn"          "$(echo "$M" | jq -r '.status')"
assert_eq "top[0] is highest"   "src/ts/hot.ts" "$(echo "$M" | jq -r '.top[0].file')"
assert_eq "top[1] next"         "src/py/hot.py" "$(echo "$M" | jq -r '.top[1].file')"
assert_eq "ccn key shed"        "null"          "$(echo "$M" | jq -c '.top[0].ccn')"
assert_eq "top keeps schema"    "file,line,code,severity,message" \
          "$(echo "$M" | jq -r '.top[0]|keys_unsorted|join(",")')"

echo ""
echo "merge: collapsing an empty slice is the identity (byte-identical proof)"
# Appending an empty lizard slice must leave the ESLint-only result untouched —
# this is the single-language byte-identical guarantee, in unit form.
COLLAPSE=$(jq -nc --argjson a "$ES" --argjson b '[]' '$a + $b')
assert_eq "merge(F + []) == merge(F)" "$(merge "$ES")" "$(merge "$COLLAPSE")"

echo ""
echo "merge: status bands (warn at ≥20-ish, fail at ≥30) by max score"
assert_eq "29 → warn" "warn" "$(merge "[$(finding a.ts 29 CCN-29)]" | jq -r '.status')"
assert_eq "30 → fail" "fail" "$(merge "[$(finding a.ts 30 CCN-30)]" | jq -r '.status')"
# A single ≥30 anywhere in the merged set drives the whole record to fail.
MIXED=$(jq -nc --argjson a "$(finding a.ts 12 CCN-12)" --argjson b "$(finding b.py 33 CCN-33)" '[$a,$b]')
assert_eq "any 30+ → fail"   "fail" "$(merge "$MIXED" | jq -r '.status')"
assert_eq "highest reported" "33"   "$(merge "$MIXED" | jq '.highest')"

echo ""
echo "merge: top capped at 20, ranked by score"
BIG=$(jq -nc '[range(25) | {file:("f\(.).ts"), line:1, ccn:(.+1), code:("CCN-\(.+1)"), severity:"low", message:"x"}]')
assert_eq "top capped at 20"  "20"     "$(merge "$BIG" | jq '.top|length')"
assert_eq "highest is 25"     "25"     "$(merge "$BIG" | jq '.highest')"
assert_eq "top[0] is max ccn" "f24.ts" "$(merge "$BIG" | jq -r '.top[0].file')"

echo ""
echo "merge: ESLint cognitive findings rank by their cognitive score"
# COG-… rows participate in ranking/status (their score is in .ccn) even though
# they are dropped from the CSV — a cognitive 40 still fails the record.
assert_eq "COG-40 → fail" "fail" "$(merge "[$(finding x.ts 40 COG-40)]" | jq -r '.status')"

echo ""
echo "csv: cyclomatic-only rows, col2=CCN, col7=file, col6 namespaced"
MIX=$(jq -nc --argjson a "$(finding 'a.ts' 14 'CCN-14')" --argjson b "$(finding 'a.ts' 18 'COG-18')" '[$a,$b]')
OUT=$(csv "$MIX" eslint)
assert_eq "COG excluded → 1 row"  "1"               "$(printf '%s\n' "$OUT" | grep -c .)"
assert_eq "col2 is CCN"           "14"              "$(printf '%s' "$OUT" | cut -d, -f2)"
assert_eq "col7 is file"          '"a.ts"'          "$(printf '%s' "$OUT" | cut -d, -f7)"
assert_eq "col6 eslint namespace" '"eslint:a.ts@1"' "$(printf '%s' "$OUT" | cut -d, -f6)"
assert_eq "col6 lizard namespace" '"lizard:a.ts@1"' "$(csv "$MIX" lizard | cut -d, -f6)"
# Cognitive must never reach column 2 — that is the churn × CCN join's input.
assert_eq "no COG score in any col2" "" \
          "$(csv "$MIX" eslint | cut -d, -f2 | grep -x 18 || true)"

echo ""
echo "routing: the slice-selection rule (mirrors bin/checkup.sh, both arms)"
# Replicates the detector. Node-dominant: ESLint primary on JS/TS, lizard on the
# non-JS rest. The ESLint slice is gated on a runnable config (#79:
# ESLINT_SLICE_OK), so a repo with non-JS source but no ESLint config routes
# lizard-only (JS/TS unmeasured) — it must NOT drop to "eslint" then fail.
# Non-node-dominant (#73): lizard covers everything by default, but a JS/TS slice
# WITH a resolvable config upgrades to the same merged arm (ESLint on JS/TS,
# lizard on the non-JS remainder) — config-less stays lizard-only, unchanged.
complexity_slices() { # <node_dom> <nonjs_present> <lizard_installed> <eslint_ok>
    local node_dom="$1" nonjs="$2" lizard="$3" eslint_ok="$4" out=""
    if [ "$node_dom" = true ]; then
        [ "$eslint_ok" = true ] && out="eslint"
        [ "$lizard" = true ] && [ "$nonjs" = true ] && out="${out:+$out }lizard"
        echo "$out"
    elif [ "$lizard" = true ]; then
        # Non-node-dominant, lizard-parseable source present (LIZARD_PROBE). #73.
        if [ "$eslint_ok" = true ]; then
            out="eslint"
            [ "$nonjs" = true ] && out="eslint lizard"
        else
            out="lizard"   # config-less → lizard covers everything (unchanged)
        fi
        echo "$out"
    else
        echo ""   # no lizard-parseable source → scc/none arm, not the merged path
    fi
}
assert_eq "dominant + non-JS + lizard + eslint → merge" "eslint lizard" "$(complexity_slices true  true  true  true)"
assert_eq "dominant, no non-JS, eslint ok → eslint"     "eslint"        "$(complexity_slices true  false true  true)"
assert_eq "#79: dominant + non-JS, NO eslint config → lizard-only" "lizard" "$(complexity_slices true true true false)"
assert_eq "#79: dominant, no eslint config, no non-JS → empty"     ""       "$(complexity_slices true false true false)"
assert_eq "#73: not dominant + JS/TS + non-JS + config → merge"   "eslint lizard" "$(complexity_slices false true  true  true)"
assert_eq "#73: not dominant + JS/TS only + config → eslint"      "eslint"        "$(complexity_slices false false true  true)"
assert_eq "#73: not dominant + config-less → lizard (unchanged)"  "lizard"        "$(complexity_slices false true  true  false)"
assert_eq "#73: not dominant, no lizard → scc arm (no merged slices)" ""          "$(complexity_slices false true  false true)"

echo ""
echo "#79: record decision — degrade, don't sink; fail/skip only when nothing ran"
# Mirrors the merged-arm gate: a slice that RAN (even with 0 findings) → real
# pass/warn/fail; nothing ran + a slice was attempted → fail; nothing ran +
# nothing routable → skip.
record_decision() { # <eslint_ran> <lizard_ran> <eslint_attempted> <lizard_attempted>
    local er="$1" lr="$2" ea="$3" la="$4"
    if [ "$er" = true ] || [ "$lr" = true ]; then echo "measured"
    elif [ "$ea" = true ] || [ "$la" = true ]; then echo "failed"
    else echo "skipped"; fi
}
assert_eq "eslint failed but lizard ran → measured" "measured" "$(record_decision false true true true)"
assert_eq "eslint ran, no lizard → measured"        "measured" "$(record_decision true false true false)"
assert_eq "eslint attempted+failed, no lizard → failed" "failed" "$(record_decision false false true false)"
assert_eq "nothing routable → skipped"              "skipped"  "$(record_decision false false false false)"

echo ""
echo "integration: lizard fences off the JS/TS slice (needs lizard)"
if command -v lizard >/dev/null 2>&1; then
    FIX="$HOME/.checkup-cxmerge-fix.$$"          # under $HOME, not /tmp
    mkdir -p "$FIX/src"
    printf 'def hot(n):\n    return n if n>0 else -n\n'      > "$FIX/src/keep.py"
    printf 'export const drop = (x:number) => x>0?x:-x;\n'   > "$FIX/src/drop.ts"
    # Same fence the merged path applies: standard excludes + the JS/TS globs.
    OUT=$(lizard --csv --CCN 9999 \
            -x '*/node_modules/*' \
            -x '*.ts' -x '*.tsx' -x '*.js' -x '*.jsx' -x '*.mjs' -x '*.cjs' \
            "$FIX/src" 2>/dev/null)
    if printf '%s' "$OUT" | grep -q 'keep.py' && ! printf '%s' "$OUT" | grep -q 'drop.ts'; then
        ok "non-JS file measured, JS/TS file excluded"
    else
        notok "lizard fence failed (py kept? $(printf '%s' "$OUT" | grep -c keep.py); ts excluded? $(printf '%s' "$OUT" | grep -c drop.ts))"
    fi
    rm -rf "$FIX"
else
    echo "  ⊘ skipped — lizard not installed"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
