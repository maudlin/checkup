# Contributing to checkup

Thanks for your interest. checkup is a small, contract-driven Bash codebase —
adding a check or a tool is deliberately a local, isolated change.

## Dev setup

No build step. You need `bash`, `jq`, and the tool a given check drives
(`shellcheck`, `semgrep`, `scc`, …) — or just use the Docker image, which bakes
the cross-stack tools:

```bash
docker build -t checkup-core .
```

## Before you open a PR

```bash
shellcheck --severity=error bin/*.sh lib/*.sh docker/*.sh test/*.sh
for f in bin/*.sh lib/*.sh docker/*.sh test/*.sh; do bash -n "$f"; done
bash test/run-tool.test.sh        # 29 helper unit tests
```

CI runs exactly these, plus a `checkup-core` image build.

## Adding a check

Every check follows the contract documented in the [README](README.md#the-contract):

1. A registry-style comment block (`section`, `purpose`, `pass_means`, `fail_means`).
2. Documented `intent` JSON.
3. Emit a normalised `reports/parsed/<slug>.json` via `write_parsed` /
   `write_skipped` / `write_failed` (see [`lib/run-tool.sh`](lib/run-tool.sh)).
4. **Graceful degrade** — if the tool is absent, `write_skipped`; never fail or
   silently pass. Empty tool output is never "0 findings → pass".

The Markdown renderer is tool-agnostic: a new `parsed/<slug>.json` shows up in
the report automatically — no renderer changes needed.

## Conventions

- **British English** in docs and comments.
- **Never reference a specific scanned project** (names, real file paths,
  findings) in code, docs, or commit messages — checkup is public. Use generic
  descriptions.
- Conventional-commit style subjects (`feat:`, `fix:`, `docs:`).

## Stacks & overlays

Cross-stack checks live in `bin/checkup.sh` (the `checkup-core` image).
Language-specific tooling belongs in a per-stack overlay (see
[`bin/checkup-dotnet.sh`](bin/checkup-dotnet.sh) and
[`Dockerfile.dotnet`](Dockerfile.dotnet)) — and the [`ROADMAP.md`](ROADMAP.md)
for the command-profile direction.
