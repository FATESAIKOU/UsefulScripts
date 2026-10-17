FROM ubuntu:24.04

ARG DEBIAN_FRONTEND=noninteractive
ARG RUNNER_VERSION=2.338.0

# 1. System packages, runner dependencies (.NET 8 runtime), and Python 3.12
RUN apt-get update && apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    jq \
    bash \
    tar \
    gzip \
    unzip \
    gnupg \
    libicu74 \
    libssl3t64 \
    libkrb5-3 \
    zlib1g \
    python3 \
    python3-pip \
    python3-venv \
    python3-yaml \
    openssh-client \
    python3-pytest \
    gettext-base \
    fzf \
    openssl \
    rsync \
    && rm -rf /var/lib/apt/lists/*

# Install PyYAML, jsonschema, and linode-cli via pip for workflow requirements
RUN pip install --no-cache-dir --break-system-packages pyyaml jsonschema linode-cli

# 2. Install GitHub CLI (gh)
RUN mkdir -p -m 755 /etc/apt/keyrings \
    && curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg -o /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && chmod go+r /etc/apt/keyrings/githubcli-archive-keyring.gpg \
    && echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" > /etc/apt/sources.list.d/github-cli.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends gh \
    && rm -rf /var/lib/apt/lists/*

# 3. Install Node.js 24 (node, npm, npx)
RUN curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
    && apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/*

# 4. Setup hostedtoolcache structure and create unprivileged runner user
ENV RUNNER_TOOL_CACHE=/opt/hostedtoolcache
ENV PIP_BREAK_SYSTEM_PACKAGES=1 \
    PIP_USER=1 \
    PATH="/home/runner/.local/bin:${PATH}"

ARG RUNNER_UID=1001

RUN set -eu; \
    existing_user="$(getent passwd "${RUNNER_UID}" | cut -d: -f1 || true)"; \
    if [ -n "${existing_user}" ] && [ "${existing_user}" != "runner" ]; then \
        userdel -r "${existing_user}" 2>/dev/null || userdel "${existing_user}"; \
    fi; \
    useradd -m -u "${RUNNER_UID}" -s /bin/bash runner \
    && mkdir -p /runner /work /opt/hostedtoolcache

RUN set -eu; \
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "${dpkg_arch}" in \
        amd64) arch="x64" ;; \
        arm64) arch="arm64" ;; \
        *) arch="${dpkg_arch}" ;; \
    esac; \
    py_ver="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}.{sys.version_info.micro}")')"; \
    node_ver="$(node -v | sed 's/^v//')"; \
    mkdir -p "/opt/hostedtoolcache/Python/${py_ver}/${arch}/bin"; \
    ln -s "$(which python3)" "/opt/hostedtoolcache/Python/${py_ver}/${arch}/bin/python3"; \
    ln -s "$(which python3)" "/opt/hostedtoolcache/Python/${py_ver}/${arch}/bin/python"; \
    if command -v pip3 >/dev/null 2>&1; then \
        ln -s "$(which pip3)" "/opt/hostedtoolcache/Python/${py_ver}/${arch}/bin/pip3"; \
        ln -s "$(which pip3)" "/opt/hostedtoolcache/Python/${py_ver}/${arch}/bin/pip"; \
    fi; \
    touch "/opt/hostedtoolcache/Python/${py_ver}/${arch}.complete"; \
    mkdir -p "/opt/hostedtoolcache/node/${node_ver}/${arch}/bin"; \
    ln -s "$(which node)" "/opt/hostedtoolcache/node/${node_ver}/${arch}/bin/node"; \
    if command -v npm >/dev/null 2>&1; then \
        ln -s "$(which npm)" "/opt/hostedtoolcache/node/${node_ver}/${arch}/bin/npm"; \
    fi; \
    if command -v npx >/dev/null 2>&1; then \
        ln -s "$(which npx)" "/opt/hostedtoolcache/node/${node_ver}/${arch}/bin/npx"; \
    fi; \
    touch "/opt/hostedtoolcache/node/${node_ver}/${arch}.complete"; \
    chown -R runner:runner /opt/hostedtoolcache /runner /work

# 5. Install GitHub Actions Runner
RUN set -eu; \
    dpkg_arch="$(dpkg --print-architecture)"; \
    case "${dpkg_arch}" in \
        amd64) runner_arch="x64" ;; \
        arm64) runner_arch="arm64" ;; \
        *) echo "Unsupported architecture: ${dpkg_arch}" >&2; exit 1 ;; \
    esac; \
    curl -fsSL -o /tmp/runner.tar.gz "https://github.com/actions/runner/releases/download/v${RUNNER_VERSION}/actions-runner-linux-${runner_arch}-${RUNNER_VERSION}.tar.gz" \
    && tar -xzf /tmp/runner.tar.gz -C /runner \
    && rm -f /tmp/runner.tar.gz \
    && chown -R runner:runner /runner

COPY entrypoint.sh /entrypoint.sh
RUN chmod 0755 /entrypoint.sh

USER runner
WORKDIR /runner
ENTRYPOINT ["/entrypoint.sh"]
