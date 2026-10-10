#!/usr/bin/env bash
# Smoke-test a built louisremi/deepseek-harness-augmented image.
#
#   scripts/smoke.sh <image> [default|bwrap|ungoogled]
#
# Runs every check under the hardening of compose.yaml (read-only rootfs,
# noexec /tmp, cap_drop ALL, no-new-privileges, pids limit), plus the
# security_opt values of compose.bwrap.yaml for the bwrap variant. Exits
# non-zero on the first failure.
set -Eeuo pipefail

image="${1:?usage: smoke.sh <image> [default|bwrap|ungoogled]}"
variant="${2:-default}"
case "${variant}" in default|bwrap|ungoogled) ;; *) echo "unknown variant ${variant}" >&2; exit 2 ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
suffix="${RANDOM}-$$"
containers=()
volumes=()
cookie_jar="$(mktemp "${TMPDIR:-/tmp}/dsh-augmented-smoke-cookie.XXXXXX")"
headers="$(mktemp "${TMPDIR:-/tmp}/dsh-augmented-smoke-headers.XXXXXX")"

# shellcheck disable=SC2317  # invoked by the trap (shellcheck < 0.10 misses it)
cleanup() {
  local c v
  for c in "${containers[@]}"; do docker container rm --force "${c}" >/dev/null 2>&1 || true; done
  for v in "${volumes[@]}"; do docker volume rm "${v}" >/dev/null 2>&1 || true; done
  rm -f "${cookie_jar}" "${headers}"
}
trap cleanup EXIT INT TERM

# shellcheck disable=SC2054  # commas are tmpfs mount options
hardening=(
  --read-only
  --tmpfs /tmp:rw,noexec,nosuid,nodev,size=512m
  --tmpfs /workspace:rw,nosuid,nodev,size=512m,uid=1000,gid=1000
  --cap-drop ALL
  --security-opt no-new-privileges:true
  --pids-limit 512
)
if [[ "${variant}" == bwrap ]]; then
  hardening+=(
    --security-opt seccomp=unconfined
    --security-opt systempaths=unconfined
    --security-opt apparmor=unconfined
  )
fi

run() { docker run --rm "${hardening[@]}" --entrypoint bash "${image}" -ec "$1"; }
pass() { printf 'ok   %s\n' "$1"; }
warn() { printf 'WARN %s\n' "$1" >&2; [[ -z "${GITHUB_ACTIONS:-}" ]] || printf '::warning::%s\n' "$1"; }
fail() { printf 'FAIL %s\n' "$1" >&2; exit 1; }

arg() {  # read an ARG default from the Dockerfile
  sed -n "s/^ARG $1=//p" "${root}/Dockerfile" | head -n1
}
plugins="${root}/tools/dsh-plugins/package.json"
plugin_names() { jq -r '.dependencies | keys[]' "${plugins}"; }
plugin_version() { jq -r --arg n "$1" '.dependencies[$n]' "${plugins}"; }
plugin_enabled() { jq -e --arg n "$1" '.dshPlugins.enabled | index($n)' "${plugins}" >/dev/null; }

# --- 1. upstream contract still holds ---------------------------------------
base_ref="$(arg "BASE_${variant^^}")"
base_tag="$(sed -n 's/^[^:]*:\([^@]*\)@sha256:.*/\1/p' <<<"${base_ref}")"
expected_dsh="$(sed -E 's/-r[0-9]+(-[a-z]+\.[0-9]+)?$//' <<<"${base_tag}")"
actual_dsh="$(docker run --rm "${image}" --version 2>/dev/null | tail -n1)"
[[ "${actual_dsh}" == "${expected_dsh}" ]] || fail "dsh --version: expected ${expected_dsh}, got ${actual_dsh}"
pass "dsh ${actual_dsh} (${variant} variant, base ${base_tag})"

label="$(docker image inspect --format '{{ index .Config.Labels "io.github.louisremi.deepseek-harness-augmented.variant" }}' "${image}")"
[[ "${label}" == "${variant}" ]] || fail "image variant label is '${label}', expected ${variant}"
docker pull --quiet "${base_ref}" >/dev/null
want_cmd="$(docker image inspect --format '{{ json .Config.Cmd }}' "${base_ref}")"
got_cmd="$(docker image inspect --format '{{ json .Config.Cmd }}' "${image}")"
[[ "${got_cmd}" == "${want_cmd}" ]] || fail "CMD ${got_cmd} differs from upstream's ${want_cmd} (update the Dockerfile CMD)"
pass "variant label and CMD match upstream (${got_cmd})"

run 'test "$(command -v pnpm)" = /usr/local/bin/pnpm' || fail "upstream pnpm no longer first on PATH"
run 'test "$(command -v python3)" = /usr/bin/python3 && test "$(command -v node)" = /usr/local/bin/node && test "$(command -v dsh)" = /usr/local/bin/dsh' \
  || fail "upstream dsh/node/python3 no longer first on PATH"
