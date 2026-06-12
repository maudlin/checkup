# Build your own

checkup is a template, not a product — "take the principles and build your own"
is a first-class path (ADR-0005). The reusable core is the
[contract](architecture.md), not the bundled images. Keep your customisations in
**your** copy; this upstream is generic and isn't a place to send them
(ADR-0006).

## Run the bare runner on a host

No image needed. checkup degrades to whatever tools are on `$PATH`:

```bash
git clone https://github.com/maudlin/checkup && cd checkup
# install only the tools you care about, e.g.:
#   apt install shellcheck   |   brew install gitleaks scc semgrep
CHECKUP_TARGET=/path/to/repo CHECKUP_OUT_DIR=/tmp/out bin/checkup.sh
```

Absent tools `skip` honestly — you get exactly the checks your host can run.

## A slim custom image

Copy only the tool blocks you want from [`Dockerfile`](../Dockerfile) into your
own image. Each block is self-contained and carries its pinned checksum — keep
the `sha256sum -c` verification when you copy it (ADR-0001):

```dockerfile
FROM debian:bookworm-slim
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash git jq curl ca-certificates && rm -rf /var/lib/apt/lists/*
# paste the gitleaks + scc RUN blocks (with their *_SHA256 ARGs) from Dockerfile
COPY bin/ /opt/checkup/bin/
COPY lib/ /opt/checkup/lib/
ENTRYPOINT ["/opt/checkup/bin/checkup.sh"]
```

## Extract a baked binary

```bash
docker create --name tmp checkup-core
docker cp tmp:/usr/local/bin/gitleaks ./gitleaks
docker rm tmp
```

See [tools.md](tools.md) for the full catalogue and upstreams.

## Opt-in: deep dependency-CVE scanning (Trivy / OSV)

Deep SCA is a deliberate **non-goal** for core (see [`ROADMAP.md`](../ROADMAP.md)
— checkup is not a dedicated security scanner). The lightweight dep signals stay
in: `npm-audit` (core) and `dotnet-vuln` (the .NET overlay). If you want
cross-ecosystem CVE scanning, bolt it on in **your** copy as one more check.

Add the binary to your image (pinned + SHA256-verified, ADR-0001) — e.g. Trivy:

```dockerfile
# in your tools stage:
ARG TRIVY_VERSION=0.71.0
ARG TRIVY_SHA256=<sha256 from the release's checksums.txt>
RUN curl -fsSL -o trivy.tar.gz \
      "https://github.com/aquasecurity/trivy/releases/download/v${TRIVY_VERSION}/trivy_${TRIVY_VERSION}_Linux-64bit.tar.gz"; \
    echo "${TRIVY_SHA256}  trivy.tar.gz" | sha256sum -c -; \
    tar -xzf trivy.tar.gz; install -m 0755 trivy /usr/local/bin/trivy
```

