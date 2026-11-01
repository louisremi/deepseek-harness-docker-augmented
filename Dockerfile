# syntax=docker/dockerfile:1.7
#
# louisremi/deepseek-harness-augmented
#
# One Dockerfile, three variants, each built FROM the matching upstream
# runzhliu/deepseek-harness image (https://github.com/runzhliu/deepseek-harness-docker):
#
#   VARIANT=default    <X-rN>                -> <X-rN>-augmented.<N>               (:latest)
#   VARIANT=bwrap      <X-rN>-bwrap.<B>      -> <X-rN>-bwrap.<B>-augmented.<N>     (:bwrap)
#   VARIANT=ungoogled  <X-rN>-ungoogled.<U>  -> <X-rN>-ungoogled.<U>-augmented.<N> (:ungoogled)
#
# Upstream's -market variant is deliberately not derived: dshmarket ships here
# as a (disabled) profile plugin instead. On top of each base we add only:
#   1. the SameSite=Lax session-cookie patch (guarded);
#   2. developer tooling from HolyClaude's "both variants" list, minus its AI
#      CLIs and minus what upstream already ships;
#   3. dsh plugins pre-installed in a seed `web` profile (tools/dsh-plugins);
#   4. a model-facing AGENTS.md describing all of the above (agents/AGENTS.md).
# Everything is pinned and kept current by Renovate (renovate.json5). Read the
# repository's AGENTS.md before editing this file.

# The three bases always come from the same upstream release (<X-rN>);
# scripts/static-check.sh enforces it and Renovate bumps them as one group.
# renovate: datasource=docker depName=upstream-default packageName=runzhliu/deepseek-harness
ARG BASE_DEFAULT=docker.io/runzhliu/deepseek-harness:0.2.2-alpha.2-r1@sha256:8cbd24d0cf0d26e5fdcd1b310e1a95e95bfc6c4d708784b08f142bd5740134bf
# renovate: datasource=docker depName=upstream-bwrap packageName=runzhliu/deepseek-harness
ARG BASE_BWRAP=docker.io/runzhliu/deepseek-harness:0.2.2-alpha.2-r1-bwrap.1@sha256:db64f875a45b8e151ea9dc1fe340c38df2b424ed8e41425ac7b793c741808c0e
# renovate: datasource=docker depName=upstream-ungoogled packageName=runzhliu/deepseek-harness
ARG BASE_UNGOOGLED=docker.io/runzhliu/deepseek-harness:0.2.2-alpha.2-r1-ungoogled.1@sha256:83a8c6b0a3bbb6a3ec3bdbded52bb358dc5f1ba65ee872fd49c7715bcb5447e9
ARG VARIANT=default

FROM ${BASE_DEFAULT} AS base-default
FROM ${BASE_BWRAP} AS base-bwrap
FROM ${BASE_UNGOOGLED} AS base-ungoogled

# BuildKit only builds the stage VARIANT selects.
# hadolint ignore=DL3006
FROM base-${VARIANT}

