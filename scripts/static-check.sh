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
    && grep -qF 'if [ "${VARIANT}" = bwrap ]; then' Dockerfile \
    && grep -qF 'command -v bwrap' Dockerfile \
    && grep -qF 'test ! -u "${bwrap}"' Dockerfile \
    && grep -qF 'PATCH GUARD: base image bwrap is setuid' Dockerfile \
    && grep -qF 'test -x "${bwrap}"' Dockerfile \
    && ! grep -Eq 'apt-get install[^;&|]*bubblewrap' <<<"${joined}" \
    && ! grep -Eq 'chmod [^;&|]*u\+s' <<<"${joined}"
}
lax_patch() {
  grep -qF 's/HttpOnly; SameSite=Strict/HttpOnly; SameSite=Lax/' Dockerfile \
    && grep -qF "grep -q 'HttpOnly; SameSite=Lax'" Dockerfile
}
agents_home() {
  grep -qF "grep -q '\"DSH_AGENTS_HOME\"'" Dockerfile \
    && grep -qE '^    DSH_AGENTS_HOME=/opt/deepseek-harness-augmented/agents \\$' Dockerfile \
    && test -s agents/AGENTS.md
}
check "bubblewrap contract assertion (bwrap variant) + sandbox-chain guard present, no local install, no setuid" bwrap_contract
check "SameSite=Lax patch + guard present" lax_patch
check "model-facing AGENTS.md wired through DSH_AGENTS_HOME (with guard)" agents_home

step "base image pins"
base_pins() {
  local rc=0 v line tag release="" pre='[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[0-9]+)?-r[0-9]+'
  declare -A suffix=([DEFAULT]='' [BWRAP]='-bwrap\.[0-9]+' [UNGOOGLED]='-ungoogled\.[0-9]+')
  [[ "$(grep -cE '^ARG BASE_[A-Z]+=' Dockerfile)" == 3 ]] || { echo "  expected exactly three ARG BASE_* pins" >&2; rc=1; }
  for v in DEFAULT BWRAP UNGOOGLED; do
    line="$(grep -E "^ARG BASE_${v}=" Dockerfile || true)"
    if ! grep -Eq "^ARG BASE_${v}=docker\.io/runzhliu/deepseek-harness:${pre}${suffix[${v}]}@sha256:[0-9a-f]{64}$" <<<"${line}"; then
      echo "  BASE_${v} must be docker.io/runzhliu/deepseek-harness:<X.Y.Z[-pre.N]-rN>${suffix[${v}]//\\/}@sha256:<digest>" >&2; rc=1; continue
    fi
    grep -B1 -E "^ARG BASE_${v}=" Dockerfile | grep -qE "^# renovate: datasource=docker depName=upstream-${v,,} packageName=runzhliu/deepseek-harness$" \
      || { echo "  BASE_${v} lacks its renovate annotation" >&2; rc=1; }
    tag="$(sed -E 's/^ARG BASE_[A-Z]+=[^:]+:([^@]+)@.*/\1/' <<<"${line}")"
    tag="$(grep -oE "^${pre}" <<<"${tag}")"
    if [[ -z "${release}" ]]; then release="${tag}"
    elif [[ "${tag}" != "${release}" ]]; then echo "  BASE_${v} is upstream release ${tag}, BASE_DEFAULT is ${release}: all variants must share one" >&2; rc=1; fi
  done
  if grep -E '^ARG BASE_' Dockerfile | grep -Eq -- '-market\.|:latest'; then echo "  never the -market variant or latest" >&2; rc=1; fi
  return "${rc}"
}
check "three upstream bases (default, -bwrap.N, -ungoogled.N) pinned by tag+digest, same upstream release, never market/latest" base_pins

