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
                          (tool-agnostic)              + by-file.json
```

Each check: run a tool → parse its output → `write_parsed` a normalised record.
The renderer never knows which tools ran — it just aggregates `parsed/*.json`
into the summary, the cross-tool **Top Problems**, the **by-file hotspots**, and
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
