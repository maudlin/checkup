# Security Policy

## Reporting a vulnerability

Please **do not open a public issue** for security vulnerabilities.

Report privately via GitHub's **[Report a vulnerability](https://github.com/maudlin/checkup/security/advisories/new)**
(Security → Advisories → Report a vulnerability). We aim to acknowledge within a
few days and will coordinate a fix and disclosure with you.

## Scope

checkup is a static-analysis tool that runs other people's tools over a target
repository. The most relevant concerns are:

- **The container images** (`checkup-core`, `checkup-dotnet`) — baked tool
  versions, supply-chain integrity of the downloads, and the image running as
  root (a known hardening item — see [`ROADMAP.md`](ROADMAP.md)).
- **The orchestrator** processing untrusted repository content / tool output —
  the report renderer sanitises tool-influenced fields (whitespace-collapse and
  HTML-escape) before they reach the Markdown report; report any way to break out
  of that.

## Running it safely on sensitive code (recommended)

checkup runs third-party tools over your source, so treat the scanner as
potentially hostile and **deny it the ability to leak or tamper**. For
sensitive or due-diligence scans, run it sealed:

```bash
docker run --rm --network none \
  --read-only --tmpfs /tmp \
  --cap-drop ALL --security-opt no-new-privileges \
  -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup-core
```

- `--network none` — **no egress**, so nothing can exfiltrate the scanned code
  (the primary exfiltration control; see ADR-0008).
- `-v …:/src:ro` — source mounted read-only; the scan can't modify your repo.
- `--read-only --tmpfs /tmp` — no persistence outside the mounted `/out`.
- `--cap-drop ALL --security-opt no-new-privileges` — no capabilities, no escalation.

**Caveat:** two checks need network and will `skip` under `--network none` until
they're provisioned offline — `semgrep` (`--config auto` fetches rules) and
`trivy` (downloads its vuln DB on first run). Everything else (gitleaks, scc,
shellcheck, yamllint, hadolint, git-forensics, the Classic-ASP rules) runs fully
air-gapped today. Making sealed mode lossless is tracked in the ROADMAP / issues.

## What this tool reports is not a vulnerability in checkup

Findings checkup surfaces about a *scanned* project (secrets, SQLi, etc.) are
about that project, not checkup. Handle a scan's output as sensitive — it can
contain credentials and exploitable locations — and keep it out of public repos.