pass "upstream binaries keep PATH precedence"

# --- 2. variant-specific base features --------------------------------------
case "${variant}" in
  bwrap)
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
    pass "bubblewrap (from upstream): read-only and workspace-write profiles work unprivileged"
    ;;
  ungoogled)
    run 'test "${CHROMIUM_FLAVOR}" = ungoogled && test -x /opt/ungoogled-chromium/chrome && chromium-docker --version' >/dev/null \
      || fail "ungoogled-chromium flavor missing"
    pass "ungoogled-chromium flavor"
    ;;
  default)
    run 'test "${CHROMIUM_FLAVOR}" = debian && chromium-docker --version' >/dev/null || fail "Debian Chromium missing"
    pass "Debian Chromium flavor"
    ;;
esac

# --- 3. patch: SameSite=Lax compiled in -----------------------------------
run '
  f=/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules/@deepseek-ai/dsh-client-connection/lib/index.js
  grep -q "HttpOnly; SameSite=Lax" "$f"
  ! grep -q "SameSite=Strict" "$f"
' || fail "session cookie is not SameSite=Lax in compiled output"
pass "SameSite=Lax present in dsh-client-connection"

# --- 4. tools ----------------------------------------------------------------
gh_v="$(arg GH_VERSION)"; yq_v="$(arg YQ_VERSION)"; fzf_v="$(arg FZF_VERSION)"; atuin_v="$(arg ATUIN_VERSION)"
run "
  export HOME=/tmp
  gh --version | sed -n 1p | grep -F ' ${gh_v} '
  yq --version | grep -F '${yq_v}'
  test \"\$(fzf --version | awk '{print \$1}')\" = '${fzf_v}'
  atuin --version | grep -F '${atuin_v}'
" >/dev/null || fail "release binaries"
pass "gh ${gh_v}, yq ${yq_v}, fzf ${fzf_v}, atuin ${atuin_v}"

# Every command the model-facing AGENTS.md promises must resolve.
mapfile -t promised < <(sed -n '/^<!-- commands:/,/^<!-- \/commands -->/p' "${root}/agents/AGENTS.md" \
  | grep -oE '`[^` ]+`' | tr -d '`' | sort -u)
