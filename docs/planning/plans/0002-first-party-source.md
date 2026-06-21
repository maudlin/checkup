# Plan 0002 — First-party source: route the engines through the inventory

> **Status: RFC / draft — stress-tested, not yet approved.** A mutable working
> plan, not an ADR. Tracking: #107. Reframed twice: first around
> *propose → confirm → execute*; then **descoped** after a Morlock adversarial pass
> (§15) + an scc-seam spike (§9) showed the load-bearing value is *routing the
> measurement engines through the inventory*, and the proposed confirm "spine" was
> scaffolding the problems don't pay for. The mechanism is **subtractive, not an
> allowlist** (§4); checkup is **operator-driven, never a CI gate** (§2).

## 1. Problem

checkup's job is to front-load *the gestalt of the codebase this team owns*.
Generated and vendored code is, by definition, **not the team's maintenance
surface** — so measuring it doesn't just add noise, it *lies about the gestalt*.
Two failure modes, both measured on real public repos (§9, §13):

- **Measurement drowning** — *corvus-jsonschema*: ~87% of files carry a generated
  marker → **14.09M "lines"** and a complexity read over machine output. The
  lizard overflow/OOM we patched in #105 *only happened because we fed the engines
  39k mostly-generated files.* (Identity was never wrong here — corvus reads
  correctly as dotnet; the lie is purely in the *volume*.)
- **Identity skew** — *dotCMS*: **flat-vendored** third-party JS (ace, dojo,
  tinymce, scriptaculous, …) committed under `dotCMS/src/main/webapp/html/js`
  (721k lines / 4,150 files, no `vendor/` dir, no marker, not minified) makes a
  Java CMS read **node-primary 41% (high confidence)** → wrong engine routing.
  Excluding that one vendored tree flips identity to the correct **java 44%**
  (§9). *(This is #78 Repro B — and the spike corrected our earlier diagnosis:
  it is not a "4:1 by files" line-inflation artefact, it is real bytes of
  copied-in library code that no marker announces.)*

