#!/bin/bash
# Tests for the knowledge-concentration / key-person transform (lib/ownership.jq,
# ADR-0010, #127). Feeds fixture authorship rows (file, email, name, commits,
# added, lastTs) straight into the pure jq filter — env-independent, no git, no
# clock — the same "one shared transform, tested in isolation" pattern the config
# and source-inventory suites use. The git log + awk normalisation that produces
# the rows lives in bin/checkup.sh and is exercised by the honesty harness; here
# we pin the maths, the thresholds, identity coalescing, and the honest skip.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"
JQF="$CHECKUP_HOME/lib/ownership.jq"

# A fixed "now" so recency is deterministic; helper to build timestamps N days back.
NOW=1752566400                      # 2026-07-15T08:00:00Z
ago() { echo $(( NOW - $1 * 86400 )); }

PASS=0
FAIL=0
ok()    { PASS=$((PASS+1)); echo "  ✓ $1"; }
notok() { FAIL=$((FAIL+1)); echo "  ✗ $1"; }
assert_eq() {
    local name="$1" expected="$2" actual="$3"
    if [ "$expected" = "$actual" ]; then ok "$name"
    else notok "$name (expected '$expected', got '$actual')"; fi
}

# ROWS is an accumulator: reset(), then R <file> <email> <name> <commits> <added>
# <daysAgo> appends one TSV row (command-substitution strips a row's trailing
# newline, so we re-add it explicitly — otherwise rows would run together).
ROWS=""
reset() { ROWS=""; }
R() { ROWS+="$(printf '%s\t%s\t%s\t%s\t%s\t%s' "$1" "$2" "$3" "$4" "$5" "$(ago "$6")")"$'\n'; }

# Run the filter over the current ROWS: run [kp% sole% orphanDays areaDepth anon mailmap]
run() {
    local kp="${1:-50}" sole="${2:-50}" orphan="${3:-180}" \
          depth="${4:-1}" anon="${5:-0}" mm="${6:-0}"
    printf '%s' "$ROWS" | jq -R -s -c \
        --argjson now "$NOW" --argjson keypersonPct "$kp" --argjson solePct "$sole" \
        --argjson orphanDays "$orphan" --argjson areaDepth "$depth" \
        --arg anon "$anon" --arg hasMailmap "$mm" -f "$JQF"
}

echo "empty input degrades to skip (never a false pass)"
reset
OUT=$(run)
assert_eq "empty → skip"  "skip" "$(echo "$OUT" | jq -r .status)"
assert_eq "empty → 0 findings" "0" "$(echo "$OUT" | jq '.findings|length')"

echo ""
echo "concentration + bus factor"
# Alice 3000 lines, Bob 1000, Carol 1000 (total 5000). Alice = 60%.
reset; R src/a.ts alice@x Alice 30 3000 5; R src/b.ts bob@x Bob 10 1000 5; R src/c.ts carol@x Carol 10 1000 5
OUT=$(run)
assert_eq "top author over threshold → warn" "warn" "$(echo "$OUT" | jq -r .status)"
assert_eq "key-person finding is warning"    "warning" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="key-person").severity')"
assert_eq "headline shows 60%"               "60" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="key-person").message|capture("authored (?<p>[0-9]+)%").p')"
assert_eq "bus factor 1 (Alice alone ≥ 50%)" "1"  "$(echo "$OUT" | jq -r '.summary|capture("bus factor (?<b>[0-9]+)").b')"

echo ""
echo "raising the threshold above the top share flips warn→pass"
# Co-authored files (sole rate 0) so ONLY the key-person threshold governs. Alice
# holds ~60% of lines; threshold 70 > 60 → not a key person → pass.
reset
R src/a.ts alice@x Alice 30 3000 5; R src/a.ts bob@x Bob 5 100 5
R src/b.ts bob@x Bob 10 900 5;      R src/b.ts carol@x Carol 5 100 5
R src/c.ts carol@x Carol 10 900 5;  R src/c.ts alice@x Alice 5 100 5
assert_eq "at threshold 50 → warn"       "warn" "$(echo "$(run 50)" | jq -r .status)"
OUT=$(run 70)
assert_eq "raised threshold 70 → pass"   "pass" "$(echo "$OUT" | jq -r .status)"
assert_eq "key-person demoted to info"   "info" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="key-person").severity')"

echo ""
echo "sole-authorship rate warns independently of the key person"
# Five authors, evenly split by lines (no key person), but every file sole-owned.
reset
R src/a.ts a@x A 5 100 5; R src/b.ts b@x B 5 100 5; R src/c.ts c@x C 5 100 5
R src/d.ts d@x D 5 100 5; R src/e.ts e@x E 5 100 5
OUT=$(run)
assert_eq "no key person (20% each)"        "info" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="key-person").severity')"
assert_eq "100% sole-authored → warn"       "warn" "$(echo "$OUT" | jq -r .status)"
assert_eq "sole-authorship finding present" "warning" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="sole-authorship").severity')"

