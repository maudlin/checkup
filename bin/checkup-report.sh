#!/bin/bash
# Generate a tool-agnostic report from reports/parsed/*.json.
#
# This script reads every parsed JSON the orchestrator wrote during the run,
# then produces both:
#   - docs/reports/checkup-report.md          (committed, always = "latest")
#   - reports/checkup-report-<utc-ts>.md      (gitignored, for trend history)
#
# Adding a new check requires NO changes to this file — drop a new parser
# in checkup.sh that calls write_parsed and the report picks it up automatically.
# See README.md for the contract.

set -e

# Resolve the project being reported on, independently of where checkup is
# installed. Same resolution as checkup.sh: CHECKUP_TARGET, else the enclosing git
# repo top level, else the current directory.
REPO_ROOT="${CHECKUP_TARGET:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}"
cd "$REPO_ROOT"

# Where checkup.sh wrote its intermediates (must match). Defaults to the
# scanned project's reports/; CHECKUP_OUT_DIR redirects everything outside the
# source tree (read-only / container scans). In out-dir mode the canonical
# "latest" report lands in the out dir too; otherwise it keeps the committed
# docs/reports/checkup-report.md convention.
OUT_DIR="${CHECKUP_OUT_DIR:-reports}"
PARSED_DIR="$OUT_DIR/parsed"
if [ -n "${CHECKUP_OUT_DIR:-}" ]; then
    REPORT_FILE="$OUT_DIR/checkup-report.md"
else
    REPORT_FILE="docs/reports/checkup-report.md"
fi
TIMESTAMP=$(date -u +"%Y-%m-%d %H:%M:%S UTC")
TS_FILENAME=$(date -u +"%Y%m%dT%H%M%SZ")
HISTORY_FILE="$OUT_DIR/checkup-report-${TS_FILENAME}.md"

# Normalised path roots — strip trailing slash so the renderer's startswith
# comparisons are well-defined regardless of how $HOME was set.
REPO_ROOT_TRIM="${REPO_ROOT%/}/"
HOME_TRIM="${HOME%/}/"

echo "Generating report..."