**Root cause (single):** checkup conflates *files in the repo* with *first-party
source*. The lizard robustness bugs (#105), the identity skew (#78 Repro B) and
the drowning are the same root cause.

**Principle (continuity with plan 0001):** *the file set is a hypothesis* — the
sibling of "*the scan root is a hypothesis*". Don't confuse what's on disk with
what the team owns.

## 2. What this plan is — and what it deliberately is *not*

checkup is **operator-driven and never a CI gate** (ADR-0009: "grade OK, gate
never"), and a **fork-and-tailor template** (AGENTS.md). There is essentially
always a human auditing or an agent driving. That shapes two decisions:

**What this plan IS — make the engines honour the inventory.** The single
load-bearing change is that the measurement engines (lizard *and scc*) assess the
**first-party inventory**, not the whole working tree. The inventory
(`lib/source-inventory.sh`, #75) is already the chokepoint for the lizard-based
engines; the gap is that the **scc-based engines bypass it** (§8). Closing that
gap is the genuinely-justified core — it is the *only* thing the existing config
levers (`CHECKUP_SRC_ROOTS`, `CHECKUP_EXCLUDE`, `.checkup.yml`) **cannot already
do** (§15, premise check).

**What this plan is NOT — a propose/confirm/execute "spine".** An earlier draft
wrapped the front door in a `--plan`/`--accept`/config-writer state machine with
human/agent/hands-off modalities. The Morlock pass (§15) and the spike (§9) killed
it: it re-implements the loop that *already exists* (operator reads report → edits
`.checkup.yml` → re-runs), it is wizard-shaped (the old §12 even carried a "don't
become a wizard" guard — a tell), and it dragged in an `--accept` honesty hole
(silently auto-excluding with nobody in the loop). **The operator IS the confirm
step.** What the tool owes is *honest defaults + a loud, specific banner + the
existing override seam* — not a negotiation protocol. (If a `--plan` emitter is
ever wanted, it ships later as a standalone, deletable sub-command that prints a
draft config to stdout — never a mode the main scan depends on.)

## 3. Three sets, and where #75 left us

1. **On disk** (working tree)
2. **VCS-tracked** (`git ls-files`, `.gitignore`-aware) — where **#75** moved us
3. **First-party, human-maintained source** — what health is *actually about*

#75 took us (1)→(2). Committed generated/vendored code is VCS-tracked but **not**
first-party — the entire gap between (2) and (3). This plan is the (2)→(3) move:
classify in the inventory, and make **every** engine — lizard *and scc* — measure
(3) instead of (2).

## 4. Why subtractive, not an allowlist (the include-vs-exclude decision)

The first-party set is built by **exclusion** (start from everything, subtract
generated/vendored), not by an **include-list** of first-party roots. Settled:

- **No positive first-party signal exists.** Nobody marks hand-written code.
  First-party is defined by the *absence* of generated/vendored markers — whereas
  generated/vendored code *announces itself* (`@generated`, `linguist-vendored`,
  submodules, `.min.js`). The reliable signal is negative, so the mechanism is
  subtractive. (GitHub Linguist — the canonical solver of "what code counts" — is
  subtractive for the same reason.)
- **The failure asymmetry is real but cuts BOTH ways (corrected — §15.M1).** The
  earlier draft claimed "exclude fails loud-wrong, allowlist fails quiet-wrong"
  and stopped there. That's only half true: **under**-exclusion is loud-wrong
  (you measure junk → visible weird hotspots — recoverable), but **over**-exclusion
  is **quiet-wrong** (a wrong rule silently drops first-party code → a confidently
  clean report over missing code — the #85 false-clean). The marker grep is itself
  a tiny include-list-of-exclusions with a quiet-wrong tail. So the asymmetry does
  **not** make exclusion automatically safe. It is made safe only by **(a)
  high-precision rules and (b) loudness — every auto-exclude must ENUMERATE the
  files it drops (sorted), never just count them.** Loudness is what converts
  over-exclusion back from quiet-wrong to loud-wrong. This is now a hard guard
  (§10), not a nicety.
- **We already use include — on the axis where it's reliable.** The inventory is
  **include-by-type** (`SOURCE_EXT_RE` allowlists `.cs/.ts/.py/…`) **+
  exclude-by-provenance**. "Include or exclude?" is a false binary.
- **The allowlist's right home is operator ratification.** `CHECKUP_SRC_ROOTS`
  *is* an include-list — asserted by someone who knows, not guessed. It maps to
  mode: **audit** (inherited repo → propose-by-exclusion) vs **tailored** (your
  repo → pre-assert the roots).
- **Framing stays positive though the mechanism is subtractive:** *"N first-party
  files assessed; M generated, K vendored excluded."*

## 5. The classification is not binary — treat by category × check

| Category | maintain? | ship? | exclude from | keep in |
|---|---|---|---|---|
| **Generated** (codegen, ORM, protobuf, OpenAPI clients) | no (regenerate) | maybe | complexity, duplication, stats, **identity** | — |
| **Vendored** (copied 3rd-party, bundles) | no | **yes** | maintainability, **identity** | **security / supply-chain** (you ship it → its CVEs/secrets are *yours*) |
| **Test corpora / fixtures** (submodule'd suites) | no | no | almost everything | its *presence* is a signal |
| **Hand-owned-but-conventional** (`migrations/`, `snapshots/`) | **yes** | yes | duplication, complexity (noisy) | **churn, bug-density, coverage, stats** |

Not a blanket exclude. Two consequences the current code violates and this plan
fixes:
- **Security opts vendored back in** — the consuming engine must know *why* a file
  was set aside.
- **`migrations/` and `snapshots/` are first-party** (Rails/Django/Flyway
  migrations are hand-written and high-bug-density). The current
  `_inventory_excluded` drops them from the inventory *entirely* — wrong. Demote
  them to **per-check** exclusion (out of duplication/complexity, kept for
  churn/coverage/stats), per §15.M1. Likewise gate `vendor/`/`third_party/`
  directory excludes on corroboration to avoid eating a first-party package
  literally named `vendor`/`snapshots`.

## 6. Signal hierarchy — strong signals EXCLUDE (loudly), fuzzy signals BANNER

Signal reliability decides whether the inventory **excludes on it** or **surfaces
it as a banner caveat** (with the exact config snippet to act on). Over-exclusion
is the dangerous direction, so the bar for silent exclusion is high — *and every
exclusion is enumerated* (§10).

**Auto-exclude in the inventory (high-confidence):**
1. **`.gitattributes` `linguist-generated`/`-vendored`** — author-declared.
   Resolve via `git check-attr` (let git parse it), not a hand-rolled parser.
2. **git submodules** (`.gitmodules`) — vendored by definition. *(Spike note §9:
   `git ls-files` already drops submodule gitlinks and they're usually un-checked-out
   on disk, so this mainly matters for the fd/find tiers and for labelling.)*
3. **Generated-file markers — as BANNER-SHAPED regexes, not bare substrings**
   (corrected — §15.M1). The earlier draft used loose case-insensitive substrings
   (`@generated`, `Code generated`, `DO NOT EDIT`) that fire on first-party code
   which merely *mentions* them (codegen tooling's own source, Flow/Relay repos,
   lint configs) or carries them legitimately (hand-owned IaC: `# DO NOT EDIT —
   managed by Terraform`; hand-written migrations). Tighten to:
   - Go's canonical full line: `^//\s*Code generated .* DO NOT EDIT\.\s*$`
   - `@generated` / `<auto-generated` only inside a comment leader at line start
     (`^\s*(//|#|/\*|\*|<!--)\s*@generated\b`).
   - **Bare `DO NOT EDIT` alone is demoted to the banner tier** (§6.5) — too weak
     to drop on; auto-exclude only when it co-occurs with a structured marker.
   Scan the first ~2KB (not "3 physical lines" — shebang+license headers push real
   markers down), `LC_ALL=C`, case-sensitive for the banner-shaped tokens.
   **The big lever** (§9: 87% of corvus) — but the precision tightening above is
   what makes it safe.
4. **Convention dirs + minified/snapshot suffixes** — already in
   `_inventory_excluded`, minus the `migrations/`/`snapshots/` demotion (§5).

**Surface as a BANNER caveat (fuzzy — too weak to drop on):**
5. **Single-directory concentration** — one dir holding a dominant code share.
   **This is the dotCMS detector** (§9: `webapp/html/js` = 25% of code in one
   tree) and the right signal for **flat-vendored** code that no marker announces.
   → *"`dotCMS/src/main/webapp/html/js` is 25% of all code (4,150 files, avg JS) —
   looks vendored. To exclude: `CHECKUP_EXCLUDE='dotCMS/src/main/webapp/html/js/*'`
   or add it to `.checkup.yml`."*
6. **Lines-vs-files dominance disagreement** — line-leader ≠ file-leader ⇒
   possible minified inflation. *Kept, but demoted in importance: the spike (§9)
   showed it does NOT fire on dotCMS (node/java file counts and avg lines/file are
   ~equal), so it is not the identity-skew detector we thought. It catches a
   narrower case (genuinely minified bundles).* 
7. **% generated / vendored** — a codegen-heavy project is itself a real finding
   (§10), printed as a first-class signal.

The banner *names the directory/finding and prints the one-line fix* — honest and
configurable, not a prompt to answer. This is the descoped replacement for the old
"confirm" tier (§2, §15).

## 7. Operator modalities (it's never CI, but it's not always a TTY)

No new protocol — the existing seam, surfaced louder:
- **Human at a terminal** — reads the banner, edits `.checkup.yml` /
  `CHECKUP_EXCLUDE`, re-runs. (An `AskUserQuestion`-style prompt may be added
  *later* as sugar; it is not required and not on the critical path.)
- **Agent driving** — consumes the banner + `detection.json` artefacts (the
  enumerated excluded lists, the concentration finding, the fix snippet), writes
  the config and re-invokes. It already can; nothing new is owed.
- **Hands-off** — runs with honest defaults (Phase 1 author-declared excludes
  always on; the marker pass gated, §11). No `--accept` that silently changes the
  default behaviour behind an unattended run (§15.M3).

**Reproducibility (honest definition — §15.M3):** EXECUTE is byte-identical given
identical *{repo state, resolved config}* (the #96 property). The excluded set is
**re-derived every run** (intent-pinned in `.checkup.yml`, e.g. "exclude
generated"), not frozen as a stale path-list — and the derived set is written to
`raw/` (sorted) as an inspectable audit artefact. "Reproducible" means *same
inputs → same output*, explicitly **not** "frozen exclude-list".

## 8. The crux this plan exists to fix: scc bypasses the inventory

`codebase-stats`, detection-dominance (`detect-stacks.jq`) and tech-viability call
`scc` directly (5 sites: `bin/checkup.sh:243,1647,1668,~2049,~3352`), each with a
hardcoded `--exclude-dir=node_modules,.svelte-kit,coverage,.prisma,build,dist`,
consulting **neither the inventory nor `CHECKUP_EXCLUDE`**. So excluding in the
inventory alone leaves stats/identity on the whole tree — an internal
contradiction ("3,982 assessed" vs "40,822 files / 14M lines" in one report). The
`.checkup.yml.example` itself admits the gap ("cross-scanner excludes tracked
separately"). **This is the part no existing lever can fix, and it drives identity
/ engine-routing — the highest-leverage wrong answer checkup can give.**

**The fix (spike-proven — §9): post-filter `scc --by-file`, re-aggregate.**
scc has no file-list/stdin input, and a dir/regex exclude model *cannot* express
"drop these scattered marker-classified files but keep their siblings" (corvus
emits `*.JsonSchema.cs` next to hand-written `.cs` in the same dirs). So we do
**not** feed scc a file list and we do **not** derive exclude-globs. Instead:

```
scc --by-file --format json   →   [ .[].Files[] ]   →   keep .Location ∈ inventory
   →   group_by(.Language) | {Name, Code, Count, Complexity, Lines}
```

- scc walks the tree **once** (corvus 1.2s, dotCMS 0.6s) and we filter its output —
  so the **xargs/argv overflow is moot** (we never pass files *to* scc; §15.M2 #1
  applies only to the rejected positional-args route).
- Re-aggregation is **faithful** (Σ by-file code = the legacy total exactly) and
  **order-invariant**, so `codebase-stats` (Total + top-3) and `detect-stacks.jq`
  (`[{Name,Code}]`) are reconstructed unchanged and **deterministically with no
  sort**. *(Per-file-ORDER consumers — the complexity hotspot list, the Tornhill
  CSV — still need a total-order key `sort_by(-.ccn, .file)`; that is a separate,
  pre-existing #96 latent bug surfaced by §15.M2 #2, fixed alongside.)*
- Do **not** use scc's native `--no-gen` — it's a *different* classifier than the
  inventory and would re-introduce a (smaller, subtler) coverage-vs-stats
  divergence (§15.M2 #4). The inventory is the single authority.

## 9. Spike evidence (the reframe is measured, not asserted)

scc-seam spike (scc 3.7.0; post-filter `--by-file` route; corvus + dotCMS):

**corvus-jsonschema — measurement drowning, scan-stage curable:**
| signal | whole tree | first-party (re-aggregated) |
|---|---|---|
| files | 40,822 | **5,191** |
| code (lines) | 14,088,880 | **1,210,563** |
| complexity | 814,095 | **49,490** |
| identity | dotnet 97% | **dotnet 73%** (still correct; honest share) |
| generated files caught (markers) | — | **35,631** |
| submodules on disk | 0 (gitlinks, un-checked-out) | — |

**dotCMS — identity skew from flat-vendored JS:**
| signal | whole tree | drop generated+minified | drop the vendored JS dir |
|---|---|---|---|
| identity | **node 41% / java 31%** (wrong) | node 41% / java 31% (unchanged) | **java 44% / node 20%** (correct) |

Learnings: (a) the post-filter seam works for stats *and* identity; (b) corvus is
pure drowning (markers do it); (c) **dotCMS is markerless flat-vendored** —
generated/minified detection does *nothing* (337 files), only excluding the named
vendored dir flips it; (d) the detector for (c) is **single-dir concentration**
(§6.5), **not** lines-vs-files (§6.6 doesn't fire — file counts ~equal); (e) the
exclusion that fixes dotCMS is exactly a `CHECKUP_EXCLUDE` / `.checkup.yml` line —
so once scc honours those (§8), an operator fixes it in one line, no auto-magic.

## 10. Honesty guards (non-negotiable)

- **Loud, not counted (§15.M1).** Every auto-exclude **enumerates** the dropped
  files (sorted) into `raw/` + `detection.json`, with a one-line console summary.
  A count is quiet-wrong; an enumerated, greppable list is loud-wrong. This is what
  *earns* the subtractive design (§4).
- **Bounded on the unattended path (§15.M1/M3).** If marker-exclusion exceeds a
  high share of files (e.g. ≥50%), say so prominently — that's either corvus
  (fine, and now visible) or a catastrophic misclassification (must be visible).
- **Conservative:** auto-exclude only on §6.1–6.4 (banner-shaped markers);
  everything fuzzier is a banner caveat, never a silent drop. When unsure, include.
- **Visible:** coverage reports excluded counts **by category**; **"% generated/
  vendored" is a first-class signal**.
- **Inspectable / overridable / reproducible:** the derived scope is recorded
  (sorted) and re-derived each run (§7); `.checkup.yml` / `CHECKUP_EXCLUDE` (#18)
  force-include or add excludes.
- **Check-aware:** security opts vendored back in (§5).

## 11. Phasing (reordered around the load-bearing core)

- **Phase 1 — route scc through the inventory + `CHECKUP_EXCLUDE`** *(the spine;
  was Phase 3).* Fix the 5 hardcoded scc sites to consume the post-filter
  `--by-file` re-aggregation (§8); add a `.checkup.yml` `exclude:` key (close the
  example file's admitted gap); add the total-order sort fix for per-file scc
  consumers. *Alone this lets any operator fix dotCMS's identity + the 14M-lines
  stat with one config line, and removes the coverage-vs-stats contradiction.*
  Includes **author-declared excludes** (`.gitattributes linguist-*` + submodules)
  applied to **both** the inventory and scc — near-zero maintenance, no regex,
  highest confidence.
- **Phase 2 — generated markers (banner-shaped, gated, enumerated).** Productionise
  the spike behind `CHECKUP_EXCLUDE_GENERATED`, with the tightened regexes (§6.3)
  and loud enumeration (§10). *The corvus lever; pre-empts #105.* **Hard-gated to
  Phase 1 — they ship in one switch / one PR** (§15.M2 #6): Phase 2 *without* the
  scc routing makes the report *more* self-contradictory than today (lizard 5k vs
  scc 14M), so it must never land half-on.
- **Phase 3 — the honest banner.** Coverage line ("N first-party; M generated, K
  vendored, L submodules excluded; X% generated") + the fuzzy caveats (§6.5–6.6)
  *with the inline fix-it config snippet*. *Catches dotCMS without any auto-magic.*
- **Phase 4 (later, optional) — check-awareness + sugar.** Security opts vendored
  back in (§5); the per-check `migrations/`/`snapshots/` demotion (§5); *if wanted*,
  a standalone `--plan` config-emitter (§2) — never a mode the scan depends on.

Phases 1–3 make the default measurement honest and the engines robust; the old
"propose/confirm spine" is gone — replaced by honest defaults + the banner + the
existing override loop.

## 12. Open questions / risks

- **Over-exclusion (the dangerous direction).** Field-test the tightened marker
  regexes for false positives; enumeration (§10) is the backstop that keeps a
  miss loud.
- **Markerless flat-vendored code (dotCMS class).** Not auto-excludable by design;
  relies on the concentration banner (§6.5) + operator exclude. Accept this limit
  explicitly — don't let corvus's marker win imply general coverage.
- **scc cost on huge trees.** `--by-file` walks the whole tree (corvus 1.2s) — fine
  at observed scale; if a tree is pathological, the marker pass shrinks the *lizard*
  load regardless, and scc stays a single concurrent walk.
- **Determinism** — aggregation is order-invariant (proven §9); add `sort_by(-.ccn,
  .file)` for per-file scc consumers; `LC_ALL=C` for the marker grep.
- **`.gitattributes`** — use `git check-attr`, never a parser.
- **Interaction:** #75 (inventory), #78 Repro B (detection), #18 (override), #105
  (robustness symptoms of this root cause).

## 13. Acceptance targets (real before/after — measured §9)

**corvus-jsonschema** — *measurement drowning; scan-stage curable.*
| | before | after (target) |
|---|---|---|
| files measured | 40,822 (~87% generated) | **~5,191 first-party** |
| code | 14.09M | **~1.21M** |
| complexity | 814,095 over generated | **~49,490 over the real library** |
| identity | dotnet 97% | dotnet (honest share ~73%) |
| lizard robustness | overflow/OOM (#105) | well under any cap |
| coverage | none | "≈87% generated, N submodules excluded" (enumerated) |

**dotCMS** — *identity skew from flat-vendored JS; fixed by the banner + one config line.*
| | before | after (target) |
|---|---|---|
| identity | **node 41% (high)** — wrong | banner flags `webapp/html/js` (25% of code, vendored-looking) + prints the exclude snippet; with it applied, **java 44% / node 20%** (correct) |

**Regression (must hold):** cx-* fixtures + a clean single-package source repo
(no generated/vendored bulk) byte-identical / unchanged; nothing first-party
silently dropped (enumeration proves it); a default run's scc numbers match the
inventory's coverage numbers (no self-contradiction).

## 14. Stress-test method (how this plan was hardened)

- **Adversarial review (Morlock pass, §15)** — 4 reviewers attacked the
  exclude-vs-prompt boundary, the scc coupling, the propose/confirm spine, and the
  premise/opportunity-cost. Findings folded below.
- **The two real targets** are the acceptance harness — before/after measured (§9).
- The scc seam (the Phase-1 crux) is now spike-proven, not a hypothesis.

## 15. Morlock findings (resolved into the plan above)

**M1 — over-exclusion boundary.** *(folded: §4, §6.3, §10)* The bare-substring
markers were far looser than the canonical banners and would drop first-party
code that documents/owns the markers (codegen tooling, Flow/Relay, IaC `DO NOT
EDIT`, hand-written migrations). The §4 "exclude fails loud-wrong" claim was false
for over-exclusion (it fails quiet-wrong). **Resolved:** banner-shaped regexes;
bare `DO NOT EDIT` demoted; **enumerate every drop (loud, not counted)**;
`migrations/`/`snapshots/` demoted to per-check. *Verdict folded — strategy sound
iff exclusions are loud.*

**M2 — scc coupling (Phase 3 crux).** *(folded: §8, §11, §12)* **Verdict:
tractable, not fatal.** The post-filter `--by-file` route is the answer; exclude-
globs structurally can't express scattered codegen; `--no-gen` is a divergent
classifier. Operational cracks: xargs batch-split (**moot** for the by-file route),
non-deterministic per-file order (fixed with a total-order key), and — the one
plan change — **Phase 2 must be hard-gated to the scc routing** or it manufactures
a contradiction that doesn't exist today.

**M3 — propose→confirm→execute spine.** *(folded: §2, §7, §11)* **Verdict:
over-built.** Phases 1–3 solve both §1 failures alone; the spine re-implements the
operator's edit-config-and-re-run loop and drags in the dangerous `--accept`
honesty hole. **Resolved:** spine removed; replaced by honest defaults + a loud
banner + the existing override seam; "reproducible" defined honestly (re-derive,
don't freeze); any `--plan` emitter deferred to optional standalone sugar.

**M4 — premise & opportunity cost.** *(folded: §2, §8, §11)* **Verdict: descope
~60%; the justified core is the scc seam.** Config already does the lizard axis
(`CHECKUP_EXCLUDE` gets corvus 39k→4k today); the *only* thing config can't do is
route scc/identity/stats through the inventory. **Resolved:** scc seam promoted to
Phase 1; the marker classifier kept but gated/opt-in (a feeder, not the headline);
the spine cut for a banner. The plan now leads with the part that earns its keep.
