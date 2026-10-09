#!/usr/bin/env bash
# Print the next image tag: <upstream-tag>-<suffix>.<N>, where N is one more than
# the highest N already published on Docker Hub for this upstream tag. Image
# name and suffix come from scripts/tag-scheme.sh.
#
#   scripts/next-tag.sh [repository]      default: IMAGE_REPO from tag-scheme.sh
#
# Anonymous Docker Hub API access is enough (public repository). A repository
# that does not exist yet yields N=1.
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
# shellcheck source=scripts/tag-scheme.sh
. "${root}/scripts/tag-scheme.sh"
repo="${1:-${IMAGE_REPO}}"

upstream="$(sed -n 's/^ARG DSH_BASE_IMAGE=.*:\([^:@]*\)@sha256:.*/\1/p' "${root}/Dockerfile")"
[[ -n "${upstream}" ]] || { echo "cannot parse upstream tag from Dockerfile" >&2; exit 1; }

url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${upstream}-${TAG_SUFFIX}."
max=0
while [[ -n "${url}" && "${url}" != null ]]; do
  # 404 = repository does not exist yet; any other failure aborts (never guess N,
  # or a later run could overwrite an existing tag).
  tmp="$(mktemp)"
  code="$(curl --silent --retry 3 --output "${tmp}" --write-out '%{http_code}' "${url}" || true)"
  body="$(cat "${tmp}")"; rm -f "${tmp}"
  [[ "${code}" == 404 ]] && break
  if [[ "${code}" != 200 ]] || ! jq -e '.results' >/dev/null 2>&1 <<<"${body}"; then
    echo "Docker Hub tag listing failed (HTTP ${code}); refusing to guess the next tag" >&2
    exit 1
  fi
  while read -r n; do
    [[ "${n}" =~ ^[0-9]+$ ]] && (( n > max )) && max="${n}"
  done < <(jq -r --arg p "${upstream}-${TAG_SUFFIX}." '.results[].name | select(startswith($p)) | ltrimstr($p)' <<<"${body}")
  url="$(jq -r '.next // empty' <<<"${body}")"
done

printf '%s-%s.%d\n' "${upstream}" "${TAG_SUFFIX}" "$((max + 1))"