ARG VARIANT
ARG BASE_DEFAULT
ARG BASE_BWRAP
ARG BASE_UNGOOGLED
ARG TARGETARCH
ARG DSH_MODULES=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# ---------- Contract: what we rely on from the base -------------------------
# Every variant: dsh's sandbox still prefers bwrap on Linux, and dsh still
# reads a shared user-global AGENTS.md from $DSH_AGENTS_HOME (used below).
# bwrap variant: a non-setuid bwrap the runtime user can execute (the runtime
# keeps no-new-privileges; compose.bwrap.yaml has the security_opt values).
# Every variant: CHROMIUM_FLAVOR matches (catches a swapped base pin).
RUN set -eux; \
    case "${VARIANT}" in default|bwrap|ungoogled) ;; \
      *) echo "unsupported VARIANT=${VARIANT} (default|bwrap|ungoogled)" >&2; exit 1 ;; esac; \
    grep -Eq 'linux: \["bwrap"' "${DSH_MODULES}/dsh-sandbox-local/lib/index.js" \
      || { echo "PATCH GUARD: dsh-sandbox-local no longer prefers bwrap on linux; re-read the sandbox plugin before shipping" >&2; exit 1; }; \
    grep -q '"DSH_AGENTS_HOME"' "${DSH_MODULES}/dsh-home-paths/lib/index.js" \
      || { echo "PATCH GUARD: dsh no longer reads DSH_AGENTS_HOME; agents/AGENTS.md would not reach the model" >&2; exit 1; }; \
    if [ "${VARIANT}" = bwrap ]; then \
      bwrap="$(command -v bwrap)" \
        || { echo "PATCH GUARD: base image has no bwrap on PATH; BASE_BWRAP must be the upstream -bwrap.N variant" >&2; exit 1; }; \
      test ! -u "${bwrap}" \
        || { echo "PATCH GUARD: base image bwrap is setuid; our invariant requires a non-setuid bwrap (the runtime keeps no-new-privileges)" >&2; exit 1; }; \
      setpriv --reuid="$(id -u node)" --regid="$(id -g node)" --clear-groups test -x "${bwrap}" \
        || { echo "PATCH GUARD: base image bwrap (${bwrap}) is not executable by the runtime user node" >&2; exit 1; }; \
    fi; \
    want_flavor=debian; [ "${VARIANT}" != ungoogled ] || want_flavor=ungoogled; \
    test "${CHROMIUM_FLAVOR:-}" = "${want_flavor}" \
      || { echo "PATCH GUARD: VARIANT=${VARIANT} expects CHROMIUM_FLAVOR=${want_flavor}, base has '${CHROMIUM_FLAVOR:-}'" >&2; exit 1; }

# ---------- Patch: SameSite=Lax ------------------------------------------
# Upstream mints the browser-session cookie at /?token= with SameSite=Strict.
# An installed Android PWA (WebAPK) launches via an intent, and Strict blocks
# that intent-initiated top-level navigation. The value is a literal in
# compiled output that neither config nor a hook can reach, and the runtime
# rootfs is read-only, hence a guarded build-time sed: a no-op if upstream
# ships Lax, a loud failure if it rewords the string.
RUN set -eux; \
    f="${DSH_MODULES}/dsh-client-connection/lib/index.js"; \
    if grep -q 'HttpOnly; SameSite=Strict' "$f"; then \
      sed -i 's/HttpOnly; SameSite=Strict/HttpOnly; SameSite=Lax/' "$f"; \
    fi; \
    grep -q 'HttpOnly; SameSite=Lax' "$f" \
      || { echo "PATCH GUARD: session cookie string not found in dsh-client-connection; upstream changed it" >&2; exit 1; }; \
    ! grep -q 'SameSite=Strict' "$f"

# ---------- Debian developer packages ---------------------------------------
# Upstream (node:24-trixie = buildpack-deps) already provides git, curl, wget,
# jq, ripgrep, unzip, zip, xz, less, rsync, openssh-client, procps, file,
# python3, gcc/make, ImageMagick, Chromium and Xvfb. Debian packages follow the
# base image's trixie snapshot and are refreshed by the weekly rebuild.
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
ARG GH_VERSION=2.103.3
ARG GH_SHA256_AMD64=e3bafef96328d1a67de3a968bdfe1cc2ffd58cf6aba8b5e201356897ed06bb3d
ARG GH_SHA256_ARM64=cac3ff84b60b68e64cca69f31f303210c26320361cc3286b773655d4226b7b06
# renovate: datasource=github-releases depName=mikefarah/yq
ARG YQ_VERSION=4.54.1
ARG YQ_SHA256_AMD64=8e34fc298390875de416e6a4afcb8cabeceb25d9aa8506c1a2f9353cf702ea5f
ARG YQ_SHA256_ARM64=189088da0c6429ec5178dfaab1a114805f6cab0b61b165ab236efedf1d57a71b
# renovate: datasource=github-releases depName=junegunn/fzf
ARG FZF_VERSION=0.74.5
ARG FZF_SHA256_AMD64=d47d7f882972c7d674dbbba998ffa4116e68379616ffac7695d0671e9a722c5f
ARG FZF_SHA256_ARM64=cf058001da21724a469b714a29cf4aab9cbe860d218a0d6c1b5b661efad7784c
# renovate: datasource=github-releases depName=atuinsh/atuin
ARG ATUIN_VERSION=18.24.4
ARG ATUIN_SHA256_AMD64=788cff5b3903ca7f1f5bdff3e4b4975c38b3c20385176a49b01ad1bea5b37636
ARG ATUIN_SHA256_ARM64=7698bd70195bde165bb37ea3133aa6663dd48ff7d6a23042cda2c7be4c22ba78

