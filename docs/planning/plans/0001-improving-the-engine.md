# Plan 0001 — Improving the checkup engine (stay bash)

> **Status: working plan — mutable, not an ADR.** Plans here change a lot; they
> capture *current intent and direction*, not agreed decisions. An item graduates
> to an issue when it's ready to build, and to an **ADR** only when a choice is
> actually settled. Nothing in here is committed by virtue of being written down.

## Decision (settled): keep bash, improve it incrementally

checkup stays a **bash template you can read, fork and hack** (ADR-0005). We
improve the engine in place rather than rewrite it. A full lift to a programmatic
(Go) engine was explored as a thought experiment and **rejected** — see
"Considered and rejected" below for why, so we don't re-run it.

The north star from the architecture conversation still stands and is pursued
*incrementally, in bash*:

> Discover → **plan** (which checks, which targets) → execute through **stack
> knowledge** that carries checks *and* the opinion of good-vs-bad *for that
> stack* → emit **honest** measurements (a finding, or a truthful "didn't/couldn't
> look") → the normalised records are the product; report/pillars/bundle/exec-brief
> are **projections**. Opinionated about health, **never a gate** (ADR-0009).

We already have embryos of all of this (stack detection, topology/plan,
`run_tool`/`write_parsed` honesty primitives, command profiles, overlays). The work
is *finishing and unifying* them, not replacing them.

## What we're improving (rough priority; mutable)

### A. Engine health — the spine (highest leverage; came out of the stress test)
The recurring honesty-bug class (#80, #85, #91) keeps returning because the
honesty contract is a *convention* and the ~29 sections aren't individually tested
(the suite tests *mirrors* of section logic, not the sections). Fix the discipline
in bash, where the chokepoint primitive already lives:
- **Enforce absence-routing**: extract a single `classify_status`/skip path; a CI
  lint that fails if a project-built section can report pass/fail on empty / 127 /
  unparseable output instead of routing through `write_skipped`.
- **Per-section unit tests** — close the "tests mirror logic, don't test sections"
  gap so a #80/#85/#91-class bug can't reappear silently.
- **Determinism hardening** — `LC_ALL=C`, total sort tie-breakers before every
  `head -N` cap, stable iteration, templated timestamps. Improves reproducibility
  (it's a *deterministic* tool) and is a prerequisite for any future golden-test
  characterisation.

### B. Fairness / calibration — make the opinion trustworthy
The report is honest but leans alarmist on borrowed-tool output (found cross-
checking a real repo). Home the calibration in the per-stack knowledge:
- npm-audit findings tagged **dev / prod / transitive**; lead with runtime risk.
- gitleaks findings carry rule context + **public-by-design** hints (a Firebase
  *web* key is hygiene, not a breach).
- runner-agnostic messages (done, #91); keep auditing for hardcoded tool names.
- per-check **thresholds overridable via `.checkup.yml`** (#72) — opinion as
  overridable data, not buried literals.

### C. Coverage depth
- Per-package **complexity / duplication / coverage** on an undeclared fan-out
  (#78 Phase 2b) — the engine-routed slice the topology recover pass left.
- More stacks (still as bash overlays/profiles).

### D. Durable ideas borrowed from the thought experiment (apply to bash)
The Go exploration produced real insights that improve the bash engine *without* a
rewrite:
- **Checks as uniform units** — a consistent `run → evidence → status` shape so
  honesty is enforced once (A), not re-hand-rolled per section.
- **Shared, target-level services** — the source inventory and the complexity
  model are *not* per-stack; make their single-authority status explicit so a
  multi-stack repo can't double-count or split a file.
- **Make inter-check data dependencies explicit** — `complexity-full.csv` is an
  undocumented ABI between the complexity and git-hotspots sections; name it.
- **"Opinionated, never a gate" as a tested invariant** — keep the audit-mode
  exit-0 guarantee, and assert it, rather than trusting prose.

## Considered and rejected: a programmatic (Go) engine rewrite

Explored in depth and adversarially stress-tested (five "Morlock" reviews).
Rejected. The decisive findings, recorded so we don't relitigate:

- **The motivating pains are bash-refactorable, not language walls.** The honesty
  chokepoint already exists (`run_tool`/`write_parsed`); #80/#91 were four-line
  fixes inside it. "Single root" is already a `for target in …` loop. These are
  un-paid refactors, not reasons to change language.
- **A typed chokepoint relocates the honesty bug, doesn't kill it** — recognising
  "empty-because-absent vs empty-because-clean" is per-check local knowledge that
  survives any substrate. The real win was *testability*, which we can have in bash (A).
- **The "decisive property" (zero runtime deps) was false** — Go removes only
  bash, while keeping every scanner tool *and* jq (158 call sites); "zero deps"
  would need all of jq reimplemented in Go, the most expensive branch.
- **The migration safety net was unsound** — golden-diffing current bash would
  *certify its bugs* (and reject the fix), and the output isn't deterministic
  enough to byte-diff, so almost everything would route through an untested
  "semantic differ" that can pass a wrong port green.
- **The strangler's predicted equilibrium is a permanent two-engine chimera** —
  early phases bank ~all the value; deleting bash is pure cost a lightly-staffed
  template won't fund.
- **It would turn a template into a product** — a Go engine + module SDK
  contradicts ADR-0005; the plan's own abort criterion ("template ethos outranks
  the rewrite") was already triggered.

The exploration was worth it: it produced section D and confirmed the bash path is
right.

## How this plan works (the meta)

- It lives in `docs/planning/plans/` and is **edited freely** as direction shifts.
- It is **not an ADR.** When a choice within it is actually settled (e.g.
  "thresholds move to `.checkup.yml`"), that becomes its own ADR and/or issue.
- Rejected explorations are kept (not deleted) so the reasoning survives.
