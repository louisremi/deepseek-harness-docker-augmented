#!/usr/bin/env bash
# Print a deterministic inventory of everything installed in the image.
# Baked into the image as /opt/devtools/MANIFEST.txt; CI diffs it against the
# published moving tag of the same variant to decide whether a scheduled
# rebuild is worth a new tag. Must not contain timestamps, build IDs or
# anything else that changes when the contents do not.
#
#   BASE_IMAGE=<ref> VARIANT=<default|bwrap|ungoogled> SEED_DIR=<dir> write-manifest.sh
set -euo pipefail

export HOME=/tmp
seed="${SEED_DIR:?SEED_DIR must be set}"

section() { printf '\n## %s\n' "$1"; }

printf '# deepseek-harness-augmented manifest\n'
printf 'variant=%s\n' "${VARIANT:?VARIANT must be set}"
printf 'base=%s\n' "${BASE_IMAGE:?BASE_IMAGE must be set}"
printf 'arch=%s\n' "$(dpkg --print-architecture)"

section "upstream"
printf 'dsh=%s\n' "$(dsh --version)"
printf 'node=%s\n' "$(node --version)"
printf 'pnpm=%s\n' "$(pnpm --version)"
printf 'python3=%s\n' "$(python3 --version | awk '{print $2}')"
printf 'chromium-flavor=%s\n' "${CHROMIUM_FLAVOR:-}"
if command -v bwrap >/dev/null; then printf 'bwrap=%s\n' "$(bwrap --version | awk '{print $2}')"; fi

section "patches"
grep -o 'HttpOnly; SameSite=[A-Za-z]*' \
  /usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js

section "model-facing instructions"
printf 'DSH_AGENTS_HOME=%s\n' "${DSH_AGENTS_HOME:-}"
(cd /opt/deepseek-harness-augmented/agents && find . -type f -print0 | LC_ALL=C sort -z | xargs -0 sha256sum)

section "dsh plugins (seed web profile)"
node -e '
  const fs = require("node:fs")
  const dir = process.argv[1] + "/profiles/web"
  const pkg = JSON.parse(fs.readFileSync(dir + "/package.json", "utf8"))
  const bundles = new Set(pkg.dsh.profile.bundles)
  for (const [name, version] of Object.entries(pkg.dependencies).sort())
    console.log(`${name}=${version} ${bundles.has(name) ? "enabled" : "disabled"}`)
  let compat = {}
  try { compat = JSON.parse(fs.readFileSync(dir + "/compatibility.json", "utf8")) } catch {}
  for (const [key, versions] of Object.entries(compat).sort()) console.log(`exemption ${key} dsh=${versions.join(",")}`)
' "${seed}"

section "release binaries"
printf 'gh=%s\n' "$(dpkg-query -W -f='${Version}' gh)"
printf 'yq=%s\n' "$(yq --version | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)"
printf 'fzf=%s\n' "$(fzf --version | awk '{print $1}')"
printf 'atuin=%s\n' "$(atuin --version | awk '{print $2}')"

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
