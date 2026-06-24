#!/bin/bash
# Tests for lib/scc-inventory.sh + lib/scc-aggregate.jq (plan 0002 Phase 1, #109):
# routing the scc-based engines through the first-party inventory by filtering +
# re-aggregating scc's `--by-file` output against a keep-set.
#
# Environment-independent: scc is NOT required. A captured `scc --by-file
# --format json` fixture is fed through the pure transform with a synthetic
# keep-set (mirrors detect.test.sh / source-inventory.test.sh feeding fixtures
# through a shared transform). The drift-prone, contract-critical behaviour lives
# here: faithful re-aggregation, keep-set filtering, "./" normalisation, the TOTAL
# order (determinism, #96), and the reconstructed Total / top-langs.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
export CHECKUP_HOME

# shellcheck source=../lib/scc-inventory.sh
source "$CHECKUP_HOME/lib/scc-inventory.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

# A captured scc `--by-file --format json` shape: a language array, each with a
# Files[] of per-file rows. Mix of first-party + generated/vendored bulk, a "./"
# prefix, a complexity tie, and a zero-complexity (data) file.
BYFILE="$TMP/byfile.json"
cat > "$BYFILE" <<'JSON'
[
  {"Name":"C#","Files":[
    {"Location":"src/A.cs","Language":"C#","Code":100,"Complexity":10,"Lines":120},
    {"Location":"./src/B.cs","Language":"C#","Code":50,"Complexity":10,"Lines":60},
    {"Location":"generated/G.cs","Language":"C#","Code":9000,"Complexity":900,"Lines":10000}
  ]},
  {"Name":"JavaScript","Files":[
    {"Location":"vendor/lib.js","Language":"JavaScript","Code":8000,"Complexity":700,"Lines":9000},
    {"Location":"src/app.js","Language":"JavaScript","Code":150,"Complexity":12,"Lines":180}
  ]},
  {"Name":"JSON","Files":[
    {"Location":"src/data.json","Language":"JSON","Code":40,"Complexity":0,"Lines":40}
  ]}
]
JSON

# Keep-set = first-party, ALL extensions (incl. JSON). Drops generated/G.cs +
# vendor/lib.js. Note "src/B.cs" (no "./") must still match scc's "./src/B.cs".
KEEP="$TMP/keep.json"
echo '["src/A.cs","src/B.cs","src/app.js","src/data.json"]' > "$KEEP"

BREAKDOWN=$(scc_breakdown "$KEEP" < "$BYFILE")

echo "breakdown: re-aggregates kept files per language, drops generated/vendored"
# C#: 100+50 code (gen dropped); JS: 150 (vendor dropped); JSON: 40.
assert_eq "C# Code = 150 (kept only)"       "150" "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="C#").Code')"
assert_eq "C# Count = 2"                    "2"   "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="C#").Count')"
assert_eq "C# Complexity = 20"              "20"  "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="C#").Complexity')"
assert_eq "C# Lines = 180"                  "180" "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="C#").Lines')"
assert_eq "JavaScript Code = 150"           "150" "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="JavaScript").Code')"
assert_eq "JavaScript Count = 1"            "1"   "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="JavaScript").Count')"
assert_eq "JSON kept (all extensions)"      "40"  "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="JSON").Code')"
assert_eq "generated/vendored excluded"     "3"   "$(printf '%s' "$BREAKDOWN" | jq 'length')"

echo ""
echo "breakdown: TOTAL order is Code desc, then Name asc (determinism, #96)"
# C# (150) and JavaScript (150) tie on Code → Name asc puts C# first; JSON last.
assert_eq "order = C#, JavaScript, JSON" "C#,JavaScript,JSON" \
    "$(printf '%s' "$BREAKDOWN" | jq -r 'map(.Name)|join(",")')"

echo ""
echo 'breakdown: "./" prefix normalised on both sides (src/B.cs ↔ ./src/B.cs)'
# If normalisation failed, ./src/B.cs would be dropped → C# Count 1 / Code 100.
assert_eq "leading ./ matched the bare keep path" "2" \
    "$(printf '%s' "$BREAKDOWN" | jq '.[]|select(.Name=="C#").Count')"

echo ""
echo "Total + top-langs reconstructed from the breakdown"
assert_eq "Total = files code complexity" "4 340 32" "$(scc_breakdown_total "$BREAKDOWN")"
assert_eq "top-2 langs (Code desc)"       "C# 150, JavaScript 150" "$(scc_breakdown_toplangs "$BREAKDOWN" 2)"
assert_eq "top-langs default n=3"         "C# 150, JavaScript 150, JSON 40" "$(scc_breakdown_toplangs "$BREAKDOWN")"

