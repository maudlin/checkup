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
    CHECKUP_MODE=$(jq -r '.mode // "tailored"' "$OUT_DIR/checkup-summary.json")
else
    HEALTH_SCORE="N/A"
    MAX_SCORE=0
    HEALTH_PERCENTAGE="N/A"
    CHECKUP_MODE="tailored"
fi

# The headline is an OVERALL health read derived from the pillars (computed
# below, once PILLARS exists) — NOT the legacy point-sum percentage, which is
# misleading (it was deploy-centric, dominated by correctness, and on a non-Node
# target collapses to ~0% simply because the scored checks didn't run). The
# legacy score stays in checkup-summary.json for trend back-compat but is no
# longer the headline (#35, ADR-0009).

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
        map("- **\(.severity)** [`\(.tool)`] \(.message | safe)" + (if (.file // "") == "" then "" else "\n  `\(.file | normPath):\(.line // 0)`" end)) | join("\n")
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

# Focus Areas — the "where should this team focus first?" synthesis. Fuses the
# five per-file health axes (the Tornhill forensic trio + complexity +
# duplication) by file, so a file that lands on MULTIPLE axes — hot × complex
# AND coupled AND bug-dense AND duplicated — rises to the top. This is the
# report's headline view; everything
# else is detail. Renderer-only: works on any repo whose run produced these
# checks (git history for the forensic axes, any complexity engine), and is
# simply empty when none ran.
#
# Scoring: each finding contributes a weight (axis × severity tier); a file's
# focusScore is their sum. Ranking is axisCount-first (multi-signal
# concentration is the whole point) then focusScore. The `why` carries one
# human phrase per axis — the strongest-severity message for that axis — so the
# row explains itself ("hotspot: 47 changes × CCN 31 · bug-fix: 57% …").
FOCUS=$(jq -s \
    --arg root "$REPO_ROOT_TRIM" \
    --arg home "$HOME_TRIM" '
    def normPath:
        (. // "")
        | tostring
        | if startswith($root) then .[($root | length):] else . end
        | if startswith($home) then "~/" + .[($home | length):] else . end;
    # Map a forensic finding to its axis + weight. Non-forensic slugs yield
    # `empty`, dropping the row (defence-in-depth; the select below also filters).
    def axisFor($slug; $sev):
        if   $slug == "git-hotspots"   then {axis:"hotspot",    weight:({"warning":3,"low":1,"info":0.5}[$sev] // 0.5)}
        elif $slug == "bug-fix-density" then {axis:"bug-fix",    weight:({"warning":2.5,"low":1}[$sev] // 1)}
        elif $slug == "change-coupling" then {axis:"coupling",   weight:({"warning":2,"low":1}[$sev] // 1)}
        elif $slug == "complexity"     then {axis:"complexity", weight:({"error":2,"high":2,"warning":1.5,"medium":1.5,"low":1,"info":0.5}[$sev] // 1)}
        elif $slug == "duplication"    then {axis:"duplication", weight:({"high":2,"warning":1.5,"low":1}[$sev] // 1)}
        else empty end;
    def sevRank: ({"critical":0,"error":0,"high":0,"warning":1,"medium":1,"low":2,"style":2,"info":3}[.] // 3);
    [ .[]
      | select(.slug == "git-hotspots" or .slug == "bug-fix-density" or .slug == "change-coupling" or .slug == "complexity" or .slug == "duplication")
      | . as $check
      | (.top // [])[]
      | select(.file != null and .file != "")
      | (axisFor($check.slug; .severity)) as $a
      | {file: (.file | normPath), axis: $a.axis, weight: $a.weight, severity, message}
    ]
    | group_by(.file)
    | map({
        file: .[0].file,
        axes: ([.[].axis] | unique),
        axisCount: ([.[].axis] | unique | length),
        focusScore: ([.[].weight] | add),
        why: (
            group_by(.axis)
            | map({axis: .[0].axis,
                   detail: (sort_by(.severity | sevRank) | .[0].message)})
            | sort_by({"hotspot":0,"bug-fix":1,"coupling":2,"complexity":3,"duplication":4}[.axis] // 9)
            | map(.axis + ": " + .detail)
        )
      })
    | sort_by(-.axisCount, -.focusScore)
' "${PARSED_FILES[@]}")

# Persist the full ranking for LLM / CI / trend consumers
echo "$FOCUS" > "$OUT_DIR/focus.json"

# Top 10 as a markdown table. `safe` also escapes `|` here because a filename in
# a coupling `why` phrase could otherwise break the table layout.
FOCUS_MD=$(echo "$FOCUS" | jq -r '
    def safe: (. // "") | tostring | gsub("\\s+"; " ") | gsub("<"; "&lt;") | gsub("\\|"; "\\\\|");
    if length == 0 then
        "_No focus signals yet — this view needs git history (hotspots / change-coupling / bug-fix density) and/or a complexity or duplication engine. See the per-check details for why each was skipped._"
    else
        (["| File | Axes | Focus | Why |",
          "| ---- | ---- | ----: | --- |"] +
          (.[0:10] | map(
              "| `" + (.file | safe) + "` | " + (.axisCount | tostring) + " | " +
              ((.focusScore * 10 | round / 10) | tostring) + " | " +
              ((.why | join(" · ")) | safe) + " |"
          ))
        ) | join("\n")
    end
')

# Health pillars (#50, ADR-0009). Map each check to one of the four HEALTH
# pillars; the security checks go to a SEPARATE lightweight Security section (a
# secret leak is headline-class, not a demoted pillar average). Unmapped checks
# (shellcheck/yamllint/hadolint housekeeping; codebase-stats is a data source for
# #52, not a band input) don't feed a pillar. Each pillar gets a HUMBLE band —
# strong / mixed / weak / no-data — from its members' statuses, plus the evidence
# behind it. (#51 will turn target-side absence into a finding; today a skipped
# member is "no data", not a false pass.)
PILLARS=$(jq -s '
    def pillarOf:
        {
          "complexity":"maintainability","duplication":"maintainability","circular-deps":"maintainability",
          "unused-code":"maintainability","git-hotspots":"maintainability","change-coupling":"maintainability",
          "bug-fix-density":"maintainability","code-quality":"maintainability","type-aware-lint":"maintainability",
          "unit-tests":"safety","coverage":"safety","mutation":"safety","branch-hygiene":"safety",
          "test-presence":"safety","docs":"safety",
          "deps-freshness":"currency","tech-viability":"currency",
          "typecheck":"correctness","build":"correctness",
          "gitleaks":"security","semgrep":"security","npm-audit":"security"
        }[.];
    # Humble band from member statuses (skip = no data, excluded). Representative,
    # not worst-case: "weak" needs fails to dominate (≥2, or any fail in a small
    # ≤2-member pillar where one failure IS the story, e.g. a broken build), so a
    # single isolated fail among many passes reads "mixed", not "weak". Exact
    # calibration is revisited with the headline score (#35).
    def band:
        map(select(. != "skip")) as $p
        | ($p | length) as $n
        | ([$p[] | select(. == "fail")] | length) as $f
        | ([$p[] | select(. == "warn")] | length) as $w
        | if   $n == 0                       then "unknown"
          elif $f == 0 and $w == 0           then "strong"
          elif $f >= 2 or ($f >= 1 and $n < 3) then "weak"
          else                                    "mixed" end;
    [ .[] | {slug, status, pillar:(.slug | pillarOf)} | select(.pillar != null) ]
    | group_by(.pillar)
    | map({pillar: .[0].pillar, band: ([.[].status] | band), evidence: (map({slug,status}) | sort_by(.slug))})
    | . as $bp
    | {
        health: (["maintainability","safety","currency","correctness"]
                 | map(. as $p | (($bp[] | select(.pillar==$p)) // {pillar:$p, band:"unknown", evidence:[]}))),
        security: (($bp[] | select(.pillar=="security")) // {pillar:"security", band:"unknown", evidence:[]})
      }
' "${PARSED_FILES[@]}")
echo "$PILLARS" > "$OUT_DIR/pillars.json"

# Overall health read — the first-impression triage (#35, ADR-0009). A humble
# synthesis of the pillar bands, NOT a percentage. Maintainability is the spine;
# the "health/risk" pillars (maintainability, safety, currency) plus Security
# drive the verdict; correctness is shown as context (often "no data" on a
# target you don't own, and it never gates). Audit mode just relabels the lead.
FOCUS_MULTI=$(echo "$FOCUS" | jq '[.[] | select(.axisCount >= 2)] | length')
OVERALL=$(echo "$PILLARS" | jq -c --arg mode "$CHECKUP_MODE" --argjson focusMulti "${FOCUS_MULTI:-0}" '
    def disp: {"maintainability":"maintainability","safety":"safety/maturity","currency":"currency & viability","security":"security"}[.] // .;
    def rank: {"weak":3,"mixed":2,"strong":1,"unknown":0}[.] // 0;
    ([.health[] | select(.pillar != "correctness")] + [.security]) as $spine
    | ($spine | map(.band | rank) | max) as $worst
    | (if $worst==3 then "weak" elif $worst==2 then "mixed" elif $worst==1 then "strong" else "unknown" end) as $band
    | ([$spine[] | select(.band=="weak") | (.pillar|disp)]) as $weak
    | ([$spine[] | select(.band=="mixed") | (.pillar|disp)]) as $mixed
    | (.health[] | select(.pillar=="correctness") | .band) as $corr
    | {
        band: $band,
        verdict: ({"weak":"🔴 Significant work needed","mixed":"🟡 Some debt worth attention","strong":"🟢 Broadly healthy","unknown":"⚪ Insufficient data to assess"}[$band]),
        weak: $weak, mixed: $mixed, correctness: $corr, focusMulti: $focusMulti, mode: $mode
      }')
echo "$OVERALL" > "$OUT_DIR/overall.json"
OVERALL_VERDICT=$(echo "$OVERALL" | jq -r '.verdict')
OVERALL_GESTALT=$(echo "$OVERALL" | jq -r '
    ( if (.weak|length) > 0 then "Needs work in **" + (.weak|join("**, **")) + "**."
      elif (.mixed|length) > 0 then "Some debt in **" + (.mixed|join("**, **")) + "**."
      else "No weak or mixed pillars." end )
    + ( if .focusMulti > 0 then " " + (.focusMulti|tostring) + " file(s) concentrate ≥2 risk axes — see Focus Areas." else "" end )
    + ( " Correctness (context): " + ({"strong":"compiles & builds","mixed":"some issues","weak":"failing","unknown":"not assessed"}[.correctness]) + "." )')

# Headline alarms (#53) — the loudest, decision-shaping signals, floated to the
# very top so an agent/human can't miss them. A curated set of headline-class
# checks (dead/declining platform, no test safety net, leaked secrets) plus any
# critical-severity finding from anywhere (e.g. a critical CVE). These are the
# whole-codebase "woah, stop" signals; the per-file ranking stays in Focus Areas.
MACRO=$(jq -s \
    --arg root "$REPO_ROOT_TRIM" --arg home "$HOME_TRIM" '
    def sevRank: ({"critical":0,"error":1,"high":1,"warning":2,"medium":2,"low":3,"style":3,"info":4}[.] // 4);
    def normPath: (. // "") | tostring
        | if startswith($root) then .[($root|length):] else . end
        | if startswith($home) then "~/" + .[($home|length):] else . end;
    (["tech-viability","test-presence","gitleaks"]) as $macroSlugs
    | [ .[] | . as $c | (.top // [])[]
        | select(($macroSlugs | index($c.slug) != null) or (.severity == "critical"))
        | {slug:$c.slug, severity, message,
           file:(if (.file // null) == null then null else (.file|normPath) end)} ]
    # Group by source so 10 leaked secrets read as ONE "N secrets" alarm, not 10
    # rows — headline alarms are distinct KINDS, not every instance.
    | group_by(.slug)
    | map( (sort_by(.severity | sevRank)) as $g
           | {slug: $g[0].slug, severity: $g[0].severity, count: ($g|length),
              message: $g[0].message,
              file: (if ($g|length) == 1 then $g[0].file else null end)} )
    | sort_by(.severity | sevRank)' "${PARSED_FILES[@]}")
echo "$MACRO" > "$OUT_DIR/macro-alarms.json"

MACRO_MD=$(echo "$MACRO" | jq -r '
    def safe: (. // "") | tostring | gsub("\\s+"; " ") | gsub("<"; "&lt;");
    def icon: ({"critical":"🔴","error":"🔴","high":"🔴","warning":"🟠","medium":"🟠","low":"🟡","style":"🟡","info":"⚪"}[.] // "⚪");
    if length == 0 then
        "_No headline alarms — no dead platform, missing test safety net, leaked secret, or critical-severity finding._"
    else
        map("- " + (.severity|icon) + " **[" + (.slug|safe) + "]** " + (.message|safe)
            + (if .count > 1 then "  _(+" + ((.count-1)|tostring) + " more of this kind)_" else "" end)
            + (if .file == null then "" else "  `" + (.file|safe) + "`" end))
        | join("\n")
    end')

PILLARS_MD=$(echo "$PILLARS" | jq -r '
    def disp: {"maintainability":"Maintainability","safety":"Safety / maturity","currency":"Currency & viability","correctness":"Correctness"}[.] // .;
    def bandLabel: {"strong":"🟢 strong","mixed":"🟡 mixed","weak":"🔴 weak","unknown":"⚪ no data"}[.] // .;
    def ev: (.evidence | map(select(.status != "skip"))) as $e
        | if ($e|length)==0 then "_no signals yet_" else ($e | map(.slug + ": " + .status) | join(" · ")) end;
    (["| Pillar | Reading | Evidence |", "| ---- | ------- | --- |"]
     + (.health | map("| " + (.pillar|disp) + " | " + (.band|bandLabel) + " | " + ev + " |")))
    | join("\n")
')

SECURITY_MD=$(echo "$PILLARS" | jq -r '
    def bandLabel: {"strong":"🟢 clean","mixed":"🟡 findings","weak":"🔴 findings","unknown":"⚪ no data"}[.] // .;
    .security
    | (.band|bandLabel) + " — "
      + (if (.evidence|length)==0 then "no security checks ran"
         else (.evidence | map(.slug + ": " + .status) | join(" · ")) end)
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
            (.top | map("- **\(.severity)** \(.message | safe)" + (if (.file // "") == "" then "" else "\n  `\(.file | normPath):\(.line // 0)`" end)) | join("\n")) +
            "\n\n</details>\n"
         else "" end)
    )
    | join("\n---\n\n")
' "${PARSED_FILES[@]}")

# Agent-first output contract (#54, ADR-0009). A single, VERSIONED bundle that an
# agent reads first: the headline read + alarms + pillar bands + top focus + a
# per-check index, with pointers to the detailed artefacts. The human report
# below is rendered from the same data, so the two never drift. Individual files
# (focus.json, pillars.json, …) remain for back-compat; this is the entry point.
CHECK_INDEX=$(jq -s 'map({slug, status, count, summary}) | sort_by(.slug)' "${PARSED_FILES[@]}")
FOCUS_TOP=$(echo "$FOCUS" | jq -c '.[0:10]')
jq -n \
    --arg schemaVersion "1.0" \
    --arg generated "$TIMESTAMP" \
    --arg mode "$CHECKUP_MODE" \
    --argjson overall "$OVERALL" \
    --argjson headlineAlarms "$MACRO" \
    --argjson pillars "$PILLARS" \
    --argjson focusTop "$FOCUS_TOP" \
    --argjson checks "$CHECK_INDEX" \
    '{
        schemaVersion: $schemaVersion,
        generated: $generated,
        mode: $mode,
        overall: $overall,
        headlineAlarms: $headlineAlarms,
        pillars: $pillars,
        focusTop: $focusTop,
        checks: $checks,
        artefacts: {
            checksDir: "parsed/",
            focus: "focus.json",
            byFile: "by-file.json",
            pillars: "pillars.json",
            overall: "overall.json",
            macroAlarms: "macro-alarms.json",
            report: "checkup-report.md"
        }
    }' > "$OUT_DIR/checkup.json"

# Render the markdown — common body used for both canonical and history files.
render_report() {
    cat << EOF
# Application Checkup Report

> **Overall: $OVERALL_VERDICT** · **Mode:** $CHECKUP_MODE · **Generated:** $TIMESTAMP

$OVERALL_GESTALT

_checkup localises where a codebase needs attention — a health read, **not a
deploy gate** ([ADR-0009](https://github.com/maudlin/checkup/blob/main/docs/decisions/0009-deterministic-health-localiser.md)). The overall read above is a humble synthesis of the
health pillars below; it is **not** a score. (A legacy point-sum lives in
\`reports/checkup-summary.json\` for trend continuity only.)_

## Headline alarms

The loudest, whole-codebase signals — read these first. A dead/declining
platform, no test safety net, a leaked secret, or a critical-severity finding.
Empty is good news.

$MACRO_MD

## How to read this

This is a codebase-health read, not a deploy gate (it never blocks a build).
Seven sections, in priority order:

1. **Headline alarms** — the loudest whole-codebase signals (dead platform, no
   tests, leaked secret, critical finding). Read first; empty is good.
2. **Summary** — counts of pass / warn / fail / skip across every check.
3. **Health pillars** — the overall read: a humble band per health pillar
   (maintainability · safety/maturity · currency & viability · correctness),
   with **Security** tracked separately. Start here for "how healthy is this?"
4. **Focus Areas** — the "where should we focus first?" view. Files ranked by
   how many health axes they land on (hot × complex, coupled, bug-dense), with
   a one-line _why_. Start here for "where is the risk concentrated?"
5. **Top Problems** — single cross-tool triage list, severity-sorted.
   Start here for "what should I fix first?"
6. **Files with most findings** — files surfaced by multiple checks;
   statistically higher-risk for bugs.
7. **Per-check details** — every check's status, summary, and intent
   (\`purpose\`, \`pass_means\`, \`fail_means\`). Top findings collapsed
   inline.

**Status:** ✅ pass (met threshold) · ⚠️ warn (non-blocking) · ❌ fail
(must-fix) · ⏭️ skip (didn't run — see the check's summary for why).

**Severity** (top[] entries, ordered by triage weight): critical / error /
high → warning / medium → low / style → info.

Machine consumption: **\`reports/checkup.json\`** is the agent-first entry point
— a single versioned bundle (overall read + headline alarms + pillar bands + top
focus + per-check index + artefact pointers). This report is rendered from the
same data. The components are also available standalone: \`reports/parsed/<slug>.json\`
per check, \`reports/overall.json\`, \`reports/macro-alarms.json\`,
\`reports/pillars.json\`, \`reports/focus.json\`, \`reports/by-file.json\`.

## Summary

| Status      | Count |
| ----------- | ----- |
| ✅ pass    | $PASS |
| ⚠️  warn   | $WARN |
| ❌ fail    | $FAIL |
| ⏭️  skip   | $SKIP |

## Health pillars

_How healthy is this codebase?_ A humble read across the four health pillars
(ADR-0009) — bands, not false-precision scores; the **Evidence** column is the
checks behind each band. **Security** is tracked separately: a secret leak or
critical CVE is headline-class, not something to average into a pillar.

$PILLARS_MD

**Security:** $SECURITY_MD

## Focus Areas

_Where should this team focus first?_ Files ranked by how many health axes
they land on — the Tornhill forensic trio (\`git-hotspots\` = churn × complexity,
\`change-coupling\`, \`bug-fix-density\`) plus \`complexity\` and \`duplication\`.
A file high on **several** axes is where risk concentrates: changed often, hard
to reason about, entangled with its neighbours, historically bug-prone, and
copy-pasted (so a fix in one copy misses the others). **Axes** is how many of
the five it appears on; **Why** is the headline reason per axis. This is a focus
signal, not a gate — it never blocks a build.

$FOCUS_MD

Full ranking: \`reports/focus.json\`.

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
