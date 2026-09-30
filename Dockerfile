# syntax=docker/dockerfile:1.7
#
# louisremi/deepseek-harness-dev
#
# runzhliu/deepseek-harness + two local patches + HolyClaude "slim" developer
# tooling. Every version below is pinned and kept current by Renovate (see
# renovate.json5); release binaries carry per-architecture sha256 values that
# scripts/refresh-checksums.py refreshes in the same PR. Read AGENTS.md before
# editing this file.
#
# ---------------------------------------------------------------------------
# Patch 1 -- bubblewrap
#
# dsh-sandbox-local's Linux runner chain is ["bwrap", "landlock"]. On nasbrico
# both rungs are missing out of the box: upstream ships no bubblewrap, and the
# Unraid kernel was built without CONFIG_SECURITY_LANDLOCK (the syscall returns
# ENOSYS, permanently). With an empty chain every bash tool call fails closed
# with SANDBOX_UNAVAILABLE and falls back to a danger-full-access escalation
# that must be approved once per command, forever. Installing bwrap restores
# the first rung, so commands are genuinely confined again and the prompts
# stop. Reported upstream as runzhliu/deepseek-harness-docker#35.
#
# bwrap is installed WITHOUT the setuid bit on purpose: the runtime keeps
# `no-new-privileges`, which neutralises setuid anyway. It works unprivileged
# via user namespaces, which needs compose security_opt values
# (seccomp=unconfined, systempaths=unconfined, and apparmor=unconfined on
# AppArmor hosts); see compose.example.yaml.
#
# Patch 2 -- SameSite=Lax
#
# Upstream mints the browser-session cookie at /?token= with SameSite=Strict.
# An installed Android PWA (WebAPK) launches via an intent, and Strict blocks
# that intent-initiated top-level navigation where Lax does not. Dropping this
# patch has been tried and failed (2026-09-23); confirmed still needed on
# 0.1.7-rc.2. The value is a literal inside a non-exported function of
# compiled output, so neither config nor a NODE_OPTIONS hook can reach it,
# and the runtime rootfs is read-only -- hence a guarded sed at build time.
# If upstream ever ships Lax itself the step becomes a no-op; if it rewords
# the string the build fails loudly instead of shipping an unpatched image.
# ---------------------------------------------------------------------------

# renovate: datasource=docker depName=runzhliu/deepseek-harness
ARG DSH_BASE_IMAGE=docker.io/runzhliu/deepseek-harness:0.2.0-rc.2-r1@sha256:9e77149170f11c444b734f0d11746722a708ac6bea5826689e4b7dbac8ffbda0

FROM ${DSH_BASE_IMAGE}

ARG DSH_BASE_IMAGE
ARG TARGETARCH

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

ENV DSH_MODULES=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai

