# 0004 — Layered images (core + per-stack overlays)

- **Status:** Accepted (2026-06-12)

## Context

Full tool coverage needs both universal tools and per-language toolchains.
Bundling everything makes one enormous image — nobody scanning Go should have to
pull a ~1.6 GB .NET SDK. But "install eight tools yourself" is the friction the
container was meant to remove.

## Decision

Layer the images: **`checkup-core`** (small, universal, no language runtimes) +
**per-stack overlays** (`checkup-dotnet`, …, each `FROM checkup-core`, one
stack's toolbelt only) + an optional **`checkup-everything`** for polyglot /
due-diligence. The runner itself stays language-agnostic and degrades (ADR-0003),
so it also runs on a host with whatever tools are on `$PATH`.

## Consequences

- Users pull only the tag matching their repo.
- Discipline: one overlay = one stack; nothing extraneous in core (a CI size
  budget is planned to enforce it).
- `checkup-everything` exists for the "unknown/mixed stack" case but is opt-in
  and labelled large.
