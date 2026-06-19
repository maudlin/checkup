# Plan 0001 — Lift the engine to a programmatic, plan→modules→execute architecture

> **Status: RFC / draft — to be stress-tested, not yet approved.** This is a plan
> to *pressure-test*, not a decision record. Nothing here is committed until the
> risk register (§7) and open questions (§9) are resolved and the abort criteria
> (§8) are accepted. Implementation is separate, phased issues filed only after
> this lands.

## 1. Why change

checkup grew organically and demand-first; it works, but the substrate now fights
the purpose we've converged on. The concrete strain (all observed, not theoretical):

- **Honesty is a convention, not an enforced property.** #80, #85 and #91 are the
  *same* bug — "absence / empty / error rendered as a verdict" — in three
  different sections, because each of **29 inline sections** hand-rolls
  run→parse→classify→write and **none are individually unit-tested** (the suite
  tests helpers and *mirrors* of the logic, not the sections). The contract
  (ADR-0002/0003) lives in prose, not a chokepoint that makes the bug impossible.
- **"The scan root is a hypothesis" is now core purpose, but the engine assumes
  one root.** Topology recovery (#78 Phase 2) needed cluster-wrapping, subshell
  avoidance to protect a *vestigial* score, `SLUG_NS` filename hacks and path
  re-prefixing — because assessment targets aren't first-class. **70 global-state
  mutations** are why a clean `for target × check` loop wasn't possible.
- **Logic has already leaked out of bash — into jq.** 23 jq `def`s in the renderer
  plus `detect-stacks.jq` / `complexity-merge.jq` / `complexity-csv.jq`. We picked
  a substitute language by accident, not design.
- **Substrate-scale correctness failures**: jq-in-single-quotes quoting traps (an
  apostrophe that closed a jq block; a `"/"` token), `set -e` fragility. These are
  language-at-scale problems, not logic errors.
- **Findings are too flat** (`{file,line,code,severity,message}`) to carry the
  provenance (dev/prod/transitive, public-by-design, confidence) that the
  calibration and exec-brief work need.

### North star (the purpose we're building to)

> A **deterministic, offline-capable** engine that **discovers** a codebase and
> emits an explicit **plan** of which checks to run over which **targets**, runs
> them through **loadable stack modules** that each carry the checks *and the
> opinion of good-vs-bad for that stack*, and for each emits an **honest
> measurement** — a finding, or a truthful "couldn't/didn't look", never an
> unearned verdict. The normalised records are the product; report, pillars, agent
> bundle and exec brief are **projections** of them. Opinionated about health,
> **never a gate** (ADR-0009).

## 2. Goals / non-goals

**Goals**
- Honesty enforced *structurally* — a check cannot report a pass/fail it didn't earn.
- Assessment **targets** are first-class (single root, workspace members, fan-out
  sub-packages — a list, not an assumption).
- **Stack modules**: loadable units carrying a stack's checks, tool wiring, and
  **thresholds + severity calibration** (good-vs-bad *for that stack*).
- **Plan as a first-class, inspectable, overridable artifact** (discover → decide → run).
- **Programmatic spine** that preserves bash's two real virtues: a **single
  artifact** and **zero container runtime deps** (→ Go, §4).
- Preserve: the `parsed/<slug>.json` **contract**, determinism, sealability
  (ADR-0008), and forkability-as-template (ADR-0005) via a documented module interface.

**Non-goals (explicit, to bound scope)**
- Not a deploy gate. Opinion expresses as bands/severity/focus, never pass/fail-the-build.
- **No new checks or features during the migration** (lift-and-shift, then improve).
- No change to the *semantics* of the parsed contract (the firewall — §3).
- No new runtime dependency surface (a scanner that rots is self-defeating).
- Not a from-scratch rewrite — strangler behind the contract (§5).

## 3. The invariant that makes this safe — the contract is the firewall

`parsed/<slug>.json`, `detection.json` and `checkup.json` are a stable interface.
**Freeze them**, then let bash (old) and Go (new) coexist behind them and migrate
piece by piece.

**Conformance harness (built first, §5 Phase 0):** golden-output fixtures of the
*current bash* across representative repos — single-package, undeclared fan-out,
polyglot, non-git, legacy — plus a **differ** that compares bash vs Go output per
check. Byte-identical where output is deterministic; semantic-diff where only
formatting differs. A check is "ported" only when it is conformance-green; bash is
deleted only then. This harness is the entire safety net — no Go ships before it.

## 4. Substrate: Go, and why

The work splits along the line where bash is good vs bad:
- **Glue / execution** (run a tool, capture stdout/stderr/exit) — bash is native; fine.
- **Logic over data structures** (the plan matrix, module contract,
  status-from-evidence, interpretation, provenance findings) — wants types, tests,
  real data. *This is most of the new architecture.*

**Go** is the choice because it keeps bash's virtues while fixing its costs:
- **Single static binary, zero container runtime deps** — preserves the minimal,
  sealable image and "one artifact you drop in" (the decisive property).
- First-class subprocess + JSON — checkup is "a CLI orchestrating CLIs, emitting JSON".
- Testable units, real types, no quoting traps.

**Alternatives considered (for stress-testing):**
- *Stay bash, disciplined (functions + registry + tests):* possible for the
  honesty refactor alone, but bash still can't hold the plan/module/finding data
  model, and we'd pay for two refactors. Rejected given the north star.
- *Python / Node:* reintroduce the exact dependency surface (pip / `node_modules`)
  checkup criticises — self-defeating for a scanner. Rejected.
- *Rust:* static binary too, but slower to author and steeper for forkers; overkill
  for glue. Rejected.

**Forkability note (honest trade):** "hack the one bash script" becomes "fork a Go
repo and add a module against a documented interface." Different, arguably better
for a tool accreting checks — but inline-hackability is genuinely lost. Mitigated
by making most checks *declarative data*, not code (§7 R3).

## 5. Strangler sequence — phased, each shippable, reversible, gated

Each phase ends green on: contract conformance differ (§3) + the existing test
suite + a real-repo smoke. Bash for a check is deleted only when its Go
replacement is conformance-green. The tool is never half-broken between phases.

- **Phase 0 — Freeze + characterise.** Write golden fixtures for current bash on
  the representative repo set; build the conformance differ. *No Go yet.* This is
  the safety net and the regression oracle for everything after.
- **Phase 1 — Go skeleton + the honest check-runner + 1 check.** One typed
  chokepoint that derives `Status` from `Evidence` (empty/127/unparseable →
  skip/failed, never pass), proven on one simple check (e.g. `codebase-stats` or
  `gitleaks`) emitting today's contract, conformance-green. A flag routes that
  check to Go; everything else stays bash. **Smallest end-to-end proof of the bet.**
- **Phase 2 — Universal module.** Port the stack-agnostic checks (secrets, SAST,
  stats, git-forensics) — no profile/threshold complexity. Establishes the module
  shape on easy mode.
- **Phase 3 — Discover→plan as an artifact.** Go owns `detection.json` + topology;
  emits an explicit execution plan (target × module × check × thresholds, with
  reasons and "detected-but-unassessed" entries). Honest-coverage becomes native.
- **Phase 4 — The `node` module.** Lift the biggest, gnarliest stack out of the
  monolith into the first *real* declarative module — including per-target
  execution (topology recovery becomes native, not a hack). The proof modules work.
- **Phase 5 — Interpretation/projection to Go.** Move pillars/focus/overall and the
  `checkup.json` bundle out of the renderer; the markdown renderer becomes a thin
  projector. Retire the 23 jq `def`s. (`checkup.json` stops being a byproduct of
  the *human* report.)
- **Phase 6 — Remaining stacks + retire bash + enrich.** dotnet overlay → module,
  then python/etc.; delete the bash orchestrator; enrich the finding schema
  (provenance) now that opinion is homed in modules → unlocks calibration.

## 6. Target architecture (concrete shape, for critique)

- `Plan`: output of discovery — a list of `{target, module, check, thresholds,
  reason}` plus `unassessed[]` (detected-but-no-module). Inspectable, overridable.
- `Module`: a manifest — `appliesWhen` (stack/topology predicates), `checks[]`,
  `thresholds`, `severityMap`, declared `tools[]` (pinned/verified). **Most checks
  are data** (command spec + how-to-parse); only gnarly parsers are code.
- `Check` unit: `Run(ctx, target) → Evidence`; the **framework** derives `Status`
  from `Evidence` — the single, typed, unit-tested honesty chokepoint.
- `Finding`: enriched — adds provenance (`scope: dev|prod|transitive`,
  `publicByDesign`, `confidence`) behind today's fields.
- **Projection**: `parsed → interpret (pillars/focus/overall) → render(md) +
  bundle(checkup.json)`. Interpretation leaves the renderer.
- **Sealability**: modules declare tools; engine runs network-denied; modules are
  declarative/vetted (no arbitrary egress) — ADR-0008 preserved.

## 7. Risk register (the core of the stress test)

| # | Risk | Mitigation | Abort/▲ signal |
|---|------|-----------|----------------|
| R1 | **Second-system effect** — rebuild + redesign at once | Contract frozen; **no new features** mid-migration; strangler | Scope creep into new checks → stop, re-baseline |
| R2 | **Lost parsing knowledge** (29 sections' hard-won tool quirks) | Port parsers **1:1 against golden fixtures** before refactoring them; differ catches drift | Conformance diffs that can't be explained |
| R3 | **Forkability regression** (Go less hackable than bash) | Declarative module format (data > code); first-class module-authoring docs; a `checks/`/`modules/` dir of manifests | A trivial module needs Go code to add |
| R4 | **Determinism / sealability regression** | Static binary; **network-denied CI**; no module egress; carry tool pinning | Any test needs network to pass |
| R5 | **Dependency-surface creep in Go** (ironic rot) | Minimal-dep policy (stdlib + tiny vetted set), vendored; dogfood checkup on itself | Dep count climbs / checkup flags itself |
| R6 | **Migration stalls half-done** (two engines forever) | Phase gates with explicit "bash deleted" criteria; a **kill-date** for coexistence; each phase independently valuable | A phase boundary slips twice |
| R7 | **Image/runtime/multi-arch regressions** | Fold into existing image work (#10/#8/#4); build matrix | Image size/arch budget breached |
| R8 | **Maintainer bandwidth** (lightly-staffed template) | Phases pausable without a broken tool; value banked each phase | Can't reach a phase gate in a reasonable window |
| R9 | **Interpretation drift** (jq→Go bands/focus scoring) | Golden fixtures on *interpretation outputs* too, not just per-check | overall/pillars differ from bash baseline |

## 8. Abort / pause criteria (decide these up front)

- After **Phase 1**, if the honest-runner + conformance harness *don't* feel
  materially safer/cleaner than bash → stop; the bet is wrong. (Phase 1 is
  deliberately a cheap, reversible spike.)
- If forkability (R3) can't be preserved — adding a stack needs real Go — →
  reconsider; the template ethos outranks the rewrite.
- If sealability/determinism (R4) regresses and can't be recovered → abort.
- Coexistence past the kill-date → freeze, ship what's green, re-plan.

## 9. Open questions (to resolve during stress test)

1. **Module expressiveness vs forkability** — how much opinion is pure data
   (thresholds, severity maps) vs an escape-hatch to code? Where's the line?
2. **Coexistence mechanism** — per-check routing flag? a manifest of "owned-by-Go"
   slugs? a wrapper that runs both and diffs during transition?
3. **Keep jq at all?** Go does JSON natively; do module-authored parsers still use
   jq (familiar, portable) or Go?
4. **Contract versioning** during migration (schemaVersion bumps while both engines write).
5. **Distribution** — binary + multi-arch image; how forkers build/extend.
6. **Where exactly does "good-vs-bad" knowledge get curated**, and what's the
   maintenance burden per module (it's an opinion + upkeep commitment, like the
   tech-viability table)?

## 10. How we'll stress-test *this plan*

- **Adversarial review** — independent passes that try to *break* the plan: "will
  the strangler actually converge, or trap us in dual-engine limbo?", "is the
  declarative module format expressive enough for a nasty polyglot?", "is Go right,
  or is disciplined bash enough?", "does this quietly become a gate?"
- **A throwaway spike** = Phase 1 itself (the honest-runner + one check + the
  differ). It de-risks the whole bet for a few days' work and is reversible.
- **A forkability test** — have someone add a trivial new stack module against the
  *proposed* interface before we commit to it.

## 11. Effort (rough, honest)

Weeks-to-months of part-time work, but **front-loaded with value and pausable**:
Phase 0+1 (the safety net + the proof) is the only "spend before payoff" stretch;
every phase after deletes bash and bankable risk. No phase requires the next.
EOF
)