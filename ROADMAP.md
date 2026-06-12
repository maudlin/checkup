# Checkup roadmap & design notes

This is the durable design record for where Checkup is going — written so a
future contributor (human or AI agent) can pick up the next phase without
re-deriving the architecture. The contract in `README.md` is the stable
surface; this document is the plan.

## Vision

Checkup is two things at once:

1. A **whole-repository examination** — health, quality, security, hygiene —
   that a team runs (pre-PR or in CI) to track and trend issues.
2. A **portable audit** an external party (or auditor) points at a brownfield
   to surface improvement priorities or flag risks — e.g. tech due diligence.

The design bet: **bake a broad diagnostic toolbelt and make it trivial to grab
and run; leave the last-mile tailoring to good-enough auto-detection plus an
agent (or human).** We don't aim for a perfectly self-configuring tool. We aim
for a capable substrate with clean seams, so adapting it to a specific repo is
cheap once the tools are already present and the contract is documented.

## Why the container is the centre of gravity

The friction in Checkup today is the Tier-2 tool list: full coverage needs
shellcheck, yamllint, hadolint, gitleaks, scc, semgrep and a language
toolchain installed. Every check degrades gracefully when its tool is absent
(honest, but partial). A container removes the install problem entirely — and,
crucially, it becomes the **distribution vehicle for tool coverage**. Adding a
stack (.NET, Python, Go, Rust) stops being "make every user install an
SDK/analyzer matrix on their host" and becomes "we install it once, in a
layer." Choosing an image tag is a far gentler instruction than running eight
per-OS installers.

## Image architecture (layered, uniform invocation)

- **`checkup-core`** _(Phase 1 — built)_ — orchestrator + helpers + the
  genuinely universal, any-repo tools: git, jq, gitleaks, semgrep, shellcheck,
  yamllint, hadolint, scc. Runs the cross-stack security / hygiene / forensics
  checks on any codebase. No language toolchain.
- **stack overlays** _(Phase 3)_ — `checkup-node`, `checkup-dotnet`,
  `checkup-python`, … each `FROM checkup-core`, adding that stack's toolchain
  and wiring the project-built checks (build / test / lint / coverage / audit)
  for it.
- **`checkup-everything`** _(optional)_ — core + all overlays. Larger, but one
  image scans a polyglot or unknown repo. Especially useful for DD across
  multiple unknown-stack targets.

Invocation stays identical across tags — only the tag changes:

```bash
docker run --rm -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup-<tag> /src
```

So "where to run" collapses to a one-line chooser: _Node → `checkup-node`;
mixed/unknown → `checkup-everything`; security+hygiene only → `checkup-core`._

**Prebuilt tags are the default path.** The well-commented, layered Dockerfile
is the escape hatch for the size- or security-constrained who want a slim
custom image — not the primary route. Making people build images would
reintroduce exactly the install friction the container removes.

## The keystone refactor: command profiles (Phase 2)

Today the project-built checks hardcode `npm run typecheck`, `npm test`, etc.
Multi-stack only stays cheap if adding .NET is "install tools + drop a
profile," not "fork and maintain a parallel `checkup.sh`." So generalise the
npm-script contract into a **command profile**:

- `checkup.sh` reads the project-built commands from a profile
  (`profiles/<stack>.sh`, or `CHECKUP_CMD_TEST` / `CHECKUP_CMD_BUILD` / … env).
- Each overlay installs its tools and selects its profile.
- The cross-stack checks stay byte-identical everywhere.

The README already documents the per-language command mapping (dotnet
build/test/format, go test, cargo, …). This turns that table from "edit the
source" into "pick a profile." It is the change that makes a new stack a small,
isolated contribution.

Already started: the **semgrep check has a direct fallback** — if the
`npm run quality:security` wiring is absent but `semgrep` is on PATH, it runs
`semgrep scan` directly. This is the pattern profiles generalise; it's why
`checkup-core` can run SAST on a non-Node repo today.

## Auto-detection (Phase 2)

Make `checkup-everything` / overlays do the right thing with zero config:

- **Manifests drive _how to build/test_** (most reliable): `package.json`
  (+ read its `scripts`), `*.sln` / `*.csproj`, `go.mod`, `pyproject.toml` /
  `setup.py`, `Cargo.toml`, `Dockerfile*`, `.github/workflows/`. These decide
  which project-built checks light up and with what command/profile.
- **`scc` drives _which language linters are worth running_** + polyglot
  awareness. It's already baked in (the codebase-stats check), so reusing it is
  free, and it catches the "60% Python but no `pyproject`" case manifests miss.