step "tag scheme (scripts/tag-scheme.sh)"
tag_scheme_consistent() {
  local IMAGE_REPO TAG_SUFFIX VARIANTS rc=0 v
  declare -A MOVING_TAGS
  # shellcheck source=scripts/tag-scheme.sh
  . scripts/tag-scheme.sh
  grep -qxF "  IMAGE: docker.io/${IMAGE_REPO}" .github/workflows/ci.yml \
    || { echo "  ci.yml IMAGE is not docker.io/${IMAGE_REPO}" >&2; rc=1; }
  local joined; joined="$(IFS=,; echo "${VARIANTS[*]}")"
  grep -qxF "        variant: [${joined//,/, }]" .github/workflows/ci.yml \
    || { echo "  ci.yml build matrix variants differ from VARIANTS" >&2; rc=1; }
  for v in "${VARIANTS[@]}"; do
    [[ -n "${MOVING_TAGS[${v}]:-}" ]] || { echo "  no moving tag for variant ${v}" >&2; rc=1; }
    grep -qE "^ARG BASE_${v^^}=" Dockerfile || { echo "  no ARG BASE_${v^^} for variant ${v}" >&2; rc=1; }
  done
  [[ "${MOVING_TAGS[default]:-}" == latest ]] || { echo "  latest must point at the default variant" >&2; rc=1; }
  # The suffix and image name must only be spelled in tag-scheme.sh.
  if grep -nF -e "-${TAG_SUFFIX}." -e "${IMAGE_REPO}" scripts/next-tag.sh scripts/release-plan.sh >&2; then
    echo "  hardcoded image name or tag suffix above; use IMAGE_REPO / TAG_SUFFIX" >&2; rc=1
  fi
  return "${rc}"
}
check "image name, tag suffix and variants defined once, ci.yml and Dockerfile agree" tag_scheme_consistent

