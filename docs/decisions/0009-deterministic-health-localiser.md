# 0009 — checkup is a deterministic health localiser, not a deploy gate

- **Status:** Accepted (2026-06-13)

## Context

checkup's closing verdict ("All systems ready for deployment!", "Do NOT
deploy — fix critical issues first") was inherited unexamined from the
progenitor's pre-deploy quality script when checkup was extracted as a
standalone tool. It miscasts the product: deploy-readiness is CI's job, and the
deploy frame answers the wrong question.

checkup's real, unique value — sharpened by the agentic era — is to
**deterministically front-load the gestalt** a smart agent (or human) would
otherwise have to infer by reading code. Inference costs tokens, needs the code
read first, is probabilistic and non-reproducible; a deterministic up-front
signal beats it on all four. (Example: a codebase is Classic ASP — a dead
platform, no talent pool. checkup already detects the language; it just never
rings the bell.)

## Decision

checkup is a **deterministic localiser of codebase health and risk — never a
deploy or CI gate.** It serves four contexts, one job ("here's where the health
problems are," not "may I ship?"):

1. **Prime an AI agent** — deterministic "start here" before the expensive,
   non-deterministic agent runs _(primary)_.
2. **Team prioritisation** — the highest-leverage fix for today's pains /
   tomorrow's failures.
3. **Tech due diligence** — a fast read of a product's code hygiene.
4. **Periodic safety-net sweep** — coarse-cadence catch of what slipped past CI
   _(secondary; deeper versions are what tailoring/forking is for)_.

It delivers **two signals**:

- **(A) Overall health** — a first-impression triage. A grade is permitted; a
  gate is not. Be humble: lead with **evidence**, not false-precision scores.
- **(B) Biggest problems** — at **two tiers**: *macro alarms* (whole-codebase:
  "Classic ASP", "no tests", "runtime EOL") and *file hotspots* (where to point
  the cursor).

Health is composed of **four pillars**:

1. **Maintainability** — complexity, duplication, coupling, hotspots.
2. **Safety / maturity** — tests, coverage, mutation, docs, types. *Absence is a
   loud finding.*
3. **Currency & technology-viability** — dependency rot, EOL runtime, dead
   platforms, dormancy.
4. **Correctness** — does it build / pass now. *Lowest weight; often unrunnable
   on a DD target.*

Three principles follow:

- **Absence is signal.** A missing test rig, no docs, an unsupported runtime is
  among the highest-value findings — not a silent skip. Distinguish
  *scanner-side* absence (we couldn't run the tool → skip) from *target-side*
  absence (we looked; it isn't there → finding).
- **Elevation over detection.** Most value is in surfacing and interpreting
  signals checkup already collects, not adding scanners.
- **Agent-first, human-always.** The structured artefact is primary; the human
  report is kept in lockstep. Neither requires the other.

## Consequences

- The verdict is reframed off deployment; deploy language is purged from the
  verdict and check intents. Exit codes never gate on health (audit already
  exits 0 — see [ADR-0005](0005-template-not-product.md) modes / #5).
- **Correctness is demoted** from the headline to a labelled context reading;
  #35 is recast as *correctness-context + maintainability-headline*, not
  "deployability vs maintainability".
- A **pillar/aggregation layer** maps each check to a pillar and rolls up
  humbly; new signals (EOL runtime, dep-rot, dormancy, tech-viability) become
  checks that slot in, not refactors — building on the parsed-JSON contract
  ([ADR-0002](0002-normalised-parsed-json-contract.md)).
- "Absence is signal" **refines** graceful-degrade
  ([ADR-0003](0003-honest-graceful-degrade.md)): target-side absence is a
  finding, not a skip.
- Tracked by #47; the acceptance test is that the report reproduces known
  ground-truth on reference codebases of known character (healthy/modern,
  large/legacy-laden, small/obsolete) unprompted.