Then add a section to your `bin/checkup.sh` following the worked-example shape
below — `trivy fs --scanners vuln --format json --output "$OUT" .`, mapping
`CRITICAL/HIGH` → `fail`, `MEDIUM/LOW` → `warn`. Note Trivy downloads its vuln DB
on first run (needs network, or a pre-seeded cache for sealed/`--network none`
runs); [OSV-Scanner](https://github.com/google/osv-scanner) is a lighter
lockfile-only alternative.

---

## Forking the substrate into a new repo

The contract, the helpers, and the renderer are stable surface area — your
project supplies the sections. Written for two audiences: a human porting the
substrate, and an AI agent driving that port. Both need to know what to keep,
what to swap, what to remove, and how to tell when they're done.

### Keep verbatim

Framework-agnostic and load-bearing — copy as-is, do not modify:

- `lib/run-tool.sh` — the `run_tool` / `write_parsed` / `write_skipped` /
  `write_failed` / `is_valid_json` / `slug` helpers. Their signatures are the
  contract; modifying them silently breaks every section that depends on them.
- `bin/checkup-report.sh` — the renderer. Tool-agnostic: reads
  `reports/parsed/*.json`, writes the report + focus & by-file aggregates.
- The status vocabulary (`pass`/`warn`/`fail`/`skip`), severity vocabulary
  (`critical`/`error`/`high`/`warning`/`medium`/`low`/`style`/`info`), and the
  parsed-JSON shape (`{slug, status, count, summary, top, intent}`). Drift here
  breaks the cross-tool aggregates.

### Swap for your project

Some assumptions are **env-configurable** (no code edit); others are **baked into
`bin/checkup.sh`** and a fork substitutes them in source.

Env-configurable (see the README's Environment variables):

| Assumption                           | Override with                                    |
| ------------------------------------ | ------------------------------------------------ |
| `src server` as source roots         | `CHECKUP_SRC_ROOTS="app internal cmd"`           |
| shell-script dirs for shellcheck     | `CHECKUP_SHELL_DIRS="scripts .githooks"`         |
| `Dockerfile` as hadolint target      | `HADOLINT_DOCKERFILE=Dockerfile.app`             |
| project root to scan                 | `CHECKUP_TARGET=/path/to/project`                |

Baked in — substitute in source:

| Assumption                                       | Where                                | Swap for                                            |
| ------------------------------------------------ | ------------------------------------ | --------------------------------------------------- |
| `npm run <script>` indirection                   | every project-built section          | your build system (`pnpm`, `yarn`, `make`, `cargo`, `go test`, …) |
| `.svelte-kit/`, `.prisma/` as scc exclusions     | scc (codebase-stats)                 | your framework's generated dirs (harmless if absent) |
| `.gitleaks.toml` as the secret-scan config       | gitleaks section                     | your config name (see `examples/`), or remove       |
| Conventional Commits (`feat:`/`fix:`/`Revert`)   | bug-fix-density                       | your convention, or "any non-merge commit"          |

A reliable grep for the scaffolding that remains baked in:

```bash
grep -nE 'npm run|\.svelte-kit|\.prisma|gitleaks\.toml|grep=.fix' bin/checkup.sh
```

### Remove if irrelevant

Each section's `LAST_EXIT == 127` path already writes a graceful `skip` when its
tool isn't installed, so sections self-disable. Delete a section only if it
actively misleads. Removal is cheap: delete the block from `bin/checkup.sh` — the
renderer iterates `reports/parsed/`, so a missing parsed JSON simply absents
itself from the report.

### Worked example: adding a check

The `shellcheck` section (~80 lines) is a good template. Adding a `ruff`
(Python lint) check:

```bash
# section:    ruff
# purpose:    Lint Python source for common bugs and style drift.
# pass_means: Zero findings.
# fail_means: Any error-level finding — investigate.
print_section "Python Linting (ruff)"
RUFF_INTENT=$(jq -n '{
    purpose: "Lint Python source for common bugs and style drift.",
    pass_means: "Zero findings.", fail_means: "Any error-level finding — investigate."
}')
MAX_SCORE=$((MAX_SCORE + 5))
run_tool "Python Linting" ruff check --output-format=json .   # run_tool handles graceful-degrade
if [ "$LAST_EXIT" = "127" ]; then
    write_skipped "ruff" "ruff not installed (pipx install ruff)" "$RUFF_INTENT"
elif ! is_valid_json "$LAST_RAW"; then
    write_failed "ruff" "ruff produced unparseable output (exit $LAST_EXIT)" "$RUFF_INTENT"
else
    RUFF_TOTAL=$(jq 'length' "$LAST_RAW")
    RUFF_TOP=$(jq -c 'sort_by(.code,.filename,.location.row) | .[0:10]
        | map({file:.filename, line:.location.row, code:.code, severity:"warning",
               message:((.message // "") | gsub("\\s+";" ") | .[0:200])})' "$LAST_RAW")
    if [ "$RUFF_TOTAL" = "0" ]; then
        HEALTH_SCORE=$((HEALTH_SCORE + 5)); RUFF_STATUS="pass"; RUFF_SUMMARY="No findings"
    else
        RUFF_STATUS="fail"; RUFF_SUMMARY="$RUFF_TOTAL findings"
    fi
    write_parsed "ruff" "$RUFF_STATUS" "$RUFF_TOTAL" "$RUFF_SUMMARY" "$RUFF_TOP" "$RUFF_INTENT"
fi
```

The renderer picks up `reports/parsed/ruff.json` on the next run; the cross-tool
aggregates join the new findings automatically.

### How to tell you're done

1. **Smoke test:** `bash bin/checkup.sh` runs to completion (no parse errors).
2. **shellcheck clean:** `shellcheck -f json bin/checkup.sh | jq '[.[]|select(.level=="error")]|length'` → `0`.
3. **Parsed JSONs valid:** `jq . reports/parsed/*.json >/dev/null`.
4. **Schema conformance:** `jq -se 'all(has("slug") and has("status") and has("count") and has("summary") and has("top") and has("intent"))' reports/parsed/*.json`.
5. **Status vocabulary:** `jq -r '.status' reports/parsed/*.json | sort -u` ⊆ `pass|warn|fail|skip`.
6. **Helper tests** (if you touched `lib/run-tool.sh`): `bash test/run-tool.test.sh`.

### For AI agents driving the fork

- **Don't redesign the contract.** The helpers, the parsed-JSON shape, and the
  vocabularies are stable; other sections depend on them. Want a new field?
  Propose it to the human first.
- **Don't skip the intent block.** Every section declares `purpose` /
  `pass_means` / `fail_means` — it's what makes the parsed stream
  self-describing for LLMs. Omitting it is the most common silent degradation.
- **Don't drop graceful-degrade.** Every section handles `LAST_EXIT == 127` with
  a `skip`. A missing tool is never an orchestrator failure.

## Your own stack overlay

`FROM checkup-core`, add that one stack's toolbelt (nothing extraneous —
ADR-0004), and add the stack's checks in the
[`checkup-dotnet`](../bin/checkup-dotnet.sh) shape: run core, append your
`parsed/*.json`, render once. A new bundled tool must be version-pinned **and**
SHA256-verified.

---

If you build something broadly useful (a new _universal_ check, a bug fix), open
an issue to discuss — but project-specific tailoring belongs in your copy, not a
PR here (ADR-0006).
