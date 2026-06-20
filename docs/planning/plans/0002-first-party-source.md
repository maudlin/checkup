# Plan 0002 — First-party source: scan-stage classification of generated/vendored code

> **Status: RFC / draft — to be stress-tested, not yet approved.** A mutable
> working plan, not an ADR. Nothing here is committed until the signal hierarchy,
> the exclude-vs-flag boundary (§4), the over-exclusion guards (§7) and the cost
> ceiling (§6) are resolved. Implementation is separate, phased issues filed only
> after this lands. Tracking: #107.

## 1. Problem

checkup's job is to front-load *the gestalt of the codebase this team owns*.
Generated and vendored code is, by definition, **not the team's maintenance
surface** — so measuring it doesn't just add noise, it *lies about the gestalt*.
We've now hit this from two directions on real repos:

- **Identity skew** — *dotCMS*: committed vendored JS made a Java CMS read
  **node-primary 41% (high confidence)**. By *lines* node leads (41% vs Java 31%);
  by *files* the Java tree dominates ~4:1 (`dotCMS/` 10,824 files vs `core-web/`
  2,943). Vendored/minified JS has huge lines-per-file, inflating the line share.
  Wrong identity → wrong engine routing. (This is #78 Repro B.)
- **Measurement drowning** — *corvus-jsonschema*: **~95% of source files carry a
  generated marker** (`DO NOT EDIT` / `@generated`) and there are **7 vendored
  submodules** (`JSON-Schema-Test-Suite`, …). Result: 14M "lines" / 40k files, a
  complexity read over machine output (6,620 "hotspots"), and the lizard
  overflow/OOM we had to patch (#105) — *which only happened because we fed the
  engines 39k mostly-generated files.*

**Root cause (single):** checkup conflates *files in the repo* with *first-party
source*. The lizard robustness bugs (#105), the dominance skew (#78 Repro B) and
the drowning are **the same root cause**.

**Principle (continuity with plan 0001):** *the file set is a hypothesis* — the
sibling of "*the scan root is a hypothesis*" (#78 topology). Don't confuse what's
on disk with what the team owns.

## 2. Three sets, and where #75 left us

1. **On disk** (working tree)
2. **VCS-tracked** (`git ls-files`, `.gitignore`-aware) — where **#75** moved us
3. **First-party, human-maintained source** — what health is *actually about*

#75 took us (1)→(2). Committed generated/vendored code is VCS-tracked but **not**
first-party — the entire gap between (2) and (3), and where both failures live.
This plan is the (2)→(3) move.

## 3. The classification is not binary — treat by category × check

"Generated", "vendored" and "test-corpus" want *different* treatment per check:

| Category | maintain? | ship? | exclude from | keep in |
|---|---|---|---|---|
| **Generated** (codegen, ORM, protobuf, OpenAPI clients) | no (regenerate) | maybe | complexity, duplication, stats, **identity** | — |
| **Vendored** (copied 3rd-party, bundles) | no | **yes** | maintainability, **identity** | **security / supply-chain** (you ship it → its CVEs/secrets are *yours*) |
| **Test corpora / fixtures** (submodule'd suites) | no | no | almost everything | its *presence* is a signal (a conformance project) |

Implication: this is **not** a blanket exclude. Vendored code's vulnerabilities
are the team's risk; its style isn't. The engine that consumes the inventory must
know *why* a file was excluded, so security can opt vendored back in (§5, §9).

## 4. Two tiers — ACT at the scan stage, FLAG at the output stage

The alarm belongs at the **scan stage** (the inventory builder, `lib/source-
inventory.sh` — the #75 chokepoint every engine reads from), because acting there
is the *cure* (stop measuring junk) not an *apology* (measure it, then caveat).
But what we may safely **exclude** vs only **flag** maps to signal reliability —
because **over-exclusion is the dangerous direction** (silently dropping
first-party code is a false-clean, the #85 sin in a new dress).

- **Scan stage — ACT (exclude from the inventory), on HIGH-confidence signals.**
  Author-declared or near-universal: safe to remove and report.
- **Output stage — FLAG (lower confidence / caveat), on FUZZY signals.** Aggregate
  heuristics too weak to silently exclude on; they catch what has no scan-time
  tell (dotCMS's markerless vendored bundles).

This boundary is the heart of the plan: *exclude only on strong evidence; flag on
the rest; never silently drop first-party code.*

## 5. Signal hierarchy (strongest first)

**Scan-stage (safe to exclude on):**
1. **`.gitattributes` `linguist-generated` / `linguist-vendored`** — repo-author
   declared; the strongest signal. Read via `git check-attr` (let git parse the
   patterns/precedence, don't reimplement `.gitattributes`):
   `git ls-files -z | git check-attr --stdin -z linguist-generated linguist-vendored`.
2. **git submodules** (`.gitmodules`) — vendored by definition.
   *Verify first (§9): if the inventory's git tier uses `git ls-files`, submodule
   contents are gitlinks and already absent — so this mainly matters for the
   `fd`/`find` fallback tiers and for sub-trees that are dirs-not-submodules.*
3. **Generated-file markers** — `^.{0,40}(DO NOT EDIT|@generated|<auto-generated>|
   Code generated .* DO NOT EDIT)` in the first ~2–3 lines. Near-universal (Go
   spec-level), deterministic, and catches generated files *outside* convention
   dirs (corvus's scattered `*.JsonSchema.cs`). This is the big accuracy win.
4. **Convention dirs + minified/snapshot suffixes** — already in
   `_inventory_excluded` (node_modules, dist, build, vendor, third_party,
   `*.min.js`, …). Keep; extend cautiously.

**Output-stage (only safe to flag on):**
5. **Lines-vs-files dominance disagreement** — when the line-share leader isn't
   the file-share leader, the line-heavy stack is inflated by high-lines-per-file
   (generated/vendored/minified) → lower `primaryConfidence`, emit a skew note.
   *Catches dotCMS.*
6. **Single-directory concentration** — one dir holding a dominant file share,
   esp. named test/bench/vendor/generated.

Ranking is deliberate: 1–4 are author-declared or near-universal → **exclude**;
5–6 are inference → **flag**.

## 6. Where it lives + cost

All scan-stage classification goes in **`lib/source-inventory.sh`** (one authority
→ detection, complexity, duplication, stats, hotspots all benefit from one change;
in particular detection reads the cleaned inventory, closing #78 Repro B).

**Cost discipline — order cheap→expensive so the set shrinks before the only
O(files) step:**
1. convention/suffix excludes (string match — free),
2. `.gitattributes` via one `git check-attr` batch (≈O(1) process),
3. submodule paths (one file),
4. **then** the generated-marker `head`-grep over *what remains*.

The marker pass reads only the first ~2 lines per file. It is **net-negative
cost**: it shrinks the measured set, so every downstream engine (lizard, scc,
jscpd) does far less work — corvus would drop from ~39k to ~2k files, *pre-empting*
the #105 overflow/OOM rather than patching it. Still, set a ceiling: if the
post-cheap-exclude set is still very large, cap/skip the marker pass and fall back
to the output-stage flag (honest-degrade, never hang).

## 7. Honesty guards (non-negotiable)

- **Conservative:** exclude only on the high-confidence signals (§5.1–5.4). When
  unsure, **include and flag** — never silently drop.
- **Visible:** the coverage block (#75) reports excluded counts *by category*
  ("excluded N generated, M vendored, K test-corpus"), and **"% of the tree that
  is generated/vendored" is promoted as a first-class signal** — a codegen-heavy
  project is itself a meaningful characterisation.
- **Inspectable / overridable:** the excluded list is recorded; `.checkup.yml` /
  `CHECKUP_EXCLUDE` (#18) can add or *force-include* paths (a forker who *wants*
  to assess generated code can).
- **Check-aware:** security/supply-chain checks may opt vendored back in (§3).

## 8. Phasing (each shippable; cheap+authoritative first)

- **Phase 1 — author-declared signals.** `.gitattributes linguist-*` (via
  `git check-attr`) + submodule paths → exclude from the inventory + report
  counts. Near-zero cost, highest confidence. *Catches corvus's submodules.*
- **Phase 2 — generated markers.** The `head`-grep pass (cost-ordered last) →
  exclude + report. *Catches corvus's ~95% generated bulk — the headline win, and
  pre-empts #105.*
- **Phase 3 — detection on the cleaned inventory.** Replace detection's raw-scc
  exclude list with the inventory's classification (or derive dominance from the
  inventory). *Closes #78 Repro B.* Add the coverage "% generated/vendored" signal.
- **Phase 4 — output-stage flags.** Lines-vs-files disagreement + dir
  concentration → lower `primaryConfidence` + skew note. *Catches dotCMS.*
- **Phase 5 (later) — check-awareness.** Security opts vendored back in.

Phases 1–2 are the cure for the corvus class; 3 fixes identity routing; 4 is the
fallback for the dotCMS class. Each is independently valuable and pausable.

## 9. Open questions / risks

- **Over-exclusion (the dangerous direction).** A wrongly-excluded first-party
  file is a silent false-clean. Mitigated by §7, but the marker regex needs
  field-testing for false positives (a hand-written file that quotes "DO NOT
  EDIT"). Anchor to the first lines + known phrasings; keep conservative.
- **Submodules may already be excluded** by the git tier (gitlinks). *Verify*
  before building Phase 1's submodule handling — it may only matter for fd/find.
- **`.gitattributes` correctness** — use `git check-attr`, never a hand-rolled
  parser (patterns, precedence, macros are subtle).
- **Test corpora that aren't submodules** (copied-in suites) have no universal
  tell — they fall to convention dirs + override, or stay measured + flagged.
- **Cost ceiling on huge trees** — define the cap and the fallback (§6).
- **Determinism** — all signals are deterministic; keep the excluded-list output
  stable (sorted) for the #96 byte-identical gates.
- **Interaction:** #75 (the inventory), #78 Repro B (detection), #18
  (CHECKUP_EXCLUDE override), #105 (robustness symptoms of this root cause).

## 10. Acceptance targets (real before/after)

Two repos that exercise *both* failure modes and *both* tiers:

**corvus-jsonschema** — *measurement drowning; scan-stage curable.*
| | before | after (target) |
|---|---|---|
| files measured | ~39k (≈95% generated + submodules) | ~first-party only (~thousands) |
| complexity | 6,620 "hotspots" over generated code | CCN of the *real* library |
| lizard robustness | overflow/OOM (needed #105 cap) | well under any cap — no degrade |
| coverage signal | none | "≈95% generated, N submodules excluded" |

**dotCMS** — *identity skew; output-stage flag.*
| | before | after (target) |
|---|---|---|
| primary | **node (high)** — wrong | node **low confidence** + skew note |
| skew signal | none | "node 41% by line vs ~19% by file — likely vendored/minified" |

**Regression (must hold):** the cx-* fixtures and a clean single-package source
repo (no generated/vendored bulk) byte-identical / unchanged; nothing first-party
silently dropped.

## 11. How we'll stress-test this plan

- **Adversarial review** (Morlock pass) on the exclude-vs-flag boundary and the
  over-exclusion guards specifically — "show me a first-party file this wrongly
  drops", "show me the cost blowing up on a huge tree", "show me a generated repo
  with no marker/submodule/attribute that still drowns".
- **The two real targets** are the acceptance harness — run before/after on
  corvus + dotCMS at each phase.
- Phase 1 is a cheap spike (two file reads) that de-risks the inventory-as-
  classifier seam before the marker pass.
