# Recipe: an executive summary from a checkup run

checkup produces honest **findings** and a **coverage** read, but it deliberately
stops short of *"so what, and what do I do?"*. This recipe closes that gap: a
portable prompt that turns a checkup run into a **CTO-level brief** — what this
is, the real risk posture (not the loudest alarm), the dominant *unknown*, how
much to trust the read, and what it would take to de-risk.

It is the same "front-load the gestalt" thesis as [priming an
agent](../README.md#priming-an-agent), one level up: synthesis over the
agent-first bundle (`reports/checkup.json` + `reports/parsed/`), not raw findings.

> **An LLM brief is advisory and non-deterministic.** It can be wrong, and two
> runs may differ. The deterministic `checkup-report.md` / `checkup.json` remain
> the source of truth; this is an interpretation layer on top.

## ⚠️ Privacy: the deterministic scan stays in your environment — this step may not

The checkup scan itself can be run with **no network egress** ([ADR-0008](decisions/0008-network-isolation.md));
your source never leaves the box. An LLM summary breaks that property to the
extent you feed it data over a hosted model:

| Mode | What the model sees | IP exposure |
| ---- | ------------------- | ----------- |
| **report-only** (default) | the report only — finding messages, file paths, summaries, counts | findings + paths leave your environment; **source does not** |
| **source-aware** | the report **and** repository source it chooses to read | **source / IP leaves your environment** |

If you run the summary through a **hosted** LLM, that data goes to the provider
(and may be retained/cached). For a confidential or due-diligence target this can
matter a great deal. Your options, in decreasing confidentiality:

1. **report-only + a local/self-hosted model** — nothing sensitive leaves.
2. **report-only + a hosted model** — findings and paths leave; source does not.
3. **source-aware + a hosted model** — richest brief (it can cross-check findings),
   but you are sending IP to a third party.

This is a **utility-vs-confidentiality choice that is yours to make** — checkup's
job is only to flag it. Pick the mode deliberately; don't let an agent quietly
escalate from report-only to source-aware.

## When to use which mode

- **report-only** is the honest default and pairs with the blind-agent validation
  harness. Caveat: the brief *inherits checkup's calibration* — if a scanner
  over-alarms (e.g. flags a public-by-design key as critical), a report-only
  agent will faithfully repeat it. The guardrails below mitigate this but can't
  fully replace ground truth.
- **source-aware** lets the agent *verify* before it downgrades — "is that key
  actually public-by-design?", "is that CVE in a runtime or a dev/transitive
  dependency?" — which is what makes the brief genuinely sharper. Use it only when
  the confidentiality trade-off above is acceptable.

## The prompt

Paste this into your agent of choice. Point it at the output directory of a
checkup run (`$CHECKUP_OUT_DIR`, or `reports/`). Delete the bracketed
source-aware line to keep it strictly report-only.

```text
You are a senior engineering advisor writing a one-page executive (CTO-level)
brief on a codebase, from the output of "checkup" (a deterministic
codebase-health localiser). Be calibrated and decision-oriented, not a findings
dump.

INPUTS — read these from the checkup output directory:
- checkup.json    — the agent-first bundle: overall read, headline alarms,
                    pillar bands, coverage, topology, per-check index.
- parsed/*.json   — one record per check {slug,status,count,summary,top,intent};
                    status is pass|warn|fail|skip. Slugs may be namespaced per
                    sub-package, e.g. "backend/npm-audit".
- detection.json  — stack, coverage (what was/ wasn't assessed), topology.
[SOURCE-AWARE ONLY: you may also read the repository to VERIFY a finding before
 you up- or down-grade it. Cite what you checked. If you are NOT explicitly in
 source-aware mode, do not read source — reason from the report alone and say so.]

CALIBRATION RULES — do not just echo the scanners:
1. Unmeasured ≠ healthy. A skip is an UNKNOWN, never a pass. If whole pillars are
   "no data", that is a finding in itself — lead with it.
2. Separate RUNTIME dependency risk from DEV/TRANSITIVE. A critical CVE in a
   build-time or transitive dependency is far less urgent than one in a direct
   runtime dependency. Lead with runtime.
3. Calibrate secret findings. A public-by-design credential (e.g. a Firebase WEB
   API key, which ships in the client bundle) is a hygiene issue, not a breach.
   A real server credential is an incident. Don't give them the same weight.
4. Read the coverage + topology signals. If checkup assessed only an orchestrator
   root (undeclared fan-out), or ran without git history, large parts of the
   picture are blind — say so and LOWER your confidence accordingly.
5. Lead with the dominant UNKNOWN, not the loudest alarm. The most important
   sentence is often "we can't yet tell whether X".

OUTPUT — a tight brief with these sections:
- **What it is** — one paragraph: stack, size, shape, maturity.
- **Risk posture** — the genuinely urgent items, calibrated per the rules above;
  explicitly down-weight noise and say why.
- **The dominant unknown** — what the scan could NOT measure and why it matters
  most.
- **Confidence** — how much to trust this read, and specifically where the scan
  was structurally blind.
- **Effort to de-risk** — concrete next steps and rough effort to convert the
  unknowns into facts (e.g. re-run per sub-package, on a real git clone).
- **Recommendation** — split: "if you own it" vs "if you're evaluating/inheriting
  it" (due diligence). Be decisive.

Keep it to one page. State confidence; never present an unmeasured area as healthy.
```

## Running it as a skill / subagent

checkup is tool-agnostic, so the prompt above is the portable artefact — it works
in any agent or chat. To wire it into a specific harness:

- **Claude Code** — drop the prompt into a project subagent (e.g.
  `.claude/agents/checkup-exec-summary.md`) or invoke it as a one-off. Run the
  summarising agent in **report-only** mode by pointing it only at the output
  directory and withholding repo access, unless you have deliberately accepted the
  source-aware trade-off.
- **Any other agent framework** — paste the prompt; pass the checkup output dir as
  the working context.

## Why this lives as a prompt, not a baked-in check

The deterministic core must stay deterministic, offline-capable, and free of any
LLM dependency — that is the whole point ([ADR-0009](decisions/0009-deterministic-health-localiser.md),
[ADR-0008](decisions/0008-network-isolation.md)). The executive brief is an
optional, non-deterministic interpretation layer. Keeping it as a documented
prompt (not a bundled tool) preserves the core's guarantees and leaves the
utility-vs-confidentiality decision with the operator.
