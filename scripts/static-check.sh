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
# bubblewrap comes from upstream's -bwrap.N base variant; the Dockerfile must
# only assert it (never install it) and keep the sandbox-chain guard.
bwrap_contract() {
  # Join backslash continuations (and drop comments) so a multi-line
  # `apt-get install \ bubblewrap \ ...` cannot slip past the negative check.
  local joined
  joined="$(awk '{ sub(/#.*/, "") } /\\$/ { printf "%s ", substr($0, 1, length($0)-1); next } { print }' Dockerfile)"
  grep -qF "grep -Eq 'linux: \\[\"bwrap\"'" Dockerfile \
    && grep -qF 'command -v bwrap' Dockerfile \
    && grep -qF 'test ! -u "${bwrap}"' Dockerfile \
    && grep -qF 'PATCH GUARD: base image bwrap is setuid' Dockerfile \
    && grep -qF 'test -x "${bwrap}"' Dockerfile \
    && ! grep -Eq 'apt-get install[^;&|]*bubblewrap' <<<"${joined}"
}
lax_patch() {
  grep -qF 's/HttpOnly; SameSite=Strict/HttpOnly; SameSite=Lax/' Dockerfile \
    && grep -qF "grep -q 'HttpOnly; SameSite=Lax'" Dockerfile
}
check "bubblewrap contract assertion + sandbox-chain guard present (no local install)" bwrap_contract
check "SameSite=Lax patch + guard present" lax_patch

step "base image pin"
if grep -Eq '^ARG DSH_BASE_IMAGE=docker\.io/runzhliu/deepseek-harness:[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?-r[0-9]+-bwrap\.[0-9]+@sha256:[0-9a-f]{64}$' Dockerfile; then
  ok "DSH_BASE_IMAGE pinned by tag and digest"
else
  bad "DSH_BASE_IMAGE must be docker.io/runzhliu/deepseek-harness:<X.Y.Z[-pre.N]-rN-bwrap.M>@sha256:<digest>"
fi
if grep '^ARG DSH_BASE_IMAGE=' Dockerfile | grep -Eq -- '-(market|ungoogled)\.'; then
  bad "DSH_BASE_IMAGE must use the bwrap upstream variant, not market/ungoogled"
else
  ok "bwrap upstream variant (not market/ungoogled)"
fi

step "release planning (scripts/release-plan.sh)"
release_plan_tests() {
  local t rc=0 pin1 pin2 c1 c2 rp="${root}/scripts/release-plan.sh"
  t="$(mktemp -d)"
  pin1='ARG DSH_BASE_IMAGE=docker.io/runzhliu/deepseek-harness:1.2.3-rc.4-r1-bwrap.1@sha256:'"$(printf 'a%.0s' {1..64})"
  pin2='ARG DSH_BASE_IMAGE=docker.io/runzhliu/deepseek-harness:1.2.3-rc.4-r1-bwrap.1@sha256:'"$(printf 'b%.0s' {1..64})"
  (
    set -e
    cd "${t}"
    git init -q .
    git config user.email t@t; git config user.name t
    printf '%s\nRUN true\n' "${pin1}" > Dockerfile; git add Dockerfile; git commit -qm one
    printf '%s\nRUN echo tools\n' "${pin1}" > Dockerfile; git commit -qam tools
  ) >/dev/null 2>&1 || rc=1
  c1="$(git -C "${t}" rev-parse HEAD~1 2>/dev/null)" || rc=1
  printf '%s\nRUN echo tools\n' "${pin2}" > "${t}/Dockerfile"
  git -C "${t}" commit -qam upstream >/dev/null 2>&1 || rc=1
  c2="$(git -C "${t}" rev-parse HEAD 2>/dev/null)" || rc=1
  export RELEASE_PLAN_ROOT="${t}"
  rp_is() { local want="$1"; shift; [[ "$("${rp}" "$@" 2>/dev/null)" == "${want}" ]] || { echo "  unexpected result: release-plan.sh $*" >&2; rc=1; }; }
  rp_fails() { if "${rp}" "$@" >/dev/null 2>&1; then echo "  should have failed: release-plan.sh $*" >&2; rc=1; fi; }
  rp_ok() { "${rp}" "$@" >/dev/null 2>&1 || { echo "  should have passed: release-plan.sh $*" >&2; rc=1; }; }

  rp_is 1.2.3-rc.4-r1-bwrap.1 upstream-tag
  rp_ok validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.1
  rp_ok validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.12
  rp_fails validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.0
  rp_fails validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.01
  rp_fails validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.x
  rp_fails validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.
  rp_fails validate-tag 1.2.3-rc.4-r1-bwrap.1
  rp_fails validate-tag 9.9.9-r1-bwrap.1-devkit.1
  rp_fails validate-tag bogus
  rp_fails validate-tag v1.0.0

  # a release that already carries the current pin: nothing to publish
  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.1 rp_ok validate-tag 1.2.3-rc.4-r1-bwrap.1-devkit.1
  git -C "${t}" tag 1.2.3-rc.4-r1-bwrap.1-devkit.1 "${c1}"
  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.1 rp_ok upstream-changed "${c2}"      # pin differs from last release
  git -C "${t}" tag 1.2.3-rc.4-r1-bwrap.1-devkit.2 "${c2}"
  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.2 rp_fails upstream-changed "${c1}"   # same pin as last release
  RELEASE_PLAN_LAST_RELEASE='' rp_ok upstream-changed "${c1}"                                  # no release: compare with BEFORE
  RELEASE_PLAN_LAST_RELEASE='' rp_fails upstream-changed "${c2}"
  RELEASE_PLAN_LAST_RELEASE='' rp_fails upstream-changed 0000000000000000000000000000000000000000  # nothing to compare: never publish
  RELEASE_PLAN_LAST_RELEASE='' rp_fails upstream-changed

  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.1 rp_is publish=true  decide push refs/heads/main "${c2}"
  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.2 rp_is publish=false decide push refs/heads/main "${c2}"
  RELEASE_PLAN_LAST_RELEASE=1.2.3-rc.4-r1-bwrap.1-devkit.1 rp_is publish=false decide push refs/heads/other "${c2}"
  rp_is publish=false decide pull_request refs/pull/1/merge "${c1}"
  rp_is publish=true  decide schedule refs/heads/main ""
  rp_is publish=true  decide workflow_dispatch refs/heads/main ""
  rp_is publish=false decide workflow_dispatch refs/heads/feature ""
  rp_is publish=true  decide release refs/tags/x ""
  rm -rf "${t}"
  return "${rc}"
}
check "tag validation and publish decisions" release_plan_tests

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
