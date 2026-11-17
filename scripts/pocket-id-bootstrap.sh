#!/usr/bin/env bash
# Declarative Pocket ID setup for dsh web: create the admin, the OIDC client,
# its secret and a one-time login link, through Pocket ID's REST API instead of
# its UI. README: "Optional: sign in with Pocket ID".
#
#   docker compose -f compose.yaml -f compose.pocket-id.yaml run --rm pocket-id-bootstrap
#
# Runs inside the augmented image (it has curl and jq), so there is no extra
# image to trust and no API key on the host or in the dsh container. Every step
# is idempotent: re-running reuses the admin, the client and the secret.
#
# It needs, from the environment (compose provides them):
#   DSH_AUTH_PUBLIC_URL      Pocket ID's public HTTPS origin (also APP_URL)
#   DSH_AUTH_OWNER           username of the owner account
#   DSH_OIDC_ALLOWED_EMAILS  the owner's e-mail (first entry is used)
#   DSH_OIDC_PUBLIC_URL      dsh's public HTTPS origin
#   WORKOS-style *_FILE paths are not used here; the two secrets are read from
#   /run/secrets: pocket_id_api_key (STATIC_API_KEY) and
#   dsh_oidc_client_secret (the secret we generate, not Pocket ID).
set -euo pipefail

app="${DSH_AUTH_PUBLIC_URL:?DSH_AUTH_PUBLIC_URL is not set}"
owner="${DSH_AUTH_OWNER:?DSH_AUTH_OWNER is not set}"
email_list="${DSH_OIDC_ALLOWED_EMAILS:?DSH_OIDC_ALLOWED_EMAILS is not set}"
dsh_url="${DSH_OIDC_PUBLIC_URL:?DSH_OIDC_PUBLIC_URL is not set}"
email="${email_list%%,*}"
email="${email#"${email%%[![:space:]]*}"}"
email="${email%"${email##*[![:space:]]}"}"
api_key_file="${POCKET_ID_API_KEY_FILE:-/run/secrets/pocket_id_api_key}"
secret_file="${DSH_OIDC_CLIENT_SECRET_FILE:-/run/secrets/dsh_oidc_client_secret}"
client_id="${DSH_OIDC_CLIENT_ID:-dsh}"
callback="${dsh_url%/}/auth/callback"

die() { echo "pocket-id-bootstrap: $*" >&2; exit 1; }
log() { printf '  %s\n' "$*"; }

[[ -r "${api_key_file}" ]] || die "${api_key_file} is not readable (is the secret mounted?)"
[[ -r "${secret_file}" ]] || die "${secret_file} is not readable (is the secret mounted?)"
api_key="$(cat "${api_key_file}")"
client_secret="$(cat "${secret_file}")"
[[ ${#api_key} -ge 16 ]] || die "the API key must be at least 16 characters"
[[ ${#client_secret} -ge 16 ]] || die "the client secret must be at least 16 characters"

api() {
  local method="$1" path="$2" data="${3:-}"
  if [[ -n "${data}" ]]; then
    curl --fail-with-body --silent --show-error --max-time 20 \
      --request "${method}" --header "X-API-KEY: ${api_key}" \
      --header 'content-type: application/json' --data "${data}" "${app}${path}"
  else
    curl --fail-with-body --silent --show-error --max-time 20 \
      --request "${method}" --header "X-API-KEY: ${api_key}" "${app}${path}"
  fi
}

# Pocket ID may still be booting when the container starts.
for attempt in $(seq 1 60); do
  curl --silent --max-time 5 --output /dev/null "${app}/api/application-configuration" && break
  [[ ${attempt} == 60 ]] && die "${app} did not answer within 2 minutes"
  sleep 2
done

echo "Pocket ID at ${app}"

# --- the owner's account -----------------------------------------------------
users="$(api GET /api/users)"
user_id="$(echo "${users}" | jq -r --arg u "${owner}" '.data[] | select(.username | ascii_downcase == ($u | ascii_downcase)) | .id' | head -n1)"
if [[ -z "${user_id}" ]]; then
  user_id="$(api POST /api/users "$(jq -nc --arg u "${owner}" --arg e "${email}" \
    '{username: $u, email: $e, emailVerified: true, isAdmin: true, displayName: $u}')" | jq -r .id)"
  log "created admin ${owner} <${email}> (e-mail already verified)"
elif [[ "$(echo "${users}" | jq -r --arg id "${user_id}" '.data[] | select(.id == $id) | .isAdmin')" != true ]]; then
  die "${owner} exists but is not an admin; fix that in Pocket ID first"
else
  log "admin ${owner} already exists"
fi

# --- the dsh OIDC client -----------------------------------------------------
clients="$(api GET /api/oidc/clients)"
client="$(echo "${clients}" | jq -c --arg id "${client_id}" '.data[] | select(.id == $id)')"
if [[ -z "${client}" ]]; then
  api POST /api/oidc/clients "$(jq -nc --arg id "${client_id}" --arg cb "${callback}" \
    '{id: $id, name: "DeepSeek Harness", callbackURLs: [$cb], isPublic: false, isGroupRestricted: false, pkceEnabled: false, skipConsent: false}')" >/dev/null
  log "created client ${client_id} (confidential, All Users, callback ${callback})"
else
  callbacks="$(echo "${client}" | jq -r '.callbackURLs[]?' | tr '\n' ' ')"
  if [[ " ${callbacks} " == *" ${callback} "* ]]; then
    log "client ${client_id} already exists with the right callback"
  else
    log "WARNING: client ${client_id} exists but its callbacks are '${callbacks%,}'; add ${callback} in Pocket ID"
  fi
fi

# The secret is ours: Pocket ID only keeps a hash, and the list exposes the
# first four characters as a prefix, which is enough to tell our secret apart.
prefix="${client_secret:0:4}"
if api GET "/api/oidc/clients/${client_id}" \
  | jq -e --arg p "${prefix}" '[.credentials.secrets[]? | select(.isActive and .prefix == $p)] | length > 0' >/dev/null; then
  log "client secret already registered"
else
  api POST "/api/oidc/clients/${client_id}/secrets" "$(jq -nc --arg s "${client_secret}" '{secret: $s}')" >/dev/null
  log "registered the client secret from $(basename "${secret_file}")"
fi

# --- one login link for the owner --------------------------------------------
token="$(api POST "/api/users/${user_id}/one-time-access-token" '{}' | jq -r .token)"
[[ -n "${token}" && "${token}" != null ]] || die "Pocket ID did not return a login code"
cat <<EOF

Open this once, then click "Add Passkey" (it signs you in without a passkey):

  ${app%/}/lc/${token}

When you are logged into dsh with that passkey, the setup is done. The code is
single use and short lived; re-run this script for a fresh one.
EOF