- **Cross-stack checks always run** regardless of detection (gitleaks, semgrep,
  scc-stats, git-forensics).
- **The plan is logged and overridable, never silently wrong.** It prints
  "detected: dotnet (3 csproj) + node; enabling …; skipping go (no go.mod)" —
  matching Checkup's existing graceful-degrade ethos. The override seam is a
  repo-local `.checkup.yml` (or env) the detector consults first.

## The agent-tailoring seam

Because every tool is present in the image and the contract is in the README
(including the "For AI agents" section), an agent dropped into a repo can do
the last-mile tailoring **with no install step**: enable/disable checks, set
thresholds, add allowlists, or write a project profile — by editing
`.checkup.yml`. That file is where automatic detection hands off to deliberate
tailoring. This is what lets us ship "good enough" detection rather than
chasing every esoteric build system.

## Phases

| Phase | Scope                                                                                                           | Status   |
| ----- | --------------------------------------------------------------------------------------------------------------- | -------- |
| 1     | `checkup-core` image; `CHECKUP_OUT_DIR` redirect (read-only source / report to `/out`); semgrep direct fallback | **done** |
| 2     | Command-profile abstraction; auto-detector (manifests + scc); `.checkup.yml` override; `checkup-node` overlay   | planned  |
| 3     | `checkup-dotnet` (+ python/go/rust) overlays; optional `checkup-everything`                                     | planned  |

## Phase-1 follow-ups / known gaps

