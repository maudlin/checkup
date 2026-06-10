# Example configs

Drop-in starting points for the linters checkup drives. Each is **optional** — the
matching check runs on tool defaults if you don't supply one, and skips
cleanly if the tool itself isn't installed. Copy the ones you want to your
project root and tune them.

| File                          | Copy to your project root as    | Used by check      |
| ----------------------------- | ------------------------------- | ------------------ |
| `gitleaks.toml`               | `.gitleaks.toml`                | `gitleaks`         |
| `yamllint.yml`                | `.yamllint.yml`                 | `yamllint`         |
| `shellcheckrc`                | `.shellcheckrc`                 | `shellcheck`       |
| `hadolint.yaml`               | `.hadolint.yaml`                | `hadolint`         |
| `eslint.config.type-aware.js` | `eslint.config.type-aware.js`   | `type-aware-lint`  |
| `semgrep-asp-classic.yml`     | _(pass to semgrep — see below)_ | manual semgrep run |

The `gitleaks` check **requires** a `.gitleaks.toml` to run (otherwise it
skips). The `type-aware-lint` check requires `eslint.config.type-aware.js`.
The rest fall back to tool defaults.

## Classic ASP / VBScript security rules (`semgrep-asp-classic.yml`)

semgrep has no AST parser for Classic ASP / VBScript, so `--config auto` finds
almost nothing in `.asp` files even though that's where the worst legacy bugs
live. This is a **generic-mode (regex) ruleset** for the classic vulnerability
classes — SQL injection by string concatenation, reflected XSS, dynamic
code/object execution of `Request` input, path traversal, and hardcoded
credentials. Run it directly:

```bash
semgrep scan --config examples/semgrep-asp-classic.yml /path/to/app
# or with the image, no install:
docker run --rm -v "$PWD:/src:ro" -v "$PWD/examples:/rules:ro" \
  --entrypoint semgrep checkup-core scan --config /rules/semgrep-asp-classic.yml /src
```

It is a **triage aid for a brownfield audit, not a gate**: generic mode can't see
VBScript comments, so commented-out code may flag. Tune the rules to the
codebase's patterns — this file is exactly the kind of last-mile tailoring an
agent (or you) drops in once the tools are already present.
