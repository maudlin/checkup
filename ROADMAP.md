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

- **Pin & verify the baked tools.** semgrep is currently unpinned (builds
  against latest); pin it for reproducible DD reports. Add SHA256 checksum
  verification for the downloaded static binaries (shellcheck / hadolint /
  gitleaks / scc).
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
- **Project-built checks report `fail`, not `skip`, when their toolchain is
  absent.** On a non-Node repo (or the node-less `checkup-core`),
  typecheck / test / build / code-quality / coverage / circular-deps /
  duplication / npm-audit show red `fail` rather than `skip — tool absent`.
  For a DD report that "wall of red" is misleading. The proper fix is the
  Phase-2 profile gating (run a project-built check only when its profile /
  toolchain is present); a stop-gap is a `LAST_EXIT == 127 → write_skipped`
  guard at the top of each npm-driven section (the documented graceful-degrade
  pattern several of these sections currently skip).
- **Run the image as non-root.** Checkup's own semgrep check flags
  `missing-user-entrypoint` on this Dockerfile (dogfooding — it runs as root).
  v1 stays root so writes to a bind-mounted `/out` "just work" regardless of
  host uid. Hardening: add a non-root `USER`, and document
  `docker run --user "$(id -u):$(id -g)" …` so `/out` stays writable and
  outputs are owned by the host user.

## Non-goals (for now)

- Running an arbitrary stranger's full **build** in the image. That needs the
  project's own dependencies installed and only helps Node-style repos; teams
  with their own toolchain are better served running Checkup in their existing
  CI. Overlays cover the common stacks deliberately, not universally.
