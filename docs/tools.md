# Tool manifest

The third-party tools checkup bundles, by image layer. This is the catalogue +
SBOM + "what would I cherry-pick" shopping list.

**The Dockerfiles are the single source of truth for the pinned bytes.** Each
binary's exact SHA256 lives in a `*_SHA256` build ARG in
[`Dockerfile`](../Dockerfile) / [`Dockerfile.dotnet`](../Dockerfile.dotnet); we
deliberately don't duplicate the hashes here, so they can't drift. (Why we pin
and verify at all: [ADR-0001](decisions/0001-pin-and-verify-tool-downloads.md).)

## `checkup-core`

| Tool         | Version | Upstream                          | Verified by                                     |
| ------------ | ------- | --------------------------------- | ----------------------------------------------- |
| shellcheck   | 0.11.0  | github.com/koalaman/shellcheck    | SHA256 (pinned-on-known-good — no upstream sum) |
| hadolint     | 2.14.0  | github.com/hadolint/hadolint      | SHA256 (matches upstream `.sha256`)             |
| gitleaks     | 8.30.1  | github.com/gitleaks/gitleaks      | SHA256 (matches upstream `checksums.txt`)       |
| scc          | 3.7.0   | github.com/boyter/scc             | SHA256 (matches upstream `checksums.txt`)       |
| trivy        | 0.71.0  | github.com/aquasecurity/trivy     | SHA256 (matches the cosign-signed `checksums.txt`) |
| semgrep      | 1.165.0 | PyPI                              | version pin (PyPI over TLS)                     |
| yamllint     | 1.35.1  | PyPI                              | version pin (PyPI over TLS)                     |
| git, jq, python3 | distro | Debian bookworm               | distro package manager                          |

## `checkup-dotnet` (overlay, `FROM checkup-core`)

| Tool        | Version | Upstream                       | Verified by                                                       |
| ----------- | ------- | ------------------------------ | ---------------------------------------------------------------- |
| .NET SDK    | 8.0.422 | dot.net / Microsoft            | install script SHA256 + script verifies the SDK package checksum |
| DevSkim CLI | 1.0.70  | NuGet (Microsoft.CST.DevSkim.CLI) | version pin (NuGet package integrity)                         |
| PMD (CPD)   | 7.25.0  | github.com/pmd/pmd             | SHA256 (pinned-on-known-good — upstream ships only a GPG `.asc`) |
| JRE         | 17      | Debian bookworm (default-jre-headless) | distro package manager                                  |

## Bumping a tool

1. Update the `*_VERSION` ARG in the Dockerfile.
2. Recompute the SHA256 of the new asset and update the `*_SHA256` ARG —
   **prefer the project's own published checksum**; only pin-on-known-good when
   none is published.
3. Rebuild; the `sha256sum -c` step proves the new bytes match before the image
   is produced.

## Extracting / cherry-picking a tool

- **From a built image:** `docker create --name x checkup-core` then
  `docker cp x:/usr/local/bin/<tool> .` then `docker rm x`.
- **Into your own slim image:** copy the relevant `FROM … RUN curl … sha256sum -c`
  block from the Dockerfile — it's self-contained and carries the pinned hash.
- **On a host:** install the tool yourself and run `bin/checkup.sh`; checks
  degrade to whatever is present (see [build-your-own](build-your-own.md)).
