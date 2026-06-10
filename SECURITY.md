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

## What this tool reports is not a vulnerability in checkup

Findings checkup surfaces about a *scanned* project (secrets, SQLi, etc.) are
about that project, not checkup. Handle a scan's output as sensitive — it can
contain credentials and exploitable locations — and keep it out of public repos.