# Collect parsed JSONs via a glob that nullglobs to an empty array if the
# directory exists but contains no .json files — otherwise the literal
# `*.json` propagates to jq and aborts the renderer.
shopt -s nullglob
PARSED_FILES=("$PARSED_DIR"/*.json)
shopt -u nullglob

if [ ! -d "$PARSED_DIR" ] || [ "${#PARSED_FILES[@]}" -eq 0 ]; then
    echo "⚠️  No parsed reports found in $PARSED_DIR — run checkup.sh first" >&2
    exit 1
fi

# Read the trend score (still produced by checkup.sh end-of-run).
if [ -f "$OUT_DIR/checkup-summary.json" ]; then
    HEALTH_SCORE=$(jq -r '.score // "N/A"' "$OUT_DIR/checkup-summary.json")
    MAX_SCORE=$(jq -r '.maxScore // 0' "$OUT_DIR/checkup-summary.json")
    HEALTH_PERCENTAGE=$(jq -r '.percentage // "N/A"' "$OUT_DIR/checkup-summary.json")
else
    HEALTH_SCORE="N/A"
    MAX_SCORE=0
    HEALTH_PERCENTAGE="N/A"
fi

# Headline status derived from the percentage.
if [ "$HEALTH_PERCENTAGE" != "N/A" ] && [ "$HEALTH_PERCENTAGE" -ge 95 ]; then
    HEALTH_STATUS="🏆 EXCELLENT"
elif [ "$HEALTH_PERCENTAGE" != "N/A" ] && [ "$HEALTH_PERCENTAGE" -ge 80 ]; then
    HEALTH_STATUS="✅ GOOD"
elif [ "$HEALTH_PERCENTAGE" != "N/A" ] && [ "$HEALTH_PERCENTAGE" -ge 60 ]; then
    HEALTH_STATUS="⚠️  NEEDS ATTENTION"
elif [ "$HEALTH_PERCENTAGE" != "N/A" ]; then
    HEALTH_STATUS="❌ CRITICAL"
else
    HEALTH_STATUS="❓ UNKNOWN"
fi

# Status counts across all parsed checks.
PASS=$(jq -s 'map(select(.status=="pass")) | length' "${PARSED_FILES[@]}")
WARN=$(jq -s 'map(select(.status=="warn")) | length' "${PARSED_FILES[@]}")
FAIL=$(jq -s 'map(select(.status=="fail")) | length' "${PARSED_FILES[@]}")
SKIP=$(jq -s 'map(select(.status=="skip")) | length' "${PARSED_FILES[@]}")

# Top Problems aggregate — flat list across all tools, severity-weighted,
# max 3 per tool to prevent a wide check (e.g. lint with 472 warnings) from
# dominating, total cap 30 so the list is scannable.
#
# Severity weights:
#   critical/error/high → 0   (must-fix)
#   warning/medium      → 1   (should-fix)
#   low/style           → 2   (nice-to-fix)
#   info/other          → 3   (informational)
#
# Note: unknown severity strings default to weight 3, which sorts them to
# the bottom alongside `info`. All current checks map through explicit
# lookup tables and never emit free-form severities, so this is just a
# defensive default. If a new check is added, prefer values from the
# documented vocabulary (see README.md) — silently
# demoting findings via an unknown severity is a real (low-probability)
# hazard.
TOP_PROBLEMS=$(jq -s '
    def sevWeight: ({"critical":0,"error":0,"high":0,"warning":1,"medium":1,"low":2,"style":2,"info":3}[.] // 3);
    map(
        . as $check
        | .top[0:3]            # max 3 per tool
        | map(. + {tool: $check.slug, tool_status: $check.status})
    )
    | flatten
    | sort_by(.severity | sevWeight)
    | .[0:30]
' "${PARSED_FILES[@]}")

# Markdown rendering of the Top Problems list. Empty when no findings.
#
# Sanitisation: tool output (.message, .file) is the only attacker-influenceable
# data the renderer touches. Two defences applied uniformly:
#   - gsub("\\s+"; " ") — collapse newlines and runs of whitespace so a
#     multiline build/tsc error can't break out of a markdown list item or
#     escape a <details> block.
#   - gsub("<"; "&lt;") — neutralise any literal HTML tag a tool might emit
#     (e.g. </details>, <script>, <img onerror>). GitHub allows HTML inside
#     <details> blocks, so this matters for the committed report. Escaping
#     after newline-strip keeps the value LLM-readable while inert as HTML.
#
# Defence lives in the renderer (single point) so every parser inherits it
# without per-call discipline.
TOP_PROBLEMS_MD=$(echo "$TOP_PROBLEMS" | jq -r \
    --arg root "$REPO_ROOT_TRIM" \
    --arg home "$HOME_TRIM" '
    def safe: (. // "") | tostring | gsub("\\s+"; " ") | gsub("<"; "&lt;");
    def normPath:
        safe
        | if startswith($root) then .[($root | length):] else . end
        | if startswith($home) then "~/" + .[($home | length):] else . end;
    if length == 0 then
        "_No findings across any check._"
    else
        map("- **\(.severity)** [`\(.tool)`] \(.message | safe)\n  `\(.file | normPath):\(.line // 0)`") | join("\n")
    end
')

# By-file aggregate — Tornhill-style cross-cut. Files appearing across
# multiple checks are likely bug hotspots. Joins all top[] entries by
# .file and ranks by severity-weighted count.
#
# Severity points (higher = worse):
#   critical/error/high → 4
#   warning/medium      → 3
#   low/style           → 2
#   info                → 1
#
# Written to reports/by-file.json for LLM consumers; rendered as a top-10
# table in the markdown report.
# Path normalization: strip $REPO_ROOT/ prefix and $HOME/ prefix so the
# committed report is reproducible across environments and doesn't leak
# user info / absolute paths. Applied before group_by so two findings on
# the same logical file group together regardless of how the tool emitted
# the path.
BY_FILE=$(jq -s \
    --arg root  "$REPO_ROOT_TRIM" \
    --arg home  "$HOME_TRIM" '
    def sevPts: ({"critical":4,"error":4,"high":4,"warning":3,"medium":3,"low":2,"style":2,"info":1}[.] // 1);
    def normPath:
        (. // "")
        | tostring
        | if startswith($root) then .[($root | length):] else . end
        | if startswith($home) then "~/" + .[($home | length):] else . end;
    [
        .[]
        | . as $check
        | (.top // [])[]
        | select(.file != null and .file != "")
        | {file: (.file | normPath), slug: $check.slug, severity: .severity}
    ]
    | group_by(.file)
    | map({
        file: .[0].file,
        total: length,
        severityScore: ([.[] | .severity | sevPts] | add),
        byCheck: (
            group_by(.slug)
            | map({slug: .[0].slug, count: length, severities: [.[].severity] | unique})
        )
    })
    | sort_by(-.severityScore, -.total)
' "${PARSED_FILES[@]}")

# Persist the full ranking for LLM/trend consumers
echo "$BY_FILE" > "$OUT_DIR/by-file.json"

# Top 10 rendered as a markdown table
BY_FILE_MD=$(echo "$BY_FILE" | jq -r '
    if length == 0 then
        "_No file-level findings to aggregate._"
    else
        (["| File | Findings | Severity score | Breakdown |",
          "| ---- | -------: | -------------: | --------- |"] +
          (.[0:10] | map(
              "| `" + .file + "` | " + (.total | tostring) + " | " +
              (.severityScore | tostring) + " | " +
              (.byCheck | map("\(.slug) (\(.count))") | join(", ")) + " |"
          ))
        ) | join("\n")
    end
')

# Per-check details — iterates every parsed JSON, renders intent + summary + top.
# Same sanitisation contract as Top Problems above: collapse whitespace and
# escape `<` on any tool-influenceable field before it lands in a <details>
# block.
PER_CHECK_MD=$(jq -s -r \
    --arg root "$REPO_ROOT_TRIM" \
    --arg home "$HOME_TRIM" '
    def statusEmoji: ({"pass":"✅","warn":"⚠️","fail":"❌","skip":"⏭️"}[.] // "❓");
    def safe: (. // "") | tostring | gsub("\\s+"; " ") | gsub("<"; "&lt;");
    def normPath:
        safe
        | if startswith($root) then .[($root | length):] else . end
        | if startswith($home) then "~/" + .[($home | length):] else . end;
    sort_by(({"fail":0,"warn":1,"pass":2,"skip":3}[.status] // 4), .slug)
    | map(
        "### \(.slug) — \(.status | statusEmoji) \(.status)\n\n" +
        "**Summary**: \(.summary | safe)\n\n" +
        (if (.intent | type) == "object" and (.intent | length) > 0 then
            "**Purpose**: \(.intent.purpose // "_(not documented)_")\n\n" +
            "**Pass means**: \(.intent.pass_means // "_(not documented)_")\n\n" +
            "**Fail means**: \(.intent.fail_means // "_(not documented)_")\n\n"
         else "" end) +
        (if (.top | length) > 0 then
            "<details><summary>Top \(.top | length) findings</summary>\n\n" +
            (.top | map("- **\(.severity)** \(.message | safe)\n  `\(.file | normPath):\(.line // 0)`") | join("\n")) +
            "\n\n</details>\n"
         else "" end)
    )
    | join("\n---\n\n")
' "${PARSED_FILES[@]}")

# Render the markdown — common body used for both canonical and history files.
render_report() {
    cat << EOF
# Application Checkup Report

> **Last Updated:** $(date -u +"%Y-%m-%d")
> **Generated:** $TIMESTAMP
> **Score:** $HEALTH_SCORE / $MAX_SCORE ($HEALTH_PERCENTAGE%) — $HEALTH_STATUS

The score is the sum of per-check point allocations (e.g. typecheck = 25,
unit-tests = 30, lint = 15). Use it for trend; use the status columns
below for triage.

## How to read this

Four sections, in priority order:

1. **Summary** — counts of pass / warn / fail / skip across every check.
   If \`fail\` > 0 ship is blocked.
2. **Top Problems** — single cross-tool triage list, severity-sorted.
   Start here for "what should I fix first?"
3. **Files with most findings** — files surfaced by multiple checks;
   statistically higher-risk for bugs.
4. **Per-check details** — every check's status, summary, and intent
   (\`purpose\`, \`pass_means\`, \`fail_means\`). Top findings collapsed
   inline.

**Status:** ✅ pass (met threshold) · ⚠️ warn (non-blocking) · ❌ fail
(must-fix) · ⏭️ skip (didn't run — see the check's summary for why).

**Severity** (top[] entries, ordered by triage weight): critical / error /
high → warning / medium → low / style → info.

Machine consumption: \`reports/parsed/<slug>.json\` per check, plus
\`reports/by-file.json\` for the cross-cut.

## Summary

| Status      | Count |
| ----------- | ----- |
| ✅ pass    | $PASS |
| ⚠️  warn   | $WARN |
| ❌ fail    | $FAIL |
| ⏭️  skip   | $SKIP |

## Top Problems

Cross-tool triage list. Max 30 entries, max 3 per check (so a wide check
can't drown the rest). Severity-sorted ascending.

$TOP_PROBLEMS_MD

## Files with most findings

Files appearing across multiple checks are statistically higher-risk for
bugs — the classic "complexity × churn" hotspot signal popularised by
Adam Tornhill ("Code as a Crime Scene"). This view shows the complexity
axis only; the \`git-hotspots\` check adds churn when enabled. Severity
score weights critical=4 → info=1.

$BY_FILE_MD

Full ranking: \`reports/by-file.json\`.

## Per-check details

Every check declares its intent (\`purpose\`, \`pass_means\`, \`fail_means\`)
so a reader — human or LLM — can understand what each check is for without
opening the source.

$PER_CHECK_MD

---

_Generated by \`checkup-report.sh\` from \`reports/parsed/*.json\`. Adding a new
check requires no changes to this file — see \`README.md\` for the contract._
EOF
}

mkdir -p "$(dirname "$REPORT_FILE")" "$OUT_DIR"
render_report > "$REPORT_FILE"
render_report > "$HISTORY_FILE"

# Format so the canonical file passes Prettier in pre-commit.
npx prettier --write "$REPORT_FILE" > /dev/null 2>&1 || true

echo "✅ Health report saved: $REPORT_FILE"
echo "📜 History snapshot:  $HISTORY_FILE"
