# 0002 — Normalised parsed-JSON contract + tool-agnostic renderer

- **Status:** Accepted (2026-06-12)

## Context

checkup combines many heterogeneous tools (linters, scanners, stats, forensics)
into one report, and needs to be extensible without every addition touching the
renderer. Tools emit wildly different formats.

## Decision

Every check emits a normalised `reports/parsed/<slug>.json`
(`{slug, status, count, summary, top, intent}`) via shared helpers
(`run_tool` / `write_parsed` / `write_skipped` / `write_failed`). A
**tool-agnostic renderer** iterates `parsed/*.json` to build the report
(summary, cross-tool Top Problems, by-file hotspots, per-check intent). This
contract — not the bundled tools — is the product.

## Consequences

- Adding a check needs **no renderer changes** — drop a new `parsed/<slug>.json`
  and it appears, including in the cross-cuts.
- The contract is re-implementable in any language; anyone can build their own
  checkup that emits the schema.
- The schema is a public interface → changes must stay **backward-compatible**.
