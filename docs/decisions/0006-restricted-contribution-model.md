# 0006 — Restricted contribution model

- **Status:** Accepted (2026-06-12)

## Context

checkup runs over other people's codebases — frequently sensitive ones (security
review, tech due diligence). That makes checkup **itself a supply-chain
element**: a poorly-reviewed or malicious change could weaponise it — e.g. make
it exfiltrate the very data it's scanning. Maintainer review bandwidth is also
limited, and unreviewed merges are exactly the risk above.

## Decision

checkup is **not an open-contribution project**:

- **Feedback, ideas, and bug reports are welcome** — via issues.
- **Forking and adapting is encouraged** — that's the intended use (ADR-0005);
  customisation lives in your copy, not upstream.
- **Code changes are invitation-only** — from the maintainer and trusted
  contributors. Open an issue first; large unsolicited PRs may go unreviewed.
- **All changes are tightly reviewed**, security-sensitive ones especially.

## Consequences

- Protects downstream users from a supply-chain compromise of the tool.
- Lower community velocity / fewer external merges — an accepted trade for a
  security tool.
- The public repo still benefits everyone (read, fork, learn, run) without the
  risk of an open merge door.
