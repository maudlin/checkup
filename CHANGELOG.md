# Changelog

All notable changes to this project are documented here. The format is based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and this project
adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

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

[0.1.0]: https://github.com/maudlin/checkup/releases/tag/v0.1.0
