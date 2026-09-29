#!/usr/bin/env bash
# Print a deterministic inventory of everything installed in the image.
# Baked into the image as /opt/devtools/MANIFEST.txt; CI diffs it against the
# published :latest to decide whether a scheduled rebuild is worth a new tag.
# Must not contain timestamps, build IDs or anything else that changes when
# the contents do not.
set -euo pipefail

export HOME=/tmp

section() { printf '\n## %s\n' "$1"; }

printf '# deepseek-harness-dev manifest\n'
printf 'base=%s\n' "${DSH_BASE_IMAGE:?DSH_BASE_IMAGE must be set}"
printf 'arch=%s\n' "$(dpkg --print-architecture)"

section "upstream"
printf 'dsh=%s\n' "$(dsh --version)"
printf 'node=%s\n' "$(node --version)"
printf 'pnpm=%s\n' "$(pnpm --version)"
printf 'python3=%s\n' "$(python3 --version | awk '{print $2}')"

section "patches"
grep -o 'HttpOnly; SameSite=[A-Za-z]*' \
  /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js
printf 'bwrap=%s\n' "$(bwrap --version | awk '{print $2}')"

section "release binaries"
printf 'gh=%s\n' "$(dpkg-query -W -f='${Version}' gh)"
printf 'yq=%s\n' "$(yq --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'fzf=%s\n' "$(fzf --version | awk '{print $1}')"
printf 'atuin=%s\n' "$(atuin --version | awk '{print $2}')"
printf 'cursor-agent=%s\n' "$(readlink -f /usr/local/bin/cursor-agent | awk -F/ '{print $(NF-1)}')"

section "npm (/opt/devtools/npm, installed tree)"
node -e '
  const fs = require("node:fs");
  const lock = require("/opt/devtools/npm/package-lock.json");
  const rows = Object.entries(lock.packages)
    .filter(([k]) => k && fs.existsSync("/opt/devtools/npm/" + k + "/package.json"))
    .map(([k, v]) => `${k.replace(/^.*node_modules\//, "")}@${v.version}`);
  console.log([...new Set(rows)].sort().join("\n"));
'

section "python (/opt/devtools/venv)"
/opt/devtools/venv/bin/pip freeze --all --disable-pip-version-check | LC_ALL=C sort

section "debian packages"
dpkg-query -W -f='${Package}=${Version}\n' | LC_ALL=C sort
