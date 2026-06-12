# Architecture

How checkup works, as it is now. For _why_ decisions were made, see
[`decisions/`](decisions/) (ADRs); for usage, the [README](../README.md).

## The contract is the product

checkup is a thin orchestrator around a simple contract. The bundled tools and
images are a curated default — the durable, reusable parts are the **schema**,
the **graceful-degrade rule**, and the **tool-agnostic renderer**. Anyone can
re-implement a check, in any language, that emits the schema. (ADR-0002.)

## Pipeline

```
bin/checkup.sh ──┐  runs each check, normalising output via lib/run-tool.sh
                 ├─►  reports/parsed/<slug>.json   (one per check)
                 │
bin/checkup-report.sh ─►  iterates parsed/*.json  ─►  checkup-report.md
                          (tool-agnostic)              + focus.json + by-file.json
```

Each check: run a tool → parse its output → `write_parsed` a normalised record.
The renderer never knows which tools ran — it just aggregates `parsed/*.json`
into the summary, the **Focus Areas** synthesis (the forensic axes + complexity
fused per file), the cross-tool **Top Problems**, the **by-file hotspots**, and
the per-check detail. Adding a check requires **no renderer change**.

## The parsed-JSON record

Each check writes `reports/parsed/<slug>.json`:

```json
{
  "slug": "gitleaks",
  "status": "fail",
  "count": 13,
  "summary": "13 finding(s)",
  "top": [{ "file": "...", "line": 1, "code": "...", "severity": "high", "message": "..." }],
  "intent": { "purpose": "...", "pass_means": "...", "fail_means": "..." }
}
```

- **status vocabulary:** `pass | warn | fail | skip`
- **severity vocabulary** (`top[].severity`): `critical | error | high | warning | medium | low | style | info`
- **intent** documents what the check is for, so a reader (human or LLM)
  understands it without opening the source.

## Helpers (`lib/run-tool.sh`)

- `run_tool "<label>" <cmd> …` — runs a tool, captures stdout/stderr, sets
  `LAST_RAW` / `LAST_EXIT` (`127` = tool not on PATH). Never aborts the run.
- `write_parsed <slug> <status> <count> <summary> <top> <intent>` — emit a record.
- `write_skipped` / `write_failed` — the honest "didn't run" / "ran but
  unparseable" cases.
- `is_fresh <file> <marker>` / `toolchain_absent` — guards behind graceful-degrade.

## Graceful-degrade (ADR-0003)

A check whose tool or prerequisite is absent emits `skip` with a reason. It
never fails spuriously, and **never reads empty tool output as a pass**.
Artifact readers freshness-gate what they consume so a stale report can't pass.

## Checks

- **Cross-stack** (any repo, in `checkup-core`): `gitleaks`, `semgrep`,
  `shellcheck`, `yamllint`, `hadolint`, `codebase-stats`, `complexity`,
  `git-hotspots`, `change-coupling`, `bug-fix-density`, `branch-hygiene`.
- **Project-built** (Node, in core; skip without the toolchain): `typecheck`,
  `unit-tests`, `build`, `code-quality`, `type-aware-lint`, `coverage`,
  `circular-deps`, `duplication`, `unused-code`, `deps-freshness`, `npm-audit`,
  `mutation`.
- **`checkup-dotnet` overlay** adds: `asp-classic`, `devskim`, `dotnet-vuln`,
  and a language-aware `duplication`.

## Images (ADR-0004)

`checkup-core` (universal, no language runtimes) + per-stack overlays
(`FROM checkup-core`, one stack each) + an optional everything image. The runner
is language-agnostic and degrades, so it also runs on a host using whatever tools
are on `$PATH`.

## Output

All checkup-owned output goes under `reports/` by default, or under
`$CHECKUP_OUT_DIR` when set (so the source can be mounted read-only). The
canonical report is `checkup-report.md`; machine-readable data is
`parsed/*.json` + `by-file.json`.

## Design rationale

**Why the dual stream (markdown + parsed JSON)?** Humans want narrative and
trend; LLMs and CI want structured findings. One dataset, two renderings.

**Why does each check write its own JSON?** The alternative — one giant summary
file every parser mutates — is the shape the original script had, and the reason
adding a check meant editing six places. One file per check makes each
independently testable, and the renderer just iterates `parsed/*.json`.

**Why is status separate from the cumulative score?** The score (sum of per-check
allocations) is for _trend_ — "healthier than last month?". Status is for
_triage_ — "what do I fix today?". Conflating them — pretending a 64% score is
actionable — was the failure mode of the original version.

**Why intent in the JSON, not just a comment?** An LLM reading the parsed output
never sees the script. Carrying `intent` in-band makes the stream self-describing
— the reader can reason about whether a finding matters without the source.
