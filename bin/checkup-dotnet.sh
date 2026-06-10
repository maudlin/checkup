#!/bin/bash
# checkup-dotnet — .NET / legacy-ASP overlay orchestrator.
#
# Runs the full checkup-core pass (cross-stack security / hygiene / forensics),
# then appends .NET- and Classic-ASP-specific checks to the SAME parsed/ stream
# so the tool-agnostic renderer aggregates them automatically:
#
#   - asp-classic  : semgrep generic-mode ruleset for Classic ASP / VBScript
#                    (SQLi / XSS / dynamic-exec / path-traversal / hardcoded creds)
#   - devskim      : Microsoft DevSkim source SAST — no build required, so it
#                    works on .NET Framework source semgrep can't parse fully
#   - dotnet-vuln  : `dotnet list package --vulnerable` (the npm-audit analogue);
#                    skips honestly on legacy packages.config / unrestorable trees
#
# Build/test/format for modern .NET are intentionally left to a command profile
# (ROADMAP Phase 2) — they need a restorable, SDK-style project and add nothing
# on a legacy Framework app that won't build on Linux.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CHECKUP_HOME="$(cd "$SCRIPT_DIR/.." && pwd)"

TARGET="${CHECKUP_TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
OUT_DIR="${CHECKUP_OUT_DIR:-reports}"
mkdir -p "$OUT_DIR"
export RAW_DIR="$OUT_DIR/raw"
export PARSED_DIR="$OUT_DIR/parsed"

# shellcheck source=../lib/run-tool.sh
source "$CHECKUP_HOME/lib/run-tool.sh"

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo "🩺 Application Checkup — .NET / legacy-ASP overlay"
echo "================================================="
echo ""

# ---- 1. core cross-stack pass (defer its render; we render once at the end) ----
echo -e "${BLUE}▶ Running checkup-core checks…${NC}"
CHECKUP_SKIP_REPORT=1 "$SCRIPT_DIR/checkup.sh" || true
echo ""

cd "$TARGET"

print_overlay_section() {
    echo ""
    echo -e "${BLUE}📊 $1${NC}"
    echo "----------------------------------------"
}

# ---- 2a. Classic ASP / VBScript security (semgrep generic ruleset) ----
print_overlay_section "Classic ASP / VBScript Security"
ASP_INTENT=$(jq -n '{
    purpose:    "Regex (generic-mode) semgrep ruleset for Classic ASP / VBScript, which has no AST parser — covers the dominant legacy vuln classes: SQL injection by string concatenation, reflected XSS, dynamic code/object execution of Request input, path traversal, hardcoded credentials.",
    pass_means: "No matches in .asp/.asa/.inc/.aspx scriptlets.",
    fail_means: "Any ERROR-severity match (SQLi / XSS / dynamic-exec) is likely a real, exploitable issue. Triage aid: generic mode cannot see VBScript comments, so commented-out code may flag."
}')
ASP_RULES="$CHECKUP_HOME/examples/semgrep-asp-classic.yml"
if ! command -v semgrep > /dev/null 2>&1; then
    echo -e "${YELLOW}⏭️  semgrep not installed${NC}"
    write_skipped "asp-classic" "semgrep not on PATH" "$ASP_INTENT"
elif [ ! -f "$ASP_RULES" ]; then
    echo -e "${YELLOW}⏭️  ruleset not found${NC}"
    write_skipped "asp-classic" "ruleset not found: $ASP_RULES" "$ASP_INTENT"
