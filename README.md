# 🩺 Application Checkup

[![CI](https://github.com/maudlin/checkup/actions/workflows/ci.yml/badge.svg)](https://github.com/maudlin/checkup/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-blue.svg)](LICENSE)

**A whole-repository examination of health, quality, security and hygiene** —
code, dependencies, secrets & CVEs, containers, CI workflows, shell scripts,
and git history. A single shell entrypoint runs ~20 checks (formatters,
linters, type-checkers, security scanners, complexity and git-forensics tools)
and produces both a human-readable markdown report and a machine-readable JSON
stream suitable for LLM consumption.

Two jobs, one tool:

1. **Track** — teams run it (locally pre-PR, or in CI) to identify and trend
   health, quality and hygiene issues in an existing codebase.
2. **Examine** — teams or auditors point it at a brownfield to surface
   improvement priorities, or to flag risks in a report (e.g. tech
   due-diligence).

It is **tool-agnostic and portable**: every check degrades gracefully when its
tool is absent, and the contract documented below lets you swap the
language-specific checks for your own stack's equivalents without touching the
helpers, the renderer, or the report format.

> Released under MIT (see `LICENSE`). Forks, ports, and ports-back welcome.

---

## Quick start

```bash
# Run against the current project (resolves the enclosing git repo):
cd /path/to/your-project
/path/to/checkup/bin/checkup.sh

# …or scan an explicit target without cd-ing into it:
CHECKUP_TARGET=/path/to/your-project /path/to/checkup/bin/checkup.sh
```

Output lands under the **scanned project**: `docs/reports/checkup-report.md`
(committable "latest") plus `reports/parsed/*.json` (machine-readable, one file
per check). Add an alias (`alias checkup=/path/to/checkup/bin/checkup.sh`) or
symlink `bin/checkup.sh` onto your `PATH`. To pin it into a project, vendor the
repo (e.g. as a git submodule) and call `bin/checkup.sh` from an npm/make task.

### Run in Docker (no host installs)

The `checkup-core` image bakes the cross-stack tools (gitleaks, semgrep, trivy,
shellcheck, yamllint, hadolint, scc) so you can examine **any** repository with
nothing installed but Docker — ideal for ad-hoc audits and due diligence:

```bash
docker build -t checkup-core .          # one-off, from this repo

# Scan a project: source mounted READ-ONLY, report written to ./checkup-out
docker run --rm \
  -v "/path/to/project:/src:ro" \
  -v "$PWD/checkup-out:/out" \
  checkup-core
# → ./checkup-out/checkup-report.md  (+ parsed/*.json, by-file.json)
```

The source is mounted read-only — checkup writes nothing into it; everything
goes to `/out`. Mount a full clone (not a shallow/exported tree) so the
git-forensics checks have history.

For sensitive or due-diligence scans, run it **sealed** (`--network none` + a
minimal sandbox) so a compromised tool can't exfiltrate the code — see
[`SECURITY.md`](SECURITY.md#running-it-safely-on-sensitive-code-recommended).

What runs in `checkup-core`: the cross-stack security, hygiene and forensics
checks (secrets, SAST, shell/YAML/Dockerfile lint, stats, churn × complexity).
Language- and build-specific checks (typecheck, test, build, coverage) belong
to per-stack images — see [`ROADMAP.md`](ROADMAP.md). On a repo without the Node
toolchain they `skip` honestly (they don't fail or false-pass); read the
cross-stack sections for the core signal.

#### `checkup-dotnet` overlay (.NET / legacy ASP)

`FROM checkup-core` plus the .NET SDK, Microsoft DevSkim and PMD CPD. Runs every
core check, then adds four .NET / legacy-ASP passes — **asp-classic** (semgrep
ruleset for Classic ASP/VBScript), **devskim** (source SAST, no build, reaches
.NET Framework source), **dotnet-vuln** (`dotnet list package --vulnerable`,
skips honestly on legacy `packages.config`), and **duplication** (PMD CPD —
language-aware copy-paste detection for C# and other CPD languages; Classic ASP
has no CPD tokeniser). New findings flow into the same report automatically (the
renderer is tool-agnostic).

```bash
docker build -t checkup-core .                        # base first
docker build -f Dockerfile.dotnet -t checkup-dotnet . # overlay

docker run --rm -v "/path/to/app:/src:ro" -v "$PWD/out:/out" checkup-dotnet
```

The report location is controlled by **`CHECKUP_OUT_DIR`** (set to `/out` in
the image): set it in any context to write outputs outside the scanned tree.
Unset, checkup keeps the committed `docs/reports/checkup-report.md` convention.

---

## Documentation

| Doc                                                    | What                                       |
| ------------------------------------------------------ | ------------------------------------------ |
| [`docs/architecture.md`](docs/architecture.md)         | How it works — contract, schema, layering  |
| [`docs/build-your-own.md`](docs/build-your-own.md)     | Run on a host, slim images, extract tools  |
| [`docs/tools.md`](docs/tools.md)                       | Bundled tools, versions, verification      |
| [`docs/decisions/`](docs/decisions/)                   | ADRs — _why_ it's built this way           |
| [`ROADMAP.md`](ROADMAP.md) + [Issues](https://github.com/maudlin/checkup/issues) | What's next (milestone `v0.2.0`) |
| [`AGENTS.md`](AGENTS.md) · [`CONTRIBUTING.md`](CONTRIBUTING.md) | Agent guidance · engagement model |

---

## Entrypoints

| Script                  | Purpose                                                                                                |
| ----------------------- | ------------------------------------------------------------------------------------------------------ |
| `bin/checkup.sh`        | Orchestrator. Sources `lib/run-tool.sh`, runs every check, emits the normalised stream.                |
| `bin/checkup-dotnet.sh` | .NET / legacy-ASP overlay. Runs core, then appends asp-classic + devskim + dotnet-vuln + duplication.  |
| `bin/checkup-report.sh` | Tool-agnostic markdown renderer. Reads `reports/parsed/*.json` → writes the report.                    |
| `lib/run-tool.sh`       | Shared helpers (`run_tool`, `write_parsed`, `write_skipped`, `write_failed`, `is_valid_json`, `slug`). |

```bash
./bin/checkup.sh        # runs all checks, then renders the report
```

---

## Prerequisites

### Tier 1 — required (everything below this line is mandatory)

The substrate cannot run without these. Most are already on any modern dev box;
listed for forker completeness.

| Tool                                       | Why                                                  |
| ------------------------------------------ | ---------------------------------------------------- |
| **bash** (4+)                              | Orchestrator + helpers                               |
| **jq**                                     | All parsed-JSON emission and the cross-tool renderer |
| **git**                                    | Required by `git-hotspots` + the `git-smells` trio   |
| **node** / **npm**                         | Every npm-script-driven check                        |
| POSIX `find`, `grep`, `sort`, `awk`, `sed` | Helpers in `lib/run-tool.sh` and section parsers     |

### Tier 2 — per-check graceful-degrade (each check skips with a documented reason if its tool is absent)

Every section in `checkup.sh` follows the contract: if its tool is missing
(`LAST_EXIT == 127`), the section emits a `skip` parsed JSON with a human
reason. No check is mandatory; missing tools never block the run.

| Tool                                           | Used by                            | Install                                                                                          |
| ---------------------------------------------- | ---------------------------------- | ------------------------------------------------------------------------------------------------ |
| `shellcheck`                                   | `shellcheck` section               | `apt install shellcheck` / `brew install shellcheck` / static binary on GitHub releases          |
| `yamllint`                                     | `yamllint` section                 | `pipx install yamllint` (recommended) / `apt install yamllint`                                   |
| `hadolint`                                     | `hadolint` section                 | `brew install hadolint` / Linux static binary on GitHub releases (arch-mapped: `x86_64`/`arm64`) |
| `gitleaks`                                     | `gitleaks` section                 | `brew install gitleaks` / Linux static binary on GitHub releases (arch-mapped: `x64`/`arm64`)    |
| `scc`                                          | `codebase-stats` section           | `brew install scc` / Linux static binary on GitHub releases                                      |
| `madge`, `jscpd`, `knip`, `semgrep`, `stryker` | various npm-script-driven sections | `npm install` (devDependencies; provided by the host project)                                    |

### Configuration files (project-owned)

The substrate is config-driven for the linters that can be tuned:

- **`.shellcheckrc`** — disabled rules
- **`.yamllint.yml`** — line-length, truthy keywords, comment style
- **`.hadolint.yaml`** — ignored rules
- **`.gitleaks.toml`** — allowlist (paths, regexes, stopwords)

Without these, each tool runs on defaults — the substrate doesn't depend on the
config files existing.

---

## Other ecosystems

The substrate is more language-agnostic than the npm-script defaults suggest.
The following all work unchanged on any stack:

- **Complexity** — the default uses ESLint's `complexity` +
  `sonarjs/cognitive-complexity` in reporter mode (AST-aware via
  typescript-eslint). For non-TS stacks, the shape is portable: `lizard`
  natively parses C, C++, Java, JS, Python, Ruby, Rust, Go, Swift, Kotlin, Lua,
  Scala, PHP, Objective-C, etc.; `radon` covers Python in more depth; `mccabe`
  / `cyclonedx` etc. are language-specific alternatives. Replace the ESLint
  invocation in the section with whichever produces per-function `(file, line,
name, score)` and the rest of the substrate carries it through. The default
  moved off lizard because lizard's state-machine TS parser mis-attributes
  class-method CCN to the first top-level function before a class — fine for
  non-TS, broken for TS-heavy codebases.
- **Stats** — `scc` covers ~150 languages.
- **Security** — `gitleaks` is content-based (not language-aware); `semgrep`
  has community rulesets for most major languages.
- **Config-lint** — `yamllint`, `hadolint` are language-neutral.
- **Git-axis** — `git-hotspots`, `change-coupling`, `bug-fix-density`,
  `branch-hygiene` are pure git; identical on every stack.
- **Contract, helpers, renderer** — language-agnostic by design.

The language-specific work is concentrated in the ten npm-script-driven
sections. Swap those for your build system's equivalents and the rest of the
substrate works as-is.

| Section        | TS / Node (default) | Java / Kotlin                  | Python              | Go                        | Rust                 | C# / .NET                          |
| -------------- | ------------------- | ------------------------------ | ------------------- | ------------------------- | -------------------- | ---------------------------------- |
| build          | `npm run build`     | `gradle build` / `mvn package` | `pip install -e .`  | `go build ./...`          | `cargo build`        | `dotnet build`                     |
| typecheck      | `tsc --noEmit`      | (compile-time)                 | `mypy` / `pyright`  | (compile-time)            | (compile-time)       | (compile-time)                     |
| test           | vitest / jest       | JUnit (gradle / maven)         | pytest              | `go test ./...`           | `cargo test`         | `dotnet test`                      |
| lint           | ESLint              | SpotBugs + Checkstyle + PMD    | ruff                | golangci-lint             | clippy               | built-in analyzers                 |
| format:check   | prettier            | google-java-format / ktlint    | ruff format / black | `gofmt -l`                | `cargo fmt --check`  | `dotnet format`                    |
| coverage       | vitest --coverage   | JaCoCo                         | coverage.py         | `go test -cover` (native) | tarpaulin / llvm-cov | coverlet                           |
| unused         | knip                | (reflection-limited)           | vulture / ruff F841 | `go vet` / deadcode       | cargo-udeps          | R# CLI / IDE                       |
| duplication    | jscpd               | jscpd                          | jscpd               | dupl / jscpd              | jscpd                | jscpd                              |
| security:audit | npm audit           | OWASP dep-check / Snyk         | pip-audit / safety  | govulncheck               | cargo-audit          | `dotnet list package --vulnerable` |
| mutation       | Stryker             | PIT (Pitest)                   | mutmut / cosmic-ray | go-mutesting              | cargo-mutants        | Stryker.NET                        |
| circular-deps  | madge               | jdeps (built-in)               | pydeps              | `go list` / staticcheck   | cargo-modules        | NDepend (commercial)               |

The mapping is approximate — many of these tools cover different surface area
than their JS-ecosystem equivalents (e.g. `golangci-lint` wraps ~10 linters;
`clippy` is more conservative than ESLint by default). The point is the
**shape** is portable: parse the tool's output into the standard `top[]`
finding shape and the rest of the substrate carries it through unchanged.

---

## Environment variables

| Variable              | Used by                                   | Default                                  | Purpose                                                                                   |
| --------------------- | ----------------------------------------- | ---------------------------------------- | ----------------------------------------------------------------------------------------- |
| `CHECKUP_TARGET`      | path resolution (`checkup.sh` + renderer) | enclosing git repo, else `$PWD`          | Explicit project root to scan, instead of auto-detecting from the git top level. For one service in a monorepo, see [Scanning a monorepo subdirectory](#scanning-a-monorepo-subdirectory). |
| `CHECKUP_SRC_ROOTS`   | complexity + git-axis sections            | `src server`                             | Space-separated source roots for the git-forensics and complexity scans (e.g. `app cmd`). |
| `CHECKUP_SHELL_DIRS`  | `shellcheck` section                      | `scripts .husky .githooks .claude/hooks` | Space-separated dirs to search for shell scripts. Missing dirs are skipped silently.      |
| `HADOLINT_DOCKERFILE` | `hadolint` section                        | auto-detect `Dockerfile*` at root        | Override the Dockerfile filename when it is named non-conventionally.                     |
| `MUTATION_TEST`       | `mutation` section                        | unset (skipped)                          | Set to `1` to enable Stryker; opt-in because mutation testing is slow (~2 min).           |
| `RAW_DIR`             | every section (via `run_tool`)            | `reports/raw`                            | Where each section's stdout/stderr capture is written.                                    |
| `PARSED_DIR`          | every section (via `run_tool`)            | `reports/parsed`                         | Where each section's normalised JSON is written.                                          |

Forks adding new env-overridable knobs should follow the same `<TOOL>_<NOUN>`
naming convention and document them here in one table.

### Scanning a monorepo subdirectory

Point `CHECKUP_TARGET` at one service inside a larger repo and scope the source
roots to it:

```bash
CHECKUP_TARGET=/path/to/monorepo/services/api \
CHECKUP_SRC_ROOTS="src" \
CHECKUP_OUT_DIR=/tmp/checkup-out \
bin/checkup.sh
```

Caveats:

- **Churn / coupling / bug-fix density scope correctly** — git pathspecs are
  cwd-relative, so the git-forensics scans see only the subtree.
- **Paths are target-relative** — the file-based scanners and git-forensics share
  one namespace (e.g. `src/app.ts`, not `services/api/src/app.ts`), so the
  by-file hotspot aggregate joins correctly.
- **branch-hygiene is repo-wide** — branches can't be scoped to a subtree, so its
  counts cover the whole monorepo, not just the service.
- **One stack per run** — a monorepo mixing stacks wants one run per service with
  the matching overlay; there's no built-in cross-service roll-up.

---

## npm-script contract

Every `npm run <script>` the orchestrator invokes must satisfy a small
contract. If the host project's `package.json` deviates, the corresponding
section may break. This table is the surface area a forker has to wire up.

| npm script             | Section         | Required behaviour                                                                                                     |
| ---------------------- | --------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `typecheck`            | `typecheck`     | Exit 0 if zero errors. Stderr/stdout should list TS errors in `path:line:col` form (consumed by the section parser).   |
| `test`                 | `unit-tests`    | Exit 0 if all tests pass. Vitest summary on stdout (the parser strips ANSI then regex-matches the summary line).       |
| `format:check`         | `code-quality`  | Exit 0 if all files formatted. Non-zero with the list of unformatted files when drift exists.                          |
| `lint`                 | `code-quality`  | Run ESLint with the **default text formatter** — the section parser anchors on the `✖ N problems` summary line.        |
| `build`                | `build`         | Exit 0 if production build succeeds. Output captured to `reports/raw/production-build.txt`.                            |
| `quality:security`     | `semgrep`       | Run Semgrep with the project ruleset. Write `reports/semgrep-report.json` (Semgrep's native JSON).                     |
| `quality:deps`         | `circular-deps` | Run `madge --circular --json` and **write to `reports/madge-circular.json`** (the section reads from that path).       |
| `quality:duplicates`   | `duplication`   | Run `jscpd` and write its report to `reports/jscpd/jscpd-report.json`.                                                 |
| `quality:unused`       | `unused-code`   | Run `knip` and emit findings on stdout (default text format).                                                          |
| `test:coverage:report` | `coverage`      | Run vitest with coverage; coverage tooling must write `coverage/coverage-summary.json` (the section reads from there). |

Direct (non-npm) invocations — no `npm run` indirection, but listed for completeness:

| Command                               | Section          | Notes                                                                                                                                                                                                                           |
| ------------------------------------- | ---------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `npm audit --json`                    | `npm-audit`      | Native npm audit JSON                                                                                                                                                                                                           |
| `npm outdated --json`                 | `deps-freshness` | Native npm outdated JSON                                                                                                                                                                                                        |
| `npx eslint --rule ... --format json` | `complexity`     | ESLint JSON: parsed into per-function `{file, line, code: "CCN-N"/"COG-N", severity, message}`. Cyclomatic findings also appended to `reports/complexity-full.csv` in lizard-compatible columns for the `git-hotspots` section. |
| `scc … --no-cocomo`                   | `codebase-stats` | Default text output, parsed by the section                                                                                                                                                                                      |
| `shellcheck -f json -x …`             | `shellcheck`     | Native JSON                                                                                                                                                                                                                     |
| `yamllint -f parsable …`              | `yamllint`       | `path:line:col: [level] message (rule)` format                                                                                                                                                                                  |
| `hadolint --no-color …`               | `hadolint`       | Text output with `Dockerfile:line code: message` lines                                                                                                                                                                          |
| `gitleaks dir --report-format=json`   | `gitleaks`       | Native JSON                                                                                                                                                                                                                     |
| `npx stryker run`                     | `mutation`       | Stryker writes its own HTML/JSON reports under `reports/mutation/`                                                                                                                                                              |

If a forker doesn't have one of these wired up, the section either skips (tool
on PATH not present) or writes `fail` with a parse-error reason — never breaks
the whole orchestrator.

---

## The contract

Every check in `checkup.sh` MUST satisfy four properties. These are the
invariants that make the script modular, reference-quality, LLM-consumable, and
graceful-degrading. They are checked by code review, not by tooling.

### 1. Registry-style plugin

Adding a check is one section in `checkup.sh`. No edits to the markdown
writer — it discovers new parsed JSONs automatically. The skeleton:

```bash
# N. <Human Label> — <ticket>
# section:    <slug>
# purpose:    <one sentence — what is this measuring?>
# pass_means: <what good looks like, and WHY this threshold>
# fail_means: <what bad looks like, and the suggested response>
print_section "<Human Label>"
echo "Command: <whatever the user would run by hand>"
echo ""

<SLUG>_INTENT=$(jq -n '{
    purpose:    "...",
    pass_means: "...",
    fail_means: "..."
}')

MAX_SCORE=$((MAX_SCORE + <points>))   # keep the 168-pt trend score
run_tool "<Human Label>" <tool> [args…]

if [ "$LAST_EXIT" = "127" ]; then
    write_skipped "<slug>" "<tool> not installed (install: …)"
elif [ ! -s "$LAST_RAW" ]; then
    write_skipped "<slug>" "<tool> produced no output"
else
    # …derive status, count, summary, top[] from $LAST_RAW…
    <SLUG>_TOP=$(jq -c '...' "$LAST_RAW")   # see severity vocabulary below

    if [ "$<count>" -eq 0 ]; then
        echo -e "${GREEN}✅ Passed${NC}"
        HEALTH_SCORE=$((HEALTH_SCORE + <points>))
        STATUS="pass"; SUMMARY="..."
    elif # …warn case…
        STATUS="warn"; …
    else
        STATUS="fail"; …
    fi
    write_parsed "<slug>" "$STATUS" "$COUNT" "$SUMMARY" "$<SLUG>_TOP" "$<SLUG>_INTENT"
fi
echo ""
```

In practice, sections are inline (not wrapped in `check_<slug>()` functions) —
extracting to functions is a worthwhile future cleanup but not required by
the contract. The comment block at the top, the intent heredoc, the `run_tool`
call, and the `write_parsed`/`write_skipped` are the load-bearing parts.

### 2. Documented intent

Every check declares `intent: {purpose, pass_means, fail_means}` so that anyone
(human or LLM) reading the parsed JSON can understand what the check is _for_
without reading the source.

The comment block at the top of the check function is the source of truth. The
JSON `intent` field is a copy for downstream consumers. The markdown report
renders the intent under each check.

### 3. Standardised parsed JSON

Each check writes `reports/parsed/<slug>.json`:

```jsonc
{
  "slug": "complexity",
  "status": "warn", // pass | warn | fail | skip
  "count": 77,
  "summary": "77 hotspots over CCN 10 / cognitive 15 (top 20 reported)",
  "top": [
    // optional — most checks populate
    {
      "file": "src/services/example-service.ts",
      "line": 347,
      "code": "CCN-37", // short tag for grouping/dedup
      "severity": "warning", // see vocabulary below
      "message": "handleRequest — CCN 37",
    },
  ],
  "intent": {
    "purpose": "Identify functions whose complexity makes them bug-incubators.",
    "pass_means": "No functions over CCN 10 or cognitive 15.",
    "fail_means": "CCN/cognitive > 30 should be refactored or covered with dedicated tests.",
  },
}
```

#### Status vocabulary

| status | meaning                                              | summary headline |
| ------ | ---------------------------------------------------- | ---------------- |
| pass   | check ran and the codebase met the threshold         | ✅               |
| warn   | check ran, threshold breached but non-blocking       | ⚠️               |
| fail   | check ran, threshold breached and treated as serious | ❌               |
| skip   | check did not run (tool missing, prereq absent)      | ⏭️               |

#### Severity vocabulary (`top[].severity`)

Ordered by triage weight:

| severity | weight | use for                                         |
| -------- | ------ | ----------------------------------------------- |
| critical | 0      | security CVEs, secrets, RLS gaps                |
| error    | 0      | hard failures (typecheck errors, test failures) |
| high     | 0      | high-severity findings (semgrep ERROR, CVEs)    |
| warning  | 1      | non-blocking but actionable                     |
| medium   | 1      | mid-severity findings                           |
| low      | 2      | minor issues                                    |
| style    | 2      | formatting, style                               |
| info     | 3      | informational                                   |

The "Top Problems" markdown aggregate uses the weight column to sort across
tools.

### 4. Graceful degrade

Every check writes a parsed JSON, even when skipped. The report shows "what
was supposed to run vs. what did". The convention:

```bash
if [ "$LAST_EXIT" = "127" ]; then
    write_skipped "$slug" "tool-name not installed (install: …)"
    return
fi
```

A missing tool is **never** a script failure. The orchestrator continues; the
final report shows the gap explicitly.

---

## Helpers (`lib/run-tool.sh`)

### `run_tool "<Label>" <cmd> [args…]`

Runs `<cmd>`, captures stdout to `$RAW_DIR/<slug>.txt`, stderr to
`$RAW_DIR/<slug>.stderr.txt` (deleted if empty). Sets globals:

| global        | meaning                                        |
| ------------- | ---------------------------------------------- |
| `LAST_LABEL`  | the human label passed in                      |
| `LAST_SLUG`   | computed slug — used for parsed filename       |
| `LAST_RAW`    | absolute path to the stdout capture            |
| `LAST_STDERR` | absolute path to the stderr capture (or empty) |
| `LAST_EXIT`   | exit code of the tool — `127` if not on PATH   |

**Always returns 0** so that `set -e` callers do not abort on expected non-zero
exits (e.g. lint with warnings, typecheck with errors). The tool's real exit
code is in `$LAST_EXIT`; `127` means the tool is not on `$PATH`.

### `write_parsed <slug> <status> <count> <summary> [top-json] [intent-json]`

Emits the parsed JSON. `top-json` and `intent-json` are passed verbatim into
`jq --argjson` so they must be valid JSON; defaults are `[]` and `{}`.

### `write_skipped <slug> <reason> [intent-json]`

Sugar for `write_parsed <slug> skip 0 "<reason>" [] <intent>` — always-write
discipline for the "deliberately not run" case (tool not installed, opt-in
not set, prereq genuinely absent). Pass the check's intent heredoc so the
report still explains why this check matters even when it didn't run; a
reader can then decide whether to enable it.

### `write_failed <slug> <reason> [intent-json]`

For the "tool ran but we can't interpret the output" case — missing/
malformed report file, non-zero exit without parseable diagnostic. Status
is `fail` with empty `top[]`. Use this in preference to `write_skipped`
when the tool actually executed; the distinction matters because skipped
implies "deliberately bypassed" whereas this case is "we tried and got
nothing usable, can't claim safety". The wrong choice silently downgrades
a real failure.

### `is_valid_json <path>`

Returns 0 if the file exists, is non-empty, and parses as JSON. Use as a guard
before `jq` against tool output you didn't construct yourself.

### `slug "<Label>"`

Lowercase kebab-case derivation. Stable identifier for filenames and the
`slug` field. `slug "Code Quality (Formatting + Linting)"` → `code-quality-formatting-linting`.

---

## Output layout

```
reports/                        # gitignored (whole tree)
├── raw/                        # one file per check — tool stdout/stderr
│   ├── complexity-hotspots.txt # ESLint JSON output (one finding per line)
│   ├── eslint.txt
│   ├── eslint.stderr.txt       # only present when stderr was non-empty
│   └── …
├── parsed/                     # one file per check — normalised JSON
│   ├── complexity.json
│   ├── eslint.json
│   └── …
├── by-file.json                # derived cross-cut — files ranked by
│                               #   severity-weighted finding count across
│                               #   every check. Combined with the
│                               #   `git-hotspots` check this completes
│                               #   the Tornhill bug-hotspot triangle.
├── checkup-report-<utc-ts>.md   # timestamped history (kept for trend)
├── checkup-summary.json         # score + max for the trend headline
└── complexity-full.csv         # complexity findings in lizard-CSV format
                                # (consumed by git-hotspots; written by the
                                # complexity section)

docs/reports/                   # committed
└── checkup-report.md     # always = "latest", overwritten on each run
```

---

## Cross-tool aggregates

The markdown writer computes two cross-tool views automatically — no check
contributes to them directly; they emerge from the standardised parsed JSON.

### Top Problems

A single triage list across every check. Max 3 entries per tool (so a wide
check like `code-quality` with 472 warnings can't drown everything else),
total cap 30. Severity-weighted: `critical/error/high → 0`, `warning/medium
→ 1`, `low/style → 2`, `info → 3`. Sort ascending by weight.

### Files with most findings (`reports/by-file.json`)

Joins every check's `top[]` by `file`. The ranking is severity-weighted
(`critical=4 … info=1`) so a file with one critical finding outranks one
with three info-only findings. A file appearing across multiple checks
(e.g. complexity + lint + semgrep) is a likely bug hotspot — the spatial
axis of the Tornhill triangle. The temporal axis lives in the dedicated
`git-hotspots` check, which joins six-month commit churn against per-file
max CCN. Together they cover both legs of the bug-prediction signal.

The full ranking goes to `reports/by-file.json` for LLM consumption; the
markdown report shows the top 10.

---

## Bring your own checks

checkup is built to be forked and adapted. The full fork-and-modify guide — what
to keep verbatim, what to swap, a worked example, "how to tell you're done", and
guidance for AI agents driving a port — lives in
**[docs/build-your-own.md](docs/build-your-own.md)**.

---

## Design rationale

Why the dual stream, per-check JSON, status-vs-score, and in-band intent: see
**[docs/architecture.md](docs/architecture.md#design-rationale)**. The deeper
decisions (pinning, layering, contribution model) are recorded as ADRs in
**[docs/decisions/](docs/decisions/)**.