# hadolint ignore=DL3008
RUN set -eux; \
    case "${TARGETARCH}" in \
      amd64) arch_uc=AMD64; atuin_target=x86_64-unknown-linux-musl ;; \
      arm64) arch_uc=ARM64; atuin_target=aarch64-unknown-linux-musl ;; \
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
    rm -rf "$tmp"; \
    test "$(dpkg-query -W -f='${Version}' gh)" = "${GH_VERSION}"; \
    yq --version | grep -F "${YQ_VERSION}"; \
    test "$(fzf --version | awk '{print $1}')" = "${FZF_VERSION}"; \
    atuin --version | grep -F "${ATUIN_VERSION}"

# ---------- npm developer CLIs ----------------------------------------------
# A locked project under /opt/devtools/npm instead of `npm i -g`, so Renovate
# manages exact versions and the lockfile. Install scripts are governed by the
# allowScripts policy in tools/npm/package.json. No AI CLIs, and no pnpm
# (upstream pins its own for `dsh plugin`).
COPY tools/npm/package.json tools/npm/package-lock.json /opt/devtools/npm/
WORKDIR /opt/devtools/npm
RUN set -eux; \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --omit=dev --no-audit --no-fund \
      --cache /tmp/npm-cache --strict-allow-scripts; \
    rm -rf /tmp/npm-cache; \
    for b in playwright tsc tsx vite esbuild eslint prettier serve nodemon concurrently dotenv; do \
      test -x "node_modules/.bin/$b" || { echo "missing npm bin: $b" >&2; exit 1; }; \
    done
WORKDIR /

# ---------- Python libraries (venv) -----------------------------------------
# On PATH after upstream's: `python` and `pip` are the venv, `python3` stays
# upstream's bare interpreter (agents/AGENTS.md tells the model).
COPY tools/python/requirements.txt /opt/devtools/python/requirements.txt
RUN set -eux; \
    python3 -m venv /opt/devtools/venv; \
    /opt/devtools/venv/bin/pip install --no-cache-dir --disable-pip-version-check \
      --only-binary=:all: -r /opt/devtools/python/requirements.txt; \
    /opt/devtools/venv/bin/pip check

# ---------- dsh plugins: seed `web` profile -----------------------------------
# tools/dsh-plugins/package.json lists the plugins (exact pins, Renovate-managed)
# and which start enabled. install-dsh-plugins.mjs installs them with dsh's own
# `dsh plugin --profile web add`, as node, so the profile is exactly what that
# command produces at runtime; then deselects the disabled ones and pins the
# pnpm store inside the Harness home. The result is moved out of $DSH_HOME into
# a seed, so the image's $DSH_HOME stays empty like upstream's, and
# augmented-entrypoint copies it into any Harness home without a `web` profile
# (fresh named volume *or* bind mount). Existing profiles are never modified.
ARG SEED_DIR=/opt/deepseek-harness-augmented/seed
COPY tools/dsh-plugins/package.json /opt/deepseek-harness-augmented/dsh-plugins.json
COPY scripts/install-dsh-plugins.mjs /usr/local/lib/deepseek-harness-augmented/install-dsh-plugins.mjs
RUN install -d -o node -g node "${SEED_DIR}"
USER node
RUN set -eux; \
    test -z "$(ls -A "${DSH_HOME}")"; \
    node /usr/local/lib/deepseek-harness-augmented/install-dsh-plugins.mjs \
      /opt/deepseek-harness-augmented/dsh-plugins.json; \
    mv "${DSH_HOME}/profiles" "${DSH_HOME}/pnpm-store" "${SEED_DIR}/"; \
    rm -rf "${DSH_HOME}/npm-cache" "${DSH_HOME}/logs"; \
    test -z "$(ls -A "${DSH_HOME}")" \
      || { ls -la "${DSH_HOME}" >&2; echo "PLUGIN GUARD: unexpected leftovers in ${DSH_HOME}" >&2; exit 1; }