- **Fixed — pin & verify the baked tools.** Every binary download is now
  SHA256-verified before use (`sha256sum -c`), so a re-tagged or tampered
  upstream artifact fails the build: shellcheck / hadolint / gitleaks / scc in
  core, PMD + dotnet-install.sh in the overlay. hadolint / gitleaks / scc match
  the projects' own published checksums; shellcheck and PMD publish none (PMD has
  a GPG `.asc` only), so those are pinned-on-known-good. semgrep is pinned to an
  exact version (was unpinned), yamllint already was, the .NET SDK is pinned to
  an exact version (was a floating channel), and DevSkim is NuGet-version-pinned.
  Residual hardening: pip deps are version-pinned but not hash-pinned (full
  `pip --require-hashes` would need every transitive dep hashed); PMD/shellcheck
  could be GPG-verified rather than pinned-on-known-good; and `dotnet-install.sh`
  is a rolling script (no versioned URL) so its pinned hash needs a deliberate
  refresh on a bump (the script then verifies the SDK package's own checksum).
- **Multi-arch.** v1 targets `linux/amd64`. The binary URLs are arch-specific;
  key them off `TARGETARCH` and publish an arm64 variant.
- **Offline semgrep.** `--config auto` fetches rules from the registry. For
  air-gapped DD, bundle a ruleset into the image and default to it.
- **Out-dir alignment for npm-tool reports.** `CHECKUP_OUT_DIR` redirects the
  paths Checkup owns. The npm-script tool outputs (madge / jscpd / coverage,
  and semgrep via the npm path) still write to project-relative `reports/`;
  in node-less core they simply skip, but Phase 2 profiles must align them.
- **Report prose paths.** A couple of the rendered report's references
  (`reports/by-file.json`) are literal; make them reflect `CHECKUP_OUT_DIR`.
- **Project-built checks mislead when their toolchain is absent — FIXED in v1
  (honesty stop-gap); deeper profile gating still Phase 2.** Empirically
  measured by running `checkup-core` against a real-world Node/TypeScript repo with a
  `:ro` source mount carrying prior build artifacts. The node-less checks had
  split into three failure modes, _two worse than the "wall of red":_
  - _False `pass` from stale artifacts in the mounted source (most dangerous)._
    `coverage` (reads `coverage/coverage-summary.json`), `duplication`
    (`reports/jscpd/jscpd-report.json`) and `circular-deps`
    (`reports/madge-circular.json`) parsed a pre-existing file and reported a
    confident green despite running no tool. A plain `127 → skip` guard does not
    fix these — they never reach 127, they find a file.
  - _False `pass` from empty-output-on-127._ `type-aware-lint`,
    `deps-freshness`, `unused-code` (and the above before their file read)
    inverted: the absent tool exits 127 with no output, read as "no findings →
    pass." Measured inversion: `type-aware-lint` went `fail/473` (native) →
    `pass/0` (core) on the same commit.
  - _Honest-ish `fail` (exit 127 surfaced)._ `unit-tests`, `build`, `npm-audit`,
    `typecheck`, `code-quality` failed — some with misleading summaries
    ("0 TypeScript compilation errors" while failing).

  **Fix shipped** (`lib/run-tool.sh` + `bin/checkup.sh`): two helpers —
  `toolchain_absent` (true on `LAST_EXIT == 127`, which `run_tool` already sets
  when `npm`/`npx` is off PATH _and_ for `npm run <missing-script>`) and
  `is_fresh <file> <marker>` (artifact newer than a marker touched just before
  the run). Every project-built section now gates: `toolchain_absent → skip` for
  all eleven, plus `is_fresh` on the three external-artifact readers (coverage /
  duplication / circular-deps) so a stale report is never trusted even when the
  toolchain _is_ present but the tool failed. `MAX_SCORE` is added only on the
  run path, so a skip neither inflates the denominator nor counts as failure.
  Validated on that repo: `checkup-core` now reports all eleven as honest `skip` and
  scores `23/30` (cross-stack only) instead of a misleading `58/160 CRITICAL`;
  the native (node-present) run is unchanged at `145/160`, with coverage /
  duplication / circular-deps / type-aware-lint identical to baseline.

  Correct-by-design and unchanged: `git-hotspots` `skip`s in core — it is
  churn × _complexity_ and complexity is eslint-driven, so the hotspot axis is
  node-gated (coupling / bug-fix-density / branch-hygiene are pure-git and run
  fine). **Deeper fix still owed in Phase 2:** profile gating (decide a check
  applies from the detected stack, not just from a 127 at runtime) and aligning
  the npm-tool report paths to `CHECKUP_OUT_DIR` so artifacts land outside the
  source tree rather than relying on the freshness marker.

- **Run the image as non-root.** Checkup's own semgrep check flags
  `missing-user-entrypoint` on this Dockerfile (dogfooding — it runs as root).
  v1 stays root so writes to a bind-mounted `/out` "just work" regardless of
  host uid. Hardening: add a non-root `USER`, and document
  `docker run --user "$(id -u):$(id -g)" …` so `/out` stays writable and
  outputs are owned by the host user.

## Field notes: auditing a legacy non-git ASP/.NET app

First real run against something unlike the repo Checkup grew up in — a ~89K-LOC
hybrid **Classic ASP (262 files) + C# ASP.NET** site, **not under git**, on a
Windows filesystem via WSL. What it taught us:

- **Fixed — non-git repos produced false-PASS forensics.** `branch-hygiene`,
  `bug-fix-density`, `change-coupling` reported reassuring "no issues" on a tree
  with no history (same false-pass class as the toolchain-absent bug). Added a
  one-time `GIT_OK` probe (`is-inside-work-tree` + `HEAD` exists); the four
  git-axis checks now `skip` honestly when there's no history.
- **Fixed — `codebase-stats` was hardcoded to TypeScript/Svelte.** On an ASP/C#
  repo it read "TypeScript: 0, Svelte: 0". Now derives the top languages from
  `scc --format json` (e.g. "top: ASP 25899, C# 20965, XSLT 3975") — meaningful
  on any stack.
- **semgrep `--config auto` already earns its keep on C#.** 53 findings
  (real SQLi + SSRF) in the C# code-behind with zero .NET-specific setup — the
  cross-stack SAST value prop holds. The focused `p/csharp` pack was _narrower_
  (8 high-confidence SQLi), so `auto` is the workhorse; packs add precision.
- **Classic ASP was the blind spot — and the biggest win.** `auto` found ~nothing
  in 26K LOC of `.asp` (no AST parser). A generic-mode regex ruleset
  (`examples/semgrep-asp-classic.yml`) found **101 real issues** (SQLi, reflected
  XSS, dynamic exec, hardcoded creds). Generic mode can't see VBScript comments
  (commented code flags) and needed one refinement (exclude ADODB `.Execute`
  from the VBScript-`Execute` rule via a non-dot prefix — re2 has no lookbehind).
  This is the agent-tailoring seam working exactly as designed.
- **Still owed (Phase 3 `checkup-dotnet`):** the real .NET depth needs the SDK —
  `dotnet build`/`test`, **Security Code Scan**, `dotnet list package
--vulnerable` (the npm-audit equivalent), devskim. None fit in node-less core.
- **Fixed — complexity/hotspots were needlessly node-locked.** The `complexity`
  check now prefers ESLint (AST-accurate) for JS/TS but falls back to **scc's
  per-file complexity** for any other language — no toolchain, covers C#, ASP,
  Go, Python, … — and writes the same Tornhill CSV so **git-hotspots works on
  any stack** too. Validated on a legacy ASP/C# app: complexity went `skip` →
  `warn` (72 files over the heuristic band, top a ~1,700-line code-behind at
  complexity 359); core on the checkup repo produced the CSV and hotspots
  consumed it (skipped only on the legitimate ≥10-files quintile guard). Caveats:
  scc complexity is a decision-keyword heuristic, not true per-function CCN
  (documented in the check's intent; `lizard` is a future precision upgrade for
  the languages it parses); and hotspots still needs real git **history**
  (churn), so a non-git snapshot gets complexity ranking but not churn ×
  complexity.
- **Fixed (overlay) — duplication is no longer node-locked.** `checkup-dotnet`
  bakes **PMD CPD** (+ JRE); the `duplication` check runs CPD for C# (and
  ecmascript when present), replacing the Node-only jscpd path. Validated on a
  legacy ASP/C# app: 133 clone blocks ≥100 tokens, top a 662-line clone plus
  cross-site code-behind copies. Two false-pass traps caught while
  wiring it (wrong CPD flag → empty output; XML default-namespace → parser found
  nothing) — both now guarded (empty/non-XML output fails, never passes).
  Remaining gaps: Classic ASP has no CPD tokeniser (so `.asp` duplication is
  unmeasured); and CPD lives in the dotnet overlay only — a core-level
  language-agnostic duplication tool would need a non-JVM/non-Node option.
