#!/usr/bin/env bash
# Print the next release tag: <X-rN>-<suffix>.<N> (the default variant's tag),
# where N is one more than the highest N already published on Docker Hub for
# this upstream release, across all variants (they share the counter). The
# other variants' tags for the same N: `release-plan.sh variant-tags <tag>`.
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

release="$("${root}/scripts/release-plan.sh" upstream-tag)"
re="^${release//./\\.}(-(bwrap|ungoogled)\\.[0-9]+)?-${TAG_SUFFIX}\\.([1-9][0-9]*)$"

url="https://hub.docker.com/v2/repositories/${repo}/tags?page_size=100&name=${release}-"
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
  while read -r name; do
    if [[ "${name}" =~ ${re} ]] && (( BASH_REMATCH[3] > max )); then max="${BASH_REMATCH[3]}"; fi
  done < <(jq -r '.results[].name' <<<"${body}")
  url="$(jq -r '.next // empty' <<<"${body}")"
done

printf '%s-%s.%d\n' "${release}" "${TAG_SUFFIX}" "$((max + 1))"
