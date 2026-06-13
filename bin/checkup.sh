#!/bin/bash
# Application Checkup — whole-repository health, quality, security & hygiene.
# Runs ~20 checks across code, dependencies, security, containers, CI and git
# history; surfaces deploy-readiness, hygiene debt, and audit/DD risks.
#
# Architecture: each check uses the run_tool / write_parsed helpers in
# lib/run-tool.sh to emit a normalised reports/parsed/<slug>.json. The
# tool-agnostic markdown writer (checkup-report.sh) iterates those files.
# See README.md for the full contract.

set -e

# Bail early on bash 3.x (macOS default) — the script uses process
# substitution `<(…)`, `$'…'` byte escapes, `${BASH_VERSINFO[…]}`, and
# `local -n` patterns that bash 3.x either mis-handles silently or
# parses incorrectly. A failure here is far more useful than a section
# that appears to pass because its parser returned zero matches on a
# silently-broken builtin.
if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ]; then
    echo "Error: this script requires bash 4 or later." >&2
    echo "  Detected: bash ${BASH_VERSION:-unknown}" >&2
    echo "  Install via: brew install bash (macOS) / apt install bash (Linux)" >&2
    exit 1
fi

# ANSI escape character — used to strip colour codes from captured tool
# output before regex parsing. Bash $'…' resolves to the literal byte so
# downstream `sed` works on both BSD (macOS) and GNU sed without relying
# on the \xNN extension.
ESC=$'\033'

# Resolve the checkup install location (for sourcing lib/ and invoking the
# renderer) independently of the project being scanned. checkup.sh lives in bin/,
# so the install root is one level up.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

# The project to scan. Resolution order:
#   1. CHECKUP_TARGET env var (explicit override)
#   2. the enclosing git repo's top level — works whether checkup is run from a
#      checkout of your project or vendored into it
#   3. the current working directory (non-git projects)
# All reports/ and docs/reports/ paths below are relative to this root.
TARGET="${CHECKUP_TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$TARGET"

# Is the target a git repository with at least one commit? The git-forensics
# checks (hotspots, change-coupling, bug-fix-density, branch-hygiene) need
# history; on a non-git tree (a vendored snapshot, an unpacked release, a legacy
# app never put under git) they would otherwise report reassuring "no issues
# found" PASSES that really mean "no history to look at". Gate them on this so
# they skip honestly. (Surfaced auditing a non-git ASP/.NET codebase.)
GIT_OK=false
if command -v git > /dev/null 2>&1 \
    && git rev-parse --is-inside-work-tree > /dev/null 2>&1 \
    && git rev-parse HEAD > /dev/null 2>&1; then
    GIT_OK=true
fi

# Path from the repo root to the scan target (empty when scanning the repo root;
# e.g. "services/api/" for a subdirectory target). `git log` reports
# repo-root-relative paths even when run from a subdirectory, so the
# git-forensics sections strip this prefix to stay in the same target-relative
# namespace as the file-based scanners (gitleaks/semgrep) — otherwise the by-file
# aggregate joins the same file under two names and the hotspot ranking is wrong.
# Stripping with `sed "s#^${GIT_PREFIX}##"` is a no-op when GIT_PREFIX is empty. (#15)
GIT_PREFIX=""
[ "$GIT_OK" = true ] && GIT_PREFIX=$(git rev-parse --show-prefix 2>/dev/null)

# Source roots for the git-axis checks (hotspots, change-coupling,
# bug-fix-density) and the complexity scan. Space-separated; override via
# CHECKUP_SRC_ROOTS for non-standard layouts (e.g. "app internal cmd").
read -r -a SRC_ROOTS <<< "${CHECKUP_SRC_ROOTS:-src server}"

# lizard (pip console script) powers two multi-language checks — complexity
# (per-function CCN, section 13) and duplication (-Eduplicate, identifier-unified
# clone detection, section 9). Resolve it and the scan roots ONCE here so both
# sections share LIZARD_BIN / SCAN_ROOTS / LIZARD_PROBE (the duplication section
# runs first, so the resolution can't live alongside the complexity engine).
LIZARD_BIN=""
if command -v lizard > /dev/null 2>&1; then
    LIZARD_BIN="lizard"
else
    for c in /usr/local/bin/lizard "$HOME/.local/bin/lizard"; do [ -x "$c" ] && { LIZARD_BIN="$c"; break; }; done
fi

# Source roots that actually exist on disk. Non-standard legacy layouts (a
# multi-site ASP app) have neither src/ nor server/ — scan the whole tree then.
SCAN_ROOTS=()
for r in "${SRC_ROOTS[@]}"; do [ -d "$r" ] && SCAN_ROOTS+=("$r"); done
[ "${#SCAN_ROOTS[@]}" -eq 0 ] && SCAN_ROOTS=(".")

# Does the tree contain any source lizard can tokenise? (`-prune` keeps the
# probe cheap on big trees.) Gates both the lizard complexity and lizard
# duplication tiers — distinguishes "no parseable source → skip" from
# "source present but clean → pass".
LIZARD_PROBE=$(find "${SCAN_ROOTS[@]}" \( -name node_modules \) -prune -o \
    -type f \( -name '*.py' -o -name '*.cs' -o -name '*.java' -o -name '*.go' -o -name '*.c' -o -name '*.cc' -o -name '*.cpp' -o -name '*.cxx' -o -name '*.h' -o -name '*.hpp' -o -name '*.rb' -o -name '*.php' -o -name '*.swift' -o -name '*.scala' -o -name '*.rs' -o -name '*.kt' -o -name '*.kts' -o -name '*.m' -o -name '*.mm' -o -name '*.lua' -o -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' \) -print 2>/dev/null | head -1)

# Where checkup writes its own intermediates (raw captures, parsed JSON,
# summary, by-file aggregate, complexity CSV, history). Defaults to the
# scanned project's reports/ — set CHECKUP_OUT_DIR (ideally absolute) to write
# everything OUTSIDE the source tree, so the source can be mounted read-only
# (e.g. a Docker audit / due-diligence scan). The canonical "latest" report
# follows: out-dir mode → $CHECKUP_OUT_DIR/checkup-report.md, otherwise the
# committed docs/reports/checkup-report.md convention.
OUT_DIR="${CHECKUP_OUT_DIR:-reports}"
mkdir -p "$OUT_DIR"

# Output directories for the run_tool / write_parsed helpers.
export RAW_DIR="$OUT_DIR/raw"
export PARSED_DIR="$OUT_DIR/parsed"

# shellcheck source=../lib/run-tool.sh
source "$CHECKUP_HOME/lib/run-tool.sh"

echo "🩺 Application Checkup"
echo "===================="
echo ""

# Color codes
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Function to print section headers
print_section() {
    echo -e "${BLUE}📊 $1${NC}"
    echo "----------------------------------------"
}

# Track overall health
HEALTH_SCORE=0
MAX_SCORE=0

# 1. TypeScript Type Checking
# section:    typecheck
# purpose:    Catch type errors before runtime — the cheapest pre-deploy gate
#             we have. tsc covers .ts/.tsx; svelte-check covers .svelte.
# pass_means: Zero compilation errors. The codebase is type-safe end-to-end.
# fail_means: Any error blocks deploy. Fix in source (don't reach for `any`
#             or `@ts-ignore` — those defer the problem to runtime).
print_section "TypeScript Type Checking"
echo "Command: npm run typecheck"
echo ""

TS_INTENT=$(jq -n '{
    purpose:    "Catch type errors before runtime — the cheapest pre-deploy gate. Wraps tsc plus any framework-specific type checker (e.g. svelte-check, vue-tsc).",
    pass_means: "Zero compilation errors. The codebase is type-safe end-to-end.",
    fail_means: "Any error blocks deploy. Fix in source — avoid `any`/`@ts-ignore` which defer the problem to runtime."
}')

run_tool "TypeScript Type Checking" npm run typecheck
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "typecheck" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$TS_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 25))
if [ "$LAST_EXIT" = "0" ]; then
    echo -e "${GREEN}✅ TypeScript compilation successful (25/25)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 25))
    write_parsed "typecheck" "pass" 0 "Zero TypeScript errors" '[]' "$TS_INTENT"
else
    # tsc + svelte-check error formats:
    #   path/file.ts(LINE,COL): error TSXXXX: message
    #   path/file.svelte:LINE:COL Error: message (svelte-check)
    # Combine stdout + stderr — npm runners sometimes split.
    COMBINED="$RAW_DIR/typecheck.combined.txt"
    cat "$LAST_RAW" > "$COMBINED"
    [ -f "$LAST_STDERR" ] && cat "$LAST_STDERR" >> "$COMBINED"

    TS_ERROR_COUNT=$(grep -cE '^\S+\.(ts|tsx)\([0-9]+,[0-9]+\): error TS[0-9]+:|^\S+\.svelte:[0-9]+:[0-9]+ Error:' "$COMBINED" || true)
    TS_ERROR_COUNT=${TS_ERROR_COUNT:-0}

    # Capture top 10 errors from BOTH formats. Some checkers (e.g. svelte-check)
    # emit a different shape from tsc, so each format is grepped + parsed
    # separately then merged into a single top[] array.
    TSC_TOP=$(grep -E '^\S+\.(ts|tsx)\([0-9]+,[0-9]+\): error TS[0-9]+:' "$COMBINED" 2>/dev/null | head -10 | jq -R -s '
        split("\n") | map(select(length > 0)) | map(
            capture("^(?<file>\\S+?)\\((?<line>\\d+),\\d+\\): error (?<code>TS\\d+): (?<message>.*)$")
            | {file: .file, line: (.line | tonumber), code: .code, severity: "error", message: .message}
        )
    ')
    SVELTE_TOP=$(grep -E '^\S+\.svelte:[0-9]+:[0-9]+ Error:' "$COMBINED" 2>/dev/null | head -10 | jq -R -s '
        split("\n") | map(select(length > 0)) | map(
            capture("^(?<file>\\S+\\.svelte):(?<line>\\d+):\\d+ Error: (?<message>.*)$")
            | {file: .file, line: (.line | tonumber), code: "svelte-check", severity: "error", message: .message}
        )
    ')
    TS_TOP=$(jq -c -s 'add | .[0:10]' <(echo "$TSC_TOP") <(echo "$SVELTE_TOP"))

    echo -e "${RED}❌ $TS_ERROR_COUNT TypeScript error(s) detected (0/25)${NC}"
    echo "Run 'npm run typecheck' to see errors."
    write_parsed "typecheck" "fail" "$TS_ERROR_COUNT" "$TS_ERROR_COUNT TypeScript compilation errors" "$TS_TOP" "$TS_INTENT"
fi
fi
echo ""

# 2. Unit Tests
# section:    unit-tests
# purpose:    Run the Vitest unit-test suite. The largest correctness gate and
#             our primary defence against regressions in business logic and
#             security-sensitive code.
# pass_means: Every test passes. The suite is the contract — if it's green,
#             we're not regressing tracked behaviour.
# fail_means: Any failure blocks deploy. Investigate; do not skip/comment a
#             failing test (project rule — CLAUDE.md absolute rule #7).
print_section "Unit Tests"
echo "Command: npm test"
echo ""

UT_INTENT=$(jq -n '{
    purpose:    "Run the unit-test suite — primary defence against regressions in business logic and security-sensitive code.",
    pass_means: "Every test passes. The suite is the contract.",
    fail_means: "Any failure blocks deploy. Investigate root cause; never skip or comment out a failing test."
}')

run_tool "Unit Tests" npm test
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "unit-tests" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$UT_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 30))
# Vitest's summary uses ANSI; strip before regex.
TEST_OUTPUT_CLEAN=$(sed "s/${ESC}\[[0-9;]*m//g" "$LAST_RAW")

if ! echo "$TEST_OUTPUT_CLEAN" | grep -q "Test Files"; then
    echo -e "${RED}❌ Tests failed to run (0/30)${NC}"
    write_failed "unit-tests" "vitest produced no recognisable summary (exit $LAST_EXIT)" "$UT_INTENT"
