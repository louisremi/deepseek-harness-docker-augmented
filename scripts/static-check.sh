#!/usr/bin/env bash
# Fast checks that need no Docker daemon. Run by CI (validate job) and by
# maintainer-agent before every push. Missing optional linters are reported, not
# fatal, so the script also works on a bare workstation.
#
#   scripts/static-check.sh [--online]
#
# --online additionally resolves the npm lockfile and Python wheels against
# the registries for both target architectures (slower, needs network).
set -uo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
cd "${root}" || exit 2
online=0
[[ "${1:-}" == "--online" ]] && online=1
failures=0

step() { printf '\n== %s\n' "$1"; }
ok() { printf 'ok   %s\n' "$1"; }
bad() { printf 'FAIL %s\n' "$1" >&2; failures=$((failures + 1)); }
skip() { printf 'skip %s\n' "$1"; }
# check "<description>" cmd args...  -> ok/FAIL depending on the command's status
check() { local d="$1"; shift; if "$@"; then ok "$d"; else bad "$d"; fi; }

step "patch guards in Dockerfile"
bwrap_patch() {
  grep -qF 'apt-get install --yes --no-install-recommends bubblewrap;' Dockerfile \
    && grep -qF "grep -Eq 'linux: \\[\"bwrap\"'" Dockerfile
}
lax_patch() {
  grep -qF 's/HttpOnly; SameSite=Strict/HttpOnly; SameSite=Lax/' Dockerfile \
    && grep -qF "grep -q 'HttpOnly; SameSite=Lax'" Dockerfile
}
check "bubblewrap patch + sandbox-chain guard present" bwrap_patch
check "SameSite=Lax patch + guard present" lax_patch

step "base image pin"
if grep -Eq '^ARG DSH_BASE_IMAGE=docker\.io/runzhliu/deepseek-harness:[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?-r[0-9]+@sha256:[0-9a-f]{64}$' Dockerfile; then
  ok "DSH_BASE_IMAGE pinned by tag and digest"
else
  bad "DSH_BASE_IMAGE must be docker.io/runzhliu/deepseek-harness:<X.Y.Z[-pre.N]-rN>@sha256:<digest>"
fi
if grep '^ARG DSH_BASE_IMAGE=' Dockerfile | grep -Eq -- '-(market|ungoogled)\.'; then
  bad "DSH_BASE_IMAGE must use the plain upstream variant"
else
  ok "plain upstream variant"
fi

step "release binary checksums"
check "checksum ARGs well-formed" python3 scripts/refresh-checksums.py --check

step "npm lockfile"
if python3 - <<'PY'
import json, sys
pkg = json.load(open("tools/npm/package.json"))
lock = json.load(open("tools/npm/package-lock.json"))
root = lock["packages"][""]
errors = []
if root.get("dependencies") != pkg["dependencies"]:
    errors.append("package-lock.json root dependencies differ from package.json (run npm install --package-lock-only)")
for name, spec in pkg["dependencies"].items():
    if not spec[0].isdigit():
        errors.append(f"{name}: '{spec}' is not an exact version")
    got = lock["packages"].get(f"node_modules/{name}", {}).get("version")
    if got != spec:
        errors.append(f"{name}: lockfile has {got}, package.json pins {spec}")
if "pnpm" in pkg["dependencies"]:
    errors.append("pnpm must not be bundled (upstream pins its own for dsh plugin)")
allowed = pkg.get("allowScripts", {})
for key, meta in lock["packages"].items():
    if key and meta.get("hasInstallScript"):
        name = key.split("node_modules/")[-1]
        if name not in allowed:
            errors.append(f"{name}@{meta.get('version')} has install scripts but no allowScripts decision")
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
then ok "lockfile consistent, exact pins, install-script policy complete"; else bad "npm lockfile"; fi

step "python requirements"
if python3 - <<'PY'
import re, sys
bad = [l.strip() for l in open("tools/python/requirements.txt")
       if l.strip() and not l.startswith("#") and not re.fullmatch(r"[A-Za-z0-9._-]+==[A-Za-z0-9.+!-]+", l.strip())]
for b in bad:
    print(f"not an exact pin: {b}", file=sys.stderr)
sys.exit(1 if bad else 0)
PY
then ok "all requirements exactly pinned"; else bad "python requirements"; fi

step "renovate config"
if command -v npx >/dev/null 2>&1 && (( online )); then
  check "renovate.json5 valid" npx --yes --package renovate@44 -- renovate-config-validator --strict --no-global renovate.json5
else
  skip "renovate-config-validator (offline; pass --online)"
fi

step "linters"
if command -v hadolint >/dev/null 2>&1; then
  check "hadolint" hadolint Dockerfile
else
  skip "hadolint not installed"
fi
if command -v shellcheck >/dev/null 2>&1; then
  check "shellcheck" shellcheck -x scripts/*.sh
else
  skip "shellcheck not installed"
fi
check "refresh-checksums.py compiles" python3 -m py_compile scripts/refresh-checksums.py

if (( online )); then
  step "npm registry resolution"
  tmp="$(mktemp -d)"
  cp tools/npm/package.json tools/npm/package-lock.json "${tmp}/"
  if (cd "${tmp}" && npm ci --dry-run --ignore-scripts --no-audit --no-fund --cache "${tmp}/.cache" >/dev/null 2>&1); then
    ok "npm ci --dry-run"
  else
    bad "npm ci --dry-run"
  fi
  rm -rf "${tmp}"

  step "python wheels (cp313, x86_64 + aarch64)"
  for arch in x86_64 aarch64; do
    plats=()
    for t in manylinux_2_39 manylinux_2_36 manylinux_2_34 manylinux_2_31 manylinux_2_28 manylinux_2_27 \
             manylinux_2_24 manylinux_2_17 manylinux2014 manylinux_2_12 manylinux2010 manylinux_2_5 manylinux1; do
      plats+=(--platform "${t}_${arch}")
    done
    dl="$(mktemp -d)"
    if python3 -m pip download --quiet --disable-pip-version-check --no-cache-dir --only-binary=:all: \
        --python-version 3.13 --implementation cp --abi cp313 "${plats[@]}" \
        -d "${dl}" -r tools/python/requirements.txt >/dev/null 2>&1; then
      ok "wheels resolve for ${arch}"
    else
      bad "wheels missing for ${arch} (rerun: pip download ... --platform manylinux_2_28_${arch})"
    fi
    rm -rf "${dl}"
  done

  step "release binary checksums (download + cross-check)"
  check "checksums match downloads and upstream-published sums" python3 scripts/refresh-checksums.py --verify
fi

echo
if (( failures )); then
  echo "static-check: ${failures} failure(s)" >&2
  exit 1
fi
echo "static-check: all passed"
