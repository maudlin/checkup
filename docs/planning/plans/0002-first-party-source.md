# Plan 0002 — First-party source: propose → confirm → execute

> **Status: RFC / draft — to be stress-tested, not yet approved.** A mutable
> working plan, not an ADR. Tracking: #107. Reframed after a spike (§9) + two
> design corrections: the mechanism is **subtractive, not an allowlist** (§4), and
> checkup is **operator-driven, never a CI gate** (§2) — which makes a
> *propose → confirm → execute* flow the natural spine rather than a silent scan.

## 1. Problem

checkup's job is to front-load *the gestalt of the codebase this team owns*.
Generated and vendored code is, by definition, **not the team's maintenance
surface** — so measuring it doesn't just add noise, it *lies about the gestalt*.
Two failure modes, both seen on real repos:

- **Identity skew** — *dotCMS*: committed vendored JS made a Java CMS read
  **node-primary 41% (high confidence)**. By *lines* node leads (41% vs Java 31%);
  by *files* the Java tree dominates ~4:1 (`dotCMS/` 10,824 vs `core-web/` 2,943).
  Vendored/minified JS has huge lines-per-file, inflating the line share → wrong
  identity → wrong engine routing. (This is #78 Repro B.)
- **Measurement drowning** — *corvus-jsonschema*: ~90% of source files carry a
  generated marker + 7 vendored submodules → 14M "lines", a complexity read over
  machine output, and the lizard overflow/OOM we patched in #105 — *which only
  happened because we fed the engines 39k mostly-generated files.*

**Root cause (single):** checkup conflates *files in the repo* with *first-party
source*. The lizard robustness bugs (#105), the identity skew (#78 Repro B) and
the drowning are the same root cause.

**Principle (continuity with plan 0001):** *the file set is a hypothesis* — the
sibling of "*the scan root is a hypothesis*". Don't confuse what's on disk with
what the team owns. And — the key move — **don't resolve that hypothesis
silently: propose it, and let the operator confirm.**

## 2. The spine — propose → confirm → execute

checkup is **operator-driven and never a CI gate** (ADR-0009: "grade OK, gate
never"). There is essentially always a human auditing or an agent driving. That
removes the "must run unattended in a pipeline" constraint and makes the natural
front door for a *localiser* not a silent scan but a brief orientation:

1. **PROPOSE** — a cheap, deterministic pre-pass: enumerate the inventory,
   classify generated/vendored/test-corpus, detect topology, compute the
   lines-vs-files skew. Emit a **proposed scope**: the default first-party set
   (§4) + any *suggested narrowing* + a ready-to-edit `.checkup.yml`. This is
   where the **fuzzy signals become prompts** (§6), not after-the-fact apologies.
   `detection.json` already does ~90% of this work.
2. **CONFIRM / tighten** — the operator ratifies or narrows the net. Two
   modalities (§7): a human answers a prompt; an agent reads the proposal, writes
   the config and re-invokes; a hands-off run `--accept`s the safe proposal.
3. **EXECUTE** — measure the *agreed* first-party scope, deterministically,
   against the captured config.

The first thing checkup front-loads is therefore **"here's my read of what this
codebase *is* and what I'll measure — agree?"** — collaborative orientation, not a
gate. The subtractive engine (§4–§6) produces the *proposal*; the operator's
ratification is the *decision*; the captured config keeps the run *reproducible*.

## 3. Three sets, and where #75 left us

1. **On disk** (working tree)
2. **VCS-tracked** (`git ls-files`, `.gitignore`-aware) — where **#75** moved us
3. **First-party, human-maintained source** — what health is *actually about*

#75 took us (1)→(2). Committed generated/vendored code is VCS-tracked but **not**
first-party — the entire gap between (2) and (3). This plan is the (2)→(3) move,
*with a confirm step* so (3) is never inferred silently.

## 4. Why subtractive, not an allowlist (the include-vs-exclude decision)

The proposal is built by **exclusion** (start from everything, subtract
generated/vendored), not by an **include-list** of first-party roots. This is a
deliberate, settled choice:

- **No positive first-party signal exists.** Nobody marks hand-written code.
  First-party is defined by the *absence* of generated/vendored markers — whereas
  generated/vendored code *announces itself* (`DO NOT EDIT`/`@generated`, `vendor/`,
  submodules, `.min.js`, `linguist-generated`). The reliable signal is negative,
  so the mechanism must be subtractive. (GitHub Linguist — the canonical solver of
  "what code counts" — is subtractive for the same reason.)
- **The failure modes are asymmetric.** Exclude fails **loud-wrong** (measure some
  junk you have no rule for → visible weird hotspots/inflation). An allowlist fails
  **quiet-wrong** (first-party code that doesn't match an include rule is *silently
  dropped* → a confidently-clean report over missing code — the #85 false-clean).
  For a health tool, loud-wrong beats quiet-wrong. **#75 already settled this** by
  killing the `src server` include-guess for exactly this reason.
- **We already use include — on the axis where it's reliable.** The inventory is
  **include-by-type** (`SOURCE_EXT_RE` allowlists `.cs/.ts/.py/…`) **+
  exclude-by-provenance** (markers/conventions). Each axis matched to where its
  reliable signal lives. "Include or exclude?" is a false binary.
- **The allowlist's right home is operator ratification, not tool inference.**
  `CHECKUP_SRC_ROOTS` *is* an include-list — but asserted by someone who knows, not
  guessed. It maps to mode: **audit** (inherited repo — you can't know the
  first-party roots → must propose-by-exclusion) vs **tailored** (your repo — you
  can pre-assert them). The CONFIRM step (§2) is where exclusion-proposal meets
  human/agent inclusion-knowledge.
- **Framing is positive even though the mechanism is subtractive:** the report
  says *"N first-party files assessed; M generated, K vendored excluded"* — the
  best of both.

## 5. The classification is not binary — treat by category × check

| Category | maintain? | ship? | exclude from | keep in |
|---|---|---|---|---|
| **Generated** (codegen, ORM, protobuf, OpenAPI clients) | no (regenerate) | maybe | complexity, duplication, stats, **identity** | — |
| **Vendored** (copied 3rd-party, bundles) | no | **yes** | maintainability, **identity** | **security / supply-chain** (you ship it → its CVEs/secrets are *yours*) |
| **Test corpora / fixtures** (submodule'd suites) | no | no | almost everything | its *presence* is a signal |

Not a blanket exclude: security checks may opt vendored back in (the consuming
engine must know *why* a file was set aside).

## 6. Signal hierarchy — strong signals EXCLUDE, fuzzy signals PROMPT

The reliability of a signal decides whether the propose step **excludes on it
silently** or **surfaces it as a confirm-step prompt** — because over-exclusion
(silently dropping first-party code) is the dangerous direction.

**Auto-exclude in the proposal (high-confidence):**
1. **`.gitattributes` `linguist-generated`/`-vendored`** — author-declared.
   Resolve via `git check-attr` (let git parse it), not a hand-rolled parser.
2. **git submodules** (`.gitmodules`) — vendored by definition. *(Verify: the
   git tier's `git ls-files` already drops submodule gitlinks — §9 spike confirmed
   — so this mainly matters for the fd/find tiers.)*
3. **Generated-file markers** — `DO NOT EDIT`/`@generated`/`<auto-generated>`/
   `Code generated` in the first ~3 lines. Near-universal, deterministic; catches
   generated files *outside* convention dirs. **The big lever (§9).**
4. **Convention dirs + minified/snapshot suffixes** — already in
   `_inventory_excluded`.

**Surface as a CONFIRM prompt (fuzzy — too weak to drop on, perfect to ask on):**
5. **Lines-vs-files dominance disagreement** — line-leader ≠ file-leader ⇒ likely
   vendored/minified inflation. *(Catches dotCMS.)* → "node looks inflated by a few
   large files — treat as node-primary, or exclude `core-web/` bundles?"
6. **Single-directory concentration** — one dir holding a dominant file share. →
   "`benchmarks/` is 73% of files — assess it, or scope to `src/`?"

This is the reframe the *propose* step earns: signals too fuzzy to act on alone
were destined to be output-stage caveats; as **prompts before measurement** they
become precisely useful — *ask and resolve, don't flag and apologise.*

## 7. Two operator modalities (it's never CI, but it's not always a TTY)

- **Human at a terminal** — a blocking prompt is fine (and good): an
  `AskUserQuestion`-style choice from the proposal. Answer, run.
- **Agent driving headless** — agents consume *artifacts*, not TTY prompts. checkup
  emits the proposed scope (the plan + draft `.checkup.yml`); the agent ratifies/
  tightens (writes the config or `CHECKUP_SRC_ROOTS`) and re-invokes. It can even
  cheaply verify (read two files) before deciding — spending its tokens on the
  *right* scope instead of post-hoc reconstructing a drowned report (which is what
  the blind auditors had to do on corvus/dotCMS).
- **Hands-off** (a scheduled trend run) — `--accept` (or audit default) takes the
  safe proposal unchanged.

**Reproducibility:** the confirm step's decision is captured in `.checkup.yml` /
a scope record — so the run is repeatable, the audit re-runnable, and the agent's
choice inspectable. The prompt yields a *durable decision*, not a keystroke.

## 8. Where it lives + cost

All classification lives in **`lib/source-inventory.sh`** (the #75 chokepoint).
**Cost-ordered cheap→expensive** so the set shrinks before the only O(files) step:
conventions/suffixes (free) → `.gitattributes` (one `git check-attr`) → submodules
(one file) → **then** the generated-marker head-grep over what remains. The marker
pass reads ~3 lines/file and is **net-negative cost** — it shrinks the set every
downstream engine processes (corvus: ~39k → ~4k), *pre-empting* #105 rather than
patching it. Ceiling: if the post-cheap-exclude set is still huge, cap/skip the
marker pass and fall back to the confirm-step prompt.

**The coupling the spike exposed (§9): scc-based checks bypass the inventory.**
`codebase-stats`, detection-dominance and tech-viability call `scc` directly with
their own `--exclude-dir`. So excluding in the inventory alone leaves stats/identity
on the full tree — an internal contradiction ("3,982 assessed" vs "40,822 files").
**Phases 2 and 3 are coupled**; the real engineering is making scc honour the
inventory (feed it the file list, or derive exclude-globs from the classification),
which is the #78 Repro B work, now concretely scoped.

## 9. Spike findings (the reframe is evidence-based)

A gated (`CHECKUP_EXCLUDE_GENERATED`) generated-marker exclusion in the inventory,
run on corvus (`spike-first-party-source`):

| signal | before | after |
|---|---|---|
| files assessed (inventory) | 39,208 | **3,982** (first-party) |
| complexity | 6,620 "hotspots" over generated code | **1,213 over the real library** |
| duplication | cap-skipped (39k > limit) | **runs** (60.3% — likely the `src`/`src-v4` parallel trees) |
| lizard robustness | overflow + OOM (needed #105) | **no overflow, no cap hit** |
| `codebase-stats` | 14M lines | **still 14M** ← scc bypasses the inventory (§8) |

Learnings: (a) the seam works — inventory exclusion flows to coverage + every
lizard-based engine; (b) the payoff is large and pre-empts #105; (c) the marker
pass is the lever (90% hit; `.gitattributes` was 0 here); (d) **scc-based checks
must be routed through the inventory or the report self-contradicts** — the
genuine remaining work.

## 10. Honesty guards (non-negotiable)

- **Conservative:** auto-exclude only on §6.1–6.4; everything fuzzier becomes a
  prompt, never a silent drop. When unsure, include + ask.
- **Visible:** coverage reports excluded counts *by category*, and **"% generated/
  vendored" is a first-class signal** (a codegen-heavy project is a real finding).
- **Inspectable / overridable / reproducible:** the proposal and the confirmed
  scope are recorded; `.checkup.yml` / `CHECKUP_EXCLUDE` (#18) can force-include.
- **Check-aware:** security opts vendored back in (§5).

## 11. Phasing

- **Phase 1 — author-declared excludes.** `.gitattributes linguist-*` + submodules
  → exclude in the inventory + report. Near-zero cost, highest confidence.
- **Phase 2 — generated markers.** The head-grep pass (productionise the spike,
  cost-ordered last). *The corvus lever; pre-empts #105.*
- **Phase 3 — scc on the cleaned inventory.** Route stats/detection/tech-viability
  through the inventory (the §8 coupling). *Closes #78 Repro B; removes the
  coverage-vs-stats contradiction.* Add the "% generated/vendored" coverage signal.
  **Phases 2 and 3 ship together** (or the report self-contradicts).
- **Phase 4 — the PROPOSE pre-pass + CONFIRM.** `checkup --plan` emits the proposed
  scope + draft `.checkup.yml`; the human-prompt / agent-ratify / `--accept`
  modalities; the fuzzy signals (§6.5–6.6) as prompts. *Catches dotCMS.*
- **Phase 5 (later) — check-awareness.** Security opts vendored back in.

Phases 1–3 make the default *proposal* honest and the engines robust; Phase 4 adds
the confirm loop that resolves what the tool can't safely decide alone.

## 12. Open questions / risks

- **Over-exclusion (the dangerous direction).** Field-test the marker regex for
  false positives (a hand-written file quoting "DO NOT EDIT"). Anchor to the head;
  stay conservative; the confirm step is the backstop.
- **scc integration** — does scc take a file list cleanly, or must we derive
  exclude-globs? This is the crux of Phase 3 (§8).
- **`.gitattributes`** — use `git check-attr`, never a parser.
- **Test corpora not as submodules** (copied-in) — no universal tell; fall to
  convention dirs + the confirm prompt.
- **Cost ceiling** on huge trees (§8) — define cap + fallback-to-prompt.
- **Determinism** — keep the excluded-list output stable (sorted) for the #96
  byte-identical gates; the confirmed scope is captured so EXECUTE is reproducible.
- **Scope discipline** — CONFIRM stays "answer a question / edit a config + re-run",
  not a wizard. The moment it needs a blocking TTY read to function, it's wrong.
- **Interaction:** #75 (inventory), #78 Repro B (detection), #18 (override), #105
  (robustness symptoms of this root cause).

## 13. Acceptance targets (real before/after)

Two repos covering both failure modes and the full spine:

**corvus-jsonschema** — *measurement drowning; scan-stage curable* (spike-proven §9).
| | before | after (target) |
|---|---|---|
| files measured | ~39k (≈90% generated + submodules) | ~first-party (~4k) |
| complexity | 6,620 over generated | CCN of the *real* library (~1.2k) |
| stats / identity | 14M lines | first-party LOC (Phase 3) |
| lizard robustness | overflow/OOM (#105) | well under any cap |
| coverage | none | "≈90% generated, N submodules excluded" |

**dotCMS** — *identity skew; resolved at CONFIRM.*
| | before | after (target) |
|---|---|---|
| primary | **node (high)** — wrong | proposal flags "node 41% by line vs ~19% by file"; operator/agent confirms Java-primary or excludes `core-web/` bundles |

**Regression (must hold):** cx-* fixtures + a clean single-package source repo
(no generated/vendored bulk) byte-identical / unchanged; nothing first-party
silently dropped; the headless `--accept` path matches today's default behaviour
until Phases 1–3 change the *proposal*.

## 14. How we'll stress-test this plan

- **Adversarial review** (Morlock pass) on: the exclude-vs-prompt boundary (§6),
  over-exclusion guards (§10), the scc-coupling (§8), and "does CONFIRM stay
  non-wizard / does `--accept` keep the headless path honest?".
- **The two real targets** are the acceptance harness — before/after at each phase.
- Phase 1 + the §9 spike already de-risked the inventory-as-classifier seam; the
  scc seam (Phase 3) is the next thing to spike before committing.