# ---------- Patch 1: bubblewrap --------------------------------------------
# hadolint ignore=DL3008
RUN set -eux; \
    grep -Eq 'linux: \["bwrap"' "${DSH_MODULES}/dsh-sandbox-local/lib/index.js" \
      || { echo "PATCH GUARD: dsh-sandbox-local no longer prefers bwrap on linux; re-read the sandbox plugin before shipping" >&2; exit 1; }; \
    apt-get update; \
    apt-get install --yes --no-install-recommends bubblewrap; \
    rm -rf /var/lib/apt/lists/*; \
    test -x /usr/bin/bwrap; \
    test "$(stat -c '%a' /usr/bin/bwrap)" = "755"

# ---------- Patch 2: SameSite=Lax ------------------------------------------
RUN set -eux; \
    f="${DSH_MODULES}/dsh-client-connection/lib/index.js"; \
    if grep -q 'HttpOnly; SameSite=Strict' "$f"; then \
      sed -i 's/HttpOnly; SameSite=Strict/HttpOnly; SameSite=Lax/' "$f"; \
    fi; \
    grep -q 'HttpOnly; SameSite=Lax' "$f" \
      || { echo "PATCH GUARD: session cookie string not found in dsh-client-connection; upstream changed it" >&2; exit 1; }; \
    ! grep -q 'SameSite=Strict' "$f"

# ---------- Debian developer packages (HolyClaude slim parity) -------------
# Upstream (node:24-trixie + buildpack-deps) already provides git, curl, wget,
# jq, ripgrep, unzip, zip, less, rsync, openssh-client, procps, python3,
# gcc/make, chromium, xvfb and fonts. Debian packages track the pinned trixie
# snapshot of the base image and are refreshed by the weekly rebuild.
# hadolint ignore=DL3008
RUN set -eux; \
    apt-get update; \
    apt-get install --yes --no-install-recommends \
      bat \
      default-mysql-client \
      dnsutils \
      fd-find \
      fonts-noto-color-emoji \
      htop \
      imagemagick \
      iproute2 \
      lsof \
      nano \
      pkg-config \
      postgresql-client \
      python3-venv \
      redis-tools \
      shellcheck \
      sqlite3 \
      strace \
      tmux \
      tree; \
    rm -rf /var/lib/apt/lists/*; \
    ln -sf /usr/bin/fdfind /usr/local/bin/fd; \
    ln -sf /usr/bin/batcat /usr/local/bin/bat

# ---------- Release binaries (checksum-pinned, both architectures) ---------
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION=2.101.0
ARG GH_SHA256_AMD64=f876a3b87bf67c94f773d17becca4dc7340b056dab901473a9260ee2a73e237b
ARG GH_SHA256_ARM64=9aec87f9a011b1521556b06cb003776e7e214144c8efd2144924a28d90c23057
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.53.6
ARG YQ_SHA256_AMD64=c5f056448f973ae7d39b5401949648a78f2dc1947d6a8eb65be60d5c504b9385
ARG YQ_SHA256_ARM64=88a1016bc1d657375a35864e4f44b6f333df8ff97b559f51bba0adcb2169df09
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.74.4
ARG FZF_SHA256_AMD64=05e6813a337cc722c3ed07e54a764b75cc5d671e2e60459db0ba696ee5fa7504
ARG FZF_SHA256_ARM64=5d673b849f494f0d64ec471d8640b153ca8849e3846a31da17abdcfce8df6b46
# renovate: datasource=github-releases depName=atuinsh/atuin
ARG ATUIN_VERSION=18.23.0
ARG ATUIN_SHA256_AMD64=d1b40dd6e7cd3d823867ffe22b39a025bc420f7875926ae9ca974155378da14d
ARG ATUIN_SHA256_ARM64=faf91adc71e6b661b21ed4f486babbd7af9d17363d4276da4a0251f83c72498d
# renovate: datasource=custom.cursor depName=cursor-agent
ARG CURSOR_VERSION=2026.09.28-64d2043
ARG CURSOR_SHA256_AMD64=6e4cd936a4866b8a77c50ff51a564460d715772fabc477a01aa0f0455d9559f0
ARG CURSOR_SHA256_ARM64=c737599b27d3d8d6743c72b487204e335f3a8ea2fdbaf18302ee207a646ffd8d

# hadolint ignore=DL3008
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch_uc=AMD64; atuin_target=x86_64-unknown-linux-musl; cursor_arch=x64 ;; \
      arm64) arch_uc=ARM64; atuin_target=aarch64-unknown-linux-musl; cursor_arch=arm64 ;; \
      *) echo "unsupported TARGETARCH=${TARGETARCH}" >&2; exit 1 ;; \
    esac; \
    sha() { eval "printf '%s' \"\${$1_SHA256_${arch_uc}}\""; }; \
    fetch() { curl --fail --location --silent --show-error --retry 5 --retry-all-errors --connect-timeout 20 --output "$2" "$1"; }; \
    tmp="$(mktemp -d)"; \
    \
    fetch "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${TARGETARCH}.deb" "$tmp/gh.deb"; \
    echo "$(sha GH)  $tmp/gh.deb" | sha256sum --check --strict -; \
    apt-get update; apt-get install --yes --no-install-recommends "$tmp/gh.deb"; rm -rf /var/lib/apt/lists/*; \
    \
    fetch "https://github.com/mikefarah/yq/releases/download/v${YQ_VERSION}/yq_linux_${TARGETARCH}" "$tmp/yq"; \
    echo "$(sha YQ)  $tmp/yq" | sha256sum --check --strict -; \
    install -m 0755 "$tmp/yq" /usr/local/bin/yq; \
    \
    fetch "https://github.com/junegunn/fzf/releases/download/v${FZF_VERSION}/fzf-${FZF_VERSION}-linux_${TARGETARCH}.tar.gz" "$tmp/fzf.tgz"; \
    echo "$(sha FZF)  $tmp/fzf.tgz" | sha256sum --check --strict -; \
    tar -xzf "$tmp/fzf.tgz" -C /usr/local/bin fzf; \
    \
    fetch "https://github.com/atuinsh/atuin/releases/download/v${ATUIN_VERSION}/atuin-${atuin_target}.tar.gz" "$tmp/atuin.tgz"; \
    echo "$(sha ATUIN)  $tmp/atuin.tgz" | sha256sum --check --strict -; \
    mkdir "$tmp/atuin"; tar -xzf "$tmp/atuin.tgz" -C "$tmp/atuin"; \
    install -m 0755 "$tmp/atuin/atuin-${atuin_target}/atuin" /usr/local/bin/atuin; \
    \
    fetch "https://downloads.cursor.com/lab/${CURSOR_VERSION}/linux/${cursor_arch}/agent-cli-package.tar.gz" "$tmp/cursor.tgz"; \
    echo "$(sha CURSOR)  $tmp/cursor.tgz" | sha256sum --check --strict -; \
    cursor_dir="/opt/devtools/cursor/${CURSOR_VERSION}"; \
    mkdir -p "$cursor_dir"; \
    tar --strip-components=1 -xzf "$tmp/cursor.tgz" -C "$cursor_dir"; \
    test -x "$cursor_dir/cursor-agent"; \
    for n in cursor-agent cursor agent; do ln -sfn "$cursor_dir/cursor-agent" "/usr/local/bin/$n"; done; \
    \
    rm -rf "$tmp"; \
    test "$(dpkg-query -W -f='${Version}' gh)" = "${GH_VERSION}"; \
    yq --version | grep -F "${YQ_VERSION}"; \
    test "$(fzf --version | awk '{print $1}')" = "${FZF_VERSION}"; \
    atuin --version | grep -F "${ATUIN_VERSION}"; \
    HOME=/tmp cursor-agent --version | grep -F "${CURSOR_VERSION}"

# ---------- npm developer CLIs + AI CLIs -----------------------------------
# Installed as a locked project under /opt/devtools/npm instead of `npm i -g`
# so Renovate can manage exact versions and the lockfile. Install scripts are
# governed by the allowScripts policy in tools/npm/package.json. pnpm is NOT
# here on purpose: upstream pins its own pnpm for `dsh plugin`.
COPY tools/npm/package.json tools/npm/package-lock.json /opt/devtools/npm/
WORKDIR /opt/devtools/npm
RUN set -eux; \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --omit=dev --no-audit --no-fund \
      --cache /tmp/npm-cache --strict-allow-scripts; \
    rm -rf /tmp/npm-cache; \
    for b in claude gemini codex task-master playwright tsc tsx vite esbuild eslint prettier serve nodemon concurrently dotenv; do \
      test -x "node_modules/.bin/$b" || { echo "missing npm bin: $b" >&2; exit 1; }; \
    done
WORKDIR /

# ---------- Python libraries (venv, HolyClaude slim parity) ----------------
COPY tools/python/requirements.txt /opt/devtools/python/requirements.txt
RUN set -eux; \
    python3 -m venv /opt/devtools/venv; \
    /opt/devtools/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
      --only-binary=:all: -r /opt/devtools/python/requirements.txt; \
    /opt/devtools/venv/bin/pip check

# Upstream binaries (dsh, pnpm, node, python3, chromium) keep precedence:
# devtools are appended to PATH, never prepended.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/devtools/npm/node_modules/.bin:/opt/devtools/venv/bin \
    PLAYWRIGHT_BROWSERS_PATH=0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# ---------- Manifest (drives "publish only when something changed") --------
COPY scripts/write-manifest.sh /usr/local/lib/deepseek-harness-dev/write-manifest.sh
RUN set -eux; \
    chmod 0755 /usr/local/lib/deepseek-harness-dev/write-manifest.sh; \
    DSH_BASE_IMAGE="${DSH_BASE_IMAGE}" /usr/local/lib/deepseek-harness-dev/write-manifest.sh > /opt/devtools/MANIFEST.txt; \
    test -s /opt/devtools/MANIFEST.txt

USER node
WORKDIR /workspace

# Metadata last so a new revision only changes image config.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="DeepSeek Harness (dev tooling + bwrap + SameSite=Lax)" \
      org.opencontainers.image.description="runzhliu/deepseek-harness with bubblewrap, a SameSite=Lax session cookie and HolyClaude-slim developer tooling" \
      org.opencontainers.image.source="https://github.com/louisremi/deepseek-harness-docker-dev" \
      org.opencontainers.image.url="https://github.com/louisremi/deepseek-harness-docker-dev" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      org.opencontainers.image.base.name="${DSH_BASE_IMAGE}" \
      io.github.louisremi.deepseek-harness-dev.patches="bubblewrap,samesite-lax"
# ENTRYPOINT / CMD are inherited unchanged from upstream (tini -> dsh web).
