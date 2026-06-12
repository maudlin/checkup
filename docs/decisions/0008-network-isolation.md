# 0008 — Network isolation as the primary exfiltration control

- **Status:** Accepted (2026-06-12)

## Context

checkup runs third-party tools over a target's source — often sensitive code
(security review, tech due diligence). That makes the scanner a place where, if
any baked tool, check, or dependency were compromised (ADR-0006), it could
**exfiltrate the very data it's reading**. Auditing every tool's runtime
behaviour to prove it never phones home is intractable and fragile.

## Decision

Treat the scanner as potentially hostile and **deny it egress** rather than try
to prove good behaviour. The recommended invocation for sensitive scans runs the
container with **no network** plus a minimal sandbox:

```
docker run --rm --network none --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup-core
```

If the container can't reach the internet, scanned data can't leave through it,
regardless of intent. This is documented in `SECURITY.md` as the recommended way
to run on sensitive code.

## Consequences

- The strongest single anti-exfiltration guarantee, independent of any tool's
  trustworthiness — complements the restricted contribution model (ADR-0006) and
  the supply-chain pinning (ADR-0001).
- `--network none` is an **operator-side flag** — the image can't self-enforce
  it; the docs make it the default recommendation for sensitive runs.
- One check needs network and `skip`s under no-egress until provisioned offline:
  `semgrep` (`--config auto`). Making sealed mode **lossless** — bundling an
  offline semgrep ruleset — is the open follow-up; everything else already runs
  air-gapped.
