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
canonical human report is `checkup-report.md`.

### Agent-first contract — `checkup.json` (ADR-0009)

`reports/checkup.json` is the **primary, versioned machine artefact** — the
entry point an agent reads first. The human report is rendered from the same
data, so the two never drift. Shape:

```jsonc
{
  "schemaVersion": "1.0",
  "generated": "<utc>",
  "mode": "tailored | audit",
  "overall":        { "band", "verdict", "weak":[…], "mixed":[…], "correctness", "focusMulti" },
  "headlineAlarms": [ { "slug", "severity", "count", "message", "file" } ],  // grouped, loudest first
  "pillars":        { "health":[ { "pillar","band","evidence":[…] } ], "security": {…} },
  "focusTop":       [ … top 10 of focus.json … ],
  "checks":         [ { "slug","status","count","summary" } ],   // per-check index
  "artefacts":      { "checksDir":"parsed/", "focus":"focus.json", … }  // pointers to detail
}
```

The two signals (ADR-0009) map directly: **overall health** = `overall` +
`pillars`; **biggest problems** = `headlineAlarms` (macro tier) + `focusTop`
(file tier). The standalone files (`overall.json`, `macro-alarms.json`,
`pillars.json`, `focus.json`, `by-file.json`, `parsed/<slug>.json`) remain for
back-compat and granular access. Bump `schemaVersion` on a breaking change.

### Stack detection — `detection.json` (#7)

Before any check runs, checkup detects which stacks the target is built from and
routes the language-sensitive engines (complexity, duplication) off that —
instead of extension probes that mis-fired when a repo merely *contained* a
stray file (one `.ts` in a Python monorepo used to route complexity to ESLint,
which then hard-failed with no flat config). Two signals are reconciled:
**manifests** (`package.json`, `*.csproj`, `go.mod`, `pyproject.toml`, …) for
how-to-build, and **scc's language breakdown** for what's worth linting. A stack
drives its own engine only when it is the **primary** language (or a co-primary
≥40%) — never merely top-3, so a stray file can't tip the decision. The breakdown
transform is shared (`lib/detect-stacks.jq`) so it has one source of truth and is
unit-tested (`test/detect.test.sh`).

The plan is printed for a human and persisted to `detection.json` (in `OUT_DIR`,
**not** under `parsed/`, so the renderer never counts it as a check):

```jsonc
{
  "schemaVersion": "1.1",
  "primary": "node",                 // largest stack, or null when ambiguous
  "primaryConfidence": "high",       // high (manifest + dominant) | medium | low
  "sccBreakdownAvailable": true,     // false → degraded to manifest/presence signal
  "stacks":   [ { "stack", "code", "top3", "pct" } ],
  "manifests": [ "node", … ],
  "engines":  {
    // complexity.engine is the summary label (eslint | eslint+lizard | lizard |
    // scc | none); complexity.slices lists the engines that each measure a
    // language slice and are merged into one record (#68) — e.g.
    // ["eslint","lizard"] for a node-dominant polyglot repo.
    "complexity": { "engine", "reason", "slices": [ … ] },
    "duplication": { "engine", "reason" }
  },
  "overridden": false                // true when a repo-local `.checkup.yml` steered detection
}
```

When a node-dominant repo also carries languages ESLint can't see (Python, C#,
Go, …), complexity runs **per language slice and merges**: ESLint measures the
JS/TS slice (AST-accurate cyclomatic + cognitive) and lizard the rest (true
per-function CCN), partitioned by extension so no file is counted twice, folded
into one `parsed/complexity.json` and one `complexity-full.csv` via the shared
`lib/complexity-merge.jq` / `lib/complexity-csv.jq` transforms (#68). A
single-language repo runs exactly one slice, so its output is unchanged.

`primaryConfidence` raises the confidence behind absence-is-signal (#51): a
"no tests" finding is asserted as a *genuine* absence only when we know we looked
the right way for a confirmed stack. Cross-stack checks (secrets, SAST,
forensics, stats, docs, test-presence, tech-viability) always run regardless of
detection.

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
