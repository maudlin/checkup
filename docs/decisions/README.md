# Architecture Decision Records

Point-in-time records of **why** checkup is built the way it is — the rationale,
alternatives, and consequences behind decisions that aren't obvious from the code.

ADRs are **immutable**: don't edit a decision when reality changes, supersede it
with a new one (and flip the old one's status). For *how it works now* see
[`../`](../) (evergreen docs) and the [`README`](../../README.md); for *what's
next* see the [`ROADMAP`](../../ROADMAP.md).

Format: **Context · Decision · Consequences · Status**.

| #    | Title                                                            | Status   |
| ---- | --------------------------------------------------------------- | -------- |
| 0001 | [Pin & verify every tool download](0001-pin-and-verify-tool-downloads.md) | Accepted |
| 0002 | [Normalised parsed-JSON contract + tool-agnostic renderer](0002-normalised-parsed-json-contract.md) | Accepted |
| 0003 | [Honest graceful-degrade](0003-honest-graceful-degrade.md)       | Accepted |
| 0004 | [Layered images (core + per-stack overlays)](0004-layered-images.md) | Accepted |
| 0005 | [checkup is a template, not a product](0005-template-not-product.md) | Accepted |
| 0006 | [Restricted contribution model](0006-restricted-contribution-model.md) | Accepted |
| 0007 | [Human-gated merges (agents never self-merge)](0007-human-gated-merges.md) | Accepted |
| 0008 | [Network isolation as the primary exfiltration control](0008-network-isolation.md) | Accepted |
| 0009 | [checkup is a deterministic health localiser, not a deploy gate](0009-deterministic-health-localiser.md) | Accepted |
| 0010 | [Knowledge-concentration (key-person / bus-factor) forensic check](0010-knowledge-concentration-forensic.md) | Accepted |