(( ${#promised[@]} > 20 )) || fail "could not parse the command list of agents/AGENTS.md"
run "
  missing=''
  for c in ${promised[*]}; do command -v \"\$c\" >/dev/null || missing=\"\$missing \$c\"; done
  [ -z \"\$missing\" ] || { echo \"missing:\$missing\" >&2; exit 1; }
" || fail "agents/AGENTS.md lists commands the image does not have"
pass "all ${#promised[@]} commands listed in agents/AGENTS.md resolve"

run '
  for c in claude gemini codex task-master cursor-agent cursor agent opencode junie; do
    if command -v "$c" >/dev/null; then echo "AI CLI present: $c" >&2; exit 1; fi
  done
' || fail "an AI CLI is bundled"
pass "no AI CLIs bundled"

run '
  export HOME=/tmp
  cd /opt/devtools/npm
  node -e "
    const pkg = require(\"./package.json\");
    for (const [name, want] of Object.entries(pkg.dependencies)) {
      const got = require(\"./node_modules/\" + name + \"/package.json\").version;
      if (got !== want) { console.error(name + \": \" + got + \" != \" + want); process.exit(1); }
    }"
  for b in tsc tsx vite esbuild eslint prettier nodemon concurrently playwright serve; do "$b" --version; done
  command -v dotenv
' >/dev/null || fail "npm CLIs"
pass "npm CLIs at locked versions"

docker run --rm "${hardening[@]}" --entrypoint python "${image}" -c '
import importlib, subprocess, sys
from importlib.metadata import version
assert sys.prefix == "/opt/devtools/venv", sys.prefix
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
pass "python (= venv): pip check clean, all libraries import at pinned versions"

run 'test -s /opt/devtools/MANIFEST.txt && grep -qx "variant='"${variant}"'" /opt/devtools/MANIFEST.txt' || fail "MANIFEST.txt"
pass "MANIFEST.txt present"

# --- 5. model-facing instructions -------------------------------------------
run 'test "${DSH_AGENTS_HOME}" = /opt/deepseek-harness-augmented/agents && test -s "${DSH_AGENTS_HOME}/AGENTS.md" && ! test -w "${DSH_AGENTS_HOME}/AGENTS.md"' \
  || fail "DSH_AGENTS_HOME/AGENTS.md missing or writable"
cmp -s <(docker run --rm --entrypoint cat "${image}" /opt/deepseek-harness-augmented/agents/AGENTS.md) "${root}/agents/AGENTS.md" \
  || fail "baked AGENTS.md differs from agents/AGENTS.md"
pass "agents/AGENTS.md baked at \$DSH_AGENTS_HOME, read-only"

# --- 6. seed profile ----------------------------------------------------------
run 'test -z "$(ls -A "${DSH_HOME}")"' || fail "the image's own \$DSH_HOME is not empty (the profile must live in the seed)"
seed_manifest="$(docker run --rm --entrypoint cat "${image}" /opt/deepseek-harness-augmented/seed/profiles/web/package.json)"
while read -r name; do
  want="$(plugin_version "${name}")"
  [[ "$(jq -r --arg n "${name}" '.dependencies[$n]' <<<"${seed_manifest}")" == "${want}" ]] || fail "seed profile does not pin ${name}@${want}"
  selected="$(jq --arg n "${name}" '.dsh.profile.bundles | index($n) != null' <<<"${seed_manifest}")"
  if plugin_enabled "${name}"; then [[ "${selected}" == true ]] || fail "${name} should be enabled in the seed profile"
  else [[ "${selected}" == false ]] || fail "${name} should be disabled in the seed profile"; fi
done < <(plugin_names)
pass "seed web profile: $(plugin_names | while read -r n; do printf '%s@%s(%s) ' "${n}" "$(plugin_version "${n}")" "$(plugin_enabled "${n}" && echo on || echo off)"; done)"

# --- 7. runtime: dsh web on a fresh named volume -----------------------------
start() {  # start <name> <volume args...>; prints the host port
  local name="$1"; shift
  containers+=("${name}")
  docker run --detach --name "${name}" --publish 127.0.0.1::3080 "${hardening[@]}" --shm-size 1g "$@" "${image}" >/dev/null
  docker port "${name}" 3080/tcp | awk -F: 'NR == 1 { print $NF }'
}
wait_ready() {  # wait_ready <name> <port>; sets token
  local status
  for _ in $(seq 1 90); do
    status="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:$2/" || true)"
    token="$(docker logs "$1" 2>&1 | sed -n 's#^dsh web: http://127\.0\.0\.1:[0-9][0-9]*/?token=\([^ ]*\).*#\1#p' | tail -n1)"
    [[ "${status}" == 401 && -n "${token}" ]] && return 0
    [[ "$(docker container inspect --format '{{.State.Running}}' "$1" 2>/dev/null || true)" == true ]] || { docker logs "$1" >&2 || true; fail "container $1 exited"; }
    sleep 1
  done
  docker logs "$1" >&2
  fail "dsh web ($1) did not become ready within 90s"
}
in_container() { docker exec "$1" sh -ec "$2"; }
# Read logs into a string first: `docker logs | grep -q` under pipefail fails
# with SIGPIPE whenever grep matches before docker logs finishes writing.
logs() { docker logs "$@" 2>&1 || true; }
logged() { local c="$1"; shift; grep "$@" <<<"$(logs "${c}")"; }

volume="dsh-augmented-smoke-home-${suffix}"; volumes+=("${volume}")
docker volume create "${volume}" >/dev/null
main="dsh-augmented-smoke-${suffix}"
port="$(start "${main}" --volume "${volume}:/home/node/.dsh")"
wait_ready "${main}" "${port}"

curl --silent --output /dev/null --dump-header "${headers}" --cookie-jar "${cookie_jar}" "http://127.0.0.1:${port}/?token=${token}"
set_cookie="$(grep -i '^set-cookie:' "${headers}" | sed -E 's/=[^;]*;/=<redacted>;/' || true)"
[[ -n "${set_cookie}" ]] || fail "no Set-Cookie on /?token="
[[ "${set_cookie}" == *"SameSite=Lax"* ]] || fail "Set-Cookie is not SameSite=Lax: ${set_cookie}"
pass "dsh web: unauthenticated 401, token exchange sets ${set_cookie#*: }"
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --cookie "${cookie_jar}" "http://127.0.0.1:${port}/")"
[[ "${code}" == 200 ]] || fail "authenticated GET / returned ${code}"
pass "dsh web: authenticated GET / returns 200"

logged "${main}" -q 'augmented: seeded' || fail "entrypoint did not seed the fresh volume"
# Runtime proof that dsh-always-on loaded: its route answers 400 (missing
# path) once authenticated; without the plugin dsh answers 404.
code="$(curl --silent --output /dev/null --write-out '%{http_code}' --cookie "${cookie_jar}" "http://127.0.0.1:${port}/api/download.file")"
[[ "${code}" == 400 ]] || fail "GET /api/download.file returned ${code}, expected 400 (dsh-always-on not loaded?)"
code="$(curl --silent --output /dev/null --write-out '%{http_code}' "http://127.0.0.1:${port}/api/download.file")"
[[ "${code}" == 401 ]] || fail "unauthenticated GET /api/download.file returned ${code}, expected 401"
pass "fresh volume seeded; dsh-always-on loaded (/api/download.file: 401 unauthenticated, 400 authenticated)"

dump="$(in_container "${main}" 'dsh --profile web --dump-config --patch /opt/deepseek-harness/web.cordis.patch.yml')"
while read -r name; do
  if plugin_enabled "${name}"; then
    grep -qE "^# == ${name//./\\.}(,|\$)" <<<"${dump}" || fail "enabled plugin ${name} contributes no rows"
  elif grep -qE "^# == ${name//./\\.}(,|\$)" <<<"${dump}"; then
    fail "disabled plugin ${name} is composed"
  fi
done < <(plugin_names)
pass "composition: enabled plugins composed, disabled plugins not"

# Later `dsh plugin` operations must work against the seeded store (no
# ERR_PNPM_UNEXPECTED_STORE) - offline, so reinstall from the lockfile.
in_container "${main}" 'cd "$DSH_HOME/profiles/web" && dsh plugin --profile web install --offline --frozen-lockfile' >/dev/null 2>&1 \
  || fail "dsh plugin install --offline fails on the seeded profile"
pass "dsh plugin works against the seeded pnpm store"

if logged "${main}" -Eqi 'SANDBOX_UNAVAILABLE|failed to load plugin|plugin tree failed|incompatible'; then
  docker logs "${main}" >&2
  fail "dsh logged sandbox, plugin load or compatibility errors"
fi
pass "no sandbox / plugin errors in dsh logs"

# Enabling the disabled plugins (what the Plugins page does) must not break
# the host. Their failures are warnings (they ship off on purpose), the host
# staying up is not.
docker stop "${main}" >/dev/null
docker run --rm --volume "${volume}:/home/node/.dsh" --entrypoint node "${image}" -e '
  const fs = require("node:fs"), f = "/home/node/.dsh/profiles/web/package.json"
  const m = JSON.parse(fs.readFileSync(f, "utf8"))
  for (const n of Object.keys(m.dependencies)) if (!m.dsh.profile.bundles.includes(n)) m.dsh.profile.bundles.push(n)
  fs.writeFileSync(f, JSON.stringify(m, null, 2) + "\n")'
docker start "${main}" >/dev/null
port="$(docker port "${main}" 3080/tcp | awk -F: 'NR == 1 { print $NF }')"
wait_ready "${main}" "${port}"
recent="$(logs --since 2m "${main}")"
if grep -Eqi 'failed to load plugin|plugin tree failed|incompatible|error' <<<"${recent}"; then
  warn "with all plugins enabled, dsh logged errors (disabled-by-default plugins may be incompatible with dsh ${actual_dsh}):"
  grep -Ei 'failed|incompatible|error' <<<"${recent}" | head -n 20 >&2 || true
fi
pass "dsh web still boots with every bundled plugin enabled"

# --- 8. runtime: bind-mount-like empty home, and an existing profile --------
empty="dsh-augmented-smoke-empty-${suffix}"
port="$(start "${empty}" --tmpfs /home/node/.dsh:rw,nosuid,nodev,size=256m,uid=1000,gid=1000)"
wait_ready "${empty}" "${port}"
logged "${empty}" -q 'augmented: seeded' || fail "entrypoint did not seed an empty (non-volume) Harness home"
pass "empty bind-mount-like Harness home gets seeded"

oldvol="dsh-augmented-smoke-old-${suffix}"; volumes+=("${oldvol}")
docker volume create "${oldvol}" >/dev/null
docker run --rm --volume "${oldvol}:/home/node/.dsh" --entrypoint sh "${image}" -ec '
  mkdir -p /home/node/.dsh/profiles/web
  printf "%s\n" "{\"name\":\"dsh-profile-web\",\"private\":true,\"dependencies\":{},\"dsh\":{\"profile\":{\"bundles\":[\"@deepseek-ai/dsh-base\",\"@deepseek-ai/dsh-web-app\"]}}}" \
    > /home/node/.dsh/profiles/web/package.json
  printf "[]\n" > /home/node/.dsh/profiles/web/cordis.patch.yml'
old="dsh-augmented-smoke-oldprofile-${suffix}"
port="$(start "${old}" --volume "${oldvol}:/home/node/.dsh")"
wait_ready "${old}" "${port}"
logged "${old}" -q 'augmented: this image bundles @louisremi/dsh-always-on' || fail "no hint for an existing profile without the plugins"
! logged "${old}" -q 'augmented: seeded' || fail "entrypoint overwrote an existing profile"
in_container "${old}" '! grep -q dsh-always-on "$DSH_HOME/profiles/web/package.json" && ! test -e "$DSH_HOME/pnpm-store"' || fail "existing profile was modified"
pass "existing profile left untouched, missing plugins reported"

echo "smoke test passed for ${image} (${variant})"
