# 0007 — Human-gated merges (agents never self-merge)

- **Status:** Accepted (2026-06-12)

## Context

checkup is a supply-chain element (ADR-0006) — it runs over sensitive
codebases. The **merge to `main` is the review chokepoint**: it's the moment an
unreviewed change ships to everyone who pulls the tool. Multiple AI agents now
operate on the repo, and an agent that can both _open_ and _merge_ its own change
makes that review hollow — a compromised or mistaken agent could ship a malicious
change (e.g. data exfiltration) with nothing in the way.

## Decision

Every change follows **issue → branch (`<issue#>-slug`) → PR (`Closes #N`) → CI
green → a human merges (squash)**. **Agents never merge** — they open the PR and
hand off. Enforced by:

- **Branch protection** (hard): no direct pushes to `main`, required CI checks,
  linear history, no force-push.
- **Convention** (AGENTS.md): agents do not run a merge.

## Consequences

- A human is always in the loop at the point of shipping.
- Today the human-merge rule is _convention_, not hard-enforced: agents and the
  maintainer currently share one account, and required-approvals can't gate that
  (you can't approve your own PR). To make it hard-enforced, give agents a
  **separate identity** (bot account / GitHub App) and add a required human
  approval (CODEOWNERS) — deferred until the agent fleet warrants it.
- Slightly slower than self-merge — an accepted cost for a security tool.
