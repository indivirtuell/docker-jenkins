# syntax=docker/dockerfile:1

# ---------------------------------------------------------------------------
# Builder stage
#
# Fetches and cryptographically verifies everything that does not come from a
# signed APT repository. Nothing from this stage ships in the final image
# except the verified sops binary and the dearmored Kubernetes APT key.
# ---------------------------------------------------------------------------
FROM debian:trixie-slim AS builder

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# cosign is the root of trust for the sops verification below, so it is pinned
# to an exact version and checksum. Bumping it means updating BOTH values from
# https://github.com/sigstore/cosign/releases (cosign_checksums.txt).
ARG COSIGN_VERSION=v3.1.3
ARG COSIGN_SHA256=4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71

RUN set -euxo pipefail; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates curl gnupg; \
    rm -rf /var/lib/apt/lists/*

# Install cosign, verified against its pinned checksum.
RUN set -euxo pipefail; \
    curl -fsSLo /usr/local/bin/cosign \
      "https://github.com/sigstore/cosign/releases/download/${COSIGN_VERSION}/cosign-linux-amd64"; \
    echo "${COSIGN_SHA256}  /usr/local/bin/cosign" | sha256sum -c -; \
    chmod 0755 /usr/local/bin/cosign; \
    cosign version

# Install sops.
#
# The version floats: the latest release is resolved from the GitHub redirect
# on https://github.com/getsops/sops/releases/latest (a plain HTTP redirect, so
# no GitHub API token and no API rate limits).
#
# Because the version is not pinned, the Sigstore bundle is what makes the
# download trustworthy. cosign proves the checksum file was produced by the
# getsops release workflow itself; sha256sum then binds the binary to that
# verified checksum. Any failure in this chain aborts the build.
WORKDIR /tmp
RUN set -euxo pipefail; \
    SOPS_VERSION="$(curl -fsSI https://github.com/getsops/sops/releases/latest \
      | tr -d '\r' \
      | sed -n 's#^location:.*/tag/\(v[^ ]*\)$#\1#Ip')"; \
    test -n "${SOPS_VERSION}"; \
    echo "Resolved sops ${SOPS_VERSION}"; \
    base="https://github.com/getsops/sops/releases/download/${SOPS_VERSION}"; \
    curl -fsSLO "${base}/sops-${SOPS_VERSION}.linux.amd64"; \
    curl -fsSLO "${base}/sops-${SOPS_VERSION}.checksums.txt"; \
    curl -fsSLO "${base}/sops-${SOPS_VERSION}.checksums.sigstore.json"; \
    cosign verify-blob \
      --bundle "sops-${SOPS_VERSION}.checksums.sigstore.json" \
      --certificate-identity-regexp '^https://github\.com/getsops/sops/\.github/workflows/release\.yml@refs/tags/v.+$' \
      --certificate-oidc-issuer 'https://token.actions.githubusercontent.com' \
      "sops-${SOPS_VERSION}.checksums.txt"; \
    grep " sops-${SOPS_VERSION}.linux.amd64\$" "sops-${SOPS_VERSION}.checksums.txt" | sha256sum -c -; \
    mkdir -p /out; \
    install -m 0755 "sops-${SOPS_VERSION}.linux.amd64" /out/sops

# Dearmor the Kubernetes APT key here so gnupg never has to be installed in the
# final image.
ARG KUBERNETES_MINOR=v1.33
RUN set -euxo pipefail; \
    mkdir -p /out/keyrings; \
    curl -fsSL "https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/Release.key" \
      | gpg --dearmor -o /out/keyrings/kubernetes-apt-keyring.gpg; \
    chmod 0644 /out/keyrings/kubernetes-apt-keyring.gpg

# ---------------------------------------------------------------------------
# Final image
# ---------------------------------------------------------------------------
FROM jenkins/jenkins:jdk21

LABEL org.opencontainers.image.authors="indivirtuell <office@indivirtuell.net>"
LABEL org.opencontainers.image.source="https://github.com/indivirtuell/docker-jenkins"
LABEL org.opencontainers.image.description="Jenkins controller with kubectl, sops, age and headless Chromium"

USER root

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# GID of the host's docker group, so the mounted docker socket is usable.
# Override at build time: --build-arg DOCKER_GID=$(getent group docker | cut -d: -f3)
ARG DOCKER_GID=988

# Must match the cluster's Kubernetes minor version (kubectl supports +/-1).
ARG KUBERNETES_MINOR=v1.33

COPY --from=builder /out/keyrings/kubernetes-apt-keyring.gpg /etc/apt/keyrings/kubernetes-apt-keyring.gpg

# Base packages. --no-install-recommends everywhere except chromium, whose
# recommends pull in the font packages headless rendering needs.
RUN set -euxo pipefail; \
    apt-get --allow-releaseinfo-change-suite update; \
    apt-get install -y --no-install-recommends \
      age \
      ca-certificates \
      curl \
      gettext-base \
      jq \
      rsync \
      xvfb; \
    apt-get install -y chromium; \
    apt-get dist-upgrade -y; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

# kubectl from the official Kubernetes APT repository: signed by the keyring
# above and verified by apt, so patch releases arrive on rebuild while the
# minor version stays pinned to the cluster.
RUN set -euxo pipefail; \
    echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${KUBERNETES_MINOR}/deb/ /" \
      > /etc/apt/sources.list.d/kubernetes.list; \
    chmod 0644 /etc/apt/sources.list.d/kubernetes.list; \
    apt-get update; \
    apt-get install -y --no-install-recommends kubectl; \
    apt-get clean; \
    rm -rf /var/lib/apt/lists/*

COPY --from=builder /out/sops /usr/local/bin/sops

RUN set -euxo pipefail; \
    groupadd -g "${DOCKER_GID}" docker; \
    usermod -aG docker jenkins

ENV CHROME_BIN=/usr/bin/chromium

USER jenkins

# Fail the build, not a pipeline at 2am, if anything is missing or unreadable
# for the jenkins user.
RUN set -euxo pipefail; \
    age --version; \
    age-keygen --version; \
    sops --version; \
    kubectl version --client; \
    jq --version; \
    rsync --version > /dev/null; \
    envsubst --version > /dev/null; \
    xvfb-run --help > /dev/null; \
    "${CHROME_BIN}" --version