USER root

# ---------- Entrypoint wrapper ----------------------------------------------
# Seeds the profile (above), then execs upstream's entrypoint unchanged.
# Setting ENTRYPOINT resets CMD, so CMD restates upstream's exactly
# (scripts/smoke.sh compares it with the base image's).
COPY scripts/augmented-entrypoint /usr/local/bin/augmented-entrypoint

# ---------- Model-facing instructions ---------------------------------------
# dsh loads $DSH_HOME/AGENTS.md (the user's own) and then $DSH_AGENTS_HOME/AGENTS.md
# as user-global instructions for every session. A read-only directory in the
# image keeps the file in step with the image (HolyClaude's first-boot copy of
# CLAUDE.md goes stale). Override DSH_AGENTS_HOME to use another directory.
COPY agents/ /opt/deepseek-harness-augmented/agents/

# Upstream binaries (dsh, pnpm, node, python3, chromium) keep precedence:
# devtools are appended to PATH, never prepended.
ENV PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/opt/devtools/npm/node_modules/.bin:/opt/devtools/venv/bin \
    DSH_AGENTS_HOME=/opt/deepseek-harness-augmented/agents \
    PLAYWRIGHT_BROWSERS_PATH=0 \
    PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1

# ---------- Manifest (drives "publish only when something changed") --------
COPY scripts/write-manifest.sh /usr/local/lib/deepseek-harness-augmented/write-manifest.sh
RUN set -eux; \
    chmod 0755 /usr/local/bin/augmented-entrypoint /usr/local/lib/deepseek-harness-augmented/write-manifest.sh; \
    sh -n /usr/local/bin/augmented-entrypoint; \
    case "${VARIANT}" in \
      default) base="${BASE_DEFAULT}" ;; bwrap) base="${BASE_BWRAP}" ;; ungoogled) base="${BASE_UNGOOGLED}" ;; \
    esac; \
    BASE_IMAGE="${base}" VARIANT="${VARIANT}" SEED_DIR="${SEED_DIR}" \
      /usr/local/lib/deepseek-harness-augmented/write-manifest.sh > /opt/devtools/MANIFEST.txt; \
    test -s /opt/devtools/MANIFEST.txt

USER node
WORKDIR /workspace

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/augmented-entrypoint"]
CMD ["web", "--patch", "/opt/deepseek-harness/web.cordis.patch.yml", "--no-open"]

# Metadata last so a new revision only changes image config.
ARG IMAGE_VERSION=dev
ARG IMAGE_REVISION=unknown
LABEL org.opencontainers.image.title="DeepSeek Harness, augmented (${VARIANT})" \
      org.opencontainers.image.description="runzhliu/deepseek-harness (${VARIANT} variant) with a SameSite=Lax session cookie, developer tooling, pre-installed dsh plugins and a model-facing AGENTS.md" \
      org.opencontainers.image.source="https://github.com/louisremi/deepseek-harness-docker-augmented" \
      org.opencontainers.image.url="https://github.com/louisremi/deepseek-harness-docker-augmented" \
      org.opencontainers.image.licenses="MIT" \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.revision="${IMAGE_REVISION}" \
      io.github.louisremi.deepseek-harness-augmented.variant="${VARIANT}" \
      io.github.louisremi.deepseek-harness-augmented.patches="samesite-lax"
