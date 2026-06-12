# AGENTS.md

Agent guidance for the **checkup** repo. Terse by design.

## What this is

checkup is a **template**, not a product. The real artefact is the contract —
normalised `parsed/<slug>.json`, the graceful-degrade rule, and the tool-agnostic
renderer. The bundled tools and images are a curated default, not the point.

## If you are using checkup on a project

- **Adapt it freely.** Copy or fork it; enable/disable checks, change thresholds,
  swap tools, rewrite checks to fit the target. That is the intended use.
- **Keep your changes in your copy — do not send them back here.** This is a
  generic template, maintained privately; project-specific tailoring lives in
  _your_ repo (a `.checkup.yml`), not upstream. External submissions are not
  generally accepted — fork and make it yours.
- **Pick a mode:**
  - _tailored_ — a repo you own: detect the stack, enable what's relevant, tune,
    prune. Default output is a starting point, not the verdict.
  - _audit_ — a repo you don't own: run broad and unconfigured; breadth over fit;
    false positives are acceptable triage. Don't tailor it to flatter the report.

## If you are changing this repo (the template itself)

This repo is **public**. Hard rules:

- **No leaks.** No secrets, and no internal/client identifiers — codenames, site
  names, real paths from scanned apps, specific findings — in code, docs,
  commits, issues, or PRs. Use generic phrasing. CI enforces this.
- **Scan output is never committed** — it goes to `$CHECKUP_OUT_DIR`.
- **Pin + verify every tool download** — exact version, SHA256 (`sha256sum -c`),
  signature where published. A tag is not enough (see `docs/decisions/`).
- **Don't break consumers** — `parsed/<slug>.json` stays backward-compatible;
  absent tool / empty output → `skip`, never a false pass; keep `checkup-core`
  lean (one overlay = one stack). Respect MIT; don't bundle incompatible tools.
- **Process** — PRs only (`main` is protected), CI green before merge, linear
  history, no force-push. Conventional commits, British English.
- **Adding a check** — follow the contract ([`README.md`](README.md#the-contract)):
  documented `intent`, emit via `write_parsed`/`write_skipped`/`write_failed`.
  The renderer picks it up automatically.

## Map

use → `README.md` · why, frozen → `docs/decisions/` (ADRs) · how, living →
`docs/` · next → `ROADMAP.md` + Issues (milestone `v0.2.0`)
