#!/usr/bin/env bash
# Release/publish decisions for CI (ci.yml). Kept in a script so shellcheck and
# scripts/static-check.sh cover it; no Docker daemon needed.
#
#   release-plan.sh base-line [REV]             the `ARG DSH_BASE_IMAGE=` line at REV (default: working tree)
#   release-plan.sh upstream-tag [REV]          the upstream image tag in it
#   release-plan.sh last-release                newest non-draft GitHub release tag (empty if none)
#   release-plan.sh upstream-changed BEFORE     exit 0 if the base image pin differs from the last
#                                               release (or from BEFORE when there is no release yet)
#   release-plan.sh validate-tag TAG [REV]      TAG must be <upstream-tag at REV>-dev.<N>, N >= 1
#   release-plan.sh tag-free TAG [REPO]         exit 0 if TAG is not on Docker Hub yet
#   release-plan.sh decide EVENT REF BEFORE     print `publish=true|false` for a CI run
#
# Test hooks: RELEASE_PLAN_ROOT (repo root) and RELEASE_PLAN_LAST_RELEASE
# (replaces the `gh release list` lookup; empty means "no release").
set -euo pipefail

root="${RELEASE_PLAN_ROOT:-$(cd "$(dirname "$0")/.." && pwd)}"

die() { echo "release-plan: $*" >&2; exit 1; }

dockerfile_at() {
  local rev="${1:-}"
  if [[ -z "${rev}" ]]; then cat "${root}/Dockerfile"; else git -C "${root}" show "${rev}:Dockerfile"; fi
}

base_line() { dockerfile_at "${1:-}" | grep -m1 '^ARG DSH_BASE_IMAGE=' || true; }

upstream_tag() {
  local line tag
  line="$(base_line "${1:-}")"
  tag="$(sed -n 's/^ARG DSH_BASE_IMAGE=.*:\([^:@]*\)@sha256:.*/\1/p' <<<"${line}")"
  [[ -n "${tag}" ]] || die "cannot parse the upstream tag from the Dockerfile${1:+ at $1}"
  printf '%s\n' "${tag}"
}

last_release() {
  if [[ -v RELEASE_PLAN_LAST_RELEASE ]]; then printf '%s\n' "${RELEASE_PLAN_LAST_RELEASE}"; return; fi
  gh release list --limit 20 --json tagName,isDraft,createdAt \
    --jq '[.[] | select(.isDraft | not)] | sort_by(.createdAt) | last | .tagName // empty'
}

upstream_changed() {
  local before="${1:-}" last ref=""
  last="$(last_release)"
  if [[ -n "${last}" ]] && git -C "${root}" cat-file -e "${last}^{commit}" 2>/dev/null; then
    ref="${last}"
  elif [[ -n "${before}" && ! "${before}" =~ ^0+$ ]] && git -C "${root}" cat-file -e "${before}^{commit}" 2>/dev/null; then
    ref="${before}"
  else
    return 1 # nothing to compare with: do not guess, do not publish
  fi
  [[ "$(base_line "${ref}")" != "$(base_line)" ]]
}

validate_tag() {
  local tag="${1:-}" rev="${2:-}" up
  up="$(upstream_tag "${rev}")"
  if [[ "${tag}" != "${up}"-dev.* || ! "${tag#"${up}"-dev.}" =~ ^[1-9][0-9]*$ ]]; then
    die "release tag '${tag}' must be '${up}-dev.<N>' (N >= 1); the next free one is printed by scripts/next-tag.sh"
  fi
}

tag_free() {
  local tag="${1:?tag}" repo="${2:-louisremi/deepseek-harness-devkit}" code
  code="$(curl --silent --retry 3 --output /dev/null --write-out '%{http_code}' \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" || true)"
  case "${code}" in
    404) return 0 ;;
    200) die "${repo}:${tag} already exists on Docker Hub; refusing to overwrite it" ;;
    *) die "Docker Hub lookup failed (HTTP ${code}); refusing to guess" ;;
  esac
}

decide() {
  local event="${1:?event}" ref="${2:-}" before="${3:-}"
  case "${event}" in
    release) echo "publish=true" ;;
    schedule | workflow_dispatch)
      [[ "${ref}" == refs/heads/main ]] && echo "publish=true" || echo "publish=false" ;;
    push)
      if [[ "${ref}" == refs/heads/main ]] && upstream_changed "${before}"; then
        echo "publish=true"
      else
        echo "publish=false"
      fi ;;
    *) echo "publish=false" ;;
  esac
}

cmd="${1:-}"
[[ -n "${cmd}" ]] || die "usage: release-plan.sh <command> [args] (see the header)"
shift
case "${cmd}" in
  base-line) base_line "$@" ;;
  upstream-tag) upstream_tag "$@" ;;
  last-release) last_release ;;
  upstream-changed) upstream_changed "$@" ;;
  validate-tag) validate_tag "$@" ;;
  tag-free) tag_free "$@" ;;
  decide) decide "$@" ;;
  *) die "unknown command '${cmd}'" ;;
esac
