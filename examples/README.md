# Example configs

Drop-in starting points for the linters checkup drives. Each is **optional** — the
matching check runs on tool defaults if you don't supply one, and skips
cleanly if the tool itself isn't installed. Copy the ones you want to your
project root and tune them.

| File                          | Copy to your project root as  | Used by check     |
| ----------------------------- | ----------------------------- | ----------------- |
| `gitleaks.toml`               | `.gitleaks.toml`              | `gitleaks`        |
| `yamllint.yml`                | `.yamllint.yml`               | `yamllint`        |
| `shellcheckrc`                | `.shellcheckrc`               | `shellcheck`      |
| `hadolint.yaml`               | `.hadolint.yaml`              | `hadolint`        |
| `eslint.config.type-aware.js` | `eslint.config.type-aware.js` | `type-aware-lint` |

The `gitleaks` check **requires** a `.gitleaks.toml` to run (otherwise it
skips). The `type-aware-lint` check requires `eslint.config.type-aware.js`.
The rest fall back to tool defaults.