step "release planning (scripts/release-plan.sh)"
release_plan_tests() {
  local t fb rc=0 c1 c2 rp="${root}/scripts/release-plan.sh" up=1.2.3-rc.4-r1
  local da db
  da="$(printf 'a%.0s' {1..64})"; db="$(printf 'b%.0s' {1..64})"
  pins() {  # pins <digest of the bwrap base>
    printf 'ARG BASE_DEFAULT=docker.io/runzhliu/deepseek-harness:%s@sha256:%s\n' "${up}" "${da}"
    printf 'ARG BASE_BWRAP=docker.io/runzhliu/deepseek-harness:%s-bwrap.2@sha256:%s\n' "${up}" "$1"
    printf 'ARG BASE_UNGOOGLED=docker.io/runzhliu/deepseek-harness:%s-ungoogled.3@sha256:%s\n' "${up}" "${da}"
  }
  t="$(mktemp -d)"; fb="$(mktemp -d)"
  (
    set -e
    cd "${t}"
    git init -q -b main .
    git config user.email t@t; git config user.name t
    { pins "${da}"; echo 'RUN true'; } > Dockerfile; git add Dockerfile; git commit -qm one
    { pins "${da}"; echo 'RUN echo tools'; } > Dockerfile; git commit -qam tools
  ) >/dev/null 2>&1 || rc=1
  c1="$(git -C "${t}" rev-parse HEAD~1 2>/dev/null)" || rc=1
  { pins "${db}"; echo 'RUN echo tools'; } > "${t}/Dockerfile"   # only one variant's digest moves
  git -C "${t}" commit -qam upstream >/dev/null 2>&1 || rc=1
  c2="$(git -C "${t}" rev-parse HEAD 2>/dev/null)" || rc=1
  git -C "${t}" branch -q side "${c1}" >/dev/null 2>&1 || rc=1
  # Every call gets its environment explicitly; nothing is exported. RELEASES
  # replaces the `gh release list` lookup (newline-separated tags, newest first).
  rp_env() { env RELEASE_PLAN_ROOT="${t}" RELEASE_PLAN_MAIN=main RELEASE_PLAN_RETRY_DELAY=0 "$@"; }
  rp_is() { local want="$1"; shift; [[ "$(rp_env "${rp}" "$@" 2>/dev/null)" == "${want}" ]] || { echo "  unexpected result: release-plan.sh $*" >&2; rc=1; }; }
  rp_fails() { if rp_env "${rp}" "$@" >/dev/null 2>&1; then echo "  should have failed: release-plan.sh $*" >&2; rc=1; fi; }
  rp_ok() { rp_env "${rp}" "$@" >/dev/null 2>&1 || { echo "  should have passed: release-plan.sh $*" >&2; rc=1; }; }
  with_releases() { local r="$1"; shift; rp_env RELEASE_PLAN_RELEASES="${r}" "$@"; }
  r_is() { local r="$1" want="$2"; shift 2; [[ "$(with_releases "${r}" "${rp}" "$@" 2>/dev/null)" == "${want}" ]] || { echo "  unexpected result (releases: ${r:-none}): release-plan.sh $*" >&2; rc=1; }; }
  r_fails() { local r="$1"; shift; if with_releases "${r}" "${rp}" "$@" >/dev/null 2>&1; then echo "  should have failed (releases: ${r:-none}): release-plan.sh $*" >&2; rc=1; fi; }
  r_ok() { local r="$1"; shift; with_releases "${r}" "${rp}" "$@" >/dev/null 2>&1 || { echo "  should have passed (releases: ${r:-none}): release-plan.sh $*" >&2; rc=1; }; }
  d_is() { local want="$1"; shift; r_is "$1" "${want}" "${@:2}"; }   # d_is WANT RELEASES args...
  local t1="${up}-augmented.1" t2="${up}-augmented.2" old="${up}-bwrap.2-augmented.1"

  rp_is "${up}" upstream-tag
  rp_is "${up}-bwrap.2" upstream-tag "" bwrap
  rp_is "${up}-ungoogled.3" upstream-tag "" ungoogled
  rp_fails upstream-tag "" market
  rp_ok validate-tag "${up}-augmented.1"
  rp_ok validate-tag "${up}-augmented.12"
  rp_fails validate-tag "${up}-augmented.0"
  rp_fails validate-tag "${up}-augmented.01"
  rp_fails validate-tag "${up}-augmented.x"
  rp_fails validate-tag "${up}-augmented."
  rp_fails validate-tag "${up}"
  rp_fails validate-tag "${up}-bwrap.2-augmented.1"                         # releases are named after the default variant
  rp_fails validate-tag "${up}-devkit.1"                                     # retired schemes are not publishable
  rp_fails validate-tag "${up}-dev.1"
  rp_fails validate-tag 9.9.9-r1-augmented.1
  rp_fails validate-tag bogus
  rp_fails validate-tag v1.0.0
  rp_is "$(printf 'default %s-augmented.7 latest\nbwrap %s-bwrap.2-augmented.7 bwrap\nungoogled %s-ungoogled.3-augmented.7 ungoogled' "${up}" "${up}" "${up}")" \
    variant-tags "${up}-augmented.7"
  rp_fails variant-tags "${up}-bwrap.2-augmented.7"

  git -C "${t}" tag "${old}" "${c1}"
  git -C "${t}" tag "${t1}" "${c1}"
  git -C "${t}" tag "${t2}" "${c2}"
  git -C "${t}" tag bogus "${c2}"
  git -C "${t}" tag "${up}-augmented.9" side # on a branch that is not main
  git -C "${t}" branch -q -f side "${c1}"
  git -C "${t}" checkout -q --detach "${c1}" && git -C "${t}" commit -q --allow-empty -m stray && git -C "${t}" tag "${up}-augmented.8" HEAD
  git -C "${t}" checkout -q main

  # last-release: newest *valid* release; strays and failed hand-made releases are skipped
  r_is "${t2}"$'\n'"${t1}" "${t2}" last-release
  r_is "bogus"$'\n'"${t2}" "${t2}" last-release                           # a stray, non-augmented release is ignored
  r_is "${up}-augmented.8"$'\n'"${t1}" "${t1}" last-release                   # tagged commit not on main is ignored
  r_is "${old}" "${old}" last-release                                       # pre-split (bwrap-named) releases are still a baseline
  r_is "" "" last-release                                                   # no release at all
  r_is "${up}-devkit.3" "" last-release                                     # retired-scheme tags are never a baseline

  # upstream-changed: compare all three pins with the last release, else with BEFORE, else never publish
  r_ok    "${t1}" upstream-changed "${c2}"                                  # one variant's pin differs from last release
  r_ok    "${old}" upstream-changed "${c2}"
  r_fails "${t2}" upstream-changed "${c1}"                                  # same pins as last release
  r_ok    "" upstream-changed "${c1}"                                       # no release: compare with BEFORE
  r_fails "" upstream-changed "${c2}"
  r_fails "" upstream-changed 0000000000000000000000000000000000000000      # nothing to compare: never publish
  r_fails "" upstream-changed
  r_ok    "bogus"$'\n'"${t1}" upstream-changed "${c2}"                      # a stray release is not the baseline

  # decide: HEAD is the tip of main
  d_is "$(printf 'publish=true\nlatest=true')"   "${t1}" decide push refs/heads/main "${c2}"
  d_is "$(printf 'publish=false\nlatest=false')" "${t2}" decide push refs/heads/main "${c2}"
  d_is "$(printf 'publish=false\nlatest=false')" "${t1}" decide push refs/heads/other "${c2}"
  d_is "$(printf 'publish=false\nlatest=false')" ""      decide pull_request refs/pull/1/merge "${c1}"
  d_is "$(printf 'publish=true\nlatest=true')"   ""      decide schedule refs/heads/main ""
  d_is "$(printf 'publish=true\nlatest=true')"   ""      decide workflow_dispatch refs/heads/main ""
  d_is "$(printf 'publish=false\nlatest=false')" ""      decide workflow_dispatch refs/heads/feature ""
  d_is "$(printf 'publish=true\nlatest=true')"   ""      decide release refs/tags/x ""

  # decide: a run for an older commit (re-run, or main moved on) never publishes
  git -C "${t}" checkout -q --detach "${c1}"
  d_is "$(printf 'publish=false\nlatest=false')" "${t1}" decide push refs/heads/main "${c1}"
  d_is "$(printf 'publish=false\nlatest=false')" ""      decide schedule refs/heads/main ""
  d_is "$(printf 'publish=false\nlatest=false')" ""      decide workflow_dispatch refs/heads/main ""
  # a release on an older commit of main is published, but does not move the moving tags
  d_is "$(printf 'publish=true\nlatest=false')"  ""      decide release refs/tags/x ""
  git -C "${t}" checkout -q main

  # tag-free checks every variant's tag (fake Docker Hub: only the bwrap tag exists)
  printf '#!/bin/sh\nfor a; do case "$a" in *-bwrap.2-augmented.5) echo 200; exit 0;; esac; done\necho 404\n' > "${fb}/curl"; chmod +x "${fb}/curl"
  if PATH="${fb}:${PATH}" rp_env "${rp}" tag-free "${up}-augmented.5" >/dev/null 2>&1; then
    echo "  tag-free must fail when any variant tag exists" >&2; rc=1
  fi
  PATH="${fb}:${PATH}" rp_env "${rp}" tag-free "${up}-augmented.6" >/dev/null 2>&1 || { echo "  tag-free should pass when no variant tag exists" >&2; rc=1; }
  printf '#!/bin/sh\necho 503\n' > "${fb}/curl"
  if PATH="${fb}:${PATH}" rp_env "${rp}" tag-free "${up}-augmented.6" >/dev/null 2>&1; then
    echo "  tag-free must fail when Docker Hub fails" >&2; rc=1
  fi
  rm -f "${fb}/curl"

  # a failing GitHub API is fatal, never a silent "nothing to publish"
  printf '#!/bin/sh\necho "HTTP 502" >&2\nexit 1\n' > "${fb}/gh"; chmod +x "${fb}/gh"
  if PATH="${fb}:${PATH}" rp_env "${rp}" decide push refs/heads/main "${c1}" >/dev/null 2>&1; then
    echo "  decide must fail when 'gh release list' fails" >&2; rc=1
  fi
  if PATH="${fb}:${PATH}" rp_env "${rp}" last-release >/dev/null 2>&1; then
    echo "  last-release must fail when 'gh release list' fails" >&2; rc=1
  fi
  # a failing API must not be mistaken for "no release" in release-free either
  if PATH="${fb}:${PATH}" rp_env "${rp}" release-free "${t1}" >/dev/null 2>&1; then
    echo "  release-free must fail when 'gh release view' fails" >&2; rc=1
  fi
  printf '#!/bin/sh\necho "release not found" >&2\nexit 1\n' > "${fb}/gh"
  PATH="${fb}:${PATH}" rp_env "${rp}" release-free "${t1}" >/dev/null 2>&1 || { echo "  release-free should pass when the release does not exist" >&2; rc=1; }
  printf '#!/bin/sh\necho "tag: x"\nexit 0\n' > "${fb}/gh"
  if PATH="${fb}:${PATH}" rp_env "${rp}" release-free "${t1}" >/dev/null 2>&1; then
    echo "  release-free must fail when the release exists" >&2; rc=1
  fi
  rm -rf "${t}" "${fb}"
  return "${rc}"
}
check "tag validation, variant tags and publish decisions" release_plan_tests

