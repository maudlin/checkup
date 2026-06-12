# 0003 — Honest graceful-degrade

- **Status:** Accepted (2026-06-12)

## Context

Tools, language toolchains, and prerequisites are frequently absent (a non-Node
repo, a node-less core image, a non-git tree). Early versions degraded
*dishonestly*: absent tools produced empty output read as "0 findings → pass",
and a non-git repo's forensics reported a reassuring "no issues". For a
due-diligence report, a false green is worse than a wall of red.

## Decision

A check whose tool or prerequisite is absent emits **`skip` with a reason** — it
never fails spuriously, and **never reads empty tool output as a pass**.
Artifact-reading checks freshness-gate what they consume so a stale report can't
masquerade as a clean result.

## Consequences

- Reports are honest: "we didn't measure this, because X" is distinct from
  "this passed".
- Especially important in `audit` mode and the node-less `checkup-core`.
- More guard code per check (presence checks, exit-code/freshness handling) — an
  accepted cost; reviewers should treat a new "passes on empty output" path as a
  bug.