- **WSL/`/mnt` works but is slow.** drvfs (9p) makes full-tree walks sluggish;
  for a real audit, `git clone`/copy into the Linux fs first. Worked fine here
  (4MB), would bite on a large monorepo.

## Candidate tools to add

Beyond what's baked (gitleaks, semgrep, scc, shellcheck, yamllint, hadolint;
overlay: DevSkim, PMD CPD, dotnet-vuln). Ranked by value/fit.

**Universal (core-friendly — single static binaries, no runtime):**

- **Fixed — Trivy added to `checkup-core`** (the `trivy` SCA check). One Go
  binary scanning dependency manifests/lockfiles for CVEs across ecosystems,
  including **.NET `packages.config` WITHOUT a restore** — closing the
  `dotnet-vuln` legacy gap, universally. Pinned + SHA256-verified against the
  release's cosign/sigstore-signed `checksums.txt`. Residual hardening:
  cosign-verify that signature in CI for the full chain (no cosign on the build
  host today); bundle an offline DB for air-gapped scans (trivy downloads its DB
  on first run, like semgrep `--config auto`). `dotnet-vuln` (overlay) now
  overlaps trivy on modern .NET and could be retired once trivy is proven there.
  (Scoped to `--scanners vuln` — secrets/misconfig stay with gitleaks/hadolint.)
- **OSV-Scanner** (Google, Go binary) — lockfile CVEs, lighter than Trivy;
  alternative if Trivy's breadth is overkill.
- **TruffleHog** — secret scanning with **live-credential verification** (would
  tell us whether an exposed cloud key is still active, not just present). Strong
  complement to gitleaks.
- **lizard** (pip) — true multi-language cyclomatic complexity (C#, Java, Go,
  Python, …). A precision upgrade over the current scc-heuristic complexity for
  the languages it parses (it does **not** cover Classic ASP — keep scc as the
  universal fallback).

**Microsoft / .NET-specific (overlay):**

- **`dotnet list package --deprecated`** — trivial companion to `--vulnerable`;
  flags abandoned dependencies. Add alongside `dotnet-vuln`.
- **BinSkim** (Microsoft) — PE/binary static analysis of compiled `.dll`/`.exe`
  (ASLR/DEP/SafeSEH, signing) with **no source build** — useful for legacy
  Framework apps where you only have `bin/`. (The legacy app shipped no
  first-party DLLs, so low value _here_, high value generally.)
- **.NET Portability Analyzer / Upgrade Assistant** (Microsoft) — quantifies
  Framework→modern migration effort; a genuine DD signal ("how stuck is this?").
- **Security Code Scan** / **SonarScanner for .NET** — the strongest .NET SAST
  (SQLi/XSS/CSRF/XXE), but **build-time** (Roslyn) ⇒ needs a Windows/MSBuild
  build, so out of scope for the Linux overlay; note for a CI-on-Windows path.

**Known scoring limitation:** overlay checks (asp-classic, devskim, dotnet-vuln,
duplication) append _after_ `checkup.sh` has computed and written the score, so
they appear in the report's check list / Top Problems / by-file cross-cut but do
**not** move the headline `score/maxScore`. Fold overlay checks into the score
when the command-profile refactor (Phase 2) centralises scoring.

## Non-goals (for now)

- Running an arbitrary stranger's full **build** in the image. That needs the
  project's own dependencies installed and only helps Node-style repos; teams
  with their own toolchain are better served running Checkup in their existing
  CI. Overlays cover the common stacks deliberately, not universally.