echo ""
echo "faithfulness: Σ kept rows == direct sum over the keep-set"
# Independently sum the kept rows straight from the fixture; must match the breakdown.
DIRECT=$(jq --slurpfile k "$KEEP" -r '
    ($k[0]|map({key:.,value:true})|from_entries) as $m
    | [ .[].Files[] | select($m[(.Location|sub("^\\./";""))]) ]
    | "\(length) \(map(.Code)|add) \(map(.Complexity)|add)"' "$BYFILE")
assert_eq "breakdown Total == direct keep-set sum" "$DIRECT" "$(scc_breakdown_total "$BREAKDOWN")"

echo ""
echo "empty keep-set degrades to [] (routes to the existing skip, never a false read)"
echo '[]' > "$TMP/empty.json"
assert_eq "empty keep → empty breakdown" "[]" "$(scc_breakdown "$TMP/empty.json" < "$BYFILE" | jq -c '.')"

echo ""
echo "per-file complexity findings: keep-set filtered, ccn>0, TOTAL order (-ccn, file)"
FIND=$(scc_perfile_findings "$KEEP" < "$BYFILE")
# Kept ccn>0 files: app.js(12), A.cs(10), B.cs(10); data.json(0) dropped; gen/vendor dropped.
assert_eq "3 findings (ccn>0, kept)"        "3" "$(printf '%s' "$FIND" | jq 'length')"
assert_eq "data.json (ccn 0) dropped"       "0" "$(printf '%s' "$FIND" | jq '[.[]|select(.file=="src/data.json")]|length')"
assert_eq "generated/vendored dropped"      "0" "$(printf '%s' "$FIND" | jq '[.[]|select(.file=="generated/G.cs" or .file=="vendor/lib.js")]|length')"
# Order: app.js(12) first; A.cs & B.cs tie at 10 → file asc → A before B.
assert_eq "ranked by -ccn then file"        "src/app.js,src/A.cs,src/B.cs" \
    "$(printf '%s' "$FIND" | jq -r 'map(.file)|join(",")')"
assert_eq "leading ./ normalised in findings" "src/B.cs" \
    "$(printf '%s' "$FIND" | jq -r '.[]|select(.ccn==10 and (.file|test("B")))|.file')"
assert_eq "severity band info (<25)"        "info" "$(printf '%s' "$FIND" | jq -r '.[0].severity')"

echo ""
echo "determinism: shuffled input → byte-identical breakdown"
# Reverse the per-file order; the breakdown must be unchanged (order-invariant + total sort).
jq '[ .[] | {Name, Files: (.Files|reverse)} ] | reverse' "$BYFILE" > "$TMP/shuffled.json"
B2=$(scc_breakdown "$KEEP" < "$TMP/shuffled.json")
assert_eq "breakdown stable under input reorder" "$(printf '%s' "$BREAKDOWN" | jq -S -c '.')" "$(printf '%s' "$B2" | jq -S -c '.')"

echo ""
echo "single-dir concentration (§6.5, #117): foreign-language dir, depth-maximal, deterministic"
# The repo is mostly C# (the real code under src/); a markerless flat-vendored JS
# tree sits under webapp/html/js (still in the keep-set — no marker/convention
# catches it). The detector must name the FOREIGN-language tree, not the larger
# primary C# dir (the false positive that would fire on every normal repo).
CONC_BYFILE="$TMP/conc.json"
cat > "$CONC_BYFILE" <<'JSON'
[
  {"Name":"C#","Files":[
    {"Location":"src/A.cs","Language":"C#","Code":500,"Complexity":50,"Lines":600},
    {"Location":"src/B.cs","Language":"C#","Code":500,"Complexity":50,"Lines":600}
  ]},
  {"Name":"JavaScript","Files":[
    {"Location":"./webapp/html/js/a.js","Language":"JavaScript","Code":200,"Complexity":5,"Lines":2000},
    {"Location":"webapp/html/js/b.js","Language":"JavaScript","Code":200,"Complexity":5,"Lines":2000}
  ]}
]
JSON
CONC_KEEP="$TMP/conc-keep.json"
echo '["src/A.cs","src/B.cs","webapp/html/js/a.js","webapp/html/js/b.js"]' > "$CONC_KEEP"

CONC=$(scc_concentration "$CONC_KEEP" 25 < "$CONC_BYFILE")
# 400/1400 = 28% under webapp/html/js; JS ≠ C# (repo primary) → flagged. src (71%,
# C# = primary) is NOT flagged despite being larger.
assert_eq "names the FOREIGN-language tree, not the bigger primary dir" "webapp/html/js" "$(printf '%s' "$CONC" | jq -r '.dir')"
assert_eq "share floored to pct"           "28"             "$(printf '%s' "$CONC" | jq -r '.pct')"
assert_eq "file count under the dir"       "2"              "$(printf '%s' "$CONC" | jq -r '.files')"
assert_eq "totalCode = kept code"          "1400"          "$(printf '%s' "$CONC" | jq -r '.totalCode')"
assert_eq "reports the foreign language"   "JavaScript"     "$(printf '%s' "$CONC" | jq -r '.lang')"
assert_eq "reports the repo's language"    "C#"             "$(printf '%s' "$CONC" | jq -r '.repoLang')"

echo ""
echo "concentration: same-language large dir is NOT flagged (no primary-dir false positive)"
# Keep ONLY the C# — now src is 100% C# = repoLang → nothing foreign → null.
echo '["src/A.cs","src/B.cs"]' > "$TMP/conc-cs.json"
assert_eq "all-primary-language repo → null" "null" "$(scc_concentration "$TMP/conc-cs.json" 25 < "$CONC_BYFILE")"

echo ""
echo "concentration: threshold respected + degrade cases"
assert_eq "pct above share → null" "null" "$(scc_concentration "$CONC_KEEP" 40 < "$CONC_BYFILE")"
assert_eq "empty keep → null"      "null" "$(scc_concentration "$TMP/empty.json" 25 < "$CONC_BYFILE")"

echo ""
echo "concentration: deterministic under input reorder (#96)"
jq '[ .[] | {Name, Files:(.Files|reverse)} ] | reverse' "$CONC_BYFILE" > "$TMP/conc-shuf.json"
assert_eq "stable under reorder" \
    "$(scc_concentration "$CONC_KEEP" 25 < "$CONC_BYFILE" | jq -S -c '.')" \
    "$(scc_concentration "$CONC_KEEP" 25 < "$TMP/conc-shuf.json" | jq -S -c '.')"

echo ""
echo "scc_keep_for_root: per-package slice of the keep-set (#78 increment 2)"
RAW_DIR="$TMP"
SCC_KEEP_JSON="$TMP/keep-slice.json"
echo '["backend/src/a.go","backend/cmd/main.go","frontend/src/app.ts","./frontend/src/util.ts","top.md"]' > "$SCC_KEEP_JSON"

# "." returns the SAME file path unchanged → the byte-identical single-package gate.
assert_eq "root '.' returns the full keep-set path unchanged" "$SCC_KEEP_JSON" "$(scc_keep_for_root .)"

BK=$(scc_keep_for_root backend)
assert_eq "backend slice keeps only backend/ files" \
    '["backend/src/a.go","backend/cmd/main.go"]' "$(jq -c '.' "$BK")"
assert_eq "slice cached under RAW_DIR" "$TMP/scc-keep.backend.json" "$BK"

# The "./"-prefixed entry is normalised before matching but preserved verbatim in
# the slice (scc-aggregate.jq normalises Location at join time anyway).
FE=$(scc_keep_for_root frontend)
assert_eq "frontend slice keeps both (incl. ./-prefixed, verbatim)" \
    '["frontend/src/app.ts","./frontend/src/util.ts"]' "$(jq -c '.' "$FE")"

assert_eq "no-match root → empty array" '[]' "$(jq -c '.' "$(scc_keep_for_root nope)")"

NESTED=$(scc_keep_for_root "packages/api")
assert_eq "nested root flattens '/' to '_' in the filename" \
    "$TMP/scc-keep.packages_api.json" "$NESTED"

# Round-trip: a backend slice fed to scc_breakdown sums ONLY backend code.
echo '[{"Name":"Go","Files":[
  {"Location":"backend/src/a.go","Code":30,"Complexity":3,"Lines":40},
  {"Location":"backend/cmd/main.go","Code":20,"Complexity":2,"Lines":25}]},
 {"Name":"TypeScript","Files":[
  {"Location":"frontend/src/app.ts","Code":99,"Complexity":9,"Lines":120}]}]' > "$TMP/slice-byfile.json"
assert_eq "breakdown over backend slice sums only backend Go" "50" \
    "$(scc_breakdown "$BK" < "$TMP/slice-byfile.json" | jq 'map(.Code)|add')"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
