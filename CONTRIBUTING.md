# Contributing & engagement

checkup runs over other people's codebases — often sensitive ones — so it is
**itself a supply-chain element**. A poorly-reviewed change could weaponise it
(e.g. exfiltrate the data it's scanning). For that reason it is **not an
open-contribution project** (see [ADR-0006](docs/decisions/0006-restricted-contribution-model.md)):

- **Feedback, ideas, and bug reports are very welcome** — please open an
  [issue](https://github.com/maudlin/checkup/issues).
- **Forking and adapting is encouraged** — that's the intended use. checkup is a
  template; customisation belongs in _your_ copy (see [`AGENTS.md`](AGENTS.md)),
  not upstream.
- **Code changes are invitation-only** — from the maintainer and trusted
  contributors. Open an issue to discuss first; large unsolicited PRs may go
  unreviewed.
- **Security issues:** see [`SECURITY.md`](SECURITY.md) — report privately, not
  via a public issue/PR.

The rest of this file is for trusted contributors and anyone working on a fork.

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
bash test/run-tool.test.sh        # helper unit tests
```

CI runs exactly these, plus a `checkup-core` image build. `main` is protected:
changes land via PR with CI green.

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
  findings) in code, docs, commits, issues, or PRs — checkup is public. Use
  generic descriptions. (A CI gate enforces this.)
- New tool downloads are version-pinned **and** SHA256-verified — see
  [ADR-0001](docs/decisions/0001-pin-and-verify-tool-downloads.md).
- Conventional-commit style subjects (`feat:`, `fix:`, `docs:`).

## Stacks & overlays

Cross-stack checks live in `bin/checkup.sh` (the `checkup-core` image).
Language-specific tooling belongs in a per-stack overlay (see
[`bin/checkup-dotnet.sh`](bin/checkup-dotnet.sh) and
[`Dockerfile.dotnet`](Dockerfile.dotnet)) — and the [`ROADMAP.md`](ROADMAP.md)
for the command-profile direction.
