# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

The **v0.2.0** line. Headline: checkup was reframed from a deploy-readiness grade
into a deterministic codebase-health **localiser** (ADR-0009), and hardened to be
honest and accurate on **polyglot** repos — *orient me, then point at the problems,
across the whole thing, honestly*.

### Added

- **Health-localiser reframe (ADR-0009):** `CHECKUP_MODE` (`tailored` | `audit`,
  never a gate); a humble **pillar-derived health triage** headline; **headline
  macro-alarms** (dead platform, no tests, leaked secret) floated to the top; an
  **absence-is-signal** layer (tree-observable docs/test presence) and a
  **technology-viability** alarm that elevates the detected stack (#46, #50–#53,
  #58–#59).
- **Agent-first output contract:** a versioned `checkup.json` bundle an agent
  reads first; "priming an agent" docs (#54, #60–#62).
- **Stack auto-detection** (`detection.json`) that routes the complexity /
  duplication engines by the detected stack (#7, #67).
- **Per-language complexity for polyglot repos** — ESLint on the JS/TS slice +
  `lizard` on the rest, partitioned by extension and merged into one record, in
  **both directions**: node-dominant repos (#68) and non-node-dominant polyglots
  whose JS/TS slice has a resolvable ESLint config (#73) — gated on that config so
  a config-less repo is unchanged (lizard covers everything, no speculative fail).
- **Honest coverage** — scan scope enumerated from the VCS (`.gitignore`-aware),
  plus a coverage signal (assessed / excluded / unmeasured / couldn't-run)
  surfaced in `detection.json`, the console, and the report headline (#75).
- **`lizard`** as a true multi-language complexity + duplication engine, and a
  **Focus Areas** view synthesising the forensic axes (#36–#38).
- **Command profiles** + a **`.checkup.yml`** override layer (stack / checks /
  commands) with a documented example (#6, #69–#71, #2).
- Generated/vendored exclusion for the multi-language scans + `CHECKUP_EXCLUDE`
  (#41, #44); evergreen reference docs, ADRs, and `AGENTS.md` (#12–#13, #19).

### Changed

- **Default scan scope is the whole VCS-tracked tree**, not `src server`;
  `CHECKUP_SRC_ROOTS` now *narrows* it (#75).
- The headline is a humble pillar read, **not** the legacy point-sum percentage;
  deploy-readiness framing purged (#35, #46, #58).
- README slimmed to pointers; detail moved to reference docs + this changelog
  (#20).

### Fixed

- An ESLint-slice failure no longer **sinks the whole complexity record** on a
  node-dominant polyglot — the non-JS slice is still measured, the JS/TS gap is
  reported as *unmeasured*, audit runs never fetch ESLint over the network, and a
  large-input argv overflow is gone (#79).
- Project-built checks **skip (not fail)** when a manifest exists but the npm
  script / toolchain is absent — including an npm diagnostic format drift — and on
  non-Node targets (#80, #14, #23).
- Monorepo-aware forensic roots + honest-degrade on an empty git window (#42);
  target-relative paths for git-forensics on subdirectory targets (#15);
  ESLint complexity gated on a real Node project (#39); type-aware-lint degrades
  honestly on parse errors (#64); branch-hygiene no longer pollutes the by-file
  aggregate (#16).

### Security / CI

- CI scans the tree **and** issue/PR text for internal references, plus a secret
  self-scan (#20, #66); sealed (`--network none`) runs recommended (ADR-0008, #30).

## [0.1.0] - 2026-06-10

First public release.

### Added

- **Orchestrator + renderer** (`bin/checkup.sh`, `bin/checkup-report.sh`) with a
  normalised parsed-JSON contract and a tool-agnostic Markdown report (summary,
  cross-tool Top Problems, by-file hotspots, per-check intent).
- **Cross-stack checks** (any repo): secret scanning (gitleaks), SAST (semgrep),
  shell/YAML/Dockerfile lint (shellcheck/yamllint/hadolint), codebase stats
  (scc), and Tornhill-style git forensics (hotspots, change-coupling, bug-fix
  density, branch hygiene).
- **Project-built checks** (Node): typecheck, tests, build, lint, type-aware
  lint, coverage, circular deps, duplication, unused code, dependency freshness,
  npm audit, mutation.
- **`checkup-core` Docker image** — bakes the cross-stack tools; scan any repo
  with a read-only mount and output to `/out`.
- **`checkup-dotnet` overlay** — `FROM checkup-core` + .NET SDK, DevSkim and PMD
  CPD; adds Classic-ASP security rules, source SAST, NuGet vuln audit, and
  language-aware duplication.
- **`CHECKUP_OUT_DIR`** to write all output outside the scanned tree (read-only
  source / due-diligence scans); location-independent target resolution
  (`CHECKUP_TARGET`, `CHECKUP_SRC_ROOTS`, `CHECKUP_SHELL_DIRS`).
- **Example configs** (`examples/`) including a Classic ASP / VBScript security
  ruleset for semgrep.
- Helper unit tests (`test/run-tool.test.sh`) and CI (ShellCheck, syntax,
  tests, core image build).

### Notable design choices

- **Honest graceful-degrade** — a check whose toolchain or prerequisite is absent
  reports `skip` with a reason; it never fails spuriously, and empty tool output
  is never read as "zero findings → pass".
- **Language-agnostic health metrics** — complexity falls back to scc (so
  git-hotspots works on any stack), duplication uses PMD CPD in the overlay.

See [`ROADMAP.md`](ROADMAP.md) for known gaps and planned work (command
profiles, auto-detection, more stack overlays, image hardening).

[Unreleased]: https://github.com/maudlin/checkup/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/maudlin/checkup/releases/tag/v0.1.0