else
    # Extract counts with portable regex (BSD grep has no -P / \K).
    TESTS_LINE=$(echo "$TEST_OUTPUT_CLEAN" | grep -E "^[[:space:]]*Tests[[:space:]]" | head -1)
    PASSED=$(echo "$TESTS_LINE" | sed -nE 's/.*[^0-9]([0-9]+) passed.*/\1/p')
    PASSED=${PASSED:-0}
    FAILED=$(echo "$TESTS_LINE" | sed -nE 's/.*[^0-9]([0-9]+) failed.*/\1/p')
    FAILED=${FAILED:-0}

    # When tests fail, capture the failing test names. Vitest prints
    # `FAIL  path/to/file > describe > it` headers — extract them.
    if [ "$FAILED" -gt 0 ]; then
        UT_TOP=$(grep -E '^[[:space:]]*FAIL[[:space:]]+' "$LAST_RAW" | sed "s/${ESC}\[[0-9;]*m//g" | head -10 | jq -R -s '
            split("\n") | map(select(length > 0)) | map(
                capture("FAIL\\s+(?<file>\\S+)(\\s+>\\s+(?<message>.*))?") as $m
                | {file: $m.file, line: 1, code: "test-failure", severity: "error", message: ($m.message // "test failed")}
            )
        ')
    else
        UT_TOP='[]'
    fi

    if [ "$FAILED" -gt 0 ]; then
        echo -e "${RED}❌ $FAILED test(s) failing (0/30)${NC}"
        echo "Run 'npm test' to see failures."
        write_parsed "unit-tests" "fail" "$FAILED" "$FAILED failing, $PASSED passing" "$UT_TOP" "$UT_INTENT"
    elif [ "$PASSED" -gt 0 ]; then
        echo -e "${GREEN}✅ All tests passing ($PASSED passed) (30/30)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 30))
        write_parsed "unit-tests" "pass" "$PASSED" "$PASSED tests passing" '[]' "$UT_INTENT"
    else
        echo -e "${RED}❌ No tests detected (0/30)${NC}"
        write_parsed "unit-tests" "fail" 0 "No tests detected in vitest output" '[]' "$UT_INTENT"
    fi
fi
fi
echo ""

# 3. Code Quality (Formatting + Linting)
# section:    code-quality
# purpose:    Run prettier (formatting) and ESLint (style + correctness).
#             Cheap, high-signal — formatting drift causes diff churn and
#             ESLint catches the kinds of bugs that types alone can't see
#             (unused vars, dead code, banned APIs, project-specific rules).
# pass_means: Zero ESLint errors, prettier reports nothing to fix. Warnings
#             tolerated but tracked.
# fail_means: Any ESLint error, or prettier needs to rewrite files. Both are
#             auto-fixable: `npm run format` for prettier, `npm run lint:fix`
#             for ESLint.
print_section "Code Quality (Formatting + Linting)"
echo "Command: npm run format:check && npm run lint"
echo ""

CQ_INTENT=$(jq -n '{
    purpose:    "Run prettier (formatting) and ESLint (style + correctness). Catches the bugs types miss — unused vars, banned APIs, project-specific rules.",
    pass_means: "Zero ESLint errors, prettier reports nothing to fix. Warnings tolerated but tracked.",
    fail_means: "Any ESLint error or prettier needing to rewrite files. Auto-fix: `npm run format` and `npm run lint:fix`."
}')

# Formatting — binary outcome
run_tool "Code Quality Format" npm run format:check
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "code-quality" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$CQ_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 15))
FORMAT_OK="true"
if [ "$LAST_EXIT" != "0" ]; then
    FORMAT_OK="false"
    echo -e "${RED}❌ Formatting issues detected${NC}"
    echo "Run 'npm run format' to fix."
fi

# Linting — count errors/warnings, capture top findings.
# ESLint emits findings on stdout (not stderr); $LAST_RAW is the right input.
# Anchor counts to the `✖ N problems (X errors, Y warnings)` summary line —
# the pre-existing `tail -1` picked the "potentially fixable" line instead,
# undercounting warnings when fix-suggested < total. Fixed here.
run_tool "Code Quality Lint" npm run lint
LINT_RAW="$LAST_RAW"
LINT_SUMMARY=$(grep -E '^✖ [0-9]+ problems?' "$LINT_RAW" | tail -1)
# Portable extraction (BSD grep has no -P / \K): `5 errors` → `5`.
ERROR_COUNT=$(echo "$LINT_SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) errors?.*/\1/p' | head -1)
ERROR_COUNT=${ERROR_COUNT:-0}
WARNING_COUNT=$(echo "$LINT_SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) warnings?.*/\1/p' | head -1)
WARNING_COUNT=${WARNING_COUNT:-0}

# ESLint default formatter output:
#   /abs/path/file.ts
#     12:3  error    Message text here  rule/name
# Two-pass parse: track current file across error/warning lines.
LINT_TOP_JSON=$(awk '
    /^\// { current_file = $0; next }
    /^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+(error|warning)[[:space:]]+/ {
        sub(/^[[:space:]]+/, "")
        n = split($0, parts, /[[:space:]]+/)
        pos = parts[1]; severity = parts[2]
        split(pos, lc, ":"); line = lc[1]
        rule = parts[n]
        msg = ""
        for (i = 3; i < n; i++) msg = msg (i==3 ? "" : " ") parts[i]
        printf "%s\t%s\t%s\t%s\t%s\n", current_file, line, severity, rule, msg
    }
' "$LINT_RAW" \
    | sort -t$'\t' -k3,3 \
    | head -10 \
    | jq -R -s '
        split("\n") | map(select(length > 0)) | map(
            split("\t") as $r
            | {file: $r[0], line: ($r[1] | tonumber), code: $r[3], severity: $r[2], message: $r[4]}
        )
    ')

if [ "$FORMAT_OK" = "true" ] && [ "$ERROR_COUNT" = "0" ]; then
    if [ "$WARNING_COUNT" = "0" ]; then
        echo -e "${GREEN}✅ Formatting and linting passed (15/15)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 15))
        CQ_STATUS="pass"
        CQ_SUMMARY="Format clean, lint clean"
    else
        echo -e "${GREEN}✅ Formatting and linting passed, $WARNING_COUNT warnings (15/15)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 15))
        echo "   (Warnings are acceptable but consider addressing them)"
        CQ_STATUS="warn"
        CQ_SUMMARY="Format clean, $WARNING_COUNT lint warnings"
    fi
else
    echo -e "${RED}❌ Code quality issues found (0/15)${NC}"
    [ "$FORMAT_OK" = "false" ] && echo "   - Run 'npm run format' to fix formatting"
    [ "$ERROR_COUNT" != "0" ] && echo "   - Run 'npm run lint:fix' to fix linting errors"
    CQ_STATUS="fail"
    if [ "$FORMAT_OK" = "false" ]; then
        CQ_SUMMARY="Formatting issues + $ERROR_COUNT lint errors, $WARNING_COUNT warnings"
    else
        CQ_SUMMARY="$ERROR_COUNT lint errors, $WARNING_COUNT warnings"
    fi
fi
TOTAL_FINDINGS=$((ERROR_COUNT + WARNING_COUNT))
write_parsed "code-quality" "$CQ_STATUS" "$TOTAL_FINDINGS" "$CQ_SUMMARY" "$LINT_TOP_JSON" "$CQ_INTENT"
fi
echo ""

# 3b. Type-Aware Lint Rules
# section:    type-aware-lint
# purpose:    Run the slower type-aware ESLint config (separate from the
#             default lint pass — needs the TypeScript project service, ~90s).
#             Catches `||` where `??` is required (drops 0/false silently);
#             see MEMORY.md "Codebase Gotchas".
# pass_means: Zero findings. No nullish-coalescing slip-ups, no other type-
#             aware rule violations.
# fail_means: Any error blocks the gate. Warnings under 10 → mild; ≥10 →
#             notable. Fix at source: `??` instead of `||` for nullable values.
print_section "Type-Aware Lint Rules"
echo "Command: npx eslint -c eslint.config.type-aware.js"
echo ""

TAL_INTENT=$(jq -n '{
    purpose:    "Type-aware ESLint pass (separate config, ~90s). Catches `||` where `??` is required and other rules needing the TypeScript project service.",
    pass_means: "Zero findings — no nullish-coalescing slip-ups or other type-aware violations.",
    fail_means: "Any error blocks the gate. Use `??` instead of `||` for nullable values where 0/false are valid."
}')

# Opt-in: only runs if the project supplies a type-aware ESLint config — a
# separate, slower config (it needs the TypeScript project service) that most
# projects keep distinct from their default lint pass. Skips cleanly when
# absent, so a project without one is not penalised in the score.
if [ ! -f eslint.config.type-aware.js ]; then
    echo -e "${BLUE}ℹ️  Skipped (no eslint.config.type-aware.js in project root)${NC}"
    write_skipped "type-aware-lint" "no eslint.config.type-aware.js in project root — supply one to enable" "$TAL_INTENT"
else
run_tool "Type-Aware Lint Rules" npx eslint -c eslint.config.type-aware.js
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npx not on PATH${NC}"
    write_skipped "type-aware-lint" "Node-stack check skipped — no package.json at the target, or npx not on PATH" "$TAL_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 5))

# Same summary-line anchor as section 3 (avoids the fixable-count undercount)
TYPE_LINT_SUMMARY=$(grep -E '^✖ [0-9]+ problems?' "$LAST_RAW" | tail -1)
TYPE_ERROR_COUNT=$(echo "$TYPE_LINT_SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) errors?.*/\1/p' | head -1)
TYPE_ERROR_COUNT=${TYPE_ERROR_COUNT:-0}
TYPE_WARNING_COUNT=$(echo "$TYPE_LINT_SUMMARY" | sed -nE 's/.*[^0-9]([0-9]+) warnings?.*/\1/p' | head -1)
TYPE_WARNING_COUNT=${TYPE_WARNING_COUNT:-0}

# Same ESLint output shape — reuse the awk parser
TAL_TOP_JSON=$(awk '
    /^\// { current_file = $0; next }
    /^[[:space:]]+[0-9]+:[0-9]+[[:space:]]+(error|warning)[[:space:]]+/ {
        sub(/^[[:space:]]+/, "")
        n = split($0, parts, /[[:space:]]+/)
        pos = parts[1]; severity = parts[2]
        split(pos, lc, ":"); line = lc[1]
        rule = parts[n]
        msg = ""
        for (i = 3; i < n; i++) msg = msg (i==3 ? "" : " ") parts[i]
        printf "%s\t%s\t%s\t%s\t%s\n", current_file, line, severity, rule, msg
    }
' "$LAST_RAW" \
    | sort -t$'\t' -k3,3 \
    | head -10 \
    | jq -R -s '
        split("\n") | map(select(length > 0)) | map(
            split("\t") as $r
            | {file: $r[0], line: ($r[1] | tonumber), code: $r[3], severity: $r[2], message: $r[4]}
        )
    ')

TAL_TOTAL=$((TYPE_ERROR_COUNT + TYPE_WARNING_COUNT))
if [ "$TYPE_ERROR_COUNT" = "0" ] && [ "$TYPE_WARNING_COUNT" = "0" ]; then
    echo -e "${GREEN}✅ No type-aware lint issues (5/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 5))
    TAL_STATUS="pass"
    TAL_SUMMARY="No type-aware lint findings"
elif [ "$TYPE_ERROR_COUNT" = "0" ]; then
    if [ "$TYPE_WARNING_COUNT" -lt 10 ]; then
        echo -e "${GREEN}✅ $TYPE_WARNING_COUNT type-aware warning(s) (4/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 4))
    else
        echo -e "${YELLOW}⚠️  $TYPE_WARNING_COUNT type-aware warning(s) (3/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 3))
    fi
    echo "   Use ?? instead of || when 0 or false are valid values"
    echo "   Run 'npx eslint -c eslint.config.type-aware.js' for details"
    TAL_STATUS="warn"
    TAL_SUMMARY="$TYPE_WARNING_COUNT warnings"
else
    echo -e "${RED}❌ $TYPE_ERROR_COUNT type-aware error(s) (0/5)${NC}"
    echo "   Run 'npx eslint -c eslint.config.type-aware.js' for details"
    TAL_STATUS="fail"
    TAL_SUMMARY="$TYPE_ERROR_COUNT errors, $TYPE_WARNING_COUNT warnings"
fi
write_parsed "type-aware-lint" "$TAL_STATUS" "$TAL_TOTAL" "$TAL_SUMMARY" "$TAL_TOP_JSON" "$TAL_INTENT"
fi
fi
echo ""

# 4. Production Build
# section:    build
# purpose:    Run the full production build (SvelteKit + tsup for server).
#             Catches errors that only surface when the optimiser runs:
#             missing imports in code-split chunks, server-bundle config drift,
#             Vite plugin failures.
# pass_means: Build succeeds. Artifacts can be deployed.
# fail_means: Build failed — investigate `npm run build` output. Common
#             causes: missing peer dep, env-var-only-in-dev pattern, server-
#             code accidentally imported from client.
print_section "Production Build"
echo "Command: npm run build"
echo ""

BUILD_INTENT=$(jq -n '{
    purpose:    "Run the full production build. Catches errors that only surface when the optimiser/code-splitter runs (e.g. missing peer deps, server code imported from client).",
    pass_means: "Build succeeds — artifacts can be deployed.",
    fail_means: "Build failed. Common causes: missing peer dep, dev-only env pattern in shipped code, server import from client."
}')

run_tool "Production Build" npm run build
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "build" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$BUILD_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 20))
if [ "$LAST_EXIT" = "0" ]; then
    echo -e "${GREEN}✅ Production build successful (20/20)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 20))
    write_parsed "build" "pass" 0 "Production build succeeded" '[]' "$BUILD_INTENT"
else
    # Extract the first few error-looking lines for top[]. Vite/esbuild
    # errors typically have `error:` or `ERROR` prefixes; we widen the net
    # since builds emit a mix of formats.
    BUILD_TOP=$(grep -iE '^(error|✘|ERROR)' "$LAST_RAW" 2>/dev/null | head -5 | jq -R -s '
        split("\n") | map(select(length > 0)) | map(
            {file: "build", line: 1, code: "build-error", severity: "error", message: (. | .[0:200])}
        )
    ')
    BUILD_TOP=${BUILD_TOP:-'[]'}
    echo -e "${RED}❌ Build failed (0/20)${NC}"
    echo "Run 'npm run build' to see errors."
    write_parsed "build" "fail" 1 "Production build failed (exit $LAST_EXIT)" "$BUILD_TOP" "$BUILD_INTENT"
fi
fi
echo ""

# 5. Security Analysis (Semgrep)
# section:    semgrep
# purpose:    Static analysis for known security antipatterns (SQL injection, XSS,
#             insecure CORS, hardcoded credentials, etc.) using the `auto` ruleset.
# pass_means: Zero findings. The codebase doesn't trip any rule in semgrep's
#             curated security pack.
# fail_means: 1+ ERROR-severity findings — these are likely real security issues
#             and should be triaged before shipping. WARNING-severity findings
#             are advisory; review but don't block on them in isolation.
print_section "Security Analysis (Semgrep)"
echo "Command: npm run quality:security"
echo ""

SEMGREP_INTENT=$(jq -n '{
    purpose:    "Static analysis for security antipatterns using semgreps curated `auto` ruleset.",
    pass_means: "Zero findings — the codebase trips no security rules.",
    fail_means: "Any ERROR-severity finding is likely a real issue; triage before shipping. WARNING-severity is advisory."
}')

MAX_SCORE=$((MAX_SCORE + 10))
run_tool "Security Analysis" npm run quality:security
# By convention the npm script writes reports/semgrep-report.json (semgrep's
# native JSON) and swallows the exit code. If that wiring is absent — a non-Node
# repo, or a container scan with no project deps — but semgrep is on PATH, fall
# back to invoking it directly: semgrep is cross-stack, so this decouples the
# check from the npm indirection. Validate the JSON before parsing; a
# malformed/missing file is the only true failure mode here.
SEMGREP_REPORT="reports/semgrep-report.json"
if [ ! -f "$SEMGREP_REPORT" ] && command -v semgrep > /dev/null 2>&1; then
    SEMGREP_REPORT="$OUT_DIR/semgrep-report.json"
    semgrep scan --config auto --json --quiet . > "$SEMGREP_REPORT" 2>/dev/null || true
fi
if [ ! -f "$SEMGREP_REPORT" ] || ! is_valid_json "$SEMGREP_REPORT"; then
    echo -e "${RED}❌ Semgrep scan failed (0/10)${NC}"
    echo "Run 'npm run quality:security' (or install semgrep) to see errors."
    write_failed "semgrep" "semgrep produced no parseable report (exit $LAST_EXIT)" "$SEMGREP_INTENT"
else
    FINDINGS_COUNT=$(jq '.results | length' "$SEMGREP_REPORT")
    ERROR_COUNT=$(jq '[.results[] | select(.extra.severity == "ERROR")] | length' "$SEMGREP_REPORT")
    WARN_COUNT=$(jq '[.results[] | select(.extra.severity == "WARNING")] | length' "$SEMGREP_REPORT")

    # Top 10 findings as normalised {file, line, code, severity, message} —
    # severity-sorted (ERROR first), then by file. message truncated for terminal.
    SEMGREP_TOP=$(jq -c '
        [.results[] | {
            file: .path,
            line: .start.line,
            code: (.check_id | split(".") | last),
            severity: ({"ERROR":"error","WARNING":"warning","INFO":"info"}[.extra.severity] // "warning"),
            message: ((.extra.message // "") | gsub("\\s+"; " ") | .[0:200])
        }]
        | sort_by(({"error":0,"warning":1,"info":2}[.severity] // 3), .file)
        | .[0:10]
    ' "$SEMGREP_REPORT")

    if [ "$FINDINGS_COUNT" = "0" ]; then
        echo -e "${GREEN}✅ No security issues found (10/10)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 10))
        SEMGREP_STATUS="pass"
        SEMGREP_SUMMARY="No findings"
    elif [ "$ERROR_COUNT" = "0" ]; then
        echo -e "${YELLOW}⚠️  $FINDINGS_COUNT security warning(s) found (7/10)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 7))
        echo "   Review $SEMGREP_REPORT for details"
        SEMGREP_STATUS="warn"
        SEMGREP_SUMMARY="$FINDINGS_COUNT WARNING-severity findings"
    else
        echo -e "${RED}❌ $ERROR_COUNT security error(s) found (0/10)${NC}"
        echo "   Review $SEMGREP_REPORT and fix critical issues"
        SEMGREP_STATUS="fail"
        SEMGREP_SUMMARY="$ERROR_COUNT ERROR-severity, $WARN_COUNT WARNING-severity"
    fi

    write_parsed "semgrep" "$SEMGREP_STATUS" "$FINDINGS_COUNT" "$SEMGREP_SUMMARY" "$SEMGREP_TOP" "$SEMGREP_INTENT"
fi
echo ""

# 6. Security Audit (npm audit)
# section:    npm-audit
# purpose:    Scan installed npm dependencies against the GitHub Advisory Database.
#             Complementary to SBOM/grype which uses the NVD; npm audit catches
#             npm-ecosystem-specific advisories sooner.
# pass_means: Zero high/critical advisories. Low/moderate are tolerated.
# fail_means: Any critical advisory. High-severity = warn (5/10). Run `npm audit fix`
#             for auto-resolvable cases, or pin a transitive override in package.json.
print_section "Security Vulnerabilities"
echo "Command: npm audit --json"
echo ""

AUDIT_INTENT=$(jq -n '{
    purpose:    "Scan installed npm dependencies against the GitHub Advisory Database.",
    pass_means: "Zero high/critical advisories. Low/moderate are tolerated as ecosystem noise.",
    fail_means: "Any critical advisory; high = warn. Run `npm audit fix` for auto-resolvable cases."
}')

run_tool "Security Vulnerabilities" npm audit --json
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "npm-audit" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$AUDIT_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 10))
# npm audit exits non-zero (1) when any advisory exists. That's expected;
# $LAST_EXIT does not signal a true failure here. Validate the JSON instead.
if [ ! -s "$LAST_RAW" ] || ! is_valid_json "$LAST_RAW"; then
    echo -e "${YELLOW}⚠️  npm audit produced no parseable output (5/10)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 5))
    write_failed "npm-audit" "npm audit produced no parseable JSON (exit $LAST_EXIT)" "$AUDIT_INTENT"
else
    CRIT_COUNT=$(jq '.metadata.vulnerabilities.critical // 0' "$LAST_RAW")
    HIGH_COUNT=$(jq '.metadata.vulnerabilities.high // 0' "$LAST_RAW")
    MOD_COUNT=$(jq '.metadata.vulnerabilities.moderate // 0' "$LAST_RAW")
    LOW_COUNT=$(jq '.metadata.vulnerabilities.low // 0' "$LAST_RAW")
    TOTAL=$((CRIT_COUNT + HIGH_COUNT + MOD_COUNT + LOW_COUNT))

    # Top 10 advisories — one entry per affected package, severity-mapped.
    # npm audit's `vulnerabilities` is a map keyed by package; we walk it
    # and take the highest-severity entry per package.
    AUDIT_TOP=$(jq -c '
        [.vulnerabilities // {} | to_entries[]
            | {
                file: "package.json",
                line: 1,
                code: (.value.name + "@" + (.value.range // "?")),
                severity: ({"critical":"critical","high":"high","moderate":"medium","low":"low","info":"info"}[.value.severity] // "warning"),
                message: (.value.name + " — " + .value.severity + " (" + ((.value.via | map(if type == "string" then . else (.title // "") end) | join(", "))[0:160]) + ")")
            }
        ]
        | sort_by(({"critical":0,"high":1,"medium":2,"low":3}[.severity] // 4), .code)
        | .[0:10]
    ' "$LAST_RAW")

    if [ "$CRIT_COUNT" -gt 0 ]; then
        echo -e "${RED}🚨 $CRIT_COUNT critical, $HIGH_COUNT high vulnerabilities (0/10)${NC}"
        AUDIT_STATUS="fail"
        AUDIT_SUMMARY="$CRIT_COUNT critical, $HIGH_COUNT high, $MOD_COUNT moderate, $LOW_COUNT low"
    elif [ "$HIGH_COUNT" -gt 0 ]; then
        echo -e "${YELLOW}⚠️  $HIGH_COUNT high-severity vulnerabilities (5/10)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 5))
        AUDIT_STATUS="warn"
        AUDIT_SUMMARY="$HIGH_COUNT high, $MOD_COUNT moderate, $LOW_COUNT low"
    else
        echo -e "${GREEN}✅ No high/critical vulnerabilities (10/10)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 10))
        AUDIT_STATUS="pass"
        AUDIT_SUMMARY="No high/critical ($MOD_COUNT moderate, $LOW_COUNT low)"
    fi
    [ "$TOTAL" -gt 0 ] && echo "Run 'npm audit' for details and 'npm audit fix' to resolve."

    write_parsed "npm-audit" "$AUDIT_STATUS" "$TOTAL" "$AUDIT_SUMMARY" "$AUDIT_TOP" "$AUDIT_INTENT"
fi
fi
echo ""

# 7. Dependency Freshness
# section:    deps-freshness
# purpose:    Count packages with newer versions available. Less urgent than
#             CVE scanning but a leading indicator: stale deps accumulate
#             security debt and make eventual upgrades painful.
# pass_means: Fewer than 6 outdated packages. The dependency tree is being
#             maintained.
# fail_means: 10+ outdated packages is the warning zone — schedule a sweep.
#             Critical dependency drift (>20 packages, >2 majors) is harder
#             to recover from than steady incremental updates.
print_section "Dependency Freshness"
echo "Command: npm outdated --json"
echo ""

DEPS_INTENT=$(jq -n '{
    purpose:    "Count outdated packages — leading indicator of accumulating security debt and harder eventual upgrades.",
    pass_means: "<6 outdated packages — dependency tree is being maintained.",
    fail_means: ">10 outdated = warning zone; schedule a sweep. Critical drift (>20) makes eventual upgrades painful."
}')

run_tool "Dependency Freshness" npm outdated --json
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "deps-freshness" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$DEPS_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 5))
# npm outdated exits 1 when outdated packages exist (expected); empty output
# means everything is current. Validate JSON before parsing.
if [ ! -s "$LAST_RAW" ]; then
    echo -e "${GREEN}✅ All dependencies are up-to-date (5/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 5))
    write_parsed "deps-freshness" "pass" 0 "All dependencies up-to-date" '[]' "$DEPS_INTENT"
elif ! is_valid_json "$LAST_RAW"; then
    echo -e "${YELLOW}⚠️  npm outdated produced unparseable output${NC}"
    write_failed "deps-freshness" "npm outdated did not produce valid JSON (exit $LAST_EXIT)" "$DEPS_INTENT"
else
    OUTDATED_COUNT=$(jq 'length' "$LAST_RAW")
    DEPS_TOP=$(jq -c '
        to_entries
        | map({
            file: "package.json",
            line: 1,
            code: .key,
            severity: "info",
            message: (.key + " — " + (.value.current // "?") + " → " + (.value.latest // "?") + " (" + (.value.type // "dep") + ")")
          })
        | sort_by(.code)
        | .[0:10]
    ' "$LAST_RAW")

    if [ "$OUTDATED_COUNT" -gt 10 ]; then
        echo -e "${YELLOW}⚠️  $OUTDATED_COUNT outdated dependencies (2/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 2))
        DEPS_STATUS="warn"
    elif [ "$OUTDATED_COUNT" -gt 5 ]; then
        echo -e "${YELLOW}⚠️  $OUTDATED_COUNT outdated dependencies (3/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 3))
        DEPS_STATUS="warn"
    else
        echo -e "${GREEN}✅ $OUTDATED_COUNT outdated dependencies (4/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 4))
        DEPS_STATUS="pass"
    fi
    echo "Run 'npm outdated' for details and 'npm update' to update."
    write_parsed "deps-freshness" "$DEPS_STATUS" "$OUTDATED_COUNT" "$OUTDATED_COUNT outdated packages (top 10 listed)" "$DEPS_TOP" "$DEPS_INTENT"
fi
fi
echo ""

# 8. Circular Dependencies (madge)
# section:    circular-deps
# purpose:    Detect import cycles via madge. Cycles cause module-init-order
#             bugs (vars referenced before assignment), break tree-shaking,
#             and complicate refactoring.
# pass_means: Zero cycles. The module graph is a DAG.
# fail_means: Any cycle is a refactoring TODO. Break by extracting shared
#             types/values into a leaf module, or by inverting one of the
#             dependency edges.
print_section "Circular Dependencies"
echo "Command: npm run quality:deps"
echo ""

MADGE_INTENT=$(jq -n '{
    purpose:    "Detect import cycles via madge. Cycles cause module-init-order bugs, break tree-shaking, and complicate refactoring.",
    pass_means: "Zero cycles — the module graph is a DAG.",
    fail_means: "Any cycle is a refactoring TODO. Extract shared types/values into a leaf module or invert an edge."
}')

MADGE_MARKER="$RAW_DIR/.circular-deps.marker"; : > "$MADGE_MARKER"
run_tool "Circular Dependencies" npm run quality:deps
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "circular-deps" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$MADGE_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 5))
# Trust only a report this run produced — a stale reports/madge-circular.json
# from a prior build would otherwise read as a confident "no cycles" pass.
if ! is_fresh reports/madge-circular.json "$MADGE_MARKER"; then
    echo -e "${YELLOW}⚠️  Madge scan produced no fresh report (3/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 3))
    write_failed "circular-deps" "no fresh reports/madge-circular.json produced this run (exit $LAST_EXIT) — stale report ignored" "$MADGE_INTENT"
else
    CIRCULAR_COUNT=$(jq 'length' reports/madge-circular.json)
    if [ "$CIRCULAR_COUNT" = "0" ]; then
        echo -e "${GREEN}✅ No circular dependencies detected (5/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 5))
        write_parsed "circular-deps" "pass" 0 "No import cycles" '[]' "$MADGE_INTENT"
    else
        # madge-circular.json is an array of arrays: each inner array is one cycle
        # (list of module paths). Surface the first file in each cycle as the
        # representative location.
        MADGE_TOP=$(jq -c '
            [.[] | {
                file: (.[0] // "?"),
                line: 1,
                code: "cycle",
                severity: "error",
                message: ("Cycle: " + (. | join(" → ")))
            }]
            | .[0:10]
        ' reports/madge-circular.json)
        echo -e "${RED}❌ $CIRCULAR_COUNT circular dependency chain(s) detected (0/5)${NC}"
        echo "   Review reports/madge-circular.json for details"
        write_parsed "circular-deps" "fail" "$CIRCULAR_COUNT" "$CIRCULAR_COUNT import cycles detected" "$MADGE_TOP" "$MADGE_INTENT"
    fi
fi
fi
echo ""

# 9. Code Duplication (tiered engine: jscpd → lizard)
# section:    duplication
# purpose:    Measure copy-paste density. Some duplication is acceptable
#             (boilerplate, generated code); high duplication signals missed
#             abstraction — and copy-pasted logic is where a bug gets fixed in
#             one place and not the others. Two engines, picked by stack:
#               1. jscpd  — Node targets: exact-token clone detection, the
#                  better-fit tool where a package.json + npm are present.
#               2. lizard — every other stack: -Eduplicate does identifier-
#                  unified (type-2) clone detection across the many languages
#                  lizard tokenises (C#, Java, Go, Python, C/C++, …), so the
#                  signal exists on the polyglot/legacy repos checkup targets.
# pass_means: <3% duplication. Healthy abstraction layer.
# fail_means: ≥5% duplication. Refactor toward shared helpers — when the same
#             pattern recurs 3+ times, the cost of extraction is usually
#             lower than the cost of maintaining the copies.
# notes:      Classic ASP/VBScript has no tokeniser in either engine, so .asp
#             duplication is NOT measured — the check degrades honestly there.
print_section "Code Duplication"

DUP_INTENT=$(jq -n '{
    purpose:    "Measure copy-paste density. jscpd (exact-token) on Node targets; lizard -Eduplicate (identifier-unified, type-2) on every other stack. High duplication signals missed abstraction and multiplies maintenance cost.",
    pass_means: "<3% duplication — healthy abstraction layer.",
    fail_means: "≥5% duplication. Refactor toward shared helpers when the same pattern recurs 3+ times. NOTE: Classic ASP/VBScript has no tokeniser in either engine, so .asp duplication is not measured."
}')

if [ -f package.json ] && command -v npm > /dev/null 2>&1; then
    # ---- Tier 1: jscpd (Node best-fit) ----
    echo "Command: npm run quality:duplicates"
    echo ""
    JSCPD_MARKER="$RAW_DIR/.duplication.marker"; : > "$JSCPD_MARKER"
    run_tool "Code Duplication" npm run quality:duplicates
    MAX_SCORE=$((MAX_SCORE + 5))
    # Trust only a report this run produced — a stale reports/jscpd/jscpd-report.json
    # would otherwise read as a confident low-duplication pass.
    if ! is_fresh reports/jscpd/jscpd-report.json "$JSCPD_MARKER"; then
        echo -e "${YELLOW}⚠️  jscpd scan produced no fresh report (3/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 3))
        write_failed "duplication" "no fresh reports/jscpd/jscpd-report.json produced this run (exit $LAST_EXIT) — stale report ignored" "$DUP_INTENT"
    else
        DUPLICATION_PCT=$(jq -r '.statistics.total.percentage' reports/jscpd/jscpd-report.json)
        DUPLICATION_INT=$(echo "$DUPLICATION_PCT" | awk '{print int($1)}')
        DUPLICATION_LINES=$(jq -r '.statistics.total.duplicatedLines // 0' reports/jscpd/jscpd-report.json)

        # Top 10 duplicate clones, file:line of the first occurrence
        JSCPD_TOP=$(jq -c '
            [.duplicates // [] | .[] | {
                file: .firstFile.name,
                line: .firstFile.start,
                code: "clone",
                severity: "warning",
                message: ("Clone (" + (.lines | tostring) + " lines, " + (.tokens | tostring) + " tokens) also at " + .secondFile.name + ":" + (.secondFile.start | tostring))
            }]
            | sort_by(-.line)
            | .[0:10]
        ' reports/jscpd/jscpd-report.json)

        if [ "$DUPLICATION_INT" -lt 3 ]; then
            echo -e "${GREEN}✅ Low code duplication: ${DUPLICATION_PCT}% (5/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            JSCPD_STATUS="pass"
        elif [ "$DUPLICATION_INT" -lt 5 ]; then
            echo -e "${YELLOW}⚠️  Moderate code duplication: ${DUPLICATION_PCT}% (3/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 3))
            echo "   Review reports/jscpd/jscpd-report.json for details"
            JSCPD_STATUS="warn"
        else
            echo -e "${RED}❌ High code duplication: ${DUPLICATION_PCT}% (0/5)${NC}"
            echo "   Review reports/jscpd/jscpd-report.json and consider refactoring"
            JSCPD_STATUS="fail"
        fi
        write_parsed "duplication" "$JSCPD_STATUS" "$DUPLICATION_LINES" "${DUPLICATION_PCT}% duplication across $DUPLICATION_LINES lines (jscpd)" "$JSCPD_TOP" "$DUP_INTENT"
    fi
elif [ -n "$LIZARD_BIN" ] && [ -n "$LIZARD_PROBE" ]; then
    # ---- Tier 2: lizard -Eduplicate (language-agnostic clone detection) ----
    echo "Command: lizard -Eduplicate"
    echo ""
    MAX_SCORE=$((MAX_SCORE + 5))
    run_tool "Code Duplication (lizard)" "$LIZARD_BIN" -Eduplicate "${SCAN_ROOTS[@]}"
    # lizard always prints the "Duplicates" banner once it has analysed files;
    # its absence means the invocation itself failed (bad flag, no readable
    # source) — which must NOT be read as "0% → clean pass".
    if ! grep -q '^Duplicates' "$LAST_RAW" 2>/dev/null; then
        echo -e "${YELLOW}⚠️  lizard produced no duplication report (exit $LAST_EXIT)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 3))
        write_failed "duplication" "lizard -Eduplicate produced no parseable report (exit $LAST_EXIT) — invocation error, not a clean result" "$DUP_INTENT"
    else
        # Parse lizard's text report: each "Duplicate block:" lists the cloned
        # locations as `file:start ~ end`; the footer gives the overall rate.
        DUP_PARSED=$(python3 - "$LAST_RAW" "$TARGET" <<'PY' || echo '{"rate":0,"count":0,"top":[]}'
import sys, json, re
path, target = sys.argv[1], sys.argv[2]
text = open(path, errors="replace").read()
m = re.search(r"Total duplicate rate:\s*([0-9.]+)%", text)
rate = float(m.group(1)) if m else 0.0
idx = text.find("\nDuplicates")
section = text[idx:] if idx >= 0 else ""
loc_re = re.compile(r"^(.*?):(\d+)\s*~\s*(\d+)\s*$")
pre = target.rstrip("/") + "/"
def rel(p):
    p = p.lstrip("./")
    return p[len(pre):] if p.startswith(pre) else p
findings = []
for block in section.split("Duplicate block:")[1:]:
    locs = []
    for line in block.splitlines():
        line = line.strip()
        if not line or line.startswith("^") or set(line) <= set("-="):
            continue
        mm = loc_re.match(line)
        if mm:
            locs.append((mm.group(1), int(mm.group(2)), int(mm.group(3))))
    if not locs:
        continue
    f0, s0, e0 = locs[0]
    span = e0 - s0 + 1
    others = ", ".join(f"{rel(f)}:{s}" for f, s, _ in locs[1:]) or "elsewhere"
    sev = "high" if span >= 80 else ("warning" if span >= 20 else "low")
    findings.append({"file": rel(f0), "line": s0, "code": "clone",
                     "severity": sev, "span": span,
                     "message": f"{span}-line clone also at {others}"})
findings.sort(key=lambda d: -d["span"])
for f in findings:
    del f["span"]
print(json.dumps({"rate": rate, "count": len(findings), "top": findings[:10]}))
PY
)
        DUP_RATE=$(echo "$DUP_PARSED" | jq -r '.rate')
        DUP_RATE_INT=$(echo "$DUP_RATE" | awk '{print int($1)}')
        DUP_COUNT=$(echo "$DUP_PARSED" | jq -r '.count')
        DUP_TOP=$(echo "$DUP_PARSED" | jq -c '.top')
        if [ "$DUP_RATE_INT" -lt 3 ]; then
            echo -e "${GREEN}✅ Low code duplication: ${DUP_RATE}% (5/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            DUP_STATUS="pass"
        elif [ "$DUP_RATE_INT" -lt 5 ]; then
            echo -e "${YELLOW}⚠️  Moderate code duplication: ${DUP_RATE}% ($DUP_COUNT clone blocks, 3/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 3))
            DUP_STATUS="warn"
        else
            echo -e "${RED}❌ High code duplication: ${DUP_RATE}% ($DUP_COUNT clone blocks, 0/5)${NC}"
            DUP_STATUS="fail"
        fi
        write_parsed "duplication" "$DUP_STATUS" "$DUP_COUNT" "${DUP_RATE}% duplicate token rate across $DUP_COUNT clone block(s) (lizard; Classic ASP not tokenised)" "$DUP_TOP" "$DUP_INTENT"
    fi
else
    echo -e "${BLUE}ℹ️  Skipped — no Node target (package.json) for jscpd and no lizard-parseable source for clone detection${NC}"
    write_skipped "duplication" "no Node target (package.json + npm) for jscpd and no lizard-parseable source for clone detection" "$DUP_INTENT"
fi
echo ""

# 10. Unused Code Detection (knip)
# section:    unused-code
# purpose:    Detect unused files, exports, and dependencies via knip's
#             whole-program reachability analysis. Catches dead code that
#             accumulates after refactors when imports are removed but the
#             source files remain.
# pass_means: Zero unused files + zero unlisted deps. Minor unused exports
#             tolerated (knip has false positives on dynamic imports).
# fail_means: 5+ critical issues (unused files + unlisted deps). Delete dead
#             code or add to knip's allowlist with justification.
print_section "Unused Code Detection"
echo "Command: npm run quality:unused"
echo ""

KNIP_INTENT=$(jq -n '{
    purpose:    "Detect unused files, exports, and dependencies via knips whole-program analysis. Catches dead code from refactors.",
    pass_means: "Zero unused files + zero unlisted deps. Minor unused exports tolerated (false-positive prone for dynamic imports).",
    fail_means: "5+ critical issues. Delete dead code or add to knips allowlist with justification."
}')

run_tool "Unused Code Detection" npm run quality:unused
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "unused-code" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$KNIP_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 5))
KNIP_OUTPUT=$(cat "$LAST_RAW")

# Count by category — portable sed extraction (BSD grep has no -P / \K).
# Knip prints e.g. `Unused files (3)`; we extract the number in parens.
knip_count() {
    echo "$KNIP_OUTPUT" | sed -nE "s/.*$1 \\(([0-9]+)\\).*/\\1/p" | head -1
}
UNUSED_FILES=$(knip_count 'Unused files');         UNUSED_FILES=${UNUSED_FILES:-0}
UNUSED_DEPS=$(knip_count 'Unused dependencies');   UNUSED_DEPS=${UNUSED_DEPS:-0}
UNUSED_DEV_DEPS=$(knip_count 'Unused devDependencies'); UNUSED_DEV_DEPS=${UNUSED_DEV_DEPS:-0}
UNLISTED_DEPS=$(knip_count 'Unlisted dependencies'); UNLISTED_DEPS=${UNLISTED_DEPS:-0}
UNUSED_EXPORTS=$(knip_count 'Unused exports');     UNUSED_EXPORTS=${UNUSED_EXPORTS:-0}

CRITICAL_ISSUES=$((UNUSED_FILES + UNLISTED_DEPS))
TOTAL_ISSUES=$((UNUSED_FILES + UNUSED_DEPS + UNUSED_DEV_DEPS + UNLISTED_DEPS))

# top[] aggregates the category counts as findings — each category gets
# a synthetic entry with severity reflecting risk (files = warning,
# unlisted = error since it means runtime breakage risk).
KNIP_TOP=$(jq -n \
    --argjson files "$UNUSED_FILES" \
    --argjson deps "$UNUSED_DEPS" \
    --argjson devdeps "$UNUSED_DEV_DEPS" \
    --argjson unlisted "$UNLISTED_DEPS" \
    --argjson exports "$UNUSED_EXPORTS" '
    [
        (if $unlisted > 0 then {file:"package.json", line:1, code:"unlisted-deps", severity:"error",   message:($unlisted | tostring + " unlisted dependencies (runtime breakage risk)")} else empty end),
        (if $files    > 0 then {file:"various",       line:1, code:"unused-files",  severity:"warning", message:($files    | tostring + " unused files — candidates for deletion")} else empty end),
        (if $deps     > 0 then {file:"package.json", line:1, code:"unused-deps",   severity:"warning", message:($deps     | tostring + " unused dependencies in package.json")} else empty end),
        (if $exports  > 0 then {file:"various",       line:1, code:"unused-exports", severity:"low",    message:($exports  | tostring + " unused exports (may be false positives for dynamic imports)")} else empty end),
        (if $devdeps  > 0 then {file:"package.json", line:1, code:"unused-devdeps", severity:"low",    message:($devdeps  | tostring + " unused devDependencies")} else empty end)
    ]
')

if [ "$CRITICAL_ISSUES" -eq 0 ] && [ "$TOTAL_ISSUES" -eq 0 ]; then
    echo -e "${GREEN}✅ No unused code detected (5/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 5))
    KNIP_STATUS="pass"
    KNIP_SUMMARY="No unused code"
elif [ "$CRITICAL_ISSUES" -eq 0 ] && [ "$TOTAL_ISSUES" -lt 10 ]; then
    echo -e "${GREEN}✅ Minor unused code: $TOTAL_ISSUES issue(s) (4/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 4))
    [ "$UNUSED_DEPS" -gt 0 ] && echo "   - $UNUSED_DEPS unused dependencies"
    [ "$UNUSED_DEV_DEPS" -gt 0 ] && echo "   - $UNUSED_DEV_DEPS unused devDependencies"
    KNIP_STATUS="warn"
    KNIP_SUMMARY="$TOTAL_ISSUES minor unused entries"
elif [ "$CRITICAL_ISSUES" -lt 5 ]; then
    echo -e "${YELLOW}⚠️  Unused code detected (3/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 3))
    [ "$UNUSED_FILES" -gt 0 ] && echo "   - $UNUSED_FILES unused files"
    [ "$UNLISTED_DEPS" -gt 0 ] && echo "   - $UNLISTED_DEPS unlisted dependencies"
    [ "$UNUSED_DEPS" -gt 0 ] && echo "   - $UNUSED_DEPS unused dependencies"
    echo "   Run 'npm run quality:unused' for details"
    KNIP_STATUS="warn"
    KNIP_SUMMARY="$CRITICAL_ISSUES critical, $TOTAL_ISSUES total unused entries"
else
    echo -e "${RED}❌ Significant unused code detected (0/5)${NC}"
    [ "$UNUSED_FILES" -gt 0 ] && echo "   - $UNUSED_FILES unused files"
    [ "$UNLISTED_DEPS" -gt 0 ] && echo "   - $UNLISTED_DEPS unlisted dependencies"
    [ "$UNUSED_DEPS" -gt 0 ] && echo "   - $UNUSED_DEPS unused dependencies"
    [ "$UNUSED_EXPORTS" -gt 0 ] && echo "   - $UNUSED_EXPORTS unused exports"
    echo "   Run 'npm run quality:unused' for details"
    KNIP_STATUS="fail"
    KNIP_SUMMARY="$CRITICAL_ISSUES critical, $TOTAL_ISSUES total unused entries"
fi
write_parsed "unused-code" "$KNIP_STATUS" "$TOTAL_ISSUES" "$KNIP_SUMMARY" "$KNIP_TOP" "$KNIP_INTENT"
fi
echo ""

# 11. Test Coverage
# section:    coverage
# purpose:    Generate the Vitest coverage report and surface the headline
#             numbers. Coverage isn't a goal in itself — but coverage trends
#             reveal whether new code is being tested. Sudden drops indicate
#             untested PRs slipped through.
# pass_means: Report generated with both summary numbers and full HTML.
#             Statements ≥ 70% is the project's target band.
# fail_means: Coverage generation failed, or stmt coverage < 50%. Investigate
#             test failures or recent merges that added untested code.
# notes:      The section checks both `coverage/coverage-summary.json` (vitest
#             default) and the `coverage/` directory existence — projects
#             that direct coverage output elsewhere may need to adjust.
print_section "Test Coverage"
echo "Command: npm run test:coverage:report"
echo ""

COVERAGE_INTENT=$(jq -n '{
    purpose:    "Generate the test coverage report. Coverage trends reveal whether new code is being tested; sudden drops suggest untested PRs.",
    pass_means: "Report generated and statements ≥70%. The project target band is 70-90%.",
    fail_means: "Generation failed or stmt coverage <50%. Investigate test failures or recent untested merges."
}')

COV_MARKER="$RAW_DIR/.coverage.marker"; : > "$COV_MARKER"
run_tool "Test Coverage" npm run test:coverage:report
if toolchain_absent; then
    echo -e "${BLUE}ℹ️  Skipped — no package.json at the target, or npm not on PATH${NC}"
    write_skipped "coverage" "Node-stack check skipped — no package.json at the target, or npm not on PATH" "$COVERAGE_INTENT"
else
MAX_SCORE=$((MAX_SCORE + 5))
# Trust only a summary this run produced — a stale coverage/coverage-summary.json
# (or a leftover coverage/ dir) would otherwise read as a confident pass.
COV_FRESH=false
is_fresh coverage/coverage-summary.json "$COV_MARKER" && COV_FRESH=true
if [ "$LAST_EXIT" != "0" ] && [ "$COV_FRESH" = false ]; then
    echo -e "${RED}❌ Coverage generation failed (0/5)${NC}"
    echo "Run 'npm run test:coverage:report' to see errors."
    write_failed "coverage" "coverage generation failed (exit $LAST_EXIT) and no fresh coverage-summary.json present — stale report ignored" "$COVERAGE_INTENT"
elif [ "$COV_FRESH" = true ]; then
    # v8 coverage produces coverage-summary.json with .total.{statements,branches,functions,lines}.pct
    STMT_PCT=$(jq -r '.total.statements.pct // 0' coverage/coverage-summary.json)
    BRANCH_PCT=$(jq -r '.total.branches.pct // 0' coverage/coverage-summary.json)
    FN_PCT=$(jq -r '.total.functions.pct // 0' coverage/coverage-summary.json)
    LINE_PCT=$(jq -r '.total.lines.pct // 0' coverage/coverage-summary.json)
    STMT_INT=$(echo "$STMT_PCT" | awk '{print int($1)}')

    if [ "$STMT_INT" -ge 70 ]; then
        echo -e "${GREEN}✅ Coverage: stmts ${STMT_PCT}%, branches ${BRANCH_PCT}%, fns ${FN_PCT}% (5/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 5))
        COV_STATUS="pass"
    elif [ "$STMT_INT" -ge 50 ]; then
        echo -e "${YELLOW}⚠️  Coverage: stmts ${STMT_PCT}% (3/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 3))
        COV_STATUS="warn"
    else
        echo -e "${RED}❌ Low coverage: stmts ${STMT_PCT}% (0/5)${NC}"
        COV_STATUS="fail"
    fi
    echo "   View detailed report: open coverage/index.html"
    write_parsed "coverage" "$COV_STATUS" "$STMT_INT" \
        "stmts ${STMT_PCT}%, branches ${BRANCH_PCT}%, fns ${FN_PCT}%, lines ${LINE_PCT}%" \
        '[]' "$COVERAGE_INTENT"
elif [ "$LAST_EXIT" = "0" ] && [ -d coverage ]; then
    # Tool succeeded this run but emitted no summary JSON (HTML-only setups)
    echo -e "${GREEN}✅ Coverage report generated (5/5)${NC}"
    echo "   View detailed report: open coverage/index.html"
    HEALTH_SCORE=$((HEALTH_SCORE + 5))
    write_parsed "coverage" "pass" 0 "Coverage report generated (no summary JSON available)" '[]' "$COVERAGE_INTENT"
else
    echo -e "${YELLOW}⚠️  Coverage ran but no fresh output detected (3/5)${NC}"
    HEALTH_SCORE=$((HEALTH_SCORE + 3))
    write_failed "coverage" "no fresh coverage output produced this run — stale report ignored" "$COVERAGE_INTENT"
fi
fi
echo ""
# 12. Codebase Statistics (scc)
# section:    codebase-stats
# purpose:    Track total code size and language breakdown over time.
# pass_means: Always passes — informational. Trend reveals growth surprises
#             (e.g. a single PR adding 10% of total LOC) that no single
#             section-by-section diff would flag.
# fail_means: N/A (stats check, not a findings check).
print_section "Codebase Statistics"
echo "Command: scc (Succinct Code Counter)"
echo ""

SCC_INTENT=$(jq -n '{
    purpose:    "Track total code size and language breakdown over time.",
    pass_means: "Always passes — stats check. Trend reveals growth surprises (e.g. a single PR adding 10% of total LOC).",
    fail_means: "N/A (informational, not a findings check)."
}')

# scc is sometimes installed outside $PATH (e.g. dropped under ~/.local/bin
# by a user-space installer). Probe a small set of conventional locations
# before reporting as missing. Avoid world-writable directories like /tmp
# — picking up an executable there would be a privilege-escalation vector.
SCC_CMD=""
if command -v scc > /dev/null 2>&1; then
    SCC_CMD="scc"
else
    for candidate in /usr/local/bin/scc "$HOME/.local/bin/scc"; do
        [ -x "$candidate" ] && { SCC_CMD="$candidate"; break; }
    done
fi

if [ -z "$SCC_CMD" ]; then
    echo -e "${YELLOW}⚠️  scc not installed${NC}"
    echo "   Install: brew install scc / static binary from https://github.com/boyter/scc/releases"
    write_skipped "codebase-stats" "scc not installed (brew install scc / static binary from GitHub releases)" "$SCC_INTENT"
else
    echo -e "${GREEN}✅ scc found: $($SCC_CMD --version)${NC}"
    echo ""

    run_tool "Codebase Statistics" "$SCC_CMD" \
        --exclude-dir=node_modules,.svelte-kit,coverage,.prisma,build,dist --no-cocomo

    if [ ! -s "$LAST_RAW" ]; then
        echo -e "${YELLOW}⚠️  scc produced no output${NC}"
        write_failed "codebase-stats" "scc returned exit $LAST_EXIT with empty output" "$SCC_INTENT"
    else
        cat "$LAST_RAW"
        echo ""

        # scc columns: Language | Files | Lines | Blanks | Comments | Code | Complexity
        # `tr -d ,` strips thousand-separators (e.g. "1,632") that would otherwise
        # produce invalid JSON when interpolated as numbers below.
        TOTAL_CODE=$(grep "^Total" "$LAST_RAW" | awk '{print $6}' | tr -d ',')
        TOTAL_FILES=$(grep "^Total" "$LAST_RAW" | awk '{print $2}' | tr -d ',')
        COMPLEXITY=$(grep "^Total" "$LAST_RAW" | awk '{print $7}' | tr -d ',')

        # Top languages by code, derived from scc's JSON rather than hardcoded to
        # TypeScript/Svelte — so the breakdown is meaningful on ANY stack (a
        # legacy ASP/C# audit, a Go service, etc.). The text table above is for
        # the console; JSON is robust to language names with spaces / truncation.
        SCC_TOP_LANGS=$("$SCC_CMD" --format json \
            --exclude-dir=node_modules,.svelte-kit,coverage,.prisma,build,dist 2>/dev/null \
            | jq -r 'sort_by(-.Code) | .[0:3] | map("\(.Name) \(.Code)") | join(", ")' 2>/dev/null)
        [ -z "$SCC_TOP_LANGS" ] && SCC_TOP_LANGS="n/a"

        echo -e "${BLUE}📈 Summary:${NC} ${TOTAL_CODE:-0} lines of code across ${TOTAL_FILES:-0} files"
        echo -e "   Top: ${SCC_TOP_LANGS} | Complexity: ${COMPLEXITY:-0}"

        # Standardised parsed JSON for the tool-agnostic markdown writer.
        write_parsed "codebase-stats" "pass" "${TOTAL_FILES:-0}" \
            "${TOTAL_CODE:-0} lines across ${TOTAL_FILES:-0} files (top: ${SCC_TOP_LANGS})" \
            '[]' \
            "$SCC_INTENT"
    fi
fi
echo ""

# 13. Complexity Hotspots (tiered engine: ESLint → lizard → scc)
# section:    complexity
# purpose:    Identify functions whose cyclomatic (and, on JS/TS, cognitive)
#             complexity makes them likely bug-incubators. Three engines, picked
#             by language (extension probe; #7 auto-detector will supersede):
#               1. ESLint  — JS/TS: AST-accurate cyclomatic (`complexity`) AND
#                  cognitive (`sonarjs/cognitive-complexity`) via
#                  typescript-eslint, so TS class methods, decorators, JSX-in-TS,
#                  satisfies expressions etc. parse correctly.
#               2. lizard  — true per-function CCN for the many languages it
#                  parses (C#, Java, Go, Python, C/C++, JS/TS, …). No cognitive.
#               3. scc     — universal decision-keyword heuristic; the only
#                  engine covering Classic ASP, so it stays the final fallback.
# pass_means: No functions over CCN 10 (or cognitive 15 on the ESLint path).
# fail_means: Any function over CCN 30 (or cognitive 30) — refactor or cover with
#             dedicated tests. 20-29 = warning, 10/15-19 = low priority.
# notes:      ESLint is preferred for JS/TS specifically: lizard's state-machine
#             TS parser mis-attributes class-method CCN to the first top-level
#             function preceding a class, generating false positives on TS-heavy
#             code. lizard (true CCN) and scc (heuristic) cover everything else.
#             All three emit the same lizard-format CSV (col 2 = CCN, col 7 =
#             file) that git-hotspots joins, so churn × complexity works on any
#             stack.
#
#             Reporter thresholds (CCN 10, cognitive 15) are intentionally
#             LOWER than typical gating thresholds in a project's ESLint
#             config, so this surfaces hotspots without blocking the build.
print_section "Complexity Hotspots"
echo "Command: complexity engine auto-selected by language (ESLint → lizard → scc)"
echo ""

COMPLEXITY_INTENT=$(jq -n '{
    purpose:    "Identify functions whose cyclomatic + cognitive complexity makes them likely bug-incubators. AST-aware via ESLint (typescript-eslint).",
    pass_means: "No functions over CCN 10 or cognitive 15.",
    fail_means: "Any function over CCN/cognitive 30 — refactor or cover with dedicated tests. 20-29 = warning."
}')

# Resolve scc for the language-agnostic fallback (same probe as codebase-stats).
CPLX_SCC=""
if command -v scc > /dev/null 2>&1; then
    CPLX_SCC="scc"
else
    for c in /usr/local/bin/scc "$HOME/.local/bin/scc"; do [ -x "$c" ] && { CPLX_SCC="$c"; break; }; done
fi

# lizard + scan roots are resolved once near the top (shared with duplication).
CPLX_LIZARD="$LIZARD_BIN"
CPLX_ROOTS=("${SCAN_ROOTS[@]}")

# Engine selection — a three-tier ladder by descending accuracy:
#   1. ESLint   — JS/TS only: AST-accurate cyclomatic AND cognitive complexity.
#   2. lizard   — true per-function CCN for the many languages it parses
#                 (C#, Java, Go, Python, C/C++, JS/TS, …). No cognitive metric.
#   3. scc      — universal decision-keyword heuristic; the only engine that
#                 covers Classic ASP, so it stays the final fallback.
# All three emit the same lizard-format Tornhill CSV (col 2 = CCN, col 7 = file)
# that git-hotspots joins, so churn × complexity works on every stack.
#
# Selection is an extension-count probe today; the #7 auto-detector will
# supersede it. JS/TS present + npx → ESLint. Else any lizard-parseable source
# (LIZARD_PROBE, resolved near the top) + lizard → lizard. Else scc.
JSTS_PROBE=$(find "${CPLX_ROOTS[@]}" \( -name node_modules -o -name .svelte-kit -o -name dist -o -name build \) -prune -o \
    -type f \( -name '*.ts' -o -name '*.tsx' -o -name '*.js' -o -name '*.jsx' -o -name '*.mjs' -o -name '*.cjs' \) -print 2>/dev/null | head -1)

if [ -n "$JSTS_PROBE" ] && command -v npx > /dev/null 2>&1; then
    echo -e "${GREEN}✅ ESLint available via npx${NC}"
    echo ""

    # Reporter thresholds (warn-level, much lower than the gating thresholds in
    # eslint.config.js). --rule overrides whatever's in the config for this
    # invocation; the project's flat config is still loaded so parser + plugins
    # work correctly. --no-warn-ignored suppresses noise about ignored files.
    run_tool "Complexity Hotspots" npx eslint \
        --rule '{"complexity":["warn",10],"sonarjs/cognitive-complexity":["warn",15]}' \
        --format json --no-warn-ignored \
        "${SRC_ROOTS[@]}"

    if ! is_valid_json "$LAST_RAW"; then
        echo -e "${YELLOW}⚠️  ESLint produced unparseable JSON (exit $LAST_EXIT)${NC}"
        write_failed "complexity" "ESLint produced unparseable JSON (exit $LAST_EXIT)" "$COMPLEXITY_INTENT"
    else
        # Normalise to TARGET-relative paths (not repo-root), so a subdirectory
        # target shares one path namespace with the file-based scanners and the
        # churn × complexity join in git-hotspots (#15). pwd == $TARGET here.
        # Filter test/build paths at the JSON layer rather than via
        # --ignore-pattern. The gating ESLint config still lints these files
        # for general issues; we only exclude them from complexity *reporting*
        # because tests legitimately have higher branching (matcher paths) than
        # production code, and dist/build paths are generated.
        ALL_FINDINGS=$(jq --arg root "$TARGET" '
            [ .[]
              | select(.filePath | test("\\.test\\.ts$|\\.spec\\.ts$|/__tests__/|/dist/|/build/|/\\.svelte-kit/") | not)
              | .filePath as $fp
              | .messages[]
              | select(.ruleId == "complexity" or .ruleId == "sonarjs/cognitive-complexity")
              # Extract numeric CCN/cognitive score from the message text:
              #   complexity:           "... has a complexity of N."
              #   sonarjs/cognitive:    "... reduce its Cognitive Complexity from N to ..."
              | (.message | capture("(?:complexity of |Complexity from )(?<n>\\d+)").n | tonumber) as $ccn
              # Extract function name. The two rules emit different formats:
              #
              # complexity (ESLint built-in) — quotes a name for declared
              # functions/methods (Function NAME, Method NAME, Async method
              # NAME), but emits "Arrow function has a complexity of N" for
              # anonymous arrow functions / closures (no quoted name).
              #
              # sonarjs/cognitive-complexity — never quotes a name. The
              # message is always "Refactor this function to reduce its
              # Cognitive Complexity from N to the X allowed."
              #
              # COG findings therefore always fall through to (anonymous).
              # That is fine for the substrate: file + line is the canonical
              # pointer into source; the function name is a display nicety.
              # Improving this would require reading the source at .line to
              # derive the name — high-effort for a small UX gain.
              | ((.message | capture("'\''(?<name>[^'\'']+)'\''").name) // "(anonymous)") as $fname
              | ($fp | sub("^" + $root + "/"; "")) as $rel
              | (if .ruleId == "sonarjs/cognitive-complexity" then "COG" else "CCN" end) as $kind
              | {
                  file: $rel,
                  line: .line,
                  ccn: $ccn,
                  code: ($kind + "-" + ($ccn | tostring)),
                  severity: (if $ccn >= 30 then "error" elif $ccn >= 20 then "warning" else "low" end),
                  message: ($fname + " — " + (if $kind == "COG" then "cognitive complexity " else "CCN " end) + ($ccn | tostring))
                }
            ]
        ' "$LAST_RAW")

        TOTAL_COUNT=$(echo "$ALL_FINDINGS" | jq 'length')

        # Reset the Tornhill-input CSV ahead of the branching. If we don't
        # truncate, a previous dirty run leaves stale CCN rows behind that
        # the git-hotspots section will happily consume on a subsequent
        # clean run. The lizard implementation always overwrote via `cp`,
        # so this matches the prior contract.
        mkdir -p "$OUT_DIR"
        : > "$OUT_DIR/complexity-full.csv"

        if [ "$TOTAL_COUNT" -eq 0 ]; then
            echo -e "${GREEN}✅ No functions over CCN 10 / cognitive 15${NC}"
            write_parsed "complexity" "pass" 0 "No hotspots over CCN 10 / cognitive 15" '[]' "$COMPLEXITY_INTENT"
        else
            # Top 20 by descending score; the public top[] sheds the internal
            # .ccn sort key so the substrate schema stays clean.
            TOP_FINDINGS=$(echo "$ALL_FINDINGS" | jq 'sort_by(-.ccn) | .[0:20] | map(del(.ccn))')
            HIGHEST_CCN=$(echo "$ALL_FINDINGS" | jq '[.[].ccn] | max')

            STATUS="warn"
            [ "$HIGHEST_CCN" -ge 30 ] && STATUS="fail"

            # Terminal display
            printf "%-7s %-50s %s\n" "Score" "Function" "Location"
            echo "----------------------------------------------------------------------------------------"
            echo "$TOP_FINDINGS" | jq -r '
                .[] | [.code, ((.message | split(" — ")[0])[0:50]), (.file + ":" + (.line | tostring))] | @tsv
            ' | awk -F'\t' '{ printf "%-7s %-50s %s\n", $1, $2, $3 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $TOTAL_COUNT hotspots over CCN 10 / cognitive 15 (top 20 shown, highest $HIGHEST_CCN)"

            # Write Tornhill-compatible CSV from the cyclomatic findings only —
            # cognitive is a separate metric and would skew column-2 "CCN" reads
            # in the git-hotspots section (which expects radon-style CCN).
            # Lizard CSV column layout, preserved for downstream compatibility:
            #   NLOC, CCN, token, params, length, function_id, file,
            #   function_name, signature, start_line, end_line
            # Tornhill (section 19) reads only columns 2 (CCN) and 7 (file);
            # the rest are zero-padded.
            # NB: the CSV is truncated ahead of the if-else above; this is the
            # only branch that populates it.
            echo "$ALL_FINDINGS" | jq -r '
                .[] | select(.code | startswith("CCN-")) |
                [0, .ccn, 0, 0, 0,
                 ("eslint:" + .file + "@" + (.line | tostring)),
                 .file,
                 ((.message | split(" — ")[0])),
                 "",
                 .line, .line] | @csv
            ' > "$OUT_DIR/complexity-full.csv"

            write_parsed "complexity" "$STATUS" "$TOTAL_COUNT" \
                "$TOTAL_COUNT hotspots over CCN 10 / cognitive 15 (top 20 reported, highest score $HIGHEST_CCN)" \
                "$TOP_FINDINGS" "$COMPLEXITY_INTENT"
        fi
    fi
elif [ -n "$CPLX_LIZARD" ] && [ -n "$LIZARD_PROBE" ]; then
    echo -e "${GREEN}✅ lizard available — true multi-language complexity${NC}"
    echo ""

    LIZARD_INTENT=$(jq -n '{
        purpose:    "True per-function cyclomatic complexity across many languages (C#, Java, Go, Python, C/C++, JS/TS, …) via lizard. Sharper than the scc heuristic; feeds the churn × complexity git-hotspots join.",
        pass_means: "No function over CCN 10.",
        fail_means: "Any function over CCN 30 — refactor or cover with dedicated tests. 20-29 = warning, 10-19 = low. (Cognitive complexity is JS/TS-only, via ESLint.)"
    }')

    # --CCN 9999 forces a zero warning count so lizard exits 0 regardless of how
    # many hotspots it finds; --csv still lists every function. The columns are
    # the canonical lizard CSV (col 2 = CCN, col 7 = file) git-hotspots consumes.
    run_tool "Complexity (lizard)" "$CPLX_LIZARD" --csv --CCN 9999 "${CPLX_ROOTS[@]}"

    # lizard --csv is CSV, not JSON — validate by content, not is_valid_json. The
    # extension probe already confirmed lizard-parseable source exists, so empty
    # output here is pathological (report it honestly rather than false-pass).
    if [ ! -s "$LAST_RAW" ]; then
        echo -e "${YELLOW}⚠️  lizard produced no output (exit $LAST_EXIT)${NC}"
        write_failed "complexity" "lizard produced no output (exit $LAST_EXIT)" "$LIZARD_INTENT"
    else
        mkdir -p "$OUT_DIR"
        # Canonical Tornhill CSV straight from lizard. Strip any leading "./" so
        # paths are TARGET-relative and share one namespace with the churn join
        # and the file-based scanners. Written unconditionally (even with zero
        # reportable hotspots) so git-hotspots sees every file's max CCN.
        sed 's#"\./#"#g' "$LAST_RAW" > "$OUT_DIR/complexity-full.csv"

        # Parse the CSV. Fields 2 (CCN), 6 (location), 7 (file) and 8 (function)
        # all precede column 9 (long_name), the only field that can contain
        # commas — so a plain comma split reads them reliably. The start line
        # comes from the location field ("name@start-end@file"), also pre-col-9.
        ALL_FINDINGS=$(jq -R -s --arg root "$TARGET" '
            def unq: gsub("^\"|\"$"; "");
            [ split("\n")[]
              | select(length > 0)
              | split(",") as $f
              | select(($f | length) >= 11)
              | ($f[1] | tonumber) as $ccn
              | ($f[5] | unq) as $loc
              | ($f[6] | unq) as $file
              | ($f[7] | unq) as $fname
              | select($ccn >= 10)
              | select($file | test("\\.test\\.|\\.spec\\.|/__tests__/|/dist/|/build/|/\\.svelte-kit/") | not)
              | {
                  file: ($file | sub("^" + $root + "/"; "") | sub("^\\./"; "")),
                  line: (($loc | capture("@(?<s>[0-9]+)-").s | tonumber) // 1),
                  ccn: $ccn,
                  code: ("CCN-" + ($ccn | tostring)),
                  severity: (if $ccn >= 30 then "error" elif $ccn >= 20 then "warning" else "low" end),
                  message: ($fname + " — CCN " + ($ccn | tostring))
                }
            ]
        ' "$LAST_RAW")

        TOTAL_COUNT=$(echo "$ALL_FINDINGS" | jq 'length')

        if [ "$TOTAL_COUNT" -eq 0 ]; then
            echo -e "${GREEN}✅ No functions over CCN 10${NC}"
            write_parsed "complexity" "pass" 0 "No hotspots over CCN 10 (lizard, true per-function CCN)" '[]' "$LIZARD_INTENT"
        else
            TOP_FINDINGS=$(echo "$ALL_FINDINGS" | jq 'sort_by(-.ccn) | .[0:20] | map(del(.ccn))')
            HIGHEST_CCN=$(echo "$ALL_FINDINGS" | jq '[.[].ccn] | max')

            STATUS="warn"
            [ "$HIGHEST_CCN" -ge 30 ] && STATUS="fail"

            printf "%-7s %-50s %s\n" "Score" "Function" "Location"
            echo "----------------------------------------------------------------------------------------"
            echo "$TOP_FINDINGS" | jq -r '
                .[] | [.code, ((.message | split(" — ")[0])[0:50]), (.file + ":" + (.line | tostring))] | @tsv
            ' | awk -F'\t' '{ printf "%-7s %-50s %s\n", $1, $2, $3 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $TOTAL_COUNT function(s) over CCN 10 (lizard; top 20 shown, highest $HIGHEST_CCN)"

            write_parsed "complexity" "$STATUS" "$TOTAL_COUNT" \
                "$TOTAL_COUNT function(s) over CCN 10 (lizard, true per-function CCN; top 20 reported, highest $HIGHEST_CCN)" \
                "$TOP_FINDINGS" "$LIZARD_INTENT"
        fi
    fi
elif [ -n "$CPLX_SCC" ]; then
    echo -e "${GREEN}✅ scc available — language-agnostic complexity${NC}"
    echo ""

    SCC_CPLX_INTENT=$(jq -n '{
        purpose:    "Rank files by complexity for any language using scc (no toolchain). scc complexity is a decision-keyword heuristic, not true per-function CCN — a solid relative signal that also feeds the churn × complexity git-hotspots join.",
        pass_means: "No file over the heuristic complexity band (25).",
        fail_means: "Files high on the heuristic are bug-incubators / refactor candidates — confirm with a language-aware tool. Reported as warn (heuristic, not a hard gate)."
    }')

    run_tool "Complexity (scc)" "$CPLX_SCC" "${CPLX_ROOTS[@]}" \
        --by-file --format json --no-cocomo \
        --exclude-dir=node_modules,.svelte-kit,coverage,.prisma,build,dist

    if ! is_valid_json "$LAST_RAW"; then
        echo -e "${YELLOW}⚠️  scc produced unparseable JSON (exit $LAST_EXIT)${NC}"
        write_failed "complexity" "scc produced unparseable JSON (exit $LAST_EXIT)" "$SCC_CPLX_INTENT"
    else
        # Flatten per-file entries; rank by scc complexity. Severity bands are
        # heuristic (scc complexity ≈ decision-keyword count), documented as such.
        CPLX_FINDINGS=$(jq '
            [ .[].Files[]?
              | select((.Complexity // 0) > 0)
              | { file: (.Location | sub("^\\./"; "")), line: 1, ccn: .Complexity, lines: .Lines,
                  code: ("complexity-" + (.Complexity | tostring)),
                  severity: (if .Complexity >= 100 then "high" elif .Complexity >= 50 then "warning" elif .Complexity >= 25 then "low" else "info" end),
                  message: ((.Location | sub(".*/"; "")) + " — scc complexity " + (.Complexity | tostring) + " (" + (.Lines | tostring) + " lines)") }
            ]
            | sort_by(-.ccn)
        ' "$LAST_RAW")

        mkdir -p "$OUT_DIR"
        : > "$OUT_DIR/complexity-full.csv"
        # Tornhill-compatible CSV: col 2 = complexity, col 7 = file (git-hotspots
        # reads only those). Same layout the ESLint path emits.
        echo "$CPLX_FINDINGS" | jq -r '
            .[] | [0, .ccn, 0, 0, 0, ("scc:" + .file), .file, (.file | sub(".*/"; "")), "", 1, 1] | @csv
        ' > "$OUT_DIR/complexity-full.csv"

        REPORTED=$(echo "$CPLX_FINDINGS" | jq '[.[] | select(.ccn >= 25)]')
        TOTAL_COUNT=$(echo "$REPORTED" | jq 'length')
        MAXC=$(echo "$CPLX_FINDINGS" | jq '([.[].ccn] | max) // 0')
        TOP_FINDINGS=$(echo "$REPORTED" | jq 'sort_by(-.ccn) | .[0:20] | map(del(.ccn, .lines))')

        if [ "$TOTAL_COUNT" -eq 0 ]; then
            echo -e "${GREEN}✅ No files over scc complexity 25 (highest $MAXC)${NC}"
            write_parsed "complexity" "pass" 0 "No files over scc complexity 25 (heuristic; highest $MAXC)" '[]' "$SCC_CPLX_INTENT"
        else
            CPLX_STATUS="pass"
            [ "$MAXC" -ge 50 ] && CPLX_STATUS="warn"
            printf "%-9s %-50s %s\n" "Score" "File" "Lines"
            echo "----------------------------------------------------------------------------------------"
            echo "$REPORTED" | jq -r 'sort_by(-.ccn) | .[0:20][] | [("scc-" + (.ccn | tostring)), ((.file | sub(".*/"; ""))[0:50]), (.lines | tostring)] | @tsv' \
                | awk -F'\t' '{ printf "%-9s %-50s %s\n", $1, $2, $3 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $TOTAL_COUNT file(s) over scc complexity 25 (heuristic; highest $MAXC)"
            write_parsed "complexity" "$CPLX_STATUS" "$TOTAL_COUNT" \
                "$TOTAL_COUNT file(s) over scc complexity 25 (heuristic ranking; highest $MAXC) — feeds git-hotspots" \
                "$TOP_FINDINGS" "$SCC_CPLX_INTENT"
        fi
    fi
else
    echo -e "${YELLOW}⚠️  no complexity engine (need npx + ESLint for JS/TS, or scc)${NC}"
    write_skipped "complexity" "no complexity engine available — need npx + ESLint (JS/TS) or scc (any language)" "$COMPLEXITY_INTENT"
fi
echo ""

# 14. Mutation Testing (Optional - slow)
# section:    mutation
# purpose:    Run Stryker mutation testing. Mutates the source (changes
#             operators, returns, conditions) and re-runs tests — if no
#             test caught the change, that's a surviving mutant: a gap in
#             the test suite's assertions.
# pass_means: Mutation score ≥ 80%. Tests reliably catch logic mutations.
# fail_means: <60% suggests tests check that code RUNS but not what it DOES.
#             Surviving mutants in reports/mutation/mutation.html name the
#             specific gaps.
# notes:      Opt-in via MUTATION_TEST=1 — slow (~2 min) so omitted from
#             default runs.
print_section "Mutation Testing (Optional)"
echo "Command: npx stryker run"
echo ""

MUTATION_INTENT=$(jq -n '{
    purpose:    "Run mutation testing — surfaces test-suite gaps that line coverage misses (tests that check code runs but not what it does).",
    pass_means: "Mutation score ≥80% — tests reliably catch logic mutations.",
    fail_means: "<60% suggests assertion-light tests. Investigate surviving mutants in reports/mutation/mutation.html."
}')

if [ "${MUTATION_TEST:-0}" != "1" ]; then
    echo -e "${BLUE}ℹ️  Skipped (run with MUTATION_TEST=1 to enable)${NC}"
    echo "   Mutation testing is slow (~2 min) - enable for deep quality audits"
    write_skipped "mutation" "opt-in only — set MUTATION_TEST=1 to enable" "$MUTATION_INTENT"
else
    MAX_SCORE=$((MAX_SCORE + 10))
    echo "Running mutation tests on critical files... (this takes ~2 minutes)"
    run_tool "Mutation Testing" npx stryker run

    if [ "$LAST_EXIT" != "0" ]; then
        echo -e "${RED}❌ Mutation testing failed (0/10)${NC}"
        echo "Run 'npx stryker run' to see errors."
        write_failed "mutation" "stryker failed (exit $LAST_EXIT)" "$MUTATION_INTENT"
    else
        # Score appears as "XX.YY |" in Stryker's text summary.
        # Portable: sed extracts the float preceding the pipe (BSD grep has no -P).
        MUTATION_SCORE=$(sed -nE 's/.*[^0-9.]([0-9]+\.[0-9]+) \|.*/\1/p' "$LAST_RAW" | head -1)
        MUTATION_SCORE=${MUTATION_SCORE:-0}
        MUTATION_INT=$(echo "$MUTATION_SCORE" | awk '{print int($1)}')

        if [ "$MUTATION_INT" -ge 80 ]; then
            echo -e "${GREEN}✅ Mutation score: ${MUTATION_SCORE}% (10/10)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 10))
            MUTATION_STATUS="pass"
        elif [ "$MUTATION_INT" -ge 60 ]; then
            echo -e "${YELLOW}⚠️  Mutation score: ${MUTATION_SCORE}% (7/10)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 7))
            echo "   Review surviving mutants in reports/mutation/mutation.html"
            MUTATION_STATUS="warn"
        elif [ "$MUTATION_INT" -gt 0 ]; then
            echo -e "${YELLOW}⚠️  Mutation score: ${MUTATION_SCORE}% (5/10)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            echo "   Many surviving mutants - tests may not catch bugs effectively"
            MUTATION_STATUS="warn"
        else
            echo -e "${YELLOW}⚠️  Mutation testing completed but could not parse score${NC}"
            MUTATION_STATUS="warn"
        fi
        echo "   View report: open reports/mutation/mutation.html"
        write_parsed "mutation" "$MUTATION_STATUS" "$MUTATION_INT" \
            "Mutation score: ${MUTATION_SCORE}%" '[]' "$MUTATION_INTENT"
    fi
fi
echo ""

# 15. Shell Script Linting (shellcheck)
# section:    shellcheck
# purpose:    Lint all shell scripts against shellcheck's default ruleset.
#             Catches the bash-specific bugs that bite hardest: quoting
#             traps, unset-variable use, command-substitution gotchas,
#             set -e interaction surprises. Particularly relevant now
#             that the substrate is ~2000 lines of bash.
# pass_means: Zero findings of any level across owned bash.
# fail_means: Any error-level finding (shellcheck classifies its rules
#             into error/warning/info/style; errors typically mean the
#             script will not behave as the author intended). Warnings
#             tolerated initially; lower-level findings are informational.
print_section "Shell Script Linting"
echo "Command: shellcheck <owned bash>"
echo ""

SHELLCHECK_INTENT=$(jq -n '{
    purpose:    "Lint shell scripts for bash-specific bugs: quoting traps, unset-variable use, command-substitution gotchas, set -e interactions.",
    pass_means: "Zero error-level findings across owned bash.",
    fail_means: "Any error-level finding — investigate; errors typically mean the script will not do what its author intended. Warnings tolerated initially."
}')

MAX_SCORE=$((MAX_SCORE + 5))

# Targets: every owned bash file under the project's shell-script dirs
# (recursive). Override the search roots via CHECKUP_SHELL_DIRS (space-separated);
# the defaults cover common script + git-hook locations. Dirs that don't
# exist are silently skipped. Exclusions:
#   .husky/_/* — husky generates these at install time; not owned.
#   __tests__/fixtures/* — deliberately malformed test data.
read -r -a SHELL_DIRS <<< "${CHECKUP_SHELL_DIRS:-scripts .husky .githooks .claude/hooks}"
SHELLCHECK_FILES=()
while IFS= read -r line; do
    SHELLCHECK_FILES+=("$line")
done < <(
    find "${SHELL_DIRS[@]}" \
        -type f \( -name '*.sh' -o -name '*.bash' \) 2>/dev/null \
        | grep -vE '(\.husky/_/|/__tests__/fixtures/)' \
        | sort -u
)
# git hooks (husky / raw .git hooks) are shebanged but extensionless — add explicitly.
for HOOK in .husky/pre-commit .husky/pre-push .husky/post-merge \
            .githooks/pre-commit .githooks/pre-push; do
    [ -f "$HOOK" ] && SHELLCHECK_FILES+=("$HOOK")
done

if [ "${#SHELLCHECK_FILES[@]}" -eq 0 ]; then
    write_skipped "shellcheck" "no shell scripts found under: ${SHELL_DIRS[*]}" "$SHELLCHECK_INTENT"
else
    run_tool "Shell Script Linting" shellcheck -f json "${SHELLCHECK_FILES[@]}"

    if [ "$LAST_EXIT" = "127" ]; then
        write_skipped "shellcheck" "shellcheck not installed (apt install shellcheck / brew install shellcheck)" "$SHELLCHECK_INTENT"
    elif ! is_valid_json "$LAST_RAW"; then
        write_failed "shellcheck" "shellcheck produced unparseable output (exit $LAST_EXIT)" "$SHELLCHECK_INTENT"
    else
        SHELLCHECK_TOTAL=$(jq 'length' "$LAST_RAW")
        SHELLCHECK_ERRORS=$(jq '[.[] | select(.level=="error")] | length' "$LAST_RAW")
        SHELLCHECK_WARNS=$(jq '[.[] | select(.level=="warning")] | length' "$LAST_RAW")

        # Top 10 findings, severity-sorted then by file. shellcheck level
        # names map 1:1 to our severity vocabulary (error/warning/info/style).
        SHELLCHECK_TOP=$(jq -c '
            sort_by(({"error":0,"warning":1,"info":2,"style":3}[.level] // 4), .file, .line)
            | .[0:10]
            | map({
                file: .file,
                line: .line,
                code: ("SC" + (.code | tostring)),
                severity: .level,
                message: ((.message // "") | gsub("\\s+"; " ") | .[0:200])
            })
        ' "$LAST_RAW")

        # Derive info+style count once — used for parallel breakdowns in both
        # the warn and fail summaries so callers see the full level distribution
        # regardless of the verdict.
        SHELLCHECK_INFOSTYLE=$((SHELLCHECK_TOTAL - SHELLCHECK_ERRORS - SHELLCHECK_WARNS))

        if [ "$SHELLCHECK_TOTAL" = "0" ]; then
            echo -e "${GREEN}✅ No shellcheck findings (5/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            SHELLCHECK_STATUS="pass"
            SHELLCHECK_SUMMARY="No findings across ${#SHELLCHECK_FILES[@]} scripts"
        elif [ "$SHELLCHECK_ERRORS" = "0" ]; then
            echo -e "${YELLOW}⚠️  $SHELLCHECK_TOTAL shellcheck finding(s), 0 errors (3/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 3))
            SHELLCHECK_STATUS="warn"
            SHELLCHECK_SUMMARY="$SHELLCHECK_TOTAL findings ($SHELLCHECK_WARNS warning, $SHELLCHECK_INFOSTYLE info/style)"
        else
            echo -e "${RED}❌ $SHELLCHECK_ERRORS shellcheck error(s) (0/5)${NC}"
            SHELLCHECK_STATUS="fail"
            SHELLCHECK_SUMMARY="$SHELLCHECK_ERRORS error, $SHELLCHECK_WARNS warning, $SHELLCHECK_INFOSTYLE info/style ($SHELLCHECK_TOTAL total)"
        fi

        write_parsed "shellcheck" "$SHELLCHECK_STATUS" "$SHELLCHECK_TOTAL" \
            "$SHELLCHECK_SUMMARY" "$SHELLCHECK_TOP" "$SHELLCHECK_INTENT"
    fi
fi
echo ""

# 16. Workflow YAML Linting (yamllint)
# section:    yamllint
# purpose:    Lint GitHub Actions workflow YAML for schema/structural
#             issues. CI workflow bugs typically surface mid-run after
#             the fact; pre-merge lint catches indent / truthy / missing-
#             key issues early.
# pass_means: Zero error-level findings against the project's .yamllint.yml.
# fail_means: Any error-level finding — investigate; warnings tolerated.
print_section "Workflow YAML Linting"
echo "Command: yamllint .github/workflows/*.yml"
echo ""

YAMLLINT_INTENT=$(jq -n '{
    purpose:    "Lint CI workflow YAML for schema/structural issues — catches indent, missing-key, and truthy/quoting bugs that otherwise surface mid-run.",
    pass_means: "Zero error-level findings against the project yamllint config.",
    fail_means: "Any error-level finding — workflow YAML bugs typically waste a CI cycle; investigate before merge."
}')

MAX_SCORE=$((MAX_SCORE + 5))

YAMLLINT_FILES=()
while IFS= read -r line; do
    YAMLLINT_FILES+=("$line")
done < <(find .github/workflows -type f -name '*.yml' 2>/dev/null | sort -u)

if [ "${#YAMLLINT_FILES[@]}" -eq 0 ]; then
    write_skipped "yamllint" "no GitHub Actions workflow YAML found under .github/workflows/" "$YAMLLINT_INTENT"
else
    run_tool "Workflow YAML Linting" yamllint -f parsable "${YAMLLINT_FILES[@]}"

    if [ "$LAST_EXIT" = "127" ]; then
        write_skipped "yamllint" "yamllint not installed (pipx install yamllint)" "$YAMLLINT_INTENT"
    else
        # Parse the `path:line:col: [level] message (rule)` parsable format
        # into the standard top[] shape. Handles empty output (zero findings)
        # as well as the populated case.
        YAMLLINT_PARSED=$(jq -R -s '
            split("\n") | map(select(length > 0))
            | map(capture("^(?<file>[^:]+):(?<line>\\d+):(?<col>\\d+): \\[(?<level>\\w+)\\] (?<message>.+) \\((?<rule>[a-z-]+)\\)$") // null)
            | map(select(. != null))
        ' "$LAST_RAW")

        YAMLLINT_TOTAL=$(echo "$YAMLLINT_PARSED" | jq 'length')
        YAMLLINT_ERRORS=$(echo "$YAMLLINT_PARSED" | jq '[.[] | select(.level=="error")] | length')
        YAMLLINT_WARNS=$(echo "$YAMLLINT_PARSED" | jq '[.[] | select(.level=="warning")] | length')

        YAMLLINT_TOP=$(echo "$YAMLLINT_PARSED" | jq -c '
            sort_by(({"error":0,"warning":1}[.level] // 2), .file, (.line | tonumber))
            | .[0:10]
            | map({
                file: .file,
                line: (.line | tonumber),
                code: .rule,
                severity: .level,
                message: ((.message // "") | gsub("\\s+"; " ") | .[0:200])
            })
        ')

        # Pluralisation helpers — `1 warning` vs `0/N warnings`.
        YAMLLINT_W_S=$([ "$YAMLLINT_WARNS" = "1" ] || echo "s")
        YAMLLINT_E_S=$([ "$YAMLLINT_ERRORS" = "1" ] || echo "s")

        if [ "$YAMLLINT_TOTAL" = "0" ]; then
            echo -e "${GREEN}✅ No yamllint findings (5/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            YAMLLINT_STATUS="pass"
            YAMLLINT_SUMMARY="No findings across ${#YAMLLINT_FILES[@]} workflow files"
        elif [ "$YAMLLINT_ERRORS" = "0" ]; then
            echo -e "${YELLOW}⚠️  $YAMLLINT_TOTAL yamllint finding(s), 0 errors (3/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 3))
            YAMLLINT_STATUS="warn"
            YAMLLINT_SUMMARY="$YAMLLINT_TOTAL findings ($YAMLLINT_WARNS warning$YAMLLINT_W_S)"
        else
            echo -e "${RED}❌ $YAMLLINT_ERRORS yamllint error(s) (0/5)${NC}"
            YAMLLINT_STATUS="fail"
            YAMLLINT_SUMMARY="$YAMLLINT_ERRORS error$YAMLLINT_E_S, $YAMLLINT_WARNS warning$YAMLLINT_W_S ($YAMLLINT_TOTAL total)"
        fi

        write_parsed "yamllint" "$YAMLLINT_STATUS" "$YAMLLINT_TOTAL" \
            "$YAMLLINT_SUMMARY" "$YAMLLINT_TOP" "$YAMLLINT_INTENT"
    fi
fi
echo ""

# 17. Dockerfile Linting (hadolint)
# section:    hadolint
# purpose:    Lint Dockerfile for common antipatterns — bad COPY --chown,
#             missing --no-install-recommends, ARG/ENV ordering, version-
#             pinning gaps. Dockerfile bugs surface at deploy or runtime;
#             pre-merge lint catches them in source.
# pass_means: Zero error-level findings against the production Dockerfile.
# fail_means: Any error-level finding — investigate; warnings tolerated.
# Project Dockerfile filename. Resolution order:
#   1. HADOLINT_DOCKERFILE env var (explicit override)
#   2. Auto-detect first `Dockerfile*` at repo root (handles
#      Dockerfile, Dockerfile.app, Dockerfile.backend, etc. without
#      project-specific names baked into the substrate)
#   3. Fall back to `Dockerfile` for the skip diagnostic
HADOLINT_TARGET="${HADOLINT_DOCKERFILE:-}"
if [ -z "$HADOLINT_TARGET" ]; then
    for candidate in Dockerfile Dockerfile.*; do
        if [ -f "$candidate" ]; then
            HADOLINT_TARGET="$candidate"
            break
        fi
    done
    HADOLINT_TARGET="${HADOLINT_TARGET:-Dockerfile}"
fi
print_section "Dockerfile Linting"
echo "Command: hadolint $HADOLINT_TARGET"
echo ""

HADOLINT_INTENT=$(jq -n '{
    purpose:    "Lint Dockerfile for build/runtime antipatterns — bad COPY --chown, missing --no-install-recommends, version-pinning gaps.",
    pass_means: "Zero error-level findings.",
    fail_means: "Any error-level finding — Dockerfile bugs typically surface at deploy or runtime; cheaper to catch pre-merge."
}')

MAX_SCORE=$((MAX_SCORE + 5))

if [ ! -f "$HADOLINT_TARGET" ]; then
    write_skipped "hadolint" "No Dockerfile* found at repo root (override with HADOLINT_DOCKERFILE)" "$HADOLINT_INTENT"
else
    run_tool "Dockerfile Linting" hadolint -f json "$HADOLINT_TARGET"

    if [ "$LAST_EXIT" = "127" ]; then
        write_skipped "hadolint" "hadolint not installed (brew install hadolint / static binary from GitHub releases)" "$HADOLINT_INTENT"
    elif ! is_valid_json "$LAST_RAW"; then
        write_failed "hadolint" "hadolint produced unparseable output (exit $LAST_EXIT)" "$HADOLINT_INTENT"
    else
        HADOLINT_TOTAL=$(jq 'length' "$LAST_RAW")
        HADOLINT_ERRORS=$(jq '[.[] | select(.level=="error")] | length' "$LAST_RAW")
        HADOLINT_WARNS=$(jq '[.[] | select(.level=="warning")] | length' "$LAST_RAW")
        HADOLINT_INFOSTYLE=$((HADOLINT_TOTAL - HADOLINT_ERRORS - HADOLINT_WARNS))

        HADOLINT_TOP=$(jq -c '
            sort_by(({"error":0,"warning":1,"info":2,"style":3}[.level] // 4), .file, .line)
            | .[0:10]
            | map({
                file: .file,
                line: .line,
                code: .code,
                severity: .level,
                message: ((.message // "") | gsub("\\s+"; " ") | .[0:200])
            })
        ' "$LAST_RAW")

        # Pluralisation helpers — `1 warning` vs `0/N warnings`.
        HADOLINT_W_S=$([ "$HADOLINT_WARNS" = "1" ] || echo "s")
        HADOLINT_E_S=$([ "$HADOLINT_ERRORS" = "1" ] || echo "s")

        if [ "$HADOLINT_TOTAL" = "0" ]; then
            echo -e "${GREEN}✅ No hadolint findings (5/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 5))
            HADOLINT_STATUS="pass"
            HADOLINT_SUMMARY="No findings"
        elif [ "$HADOLINT_ERRORS" = "0" ]; then
            echo -e "${YELLOW}⚠️  $HADOLINT_TOTAL hadolint finding(s), 0 errors (3/5)${NC}"
            HEALTH_SCORE=$((HEALTH_SCORE + 3))
            HADOLINT_STATUS="warn"
            HADOLINT_SUMMARY="$HADOLINT_TOTAL findings ($HADOLINT_WARNS warning$HADOLINT_W_S, $HADOLINT_INFOSTYLE info/style)"
        else
            echo -e "${RED}❌ $HADOLINT_ERRORS hadolint error(s) (0/5)${NC}"
            HADOLINT_STATUS="fail"
            HADOLINT_SUMMARY="$HADOLINT_ERRORS error$HADOLINT_E_S, $HADOLINT_WARNS warning$HADOLINT_W_S, $HADOLINT_INFOSTYLE info/style ($HADOLINT_TOTAL total)"
        fi

        write_parsed "hadolint" "$HADOLINT_STATUS" "$HADOLINT_TOTAL" \
            "$HADOLINT_SUMMARY" "$HADOLINT_TOP" "$HADOLINT_INTENT"
    fi
fi
echo ""

# 18. Secret Scanning (gitleaks)
# section:    gitleaks
# purpose:    Scan the working tree for committed/checked-out secrets
#             that the staged-only secretlint pre-commit hook would
#             have missed. Catches accidental leaks in files that
#             never made it through staging review.
# pass_means: Zero findings against the working tree.
# fail_means: Any finding — investigate. Complementary to a secret manager,
#             which prevents secrets reaching dev envs in the first place.
print_section "Secret Scanning"
echo "Command: gitleaks dir [--config .gitleaks.toml] ."
echo ""

GITLEAKS_INTENT=$(jq -n '{
    purpose:    "Scan the working tree for committed/checked-out secrets.",
    pass_means: "Zero findings (project .gitleaks.toml allowlist if present, else gitleaks defaults).",
    fail_means: "Any finding is a real signal — investigate. Without a project allowlist, expect some false positives to triage."
}')

MAX_SCORE=$((MAX_SCORE + 5))

# Use the project's allowlist if it has one; otherwise fall back to gitleaks'
# built-in default rules so the scan still runs on any repo (e.g. auditing a
# project that never configured gitleaks). Decouples the check from a
# repo-supplied config — same spirit as the semgrep fallback.
# gitleaks writes its JSON to --report-path. Use a real file under $OUT_DIR
# rather than /dev/stdout: piping the report to stdout is unreliable across
# gitleaks 8.x under redirection (it can emit nothing), whereas a file is
# deterministic and stays outside a read-only source mount.
GITLEAKS_REPORT="$OUT_DIR/gitleaks-report.json"
GITLEAKS_ARGS=(dir --no-banner --redact --report-format=json --report-path="$GITLEAKS_REPORT")
[ -f .gitleaks.toml ] && GITLEAKS_ARGS+=(--config .gitleaks.toml)
run_tool "Secret Scanning" gitleaks "${GITLEAKS_ARGS[@]}" .

if [ "$LAST_EXIT" = "127" ]; then
    write_skipped "gitleaks" "gitleaks not installed (brew install gitleaks / static binary from GitHub releases)" "$GITLEAKS_INTENT"
elif ! is_valid_json "$GITLEAKS_REPORT"; then
    write_failed "gitleaks" "gitleaks produced no parseable report (exit $LAST_EXIT)" "$GITLEAKS_INTENT"
else
    GITLEAKS_TOTAL=$(jq 'length' "$GITLEAKS_REPORT")

    GITLEAKS_TOP=$(jq -c '
        sort_by(.File, .StartLine)
        | .[0:10]
        | map({
            file: .File,
            line: .StartLine,
            code: .RuleID,
            severity: "critical",
            message: ((.Description // "") | gsub("\\s+"; " ") | .[0:200])
        })
    ' "$GITLEAKS_REPORT")

    if [ "$GITLEAKS_TOTAL" = "0" ]; then
        echo -e "${GREEN}✅ No secrets detected (5/5)${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + 5))
        GITLEAKS_STATUS="pass"
        GITLEAKS_SUMMARY="No secrets detected in working tree"
    else
        echo -e "${RED}❌ $GITLEAKS_TOTAL secret finding(s) (0/5)${NC}"
        echo "   Review $GITLEAKS_REPORT for redacted details."
        GITLEAKS_STATUS="fail"
        GITLEAKS_SUMMARY="$GITLEAKS_TOTAL finding(s)"
    fi

    write_parsed "gitleaks" "$GITLEAKS_STATUS" "$GITLEAKS_TOTAL" \
        "$GITLEAKS_SUMMARY" "$GITLEAKS_TOP" "$GITLEAKS_INTENT"
fi
echo ""

# 19. Git Hotspots (churn × complexity)
# section:    git-hotspots
# purpose:    Cross-correlate 6-month commit churn with max cyclomatic
#             complexity per file. Files high on BOTH axes are the
#             "bug hotspots" from Tornhill's "Code as a Crime Scene":
#             statistically the highest-risk-per-dollar refactor
#             targets in long-lived codebases.
# pass_means: No files in the top quintile of BOTH churn AND complexity
#             — the chronic-change × high-difficulty quadrant is empty.
# fail_means: Any file in that top-quintile pairing — surface as a
#             warning. Informational signal; never gates the build,
#             same model as the complexity check.
# notes:      Depends on $OUT_DIR/complexity-full.csv (ESLint- or scc-derived,
#             written by the complexity section above). Skipped if absent or
#             if the target is not a git repo with history.
print_section "Git Hotspots (Churn × Complexity)"
echo "Command: git log (6-month churn) joined with $OUT_DIR/complexity-full.csv (max CCN/file)"
echo ""

HOTSPOTS_INTENT=$(jq -n '{
    purpose:    "Cross-correlate 6-month commit churn with max CCN per file. Tornhill bug-hotspot signal — informational, never gates.",
    pass_means: "No files in the top quintile of BOTH churn AND complexity — the dangerous diagonal is empty.",
    fail_means: "Files in the top quintile of BOTH axes — refactor candidates in score-descending priority order."
}')

# Informational only — no MAX_SCORE addition. Mirrors the complexity
# check (section 13): we want the signal in the report without conflating
# it with the deployability gate.

if [ ! -s "$OUT_DIR/complexity-full.csv" ]; then
    echo -e "${YELLOW}⚠️  $OUT_DIR/complexity-full.csv missing — run the complexity section first${NC}"
    write_skipped "git-hotspots" \
        "$OUT_DIR/complexity-full.csv not present — depends on the complexity section" \
        "$HOTSPOTS_INTENT"
elif [ "$GIT_OK" != true ]; then
    write_skipped "git-hotspots" "not a git repository with history (or git absent) — cannot compute churn" "$HOTSPOTS_INTENT"
else
    # Churn: count of commits touching each file in the last 6 months,
    # scoped to the same source roots ESLint covered (src/, server/).
    # --pretty=format: suppresses commit headers; --name-only emits the
    # changed-files list. Blank separators between commits are filtered.
    CHURN_TSV=$(git log --since=6.months.ago --pretty=format: --name-only -- "${SRC_ROOTS[@]}" 2>/dev/null \
        | sed "s#^${GIT_PREFIX}##" \
        | grep -v '^$' \
        | sort | uniq -c \
        | awk '{
            count = $1
            $1 = ""
            sub(/^ +/, "")
            printf "%s\t%d\n", $0, count
        }')

    # Max CCN per file from the complexity CSV (lizard-format compatible —
    # written by the ESLint reporter in section 13). Column 7
    # is the file path (quoted); column 2 is CCN. The function_id-derived
    # parse used in section 13 is overkill here — column 7 is comma-clean.
    MAX_CCN_TSV=$(awk -F',' '{
        f = $7
        gsub(/"/, "", f)
        if ($2+0 > max[f]) max[f] = $2+0
    }
    END { for (f in max) printf "%s\t%d\n", f, max[f] }' "$OUT_DIR/complexity-full.csv")

    # Inner join on file, requiring positive churn. A file untouched in
    # the last 6 months cannot be a hotspot regardless of CCN. Including
    # zero-churn rows poisons the quintile computation in two ways:
    #   1) If 20%+ of complexity-tracked files are zero-churn (small repo or
    #      sparse 6-month window), churnQ80 = 0 and `.churn >= 0` matches
    #      everything — unchanged high-CCN files get classified as
    #      diagonal hotspots.
    #   2) Even when churnQ80 > 0, the median branch's `.churn >= 0`
    #      misclassifies zero-churn files as above-median.
    # Filtering at the join keeps the tiered universe to files that
    # genuinely have temporal signal.
    JOINED=$(awk -F'\t' '
        NR==FNR { churn[$1] = $2; next }
        ($1 in churn) { printf "%s\t%d\t%d\n", $1, $2, churn[$1] }
    ' <(printf "%s\n" "$CHURN_TSV") <(printf "%s\n" "$MAX_CCN_TSV"))

    JOINED_COUNT=$(echo "$JOINED" | grep -c . || true)

    if [ "$JOINED_COUNT" -lt 10 ]; then
        echo -e "${YELLOW}⚠️  Too few files in joined dataset ($JOINED_COUNT) — quintile analysis not meaningful${NC}"
        write_skipped "git-hotspots" \
            "Joined dataset has only $JOINED_COUNT files; quintile analysis requires ≥10 to be meaningful" \
            "$HOTSPOTS_INTENT"
    else
        # Tier by quintile membership. Severity values follow the
        # standard severity contract (see README.md):
        #   diagonal     (top quintile BOTH axes)  → severity "warning"
        #   single-axis  (top quintile ONE axis)   → severity "low"
        #   above-median (above median BOTH axes)  → severity "info"
        #   (none)       drop
        # `error` deliberately NOT used — `error` weights at 4 (must-fix)
        # in the by-file aggregate and at 0 (highest triage) in Top
        # Problems, which would promote informational hotspot rows above
        # real failures. Demoted severities still render hotspots in
        # Top Problems with reasonable priority without competing with
        # hard failures.
        #
        # Within the tiered set, sort tier-first (diagonal > single-axis
        # > above-median), then by descending score = log(churn+1)×CCN.
        # Score-only sort can evict diagonal rows from the top-20 cap
        # when a high-CCN single-axis outlier outscores them. Tier-first
        # guarantees every diagonal hotspot appears before any
        # single-axis or above-median row.
        HOTSPOTS_JSON=$(echo "$JOINED" | jq -R -s '
            def quantile($p): . as $arr | length as $n
                | if $n == 0 then 0 else $arr[((($n - 1) * $p) | floor)] end;
            def sevRank: ({"warning":1, "low":2, "info":3}[.] // 9);

            split("\n")
            | map(select(length > 0))
            | map(split("\t") | {file:.[0], maxCcn:(.[1]|tonumber), churn:(.[2]|tonumber)})
            | . as $rows
            | ($rows | map(.churn)  | sort | quantile(0.8)) as $churnQ80
            | ($rows | map(.maxCcn) | sort | quantile(0.8)) as $ccnQ80
            | ($rows | map(.churn)  | sort | quantile(0.5)) as $churnMed
            | ($rows | map(.maxCcn) | sort | quantile(0.5)) as $ccnMed
            | $rows
            | map(. + {severity:
                (if   .churn >= $churnQ80 and .maxCcn >= $ccnQ80 then "warning"
                 elif .churn >= $churnQ80 or  .maxCcn >= $ccnQ80 then "low"
                 elif .churn >= $churnMed and .maxCcn >= $ccnMed then "info"
                 else null end)})
            | map(select(.severity != null))
            | map(. + {score: ((.churn + 1 | log) * .maxCcn)})
            | sort_by([(.severity | sevRank), -.score])
            | {
                cutoffs: {churnQ80:$churnQ80, ccnQ80:$ccnQ80, churnMed:$churnMed, ccnMed:$ccnMed},
                diagonalCount:    (map(select(.severity == "warning")) | length),
                singleAxisCount:  (map(select(.severity == "low"))     | length),
                aboveMedianCount: (map(select(.severity == "info"))    | length),
                findings: (.[0:20] | map({
                    file,
                    line: 1,
                    code: "hotspot",
                    severity,
                    message: ((.churn | tostring) + " changes × CCN " + (.maxCcn | tostring))
                }))
            }
        ')

        DIAGONAL_COUNT=$(echo "$HOTSPOTS_JSON" | jq -r '.diagonalCount')
        SINGLE_AXIS_COUNT=$(echo "$HOTSPOTS_JSON" | jq -r '.singleAxisCount')
        ABOVE_MEDIAN_COUNT=$(echo "$HOTSPOTS_JSON" | jq -r '.aboveMedianCount')
        TOTAL_TIERED=$((DIAGONAL_COUNT + SINGLE_AXIS_COUNT + ABOVE_MEDIAN_COUNT))
        CHURN_Q80=$(echo "$HOTSPOTS_JSON" | jq -r '.cutoffs.churnQ80')
        CCN_Q80=$(echo "$HOTSPOTS_JSON" | jq -r '.cutoffs.ccnQ80')
        FINDINGS=$(echo "$HOTSPOTS_JSON" | jq -c '.findings')

        HOTSPOTS_D_S=$([ "$DIAGONAL_COUNT" = "1" ] || echo "s")
        HOTSPOTS_A_S=$([ "$SINGLE_AXIS_COUNT" = "1" ] || echo "s")

        # Terminal display: top 10 only. Full top-20 lives in parsed JSON.
        # Display column shows the tier *position* (diagonal / single-axis /
        # above-median) rather than the underlying severity string, which
        # is an alias chosen for renderer-weight reasons. Tier labels are
        # the names a human reads in the Tornhill model.
        if [ "$TOTAL_TIERED" -eq 0 ]; then
            echo -e "${GREEN}✅ No files in the hotspot quadrant${NC}"
            echo "   Cutoffs: churn ≥ $CHURN_Q80, max CCN ≥ $CCN_Q80 (top quintiles)"
        else
            printf "%-13s %-7s %-7s %s\n" "Tier" "Churn" "Max CCN" "File"
            echo "----------------------------------------------------------------------------------------"
            echo "$FINDINGS" | jq -r '
                .[0:10][]
                | [
                    ({"warning":"diagonal","low":"single-axis","info":"above-median"}[.severity] // .severity),
                    (.message | split(" ")[0]),
                    (.message | split(" CCN ")[1]),
                    .file
                  ]
                | @tsv
            ' | awk -F'\t' '{ printf "%-13s %-7s %-7s %s\n", $1, $2, $3, $4 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $DIAGONAL_COUNT diagonal, $SINGLE_AXIS_COUNT single-axis, $ABOVE_MEDIAN_COUNT above-median"
            echo "   Cutoffs: churn ≥ $CHURN_Q80, max CCN ≥ $CCN_Q80 (top quintiles)"
            echo "   Showing top 10 by tier then score; top 20 in reports/parsed/git-hotspots.json"
        fi

        # Status: warn if any diagonal hotspot exists; otherwise pass.
        # Never fail — this is a bug-prediction signal, not a gate. The
        # complexity check (section 13) already fails on CCN ≥ 30; gating
        # here too would double-charge the same files.
        if [ "$DIAGONAL_COUNT" -gt 0 ]; then
            HOTSPOTS_STATUS="warn"
            HOTSPOTS_SUMMARY="$DIAGONAL_COUNT file${HOTSPOTS_D_S} in the top quintile of both churn and complexity (top 20 reported)"
        elif [ "$SINGLE_AXIS_COUNT" -gt 0 ]; then
            HOTSPOTS_STATUS="pass"
            HOTSPOTS_SUMMARY="No files in the bug-hotspot diagonal; $SINGLE_AXIS_COUNT single-axis outlier${HOTSPOTS_A_S}"
        else
            HOTSPOTS_STATUS="pass"
            HOTSPOTS_SUMMARY="No files in the hotspot quadrant (cutoffs: churn ≥ $CHURN_Q80, CCN ≥ $CCN_Q80)"
        fi

        write_parsed "git-hotspots" "$HOTSPOTS_STATUS" "$DIAGONAL_COUNT" \
            "$HOTSPOTS_SUMMARY" "$FINDINGS" "$HOTSPOTS_INTENT"
    fi
fi
echo ""

# 20. Change Coupling (git-smells trio)
# section:    change-coupling
# purpose:    Surface file pairs that always change together. The classic
#             Tornhill "logical coupling" signal — files that consistently
#             co-change across many commits are coupled even if they share
#             no import graph edge. Reveals hidden architectural seams
#             (interfaces that should exist) and missed shared abstractions.
# pass_means: No pair exceeds 80% co-change ratio within the noise-filter
#             threshold (≥ 3 shared commits).
# fail_means: Pairs ≥ 80% co-change ratio — likely candidates for a shared
#             interface, an extracted component, or a merged module. Never
#             gates: review is a refactor decision, not a deployment block.
# notes:      Filters out (a) test ↔ implementation pairs (stem match —
#             these SHOULD co-change), (b) known auto-generated coupling
#             (i18n-types.ts, package-lock.json). All other pairs flow
#             through so the human can interpret.
print_section "Change Coupling"
echo "Command: git log (6-month pair co-occurrences) — Tornhill logical-coupling signal"
echo ""

COUPLING_INTENT=$(jq -n '{
    purpose:    "Surface file pairs that always change together. Tornhill logical-coupling: hidden architectural seams.",
    pass_means: "No pair exceeds 80% co-change ratio within the noise-filter threshold (≥ 3 shared commits).",
    fail_means: "Pairs ≥ 80% co-change — likely candidates for a shared interface, extracted component, or merged module."
}')

if [ "$GIT_OK" != true ]; then
    write_skipped "change-coupling" "not a git repository with history (or git absent) — git-forensics needs commits" "$COUPLING_INTENT"
else
    # Per-file change count over the same 6-month window — denominator
    # for the co-change ratio.
    PER_FILE_CHANGES=$(git log --since=6.months.ago --pretty=format: --name-only -- "${SRC_ROOTS[@]}" 2>/dev/null \
        | sed "s#^${GIT_PREFIX}##" \
        | grep -v '^$' \
        | sort | uniq -c \
        | awk '{ count = $1; $1 = ""; sub(/^ +/, ""); printf "%s\t%d\n", $0, count }')

    # Pair counts: for each commit, emit every unordered pair of files
    # (lexicographically ordered for dedup). Filter test↔impl pairs and
    # known auto-coupled files in the same awk pass.
    # Pair generation is O(n²) per commit — a single broad sweep commit
    # (formatting run, directory rename, locale rebrand) can emit tens
    # of thousands of pairs that drown the real coupling signal and
    # stress the downstream sort/uniq + jq -s slurp. The hard cap below
    # skips any commit touching > 50 files: a sweep commit doesn't tell
    # us "these files are architecturally coupled" — it tells us "we
    # did one big refactor," which is noise for the coupling axis.
    # 50 is generous (genuine feature commits rarely exceed ~30 files)
    # while still excluding sweeps.
    PAIR_COUNTS=$(git log --since=6.months.ago --pretty=format:'---COMMIT---' --name-only -- "${SRC_ROOTS[@]}" 2>/dev/null \
        | sed "s#^${GIT_PREFIX}##" \
        | awk 'BEGIN { RS="---COMMIT---\n"; FS="\n" }
               NR > 1 {
                   n = 0
                   for (i = 1; i <= NF; i++) if ($i != "") files[n++] = $i
                   if (n > 50) { delete files; next }
                   for (i = 0; i < n; i++) for (j = i + 1; j < n; j++) {
                       a = files[i]; b = files[j]
                       if (a > b) { t = a; a = b; b = t }
                       print a "\t" b
                   }
                   delete files
               }' \
        | sort | uniq -c | sort -rn \
        | awk -v OFS='\t' '{
            count = $1; $1 = ""; sub(/^[ \t]+/, "", $0)
            split($0, p, "\t"); a = p[1]; b = p[2]

            # Drop known auto-coupled files (generated; commit-time correlations,
            # not architectural smells).
            if (a ~ /(^|\/)i18n-types\.ts$/ || b ~ /(^|\/)i18n-types\.ts$/) next
            if (a ~ /(^|\/)package-lock\.json$/ || b ~ /(^|\/)package-lock\.json$/) next

            # Drop test ↔ implementation pairs by stem match — co-change is
            # expected and not a smell.
            a_stem = a; gsub(/\/__tests__\//, "/", a_stem); gsub(/\.test\.ts$/, ".ts", a_stem); gsub(/\.spec\.ts$/, ".ts", a_stem)
            b_stem = b; gsub(/\/__tests__\//, "/", b_stem); gsub(/\.test\.ts$/, ".ts", b_stem); gsub(/\.spec\.ts$/, ".ts", b_stem)
            if (a_stem == b_stem) next

            # Noise filter: pairs co-occurring < 3 times are statistical noise.
            if (count + 0 < 3) next

            print count, a, b
        }')

    if [ -z "$PAIR_COUNTS" ]; then
        echo -e "${GREEN}✅ No pairs above the noise-filter threshold (≥ 3 shared commits)${NC}"
        write_parsed "change-coupling" "pass" 0 \
            "No file pairs with ≥ 3 shared commits in the last 6 months" "[]" "$COUPLING_INTENT"
    else
        # Build JSONL of {fileA, fileB, pairCount, changesA, changesB} and let
        # jq compute the normalised ratio + tier the pairs.
        COUPLING_JSON=$(awk -F'\t' '
            FILENAME == ARGV[1] { perFile[$1] = $2; next }
            {
                a = $2; b = $3
                ca = (a in perFile) ? perFile[a] : 1
                cb = (b in perFile) ? perFile[b] : 1
                printf "{\"fileA\":\"%s\",\"fileB\":\"%s\",\"pairCount\":%d,\"changesA\":%d,\"changesB\":%d}\n", a, b, $1+0, ca, cb
            }' <(printf "%s\n" "$PER_FILE_CHANGES") <(printf "%s\n" "$PAIR_COUNTS") \
            | jq -s '
                def sevRank: ({"warning":1, "low":2}[.] // 9);

                map(. + {
                    ratio: (.pairCount / ([.changesA, .changesB] | max)),
                    jointMax: ([.changesA, .changesB] | max)
                })
                | map(. + {severity:
                    (if   .ratio >= 0.8 then "warning"
                     elif .ratio >= 0.6 then "low"
                     else null end)})
                | map(select(.severity != null))
                | sort_by([(.severity | sevRank), -.ratio, -.pairCount])
                | {
                    warningCount: (map(select(.severity == "warning")) | length),
                    lowCount:     (map(select(.severity == "low"))     | length),
                    findings: (.[0:20] | map({
                        file: .fileA,
                        line: 1,
                        code: "couples-with",
                        severity,
                        message: (
                            "couples with " + .fileB +
                            " (" + ((.ratio * 100) | floor | tostring) + "% co-change, " +
                            (.pairCount | tostring) + " of " + (.jointMax | tostring) + " changes)"
                        )
                    }))
                }
            ')

        WARN_COUNT=$(echo "$COUPLING_JSON" | jq -r '.warningCount')
        LOW_COUNT=$(echo "$COUPLING_JSON" | jq -r '.lowCount')
        COUPLING_TOP=$(echo "$COUPLING_JSON" | jq -c '.findings')

        COUPLING_W_S=$([ "$WARN_COUNT" = "1" ] || echo "s")
        COUPLING_L_S=$([ "$LOW_COUNT" = "1" ] || echo "s")

        if [ "$WARN_COUNT" = "0" ] && [ "$LOW_COUNT" = "0" ]; then
            echo -e "${GREEN}✅ No pairs above the 60% co-change threshold${NC}"
            COUPLING_STATUS="pass"
            COUPLING_SUMMARY="No pairs above the 60% co-change threshold"
        else
            printf "%-6s %-6s %-6s %s\n" "Tier" "Pct" "Count" "Pair"
            echo "----------------------------------------------------------------------------------------"
            echo "$COUPLING_TOP" | jq -r '
                .[0:10][]
                | [
                    ({"warning":"high","low":"med"}[.severity] // .severity),
                    (.message | capture("(?<n>\\d+)%") | .n + "%"),
                    (.message | capture("(\\d+)% co-change, (?<c>\\d+)") | .c),
                    .file + " ↔ " + (.message | capture("couples with (?<b>[^ ]+)") | .b)
                  ]
                | @tsv
            ' | awk -F'\t' '{ printf "%-6s %-6s %-6s %s\n", $1, $2, $3, $4 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $WARN_COUNT high-coupling pair${COUPLING_W_S} (≥ 80%), $LOW_COUNT medium-coupling pair${COUPLING_L_S} (≥ 60%)"
            echo "   Top 10 by tier then ratio; top 20 in reports/parsed/change-coupling.json"

            if [ "$WARN_COUNT" -gt 0 ]; then
                COUPLING_STATUS="warn"
                COUPLING_SUMMARY="$WARN_COUNT pair${COUPLING_W_S} at ≥ 80% co-change ratio (top 20 reported)"
            else
                COUPLING_STATUS="pass"
                COUPLING_SUMMARY="No ≥ 80% pairs; $LOW_COUNT pair${COUPLING_L_S} at ≥ 60% co-change"
            fi
        fi

        write_parsed "change-coupling" "$COUPLING_STATUS" "$WARN_COUNT" \
            "$COUPLING_SUMMARY" "$COUPLING_TOP" "$COUPLING_INTENT"
    fi
fi
echo ""

# 21. Bug-fix Density (git-smells trio)
# section:    bug-fix-density
# purpose:    Per-file ratio of bug-fix commits to total commits over the
#             last 6 months. Tornhill's strongest single bug-density
#             predictor — empirically beats complexity alone. Files
#             where ≥ 50% of touches are fixes are bug-prone code.
# pass_means: No files with ≥ 50% fix-touch ratio at the noise-filter
#             threshold (≥ 3 fix touches).
# fail_means: Files at ≥ 50% fix-touch ratio — fix-heavy code patterns
#             worth investigating: missing tests, fragile contracts,
#             unstable third-party integration. Informational; never
#             gates.
# notes:      "fix" identified by conventional-commit prefix (`fix(...)`
#             or `fix:`) and explicit `^Revert ` commits. Auto-generated
#             files filtered (i18n-types.ts).
print_section "Bug-fix Density"
echo "Command: git log --grep='^fix' --grep='^Revert ' (6-month window)"
echo ""

BUGFIX_INTENT=$(jq -n '{
    purpose:    "Per-file fix-touch ratio over the last 6 months. Tornhill: strongest single bug-density predictor.",
    pass_means: "No files at ≥ 50% fix-touch ratio with ≥ 3 fix touches (noise filter).",
    fail_means: "Files ≥ 50% fix-touch ratio — fragile contracts, missing tests, or unstable integration. Refactor/test target."
}')

if [ "$GIT_OK" != true ]; then
    write_skipped "bug-fix-density" "not a git repository with history (or git absent) — git-forensics needs commits" "$BUGFIX_INTENT"
else
    # Fix touches: commits matching the conventional-commit fix prefix
    # OR an explicit revert. --grep treats each pattern as OR'd.
    FIX_TOUCHES_TSV=$(git log --since=6.months.ago --pretty=format: --name-only \
        --grep='^fix' --grep='^Revert ' \
        -- "${SRC_ROOTS[@]}" 2>/dev/null \
        | sed "s#^${GIT_PREFIX}##" \
        | grep -v '^$' \
        | sort | uniq -c \
        | awk '{ count = $1; $1 = ""; sub(/^ +/, ""); printf "%s\t%d\n", $0, count }')

    # Total churn over the same window — denominator.
    TOTAL_CHURN_TSV=$(git log --since=6.months.ago --pretty=format: --name-only -- "${SRC_ROOTS[@]}" 2>/dev/null \
        | sed "s#^${GIT_PREFIX}##" \
        | grep -v '^$' \
        | sort | uniq -c \
        | awk '{ count = $1; $1 = ""; sub(/^ +/, ""); printf "%s\t%d\n", $0, count }')

    if [ -z "$FIX_TOUCHES_TSV" ]; then
        echo -e "${GREEN}✅ No bug-fix commits in the last 6 months${NC}"
        write_parsed "bug-fix-density" "pass" 0 \
            "No bug-fix or revert commits in the last 6 months" "[]" "$BUGFIX_INTENT"
    else
        BUGFIX_JSON=$(awk -F'\t' '
            FILENAME == ARGV[1] { totalChurn[$1] = $2; next }
            {
                # Drop auto-generated files
                if ($1 ~ /(^|\/)i18n-types\.ts$/) next
                t = ($1 in totalChurn) ? totalChurn[$1] : $2
                printf "{\"file\":\"%s\",\"fixCount\":%d,\"totalCount\":%d}\n", $1, $2, t
            }' <(printf "%s\n" "$TOTAL_CHURN_TSV") <(printf "%s\n" "$FIX_TOUCHES_TSV") \
            | jq -s '
                def sevRank: ({"warning":1, "low":2}[.] // 9);

                # Noise filter: <3 fix-touches is statistical noise.
                map(select(.fixCount >= 3))
                | map(. + {ratio: (.fixCount / .totalCount)})
                | map(. + {severity:
                    (if   .ratio >= 0.5 then "warning"
                     elif .ratio >= 0.3 then "low"
                     else null end)})
                | map(select(.severity != null))
                | sort_by([(.severity | sevRank), -.ratio, -.fixCount])
                | {
                    warningCount: (map(select(.severity == "warning")) | length),
                    lowCount:     (map(select(.severity == "low"))     | length),
                    findings: (.[0:20] | map({
                        file: .file,
                        line: 1,
                        code: "fix-density",
                        severity,
                        message: (
                            (.fixCount | tostring) + " fix-touches of " +
                            (.totalCount | tostring) + " (" +
                            ((.ratio * 100) | floor | tostring) + "%)"
                        )
                    }))
                }
            ')

        BUGFIX_WARN_COUNT=$(echo "$BUGFIX_JSON" | jq -r '.warningCount')
        BUGFIX_LOW_COUNT=$(echo "$BUGFIX_JSON" | jq -r '.lowCount')
        BUGFIX_TOP=$(echo "$BUGFIX_JSON" | jq -c '.findings')

        BUGFIX_W_S=$([ "$BUGFIX_WARN_COUNT" = "1" ] || echo "s")
        BUGFIX_L_S=$([ "$BUGFIX_LOW_COUNT" = "1" ] || echo "s")

        if [ "$BUGFIX_WARN_COUNT" = "0" ] && [ "$BUGFIX_LOW_COUNT" = "0" ]; then
            echo -e "${GREEN}✅ No files at ≥ 30% fix-touch ratio (≥ 3 fixes)${NC}"
            BUGFIX_STATUS="pass"
            BUGFIX_SUMMARY="No files at ≥ 30% fix-touch ratio with ≥ 3 fix touches"
        else
            printf "%-6s %-7s %-7s %s\n" "Tier" "Fixes" "Ratio" "File"
            echo "----------------------------------------------------------------------------------------"
            echo "$BUGFIX_TOP" | jq -r '
                .[0:10][]
                | [
                    ({"warning":"high","low":"med"}[.severity] // .severity),
                    (.message | capture("(?<f>\\d+) fix") | .f),
                    (.message | capture("\\((?<p>\\d+)%\\)") | .p + "%"),
                    .file
                  ]
                | @tsv
            ' | awk -F'\t' '{ printf "%-6s %-7s %-7s %s\n", $1, $2, $3, $4 }'
            echo ""
            echo -e "${BLUE}📈 Summary:${NC} $BUGFIX_WARN_COUNT high fix-density file${BUGFIX_W_S} (≥ 50%), $BUGFIX_LOW_COUNT medium (≥ 30%)"
            echo "   Top 10 by tier then ratio; top 20 in reports/parsed/bug-fix-density.json"

            if [ "$BUGFIX_WARN_COUNT" -gt 0 ]; then
                BUGFIX_STATUS="warn"
                BUGFIX_SUMMARY="$BUGFIX_WARN_COUNT file${BUGFIX_W_S} at ≥ 50% fix-touch ratio (top 20 reported)"
            else
                BUGFIX_STATUS="pass"
                BUGFIX_SUMMARY="No ≥ 50% files; $BUGFIX_LOW_COUNT file${BUGFIX_L_S} at ≥ 30% fix-touch ratio"
            fi
        fi

        write_parsed "bug-fix-density" "$BUGFIX_STATUS" "$BUGFIX_WARN_COUNT" \
            "$BUGFIX_SUMMARY" "$BUGFIX_TOP" "$BUGFIX_INTENT"
    fi
fi
echo ""

# 22. Branch Hygiene (git-smells trio)
# section:    branch-hygiene
# purpose:    Local + remote branches with no committer activity in 30+
#             days. Long-lived branches are integration debt; abandoned
#             local clutter accumulates over time. Cheap cleanup nudge.
# pass_means: No branches idle ≥ 90 days (excluding main, current, HEAD,
#             dependabot/*, claude/*). Branches 30-89 days are reported
#             as low-tier opportunistic cleanup but do NOT gate the
#             section — status stays `pass` while they exist.
# fail_means: Branches idle ≥ 90 days — likely abandoned or forgotten.
#             Informational; never gates the build. Does NOT delete
#             anything — the check only surfaces.
# notes:      Branches aren't files, so findings carry the branch name in
#             `message` and leave `top[].file` empty — the by-file aggregate
#             (which counts only real paths) excludes them, keeping the spatial
#             hotspot ranking about source files alone.
print_section "Branch Hygiene"
echo "Command: git for-each-ref refs/heads/ refs/remotes/origin/"
echo ""

BRANCH_INTENT=$(jq -n '{
    purpose:    "Surface branches with no committer activity in 30+ days. Long-lived branches accumulate integration debt.",
    pass_means: "No branches idle ≥ 90 days outside the dependabot/* and claude/* exclusions. 30-89d entries surface but do not gate.",
    fail_means: "Branches idle ≥ 90 days — review for delete or revival. Lower-tier (30-89 days) is opportunistic cleanup."
}')

if [ "$GIT_OK" != true ]; then
    write_skipped "branch-hygiene" "not a git repository with history (or git absent) — git-forensics needs commits" "$BRANCH_INTENT"
else
    CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
    NOW_TS=$(date +%s)

    # Exclusions:
    #   main / origin/main / HEAD / origin/HEAD — load-bearing or alias
    #   <current-branch>                        — actively in use
    #   dependabot/* / origin/dependabot/*      — managed by Dependabot
    #   claude/* / origin/claude/*              — agent worktrees, ephemeral
    BRANCH_AGES=$(git for-each-ref \
        --format='%(refname:short)|%(committerdate:unix)|%(committerdate:short)' \
        refs/heads/ refs/remotes/origin/ 2>/dev/null \
        | awk -F'|' -v now="$NOW_TS" -v cur="$CURRENT_BRANCH" '
            $1 == "main" || $1 == "origin/main" || $1 == "HEAD" || $1 == "origin/HEAD" { next }
            $1 == cur || $1 == "origin/" cur { next }
            $1 ~ /^(origin\/)?dependabot\// { next }
            $1 ~ /^(origin\/)?claude\// { next }
            {
                age_days = int((now - $2) / 86400)
                if (age_days < 30) next
                print age_days "|" $1 "|" $3
            }
        ' | sort -t'|' -k1,1nr)

    if [ -z "$BRANCH_AGES" ]; then
        echo -e "${GREEN}✅ No branches idle > 30 days (excluding main, current, dependabot, claude)${NC}"
        write_parsed "branch-hygiene" "pass" 0 \
            "No branches idle > 30 days" "[]" "$BRANCH_INTENT"
    else
        BRANCH_JSON=$(echo "$BRANCH_AGES" | jq -R -s '
            def sevRank: ({"warning":1, "low":2}[.] // 9);

            split("\n")
            | map(select(length > 0))
            | map(split("|") | {age:(.[0]|tonumber), branch:.[1], date:.[2]})
            | map(. + {severity:
                (if .age >= 90 then "warning" else "low" end)})
            | sort_by([(.severity | sevRank), -.age])
            | {
                warningCount: (map(select(.severity == "warning")) | length),
                lowCount:     (map(select(.severity == "low"))     | length),
                findings: (.[0:20] | map({
                    file: "",
                    line: 1,
                    code: "stale-branch",
                    severity,
                    message: (.branch + " — idle " + (.age | tostring) + " days (last commit " + .date + ")")
                }))
            }
        ')

        BRANCH_WARN_COUNT=$(echo "$BRANCH_JSON" | jq -r '.warningCount')
        BRANCH_LOW_COUNT=$(echo "$BRANCH_JSON" | jq -r '.lowCount')
        BRANCH_TOP=$(echo "$BRANCH_JSON" | jq -c '.findings')

        BRANCH_W_S=$([ "$BRANCH_WARN_COUNT" = "1" ] || echo "es")
        BRANCH_L_S=$([ "$BRANCH_LOW_COUNT" = "1" ] || echo "es")

        printf "%-6s %-7s %s\n" "Tier" "Age" "Branch"
        echo "----------------------------------------------------------------------------------------"
        echo "$BRANCH_TOP" | jq -r '
            .[0:10][]
            | [
                ({"warning":">90d","low":"30-89d"}[.severity] // .severity),
                (.message | capture("idle (?<d>\\d+)") | .d + "d"),
                (.message | split(" — ")[0])
              ]
            | @tsv
        ' | awk -F'\t' '{ printf "%-6s %-7s %s\n", $1, $2, $3 }'
        echo ""
        echo -e "${BLUE}📈 Summary:${NC} $BRANCH_WARN_COUNT branch${BRANCH_W_S} idle ≥ 90 days, $BRANCH_LOW_COUNT 30-89 days"
        echo "   Excludes main, current branch, dependabot/*, claude/*"

        if [ "$BRANCH_WARN_COUNT" -gt 0 ]; then
            BRANCH_STATUS="warn"
            BRANCH_SUMMARY="$BRANCH_WARN_COUNT branch${BRANCH_W_S} idle ≥ 90 days (top 20 reported)"
        else
            BRANCH_STATUS="pass"
            BRANCH_SUMMARY="No branches idle ≥ 90 days; $BRANCH_LOW_COUNT branch${BRANCH_L_S} idle 30-89 days"
        fi

        write_parsed "branch-hygiene" "$BRANCH_STATUS" "$BRANCH_WARN_COUNT" \
            "$BRANCH_SUMMARY" "$BRANCH_TOP" "$BRANCH_INTENT"
    fi
fi
echo ""

# Overall Health Score
print_section "Overall Health Score"

# Guard against division by zero — happens if every scored section skipped
# (e.g. clean checkout before npm install on a stripped-down dev box).
if [ "$MAX_SCORE" -le 0 ]; then
    PERCENTAGE=0
else
    PERCENTAGE=$((HEALTH_SCORE * 100 / MAX_SCORE))
fi

echo "📊 Score: $HEALTH_SCORE/$MAX_SCORE ($PERCENTAGE%)"
echo ""

# Save summary for health report generation
mkdir -p "$OUT_DIR"
cat > "$OUT_DIR/checkup-summary.json" << SUMMARY
{
  "timestamp": "$(date -u +"%Y-%m-%d %H:%M:%S UTC")",
  "score": $HEALTH_SCORE,
  "maxScore": $MAX_SCORE,
  "percentage": $PERCENTAGE
}
SUMMARY

if [ "$PERCENTAGE" -ge 95 ]; then
    echo -e "${GREEN}🏆 EXCELLENT${NC}"
    echo "All systems ready for deployment!"
    STATUS="EXCELLENT"
    EXIT_CODE=0
elif [ "$PERCENTAGE" -ge 80 ]; then
    echo -e "${GREEN}✅ GOOD${NC}"
    echo "Minor issues detected. Consider fixing before deployment."
    STATUS="GOOD"
    EXIT_CODE=0
elif [ "$PERCENTAGE" -ge 60 ]; then
    echo -e "${YELLOW}⚠️  NEEDS ATTENTION${NC}"
    echo "Address issues above before deploying to production."
    STATUS="NEEDS_ATTENTION"
    EXIT_CODE=1
else
    echo -e "${RED}❌ CRITICAL ISSUES${NC}"
    echo "Do NOT deploy - fix critical issues first."
    STATUS="CRITICAL"
    EXIT_CODE=1
fi

# Generate committable report. An overlay (e.g. checkup-dotnet) that appends its
# own parsed/<slug>.json after this run sets CHECKUP_SKIP_REPORT=1 so the report
# is rendered once, downstream, with every check included.
if [ -n "${CHECKUP_SKIP_REPORT:-}" ]; then
    echo ""
    echo "📄 Report deferred (CHECKUP_SKIP_REPORT set) — overlay will render."
    exit "$EXIT_CODE"
fi
echo ""
echo "📄 Generating report..."
if "$SCRIPT_DIR/checkup-report.sh" > /dev/null 2>&1; then
    if [ -n "${CHECKUP_OUT_DIR:-}" ]; then
        echo "✅ Report saved to $OUT_DIR/checkup-report.md"
    else
        echo "✅ Report saved to docs/reports/checkup-report.md"
    fi
else
    echo "⚠️  Could not generate report"
fi

exit $EXIT_CODE
