# 0005 — checkup is a template, not a product

- **Status:** Accepted (2026-06-12)

## Context

No single configuration fits every repository, and trying to make checkup
perfectly self-configuring is a losing game. The valuable, durable parts are the
contract, the curated toolbelt, and the graceful-degrade discipline — not a
particular set of enabled checks and thresholds.

## Decision

Ship a broadly-working default and expect **downstream tailoring**: enable/
disable checks, tune thresholds, prune noise, record choices in `.checkup.yml`.
Two modes make the intent explicit — **tailored** (a repo you own; default
output is a starting point) and **audit** (a repo you don't; run broad and
unconfigured, breadth over fit). "Take the principles and build your own" is a
first-class path, not a fallback.

## Consequences

- Default output is a starting point, not a verdict; agents are told to adapt it
  (see [`AGENTS.md`](../../AGENTS.md)).
- Due-diligence on a repo you don't own is the deliberate exception — run it
  broad, as-is.
- Implies the restricted contribution model in [ADR-0006](0006-restricted-contribution-model.md):
  customisation belongs in *your* copy, not upstream.
