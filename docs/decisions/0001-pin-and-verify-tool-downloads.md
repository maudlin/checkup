# 0001 — Pin & verify every tool download

- **Status:** Accepted (2026-06-12)

## Context

checkup bakes third-party tools into its images. A pinned version *tag* only
trusts that the tag still points at the same bytes — a re-tag or a compromised
release would slip straight in. This is not hypothetical: the Trivy ecosystem
had a published "supply chain temporarily compromised" advisory. Because users
run checkup over their own (often sensitive) code, a tampered tool is high-impact.

## Decision

Every downloaded tool is **version-pinned _and_ SHA256-verified before use**
(`sha256sum -c`), and **signature-verified** where the project publishes one
(cosign/sigstore, GPG). Prefer the project's own published checksum; where none
exists, pin-on-known-good with a comment saying so. Language-package installs
(pip, NuGet) are at least version-pinned.

## Consequences

- A swapped or re-tagged upstream artifact **fails the build** instead of
  shipping — the intended safety, at the cost of a deliberate hash refresh on
  every version bump.
- Rolling scripts with no versioned URL (e.g. `dotnet-install.sh`) need a manual
  hash refresh when upstream updates them.
- Residual hardening (tracked): pip `--require-hashes` for full transitive
  pinning; GPG verification for tools that publish only a signature.
