#!/usr/bin/env bash
# Smoke-test a built louisremi/deepseek-harness-dev image.
#
#   scripts/smoke.sh <image>
#
# Runs every check under the same hardening the production compose service
# uses (read-only rootfs, cap_drop ALL, no-new-privileges, plus the two
# security_opt values bubblewrap needs). Exits non-zero on the first failure.
set -Eeuo pipefail

image="${1:?usage: smoke.sh <image>}"
root="$(cd "$(dirname "$0")/.." && pwd)"
suffix="${RANDOM}-$$"
container="dsh-dev-smoke-${suffix}"
volume="dsh-dev-smoke-home-${suffix}"
cookie_jar="$(mktemp "${TMPDIR:-/tmp}/dsh-dev-smoke-cookie.XXXXXX")"
headers="$(mktemp "${TMPDIR:-/tmp}/dsh-dev-smoke-headers.XXXXXX")"

# shellcheck disable=SC2317  # invoked by the trap (shellcheck < 0.10 misses it)
cleanup() {
  docker container rm --force "${container}" >/dev/null 2>&1 || true
  docker volume rm "${volume}" >/dev/null 2>&1 || true
  rm -f "${cookie_jar}" "${headers}"
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC2054  # commas are tmpfs mount options
hardening=(
  --read-only
  --tmpfs /tmp:rw,nosuid,nodev,size=512m
  --tmpfs /workspace:rw,nosuid,nodev,size=512m,uid=1000,gid=1000
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --security-opt seccomp=unconfined
  --security-opt systempaths=unconfined
  --security-opt apparmor=unconfined
)

run() { docker run --rm "${hardening[@]}" --entrypoint bash "${image}" -ec "$1"; }
pass() { printf 'ok   %s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

arg() {  # read an ARG default from the Dockerfile
  sed -n "s/^ARG $1=//p" "${root}/Dockerfile" | head -n1
}

# --- 1. upstream contract still holds ---------------------------------------
base_tag="$(sed -n 's/^ARG DSH_BASE_IMAGE=.*:\([^:@]*\)@sha256:.*/\1/p' "${root}/Dockerfile")"
expected_dsh="${base_tag%-r*}"
actual_dsh="$(docker run --rm "${image}" --version)"
[[ "${actual_dsh}" == "${expected_dsh}" ]] || fail "dsh --version: expected ${expected_dsh}, got ${actual_dsh}"
pass "dsh ${actual_dsh} (base ${base_tag})"

run 'test "$(command -v pnpm)" = /usr/local/bin/pnpm' || fail "upstream pnpm no longer first on PATH"
run 'test "$(command -v python3)" = /usr/bin/python3 && test "$(command -v node)" = /usr/local/bin/node' \
  || fail "upstream node/python3 no longer first on PATH"
pass "upstream binaries keep PATH precedence"

# --- 2. patch 1: bubblewrap actually confines -------------------------------
run '
  test -x /usr/bin/bwrap
  test ! -u /usr/bin/bwrap
  bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- true
  if bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent -- touch /bwrap-escape 2>/dev/null; then
    echo "bwrap did not make / read-only" >&2; exit 1
  fi
  bwrap --ro-bind / / --dev /dev --unshare-pid --proc /proc --die-with-parent \
    --tmpfs /tmp --bind /workspace /workspace -- touch /workspace/bwrap-ok
  test -f /workspace/bwrap-ok
' || fail "bubblewrap cannot create the dsh-sandbox-local profile under production hardening"
pass "bubblewrap: read-only and workspace-write profiles work unprivileged"

# --- 3. patch 2: SameSite=Lax compiled in -----------------------------------
run '
  f=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js
  grep -q "HttpOnly; SameSite=Lax" "$f"
  ! grep -q "SameSite=Strict" "$f"
' || fail "session cookie is not SameSite=Lax in compiled output"
pass "SameSite=Lax present in dsh-client-connection"

# --- 4. every bundled tool resolves at its pinned version -------------------
gh_v="$(arg GH_VERSION)"; yq_v="$(arg YQ_VERSION)"; fzf_v="$(arg FZF_VERSION)"
atuin_v="$(arg ATUIN_VERSION)"; cursor_v="$(arg CURSOR_VERSION)"
run "
  export HOME=/tmp
  gh --version | head -1 | grep -F ' ${gh_v} '
  yq --version | grep -F '${yq_v}'
  test \"\$(fzf --version | awk '{print \$1}')\" = '${fzf_v}'
  atuin --version | grep -F '${atuin_v}'
  cursor-agent --version | grep -F '${cursor_v}'
  for c in fd bat tree tmux nano shellcheck dig strace lsof ip htop psql redis-cli sqlite3 mysql mysqldump convert identify; do
    command -v \"\$c\" >/dev/null || { echo \"missing \$c\" >&2; exit 1; }
  done
" >/dev/null || fail "release binaries / apt tools"
pass "gh ${gh_v}, yq ${yq_v}, fzf ${fzf_v}, atuin ${atuin_v}, cursor-agent ${cursor_v}, apt tools"

run '
  export HOME=/tmp
  cd /opt/devtools/npm
  node -e "
    const pkg = require(\"./package.json\");
    for (const [name, want] of Object.entries(pkg.dependencies)) {
      const got = require(\"./node_modules/\" + name + \"/package.json\").version;
      if (got !== want) { console.error(name + \": \" + got + \" != \" + want); process.exit(1); }
    }"
  claude --version
  gemini --version
  codex --version
  task-master --version
  tsc --version
  tsx --version
  vite --version
  esbuild --version
  eslint --version
  prettier --version
  nodemon --version
  concurrently --version
  playwright --version
  serve --version
  command -v dotenv
' >/dev/null || fail "npm CLIs"
pass "npm CLIs (claude, gemini, codex, task-master, tsc, tsx, vite, esbuild, eslint, prettier, ...) at locked versions"

docker run --rm "${hardening[@]}" --entrypoint /opt/devtools/venv/bin/python "${image}" -c '
import importlib, subprocess, sys
from importlib.metadata import version
subprocess.run([sys.executable, "-m", "pip", "check", "--disable-pip-version-check"], check=True)
mods = {"beautifulsoup4": "bs4", "pillow": "PIL", "pyyaml": "yaml", "python-docx": "docx",
        "python-dotenv": "dotenv", "pytest-asyncio": "pytest_asyncio",
        "tree-sitter": "tree_sitter", "tree-sitter-language-pack": "tree_sitter_language_pack"}
for line in open("/opt/devtools/python/requirements.txt"):
    r = line.split("#")[0].strip()
    if not r:
        continue
    name, want = r.split("==")
    got = version(name)
    if got != want:
        sys.exit(f"{name}: {got} != {want}")
    importlib.import_module(mods.get(name, name.replace("-", "_")))
' || fail "python venv"
pass "python venv: pip check clean, all libraries import at pinned versions"

run 'test -s /opt/devtools/MANIFEST.txt && grep -q "^base=" /opt/devtools/MANIFEST.txt' || fail "MANIFEST.txt"
pass "MANIFEST.txt present"

# The dsh-docker-adapter plugin is baked into the image's own web profile (no
# volume mounted here, so this reads the image, not a seeded volume).
adapter_v="$(arg DSH_DOCKER_ADAPTER_VERSION)"
run "
  p=\"\${DSH_HOME:-/home/node/.dsh}/profiles/web\"
  grep -qF '\"@louisremi/dsh-docker-adapter\": \"${adapter_v}\"' \"\$p/package.json\"
  test \"\$(node -p 'require(\"'\"\$p\"'/node_modules/@louisremi/dsh-docker-adapter/package.json\").version')\" = '${adapter_v}'
" || fail "dsh-docker-adapter ${adapter_v} is not baked into the web profile"
pass "dsh-docker-adapter ${adapter_v} baked into the web profile"

# --- 5. dsh web boots and issues a SameSite=Lax cookie ----------------------
docker volume create "${volume}" >/dev/null
docker run --detach --name "${container}" \
  --publish 127.0.0.1::3080 \
  "${hardening[@]}" \
  --shm-size 1g \
  --pids-limit 1024 \
  --volume "${volume}:/home/node/.dsh" \
  "${image}" >/dev/null
port="$(docker port "${container}" 3080/tcp | awk -F: 'NR == 1 { print $NF }')"

for _ in $(seq 1 60); do
  status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/" || true)"
  token="$(docker logs "${container}" 2>&1 \
    | sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9][0-9]*/?token=\([^ ]*\).*#\1#p' | tail -n1)"
  if [[ "${status}" == 401 && -n "${token}" ]]; then
    curl --silent --output /dev/null --dump-header "${headers}" --cookie-jar "${cookie_jar}" \
      "http://127.0.0.1:${port}/?token=${token}"
    set_cookie="$(grep -i '^set-cookie:' "${headers}" | sed -E 's/=[^;]*;/=<redacted>;/' || true)"
    [[ -n "${set_cookie}" ]] || fail "no Set-Cookie on /?token="
    [[ "${set_cookie}" == *"SameSite=Lax"* ]] || fail "Set-Cookie is not SameSite=Lax: ${set_cookie}"
    pass "dsh web: unauthenticated 401, token exchange sets ${set_cookie#*: }"
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --cookie "${cookie_jar}" "http://127.0.0.1:${port}/")"
    [[ "${code}" == 200 ]] || fail "authenticated GET / returned ${code}"
    pass "dsh web: authenticated GET / returns 200"
    # Runtime proof that the plugin loaded (from the volume Docker seeded from
    # the image): its route answers 400 (missing path) once authenticated; with
    # no plugin the route does not exist and dsh answers 404.
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' --cookie "${cookie_jar}" "http://127.0.0.1:${port}/api/download.file")"
    [[ "${code}" == 400 ]] || fail "GET /api/download.file returned ${code}, expected 400 (dsh-docker-adapter not loaded?)"
    code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/api/download.file")"
    [[ "${code}" == 401 ]] || fail "unauthenticated GET /api/download.file returned ${code}, expected 401"
    pass "dsh-docker-adapter loaded: /api/download.file is 401 unauthenticated, 400 authenticated"
    if docker logs "${container}" 2>&1 | grep -Eqi 'SANDBOX_UNAVAILABLE|failed to load plugin|plugin .* error'; then
      docker logs "${container}" >&2
      fail "dsh logged sandbox or plugin load errors"
    fi
    pass "no sandbox / plugin load errors in dsh logs"
    echo "smoke test passed for ${image}"
    exit 0
  fi
  docker container inspect "${container}" >/dev/null 2>&1 || { docker logs "${container}" >&2 || true; fail "container exited"; }
  sleep 1
done
docker logs "${container}" >&2
fail "dsh web did not become ready within 60s"
