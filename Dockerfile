# syntax=docker/dockerfile:1
#
# checkup-core — the language-neutral Application Checkup image.
#
# Bakes the cross-stack diagnostic tools so you can examine ANY repository with
# zero host installs:
#
#   docker run --rm -v "$PWD:/src:ro" -v "$PWD/checkup-out:/out" checkup-core /src
#
# Active on any repo: gitleaks (secrets), semgrep (SAST), shellcheck, yamllint,
# hadolint, scc (stats), and the git-forensics axis (churn / coupling /
# bug-fix density / branch hygiene). Language- and build-specific checks
# (typecheck, test, build, lint, coverage) belong to per-stack overlays — see
# ROADMAP.md — and skip cleanly here.
#
# v1 targets linux/amd64. Multi-arch (arm64) is a ROADMAP item: the binary
# URLs below are arch-specific and would key off TARGETARCH.

# ---- stage 1: fetch + unpack pinned static binaries ----
FROM debian:bookworm-slim AS tools
ARG SHELLCHECK_VERSION=0.11.0
ARG HADOLINT_VERSION=2.14.0
ARG GITLEAKS_VERSION=8.30.1
ARG SCC_VERSION=3.7.0
RUN apt-get update && apt-get install -y --no-install-recommends \
        curl ca-certificates xz-utils tar \
    && rm -rf /var/lib/apt/lists/*
WORKDIR /dl
RUN set -eux; \
    # shellcheck — static, .xz tarball
    curl -fsSL "https://github.com/koalaman/shellcheck/releases/download/v${SHELLCHECK_VERSION}/shellcheck-v${SHELLCHECK_VERSION}.linux.x86_64.tar.xz" | tar -xJ; \
    install -m 0755 "shellcheck-v${SHELLCHECK_VERSION}/shellcheck" /usr/local/bin/shellcheck; \
    # hadolint — single static binary (asset name is lowercase 'linux')
    curl -fsSL -o /usr/local/bin/hadolint "https://github.com/hadolint/hadolint/releases/download/v${HADOLINT_VERSION}/hadolint-linux-x86_64"; \
    chmod 0755 /usr/local/bin/hadolint; \
    # gitleaks — .tar.gz (linux_x64)
    curl -fsSL "https://github.com/gitleaks/gitleaks/releases/download/v${GITLEAKS_VERSION}/gitleaks_${GITLEAKS_VERSION}_linux_x64.tar.gz" | tar -xz; \
    install -m 0755 gitleaks /usr/local/bin/gitleaks; \
    # scc — .tar.gz (asset name carries no version, only the tag does)
    curl -fsSL "https://github.com/boyter/scc/releases/download/v${SCC_VERSION}/scc_Linux_x86_64.tar.gz" | tar -xz; \
    install -m 0755 scc /usr/local/bin/scc

# ---- stage 2: runtime ----
FROM debian:bookworm-slim
ARG YAMLLINT_VERSION=1.35.1
# semgrep is intentionally unpinned for v1 so the image builds against the
# current release. Pin it for reproducible due-diligence reports — see ROADMAP.
RUN apt-get update && apt-get install -y --no-install-recommends \
        bash git jq ca-certificates python3 python3-pip \
    && pip3 install --no-cache-dir --break-system-packages \
        "yamllint==${YAMLLINT_VERSION}" semgrep \
    && apt-get purge -y --auto-remove python3-pip \
    && rm -rf /var/lib/apt/lists/* /root/.cache

COPY --from=tools /usr/local/bin/shellcheck /usr/local/bin/shellcheck
COPY --from=tools /usr/local/bin/hadolint  /usr/local/bin/hadolint
COPY --from=tools /usr/local/bin/gitleaks  /usr/local/bin/gitleaks
COPY --from=tools /usr/local/bin/scc       /usr/local/bin/scc

# checkup itself
COPY bin/ /opt/checkup/bin/
COPY lib/ /opt/checkup/lib/
COPY docker/entrypoint.sh /opt/checkup/entrypoint.sh
RUN chmod +x /opt/checkup/bin/*.sh /opt/checkup/entrypoint.sh

# Convention: scan target mounted read-only at /src, report written to /out.
ENV CHECKUP_TARGET=/src \
    CHECKUP_OUT_DIR=/out
WORKDIR /src
ENTRYPOINT ["/opt/checkup/entrypoint.sh"]