step "dsh plugins (tools/dsh-plugins/package.json)"
if python3 - <<'PY'
import json, re, sys
p = json.load(open("tools/dsh-plugins/package.json"))
deps = p.get("dependencies", {})
enabled = p.get("dshPlugins", {}).get("enabled", [])
errors = []
if not deps:
    errors.append("no plugins listed")
for name, spec in deps.items():
    if not re.fullmatch(r"\d+\.\d+\.\d+(-[0-9A-Za-z.-]+)?", spec):
        errors.append(f"{name}: '{spec}' is not an exact version")
for name in enabled:
    if name not in deps:
        errors.append(f"enabled plugin {name} is not in dependencies")
if not enabled:
    errors.append("at least one plugin must be enabled by default")
if "@louisremi/dsh-docker-adapter" in deps:
    errors.append("@louisremi/dsh-docker-adapter is superseded by (and conflicts with) @louisremi/dsh-always-on")
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
then ok "exact pins, enabled set valid"; else bad "dsh plugins list"; fi

step "model-facing AGENTS.md command list"
agents_commands() {
  local block
  block="$(sed -n '/^<!-- commands:/,/^<!-- \/commands -->/p' agents/AGENTS.md)"
  [[ -n "${block}" ]] && grep -oE '`[^` ]+`' <<<"${block}" | grep -q .
}
check "agents/AGENTS.md has a smoke-testable <!-- commands --> block" agents_commands

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
for ai in ("@anthropic-ai/claude-code", "@google/gemini-cli", "@openai/codex", "task-master-ai", "opencode-ai", "@mariozechner/pi-coding-agent"):
    if ai in pkg["dependencies"]:
        errors.append(f"{ai}: AI CLIs are deliberately not bundled")
allowed = pkg.get("allowScripts", {})
for key, meta in lock["packages"].items():
    if key and meta.get("hasInstallScript"):
        name = key.split("node_modules/")[-1]
        if name not in allowed:
            errors.append(f"{name}@{meta.get('version')} has install scripts but no allowScripts decision")
locked = {k.split("node_modules/")[-1] for k in lock["packages"] if k}
for name in allowed:
    if name not in locked:
        errors.append(f"allowScripts entry {name} matches no locked package; remove it")
for e in errors:
    print(e, file=sys.stderr)
sys.exit(1 if errors else 0)
PY
then ok "lockfile consistent, exact pins, no AI CLIs, install-script policy complete"; else bad "npm lockfile"; fi

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
  check "shellcheck" shellcheck -x scripts/*.sh scripts/augmented-entrypoint
else
  skip "shellcheck not installed"
fi
check "refresh-checksums.py compiles" python3 -m py_compile scripts/refresh-checksums.py
check "install-dsh-plugins.mjs parses" node --check scripts/install-dsh-plugins.mjs

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