else
    run_tool "Classic ASP Security" semgrep scan --config "$ASP_RULES" --json --quiet .
    if ! is_valid_json "$LAST_RAW"; then
        echo -e "${YELLOW}⚠️  semgrep produced no parseable JSON (exit $LAST_EXIT)${NC}"
        write_failed "asp-classic" "semgrep produced no parseable JSON (exit $LAST_EXIT)" "$ASP_INTENT"
    else
        ASP_TOTAL=$(jq '.results | length' "$LAST_RAW")
        ASP_ERRORS=$(jq '[.results[] | select(.extra.severity == "ERROR")] | length' "$LAST_RAW")
        ASP_TOP=$(jq -c '
            [.results[] | {
                file: .path,
                line: .start.line,
                code: (.check_id | sub(".*\\."; "")),
                severity: (.extra.severity | ascii_downcase),
                message: .extra.message
            }]
            | sort_by({"error":0,"warning":1,"info":2}[.severity] // 3)
            | .[0:10]
        ' "$LAST_RAW")
        if [ "$ASP_ERRORS" -gt 0 ]; then
            ASP_STATUS="fail"
        elif [ "$ASP_TOTAL" -gt 0 ]; then
            ASP_STATUS="warn"
        else
            ASP_STATUS="pass"
        fi
        echo -e "${GREEN}Found $ASP_TOTAL match(es): $ASP_ERRORS high-risk${NC}"
        write_parsed "asp-classic" "$ASP_STATUS" "$ASP_TOTAL" \
            "$ASP_ERRORS high-risk, $((ASP_TOTAL - ASP_ERRORS)) advisory (Classic ASP/VBScript)" \
            "$ASP_TOP" "$ASP_INTENT"
    fi
fi
echo ""

# ---- 2b. DevSkim source SAST (no build; covers .NET Framework source) ----
print_overlay_section "DevSkim Source Analysis (.NET / multi-language)"
DEVSKIM_INTENT=$(jq -n '{
    purpose:    "Microsoft DevSkim source-level SAST. No build required, so it covers .NET Framework / Classic ASP source that build-time Roslyn analysers cannot reach on Linux. Flags risky APIs, weak crypto, hardcoded secrets, injection-prone sinks across C#, VB, JS, SQL and more.",
    pass_means: "No findings.",
    fail_means: "Any error-level finding is a flagged risky construct — review in context. Lower-severity findings are advisory."
}')
if ! command -v devskim > /dev/null 2>&1; then
    echo -e "${YELLOW}⏭️  devskim not installed${NC}"
    write_skipped "devskim" "devskim not on PATH (dotnet tool install -g Microsoft.CST.DevSkim.CLI)" "$DEVSKIM_INTENT"
else
    DEVSKIM_SARIF="$OUT_DIR/devskim.sarif"
    rm -f "$DEVSKIM_SARIF"
    # DevSkim writes to a file, not stdout — run_tool still gives us $LAST_EXIT
    # and a presence check on the tool.
    run_tool "DevSkim" devskim analyze --source-code . --output-file "$DEVSKIM_SARIF" --file-format sarif
    if [ ! -f "$DEVSKIM_SARIF" ] || ! is_valid_json "$DEVSKIM_SARIF"; then
        echo -e "${YELLOW}⚠️  DevSkim produced no parseable SARIF (exit $LAST_EXIT)${NC}"
        write_failed "devskim" "devskim produced no parseable SARIF (exit $LAST_EXIT)" "$DEVSKIM_INTENT"
    else
        DS_TOTAL=$(jq '[.runs[].results[]?] | length' "$DEVSKIM_SARIF")
        DS_ERRORS=$(jq '[.runs[].results[]? | select(.level == "error")] | length' "$DEVSKIM_SARIF")
        DS_TOP=$(jq -c '
            [.runs[].results[]? | {
                file: (.locations[0].physicalLocation.artifactLocation.uri | sub("^file://"; "")),
                line: (.locations[0].physicalLocation.region.startLine // 1),
                code: .ruleId,
                severity: (.level | if . == "error" then "error" elif . == "warning" then "warning" else "info" end),
                message: .message.text
            }]
            | sort_by({"error":0,"warning":1,"info":2}[.severity] // 3)
            | .[0:10]
        ' "$DEVSKIM_SARIF")
        if [ "$DS_ERRORS" -gt 0 ]; then
            DS_STATUS="fail"
        elif [ "$DS_TOTAL" -gt 0 ]; then
            DS_STATUS="warn"
        else
            DS_STATUS="pass"
        fi
        echo -e "${GREEN}Found $DS_TOTAL finding(s): $DS_ERRORS error-level${NC}"
        write_parsed "devskim" "$DS_STATUS" "$DS_TOTAL" \
            "$DS_ERRORS error, $((DS_TOTAL - DS_ERRORS)) lower-severity findings" \
            "$DS_TOP" "$DEVSKIM_INTENT"
    fi
fi
echo ""

# ---- 2c. NuGet vulnerability audit (the npm-audit analogue) ----
print_overlay_section "NuGet Vulnerability Audit"
DOTNET_INTENT=$(jq -n '{
    purpose:    "Scan NuGet dependencies for known advisories via `dotnet list package --vulnerable`. The .NET analogue of npm audit.",
    pass_means: "No known vulnerable packages.",
    fail_means: "Any High/Critical advisory — upgrade or pin. Note: requires an SDK-style, restorable project; legacy packages.config / .NET Framework trees skip (cannot be queried without migration/restore)."
}')
if ! command -v dotnet > /dev/null 2>&1; then
    echo -e "${YELLOW}⏭️  dotnet SDK not installed${NC}"
    write_skipped "dotnet-vuln" "dotnet SDK not on PATH" "$DOTNET_INTENT"
else
    DN_PROJ=$(find . -maxdepth 4 -iname '*.sln' 2>/dev/null | head -1)
    [ -z "$DN_PROJ" ] && DN_PROJ=$(find . -maxdepth 4 -iname '*.csproj' 2>/dev/null | head -1)
    if [ -z "$DN_PROJ" ]; then
        echo -e "${YELLOW}⏭️  no .sln/.csproj found${NC}"
        write_skipped "dotnet-vuln" "no .sln/.csproj found under target" "$DOTNET_INTENT"
    else
        run_tool "NuGet Vulnerability Audit" dotnet list "$DN_PROJ" package --vulnerable --include-transitive
        if [ "$LAST_EXIT" != "0" ] || ! grep -qiE 'vulnerable|no vulnerable' "$LAST_RAW" 2>/dev/null; then
            echo -e "${YELLOW}⏭️  could not query packages (legacy/unrestorable project)${NC}"
            write_skipped "dotnet-vuln" \
                "dotnet could not restore/query packages (exit $LAST_EXIT) — legacy packages.config / .NET Framework project needs migration to PackageReference or a restore step" \
                "$DOTNET_INTENT"
        else
            # Vulnerable packages are the lines beginning with `>`.
            DN_TOP=$(awk '/^[[:space:]]*>/ {
                sev = $(NF-1); pkg = $2; resolved = $4; url = $NF;
                sl = tolower(sev);
                mapped = (sl=="critical"||sl=="high") ? sl : (sl=="moderate" ? "medium" : "low");
                printf "%s\t%s\t%s\t%s\n", pkg, resolved, mapped, url
            }' "$LAST_RAW" | jq -R -s '
                split("\n") | map(select(length > 0)) | map(
                    split("\t") as $r
                    | {file: "packages", line: 1, code: $r[0], severity: $r[2],
                       message: ($r[0] + " " + $r[1] + " — " + $r[2] + " (" + $r[3] + ")")}
                ) | .[0:10]')
            DN_TOTAL=$(echo "$DN_TOP" | jq 'length')
            DN_CRIT=$(echo "$DN_TOP" | jq '[.[] | select(.severity=="critical" or .severity=="high")] | length')
            if [ "$DN_CRIT" -gt 0 ]; then
                DN_STATUS="fail"
            elif [ "$DN_TOTAL" -gt 0 ]; then
                DN_STATUS="warn"
            else
                DN_STATUS="pass"
            fi
            echo -e "${GREEN}$DN_TOTAL vulnerable package(s), $DN_CRIT high/critical${NC}"
            write_parsed "dotnet-vuln" "$DN_STATUS" "$DN_TOTAL" \
                "$DN_TOTAL vulnerable NuGet package(s), $DN_CRIT high/critical" \
                "$DN_TOP" "$DOTNET_INTENT"
        fi
    fi
fi
echo ""

# ---- 2d. Code duplication (PMD CPD — language-aware, no build) ----
print_overlay_section "Code Duplication (PMD CPD)"
CPD_INTENT=$(jq -n '{
    purpose:    "Copy-paste detection via PMD CPD — language-aware tokenisation (C# and many others), no build required. Replaces the Node-only jscpd duplication check on non-Node stacks. High duplication signals missed abstraction and multiplies maintenance cost.",
    pass_means: "No clone blocks at/above the token threshold in the tokenised languages.",
    fail_means: "Clone blocks found — refactor toward shared helpers. Reported as warn. NOTE: Classic ASP/VBScript has no CPD tokeniser, so .asp duplication is NOT measured here."
}')
if ! command -v pmd > /dev/null 2>&1; then
    echo -e "${YELLOW}⏭️  PMD CPD not installed${NC}"
    write_skipped "duplication" "PMD CPD not on PATH" "$CPD_INTENT"
else
    # Languages CPD can tokenise that are present. C# is the overlay's focus;
    # add ecmascript when .js exists. (Classic ASP has no CPD tokeniser.)
    CPD_LANGS="cs"
    [ -n "$(find . -name '*.js' -not -path '*/node_modules/*' -print -quit 2>/dev/null)" ] && CPD_LANGS="$CPD_LANGS ecmascript"
    DUP_ALL='[]'
    CPD_ERR=0
    for lang in $CPD_LANGS; do
        run_tool "Code Duplication ($lang)" pmd cpd \
            --minimum-tokens 100 --dir . --language "$lang" \
            --format xml --no-fail-on-violation
        # CPD's XML report starts with a '<' tag. Empty / non-XML output means
        # the invocation failed (bad flag, no tokeniser) — must NOT be read as
        # "zero clones → pass". Flag it so the section fails honestly.
        if ! head -c 64 "$LAST_RAW" 2>/dev/null | grep -q '<'; then
            CPD_ERR=1
            echo -e "${YELLOW}  $lang: CPD produced no XML (exit $LAST_EXIT)${NC}"
            continue
        fi
        FINDINGS=$(python3 - "$LAST_RAW" "$lang" <<'PY'
import sys, json
import xml.etree.ElementTree as ET
path, lang = sys.argv[1], sys.argv[2]
try:
    root = ET.parse(path).getroot()
except Exception:
    print('[]'); sys.exit(0)
out = []
# CPD's report uses a default XML namespace, so match element names with a
# namespace wildcard ({*}) — a plain 'duplication' tag name finds nothing.
for dup in root.findall('{*}duplication'):
    n = int(dup.get('lines') or 0); toks = dup.get('tokens')
    files = dup.findall('{*}file')
    if not files:
        continue
    f0 = files[0]
    others = ", ".join(f"{f.get('path')}:{f.get('line')}" for f in files[1:]) or "elsewhere"
    out.append({
        "file": f0.get('path'),
        "line": int(f0.get('line') or 1),
        "code": f"clone-{lang}",
        "severity": "high" if n >= 100 else "warning",
        "message": f"{n}-line clone ({toks} tokens) also at {others}",
    })
print(json.dumps(out))
PY
)
        echo "$FINDINGS" | jq -e 'type=="array"' > /dev/null 2>&1 || FINDINGS='[]'
        echo -e "${GREEN}  $lang: $(echo "$FINDINGS" | jq 'length') clone block(s)${NC}"
        DUP_ALL=$(jq -s 'add' <(echo "$DUP_ALL") <(echo "$FINDINGS"))
    done
    DUP_TOTAL=$(echo "$DUP_ALL" | jq 'length')
    DUP_TOP=$(echo "$DUP_ALL" | jq 'sort_by(- (.message | capture("(?<n>[0-9]+)-line") | .n | tonumber)) | .[0:10]')
    if [ "$DUP_TOTAL" -eq 0 ] && [ "$CPD_ERR" = 1 ]; then
        echo -e "${YELLOW}⚠️  CPD produced no parseable output${NC}"
        write_failed "duplication" "PMD CPD produced no parseable output (exit $LAST_EXIT) — invocation error, not a clean result" "$CPD_INTENT"
    elif [ "$DUP_TOTAL" -eq 0 ]; then
        echo -e "${GREEN}No clone blocks ≥100 tokens${NC}"
        write_parsed "duplication" "pass" 0 "No clone blocks ≥100 tokens (CPD: $CPD_LANGS)" '[]' "$CPD_INTENT"
    else
        echo -e "${GREEN}$DUP_TOTAL clone block(s)${NC}"
        write_parsed "duplication" "warn" "$DUP_TOTAL" \
            "$DUP_TOTAL clone block(s) ≥100 tokens (CPD: $CPD_LANGS; Classic ASP not tokenised)" \
            "$DUP_TOP" "$CPD_INTENT"
    fi
fi
echo ""

# ---- 3. render once, with core + overlay findings ----
echo -e "${BLUE}📄 Generating report…${NC}"
if "$SCRIPT_DIR/checkup-report.sh" > /dev/null 2>&1; then
    echo -e "${GREEN}✅ Report saved${NC}"
else
    echo -e "${YELLOW}⚠️  Could not generate report${NC}"
fi