echo ""
echo "shared files are NOT counted as sole-authored"
# Every file touched by two authors → sole rate 0; balanced lines → pass.
reset
R src/a.ts a@x A 5 100 5; R src/a.ts b@x B 5 100 5
R src/b.ts b@x B 5 100 5; R src/b.ts c@x C 5 100 5
R src/c.ts c@x C 5 100 5; R src/c.ts a@x A 5 100 5
OUT=$(run)
assert_eq "no sole-authored files → pass" "pass" "$(echo "$OUT" | jq -r .status)"
assert_eq "0% single-author in summary"   "0" "$(echo "$OUT" | jq -r '.summary|capture("; (?<p>[0-9]+)% single-author").p')"

echo ""
echo "orphaned knowledge: sole owner gone quiet (absence-is-signal)"
# Six files. Five owned by an active author; one sole-owned by an inactive one.
reset
R src/a.ts act@x Active 5 100 3; R src/b.ts act@x Active 5 100 3; R src/c.ts act@x Active 5 100 3
R src/d.ts act@x Active 5 100 3; R src/e.ts act@x Active 5 100 3
R legacy/old.ts gone@x Gone 5 100 400
OUT=$(run)
assert_eq "orphaned file flagged"        "legacy/old.ts" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="orphaned-knowledge").file')"
assert_eq "orphaned finding is warning"  "warning" "$(echo "$OUT" | jq -r '.findings[]|select(.code=="orphaned-knowledge").severity')"
assert_eq "orphan count in summary"      "1" "$(echo "$OUT" | jq -r '.summary|capture(", (?<n>[0-9]+) orphaned").n')"
# A recently-active sole owner is NOT orphaned.
reset
R src/a.ts act@x Active 5 100 3; R src/b.ts act@x Active 5 100 3; R src/c.ts act@x Active 5 100 3
R src/d.ts act@x Active 5 100 3; R src/e.ts act@x Active 5 100 3
R legacy/old.ts gone@x Gone 5 100 30
OUT=$(run)
assert_eq "recent sole owner not orphaned" "0" "$(echo "$OUT" | jq '[.findings[]|select(.code=="orphaned-knowledge")]|length')"

echo ""
echo "identity: email coalescing merges an author's rows (case-insensitive)"
reset
R src/a.ts Alice@X Alice 20 2000 5; R src/b.ts alice@x Alice 20 2000 5; R src/c.ts bob@x Bob 5 100 5
OUT=$(run)
assert_eq "two emails, one casing → one author" "2" "$(echo "$OUT" | jq -r '.summary|capture("across (?<n>[0-9]+) authors").n')"

echo ""
echo "identity caveat + mailmap note always present in the summary"
OUT=$(run 50 50 180 1 0 1)
echo "$OUT" | jq -e '.summary|test("mailmap-resolved")' >/dev/null && ok "mailmap=1 → '.mailmap-resolved'" || notok "mailmap note"
OUT=$(run 50 50 180 1 0 0)
echo "$OUT" | jq -e '.summary|test("no .mailmap")' >/dev/null && ok "mailmap=0 → 'no .mailmap'" || notok "no-mailmap note"
echo "$OUT" | jq -e '.summary|test("unmerged aliases")' >/dev/null && ok "alias caveat surfaced" || notok "alias caveat"

echo ""
echo "anonymise mode strips names for shared reports"
reset; R src/a.ts alice@x Alice 30 3000 5; R src/b.ts bob@x Bob 5 100 5
OUT=$(run 50 50 180 1 1 0)
echo "$OUT" | jq -e '[.findings[].message]|any(test("Alice"))|not' >/dev/null && ok "no real names when anon=1" || notok "anon leaked a name"
echo "$OUT" | jq -e '.findings[]|select(.code=="key-person").message|test("Contributor 1")' >/dev/null && ok "top author → 'Contributor 1'" || notok "anon pseudonym"

echo ""
echo "single-owned areas surface only past the size floor (≥3 files)"
# src/ has 4 files all Alice; tiny/ has 1 → only src/ is an area finding.
reset
R src/a.ts alice@x Alice 5 100 5; R src/b.ts alice@x Alice 5 100 5
R src/c.ts alice@x Alice 5 100 5; R src/d.ts alice@x Alice 5 100 5
R tiny/z.ts bob@x Bob 5 100 5
OUT=$(run)
assert_eq "one single-owned area (src)" "src" "$(echo "$OUT" | jq -r '[.findings[]|select(.code=="single-owned-area")]|first.file')"
assert_eq "tiny (1 file) not an area"   "1"   "$(echo "$OUT" | jq '[.findings[]|select(.code=="single-owned-area")]|length')"

echo ""
echo "deterministic: identical input yields byte-identical output"
A=$(run); B=$(run)
assert_eq "repeated run identical" "$A" "$B"

echo ""
echo "status is capped at warn — the transform never emits fail"
# Worst case: one author, everything, ancient. Still warn, never fail.
reset
R src/a.ts solo@x Solo 50 5000 500; R src/b.ts solo@x Solo 50 5000 500; R src/c.ts solo@x Solo 50 5000 500
R src/d.ts solo@x Solo 50 5000 500; R src/e.ts solo@x Solo 50 5000 500
OUT=$(run)
assert_eq "extreme concentration still warn" "warn" "$(echo "$OUT" | jq -r .status)"

echo ""
echo "=================================================="
echo "ownership.jq: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
