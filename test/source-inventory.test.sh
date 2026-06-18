#!/bin/bash
# Tests for the source inventory (lib/source-inventory.sh, #75) — the honest
# answer to "what source should checkup assess?".
#
# The drift-prone, security-relevant logic is the PURE filter (extension allow-
# list + vendored/generated exclusion + path normalisation) and the scan-root
# resolution. Both are exercised directly here, environment-independent: the
# filter takes a synthetic NUL list on stdin, so no git/fd/find is needed (mirrors
# detect.test.sh feeding fixtures through the shared transform). A final git-tier
# case runs end-to-end only if git is present, proving .gitignore'd files are
# excluded — the regression that motivated the change.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# shellcheck source=../lib/source-inventory.sh
source "$CHECKUP_HOME/lib/source-inventory.sh"

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

# Feed NUL-joined paths through the pure filter; return newline-joined results
# (sorted) for easy assertion.
filter() {  # filter <path> <path> ...
    local p out
    for p in "$@"; do printf '%s\0' "$p"; done | _filter_inventory | tr '\0' '\n' | sort | paste -sd',' -
}

echo "pure filter: keeps source extensions, drops the rest"
assert_eq "ts/py/cs/go kept, md/json/txt dropped" \
    "a.ts,b.py,d.go,sub/c.cs" \
    "$(filter a.ts b.py readme.md d.go config.json sub/c.cs notes.txt)"

echo ""
echo "pure filter: excludes vendored/generated, leading + nested"
assert_eq "top-level node_modules/dist excluded" \
    "src/a.ts" \
    "$(filter src/a.ts node_modules/x.js dist/y.js)"
assert_eq "nested node_modules + min/bundle/snap excluded" \
    "src/a.ts" \
    "$(filter src/a.ts pkg/node_modules/dep.js src/x.min.js src/y.bundle.js src/z.snap)"
assert_eq "vendor / migrations / __snapshots__ excluded" \
    "src/keep.rb" \
    "$(filter src/keep.rb vendor/v.rb db/migrations/001.py src/__snapshots__/s.js)"

echo ""
echo "pure filter: normalises the find/fd './' prefix to one namespace"
assert_eq "'./src/a.ts' → 'src/a.ts'" "src/a.ts" "$(filter ./src/a.ts)"

echo ""
echo "pure filter: paths with spaces survive (NUL-delimited)"
assert_eq "space in path kept verbatim" "my dir/a b.ts" "$(filter 'my dir/a b.ts')"

echo ""
echo "pure filter: empty input → empty output"
assert_eq "empty" "" "$(printf '' | _filter_inventory | tr '\0' '\n')"

echo ""
echo "CHECKUP_EXCLUDE adds user globs"
assert_eq "user glob '*/legacy/*' excluded" \
    "src/a.ts" \
    "$(CHECKUP_EXCLUDE='*/legacy/*'; filter src/a.ts src/legacy/old.ts)"

echo ""
echo "resolve_scan_roots: whole-tree default; override narrows to existing"
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
mkdir -p "$TMP/src" "$TMP/services"
( cd "$TMP"; resolve_scan_roots; assert_eq "default is whole tree" "." "${SCAN_ROOTS[*]}" )
( cd "$TMP"; CHECKUP_SRC_ROOTS="src services"; resolve_scan_roots; assert_eq "override → existing dirs" "src services" "${SCAN_ROOTS[*]}" )
( cd "$TMP"; CHECKUP_SRC_ROOTS="src nope"; resolve_scan_roots; assert_eq "override drops missing dirs" "src" "${SCAN_ROOTS[*]}" )
( cd "$TMP"; CHECKUP_SRC_ROOTS="none here"; resolve_scan_roots; assert_eq "all-missing override → whole-tree fallback" "." "${SCAN_ROOTS[*]}" )
# Regression: the orchestrator runs under `set -e`, so resolve_scan_roots must
# return 0 even when its final test is false (override matched → array non-empty).
# Otherwise the whole run dies silently the moment a user sets CHECKUP_SRC_ROOTS.
if ( set -e; cd "$TMP"; CHECKUP_SRC_ROOTS="src"; resolve_scan_roots ); then
    ok "returns 0 under set -e with a matching override"
else
    notok "returns 0 under set -e with a matching override (set -e would kill the run)"
fi

echo ""
echo "slice regexes partition JS/TS vs non-JS with no overlap"
# Confirm the published slice regexes are disjoint and cover the inventory set.
injs() { printf '%s\0' "$@" | { while IFS= read -r -d '' p; do [[ "$p" =~ $INV_JSTS_RE ]] && echo "$p"; done; } ; }
innonjs() { printf '%s\0' "$@" | { while IFS= read -r -d '' p; do [[ "$p" =~ $INV_NONJS_RE ]] && echo "$p"; done; } ; }
assert_eq "JS/TS slice"  "a.ts b.js" "$(injs a.ts b.js c.py d.go | tr '\n' ' ' | sed 's/ $//')"
assert_eq "non-JS slice" "c.py d.go" "$(innonjs a.ts b.js c.py d.go | tr '\n' ' ' | sed 's/ $//')"

echo ""
echo "git tier end-to-end: tracked source in, .gitignore'd generated out"
if command -v git > /dev/null 2>&1; then
    G="$HOME/.checkup-inv-fix.$$"; rm -rf "$G"; mkdir -p "$G/src" "$G/scripts" "$G/.vercel/output"
    ( cd "$G"
      git init -q && git config user.email t@t && git config user.name t
      printf '.vercel/\n' > .gitignore
      printf 'export const a=1;\n' > src/a.ts
      printf 'def f():\n    return 1\n' > scripts/build.py        # tracked, NON-src → must be included
      printf 'export const gen=1;\n' > .vercel/output/gen.js      # gitignored → must be excluded
      git add -A && git commit -qm init >/dev/null 2>&1 )
    got=$( cd "$G"; GIT_OK=true; RAW_DIR="$G/raw"; SCAN_ROOTS=(.); build_source_inventory; tr '\0' '\n' < "$SOURCE_LST" | sort | paste -sd',' - )
    assert_eq "tracked non-src kept, gitignored excluded" "scripts/build.py,src/a.ts" "$got"
    rm -rf "$G"
else
    echo "  ⊘ skipped — git not installed"
fi

echo ""
echo "coverage helpers: by-area grouping and exclusion-source label"
SOURCE_LST="$TMP/cov.lst"
printf 'src/a.ts\0src/b.ts\0scripts/c.py\0root.ts\0' > "$SOURCE_LST"
assert_eq "by-area groups by top dir, <root> for root files" \
    '{"<root>":1,"scripts":1,"src":2}' \
    "$(inventory_by_area_json | jq -cS .)"
assert_eq "git scope → .gitignore"        ".gitignore"               "$(SOURCE_SCOPE=git inventory_exclusion_source)"
assert_eq "override:git scope → .gitignore" ".gitignore"             "$(SOURCE_SCOPE=override:git inventory_exclusion_source)"
assert_eq "find scope → builtin excludes"  "builtin excludes (no VCS)" "$(SOURCE_SCOPE=find inventory_exclusion_source)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
