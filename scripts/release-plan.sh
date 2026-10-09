#!/usr/bin/env bash
# Release/publish decisions for CI (ci.yml). Kept in a script so shellcheck and
# scripts/static-check.sh cover it; no Docker daemon needed.
#
#   release-plan.sh base-line [REV]             the `ARG DSH_BASE_IMAGE=` line at REV (default: working tree)
#   release-plan.sh upstream-tag [REV]          the upstream image tag in it
#   release-plan.sh last-release                newest non-draft release named <upstream>-augmented.<N>
#                                               whose commit is on main (empty if none). Anything else
#                                               (a stray or failed hand-made release) is ignored.
#                                               Fails if the GitHub API does; never guesses.
#   release-plan.sh upstream-changed BEFORE     exit 0 if the base image pin differs from the last
#                                               release (or from BEFORE when there is no release yet)
#   release-plan.sh validate-tag TAG [REV]      TAG must be <upstream-tag at REV>-augmented.<N>, N >= 1
#   release-plan.sh tag-free TAG [REPO]         exit 0 if TAG is not on Docker Hub yet
#   release-plan.sh release-free TAG            exit 0 if no GitHub release named TAG exists
#   release-plan.sh decide EVENT REF BEFORE     print `publish=true|false` and `latest=true|false`
#
# Only the tip of main is ever published by a push / schedule / dispatch run (a
# re-run of an older run would otherwise republish an old commit). A release on
# an older commit of main is published under its own tag but does not move `latest`.
#
# Test hooks: RELEASE_PLAN_ROOT (repo root), RELEASE_PLAN_MAIN (default
# origin/main), RELEASE_PLAN_RELEASES (newline-separated release tags, newest
# first; replaces the `gh release list` lookup) and RELEASE_PLAN_RETRY_DELAY.
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

main_ref() { printf '%s' "${RELEASE_PLAN_MAIN:-origin/main}"; }

# Is the checked-out commit the tip of main?
at_main_tip() {
  local head tip
  head="$(git -C "${root}" rev-parse HEAD)"
  tip="$(git -C "${root}" rev-parse --verify -q "$(main_ref)^{commit}")" || return 1
  [[ "${head}" == "${tip}" ]]
}

# Non-draft release tags, newest first. A failing API call is retried and then
# fatal: a silent fallback would hide a missed publish.
release_tags() {
  if [[ -v RELEASE_PLAN_RELEASES ]]; then printf '%s\n' "${RELEASE_PLAN_RELEASES}"; return 0; fi
  local out
  for _ in 1 2 3; do
    if out="$(gh release list --limit 30 --json tagName,isDraft,createdAt \
        --jq '[.[] | select(.isDraft | not)] | sort_by(.createdAt) | reverse | .[].tagName')"; then
      printf '%s\n' "${out}"
      return 0
    fi
    sleep "${RELEASE_PLAN_RETRY_DELAY:-3}"
  done
  die "cannot list GitHub releases (gh failed 3 times); refusing to guess"
}

last_release() {
  local tags tag sha tip
  tags="$(release_tags)" || exit 1
  while IFS= read -r tag; do
    [[ "${tag}" =~ -augmented\.[1-9][0-9]*$ ]] || continue
    # Resolvable and not an ancestor of main: a release made from a stray commit.
    if sha="$(git -C "${root}" rev-parse --verify -q "${tag}^{commit}")" \
      && tip="$(git -C "${root}" rev-parse --verify -q "$(main_ref)^{commit}")" \
      && ! git -C "${root}" merge-base --is-ancestor "${sha}" "${tip}"; then
      continue
    fi
    printf '%s\n' "${tag}"
    return 0
  done <<<"${tags}"
}

upstream_changed() {
  local before="${1:-}" last ref=""
  last="$(last_release)" || exit 1
  if [[ -n "${last}" ]] && git -C "${root}" cat-file -e "${last}^{commit}" 2>/dev/null; then
    ref="${last}"
  elif [[ -n "${before}" && ! "${before}" =~ ^0+$ ]] && git -C "${root}" cat-file -e "${before}^{commit}" 2>/dev/null; then
    echo "::warning::No usable GitHub release to compare with; comparing with the previous commit of this push (${before})." >&2
    ref="${before}"
  else
    echo "::warning::Nothing to compare the upstream pin with (no release, no previous commit); not publishing." >&2
    return 1
  fi
  [[ "$(base_line "${ref}")" != "$(base_line)" ]]
}

validate_tag() {
  local tag="${1:-}" rev="${2:-}" up
  up="$(upstream_tag "${rev}")"
  if [[ "${tag}" != "${up}"-augmented.* || ! "${tag#"${up}"-augmented.}" =~ ^[1-9][0-9]*$ ]]; then
    die "release tag '${tag}' must be '${up}-augmented.<N>' (N >= 1); the next free one is printed by scripts/next-tag.sh"
  fi
}

tag_free() {
  local tag="${1:?tag}" repo="${2:-louisremi/deepseek-harness-augmented}" code
  code="$(curl --silent --retry 3 --output /dev/null --write-out '%{http_code}' \
    "https://hub.docker.com/v2/repositories/${repo}/tags/${tag}" || true)"
  case "${code}" in
    404) return 0 ;;
    200) die "${repo}:${tag} already exists on Docker Hub; refusing to overwrite it" ;;
    *) die "Docker Hub lookup failed (HTTP ${code}); refusing to guess" ;;
  esac
}

release_free() {
  local tag="${1:?tag}" out
  if out="$(gh release view "${tag}" 2>&1)"; then
    die "a GitHub release named '${tag}' already exists; refusing to publish over it"
  elif grep -qi 'release not found' <<<"${out}"; then
    return 0
  fi
  die "GitHub release lookup failed (${out}); refusing to guess"
}

emit() { echo "publish=$1"; echo "latest=$2"; }

decide() {
  local event="${1:?event}" ref="${2:-}" before="${3:-}"
  case "${event}" in
    release)
      # validate-tag, on-main and tag-free already ran. `latest` only moves for the tip of main.
      if at_main_tip; then emit true true; else emit true false; fi ;;
    schedule | workflow_dispatch | push)
      if [[ "${ref}" != refs/heads/main ]]; then emit false false; return 0; fi
      if ! at_main_tip; then
        echo "::notice::This run is not for the tip of main (re-run of an older run, or main moved on); not publishing." >&2
        emit false false; return 0
      fi
      if [[ "${event}" != push ]] || upstream_changed "${before}"; then emit true true; else emit false false; fi ;;
    *) emit false false ;;
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
  release-free) release_free "$@" ;;
  decide) decide "$@" ;;
  *) die "unknown command '${cmd}'" ;;
esac
