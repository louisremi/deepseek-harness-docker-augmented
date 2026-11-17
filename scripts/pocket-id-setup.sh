#!/usr/bin/env bash
# Prepare a Pocket ID instance that signs the owner in to dsh web
# (README: "Optional: sign in with Pocket ID").
#
#   scripts/pocket-id-setup.sh <dir>
#
# Creates, under <dir>:
#   data/                                   Pocket ID's SQLite database
#   secrets/pocket_id_encryption_key        32-byte base64 key, mode 600
#   secrets/pocket_id_api_key               STATIC_API_KEY for the bootstrap, mode 600
#   secrets/dsh_oidc_client_secret          the dsh client secret, mode 600
#
# Everything else (the admin account, the OIDC client and its secret) is
# registered by scripts/pocket-id-bootstrap.sh through Pocket ID's API, so no
# Pocket ID UI step is needed except adding your passkey. Existing files are
# kept, so re-running never invalidates what is already deployed.
# Run it as the user that will own the files (the container's user).
set -euo pipefail

[[ $# -eq 1 ]] || { echo "usage: $0 <dir>" >&2; exit 2; }
dir="$1"
umask 077
mkdir -p "${dir}/data" "${dir}/secrets"
dir="$(cd "${dir}" && pwd)"

# Pocket ID's SQLite database must not live on Unraid's shfs (/mnt/user): that
# FUSE layer is slow and has bitten other tools here. The overlay mounts
# DSH_AUTH_DATA_DIR separately for exactly this reason.
if [[ "${dir}" == /mnt/user/* ]]; then
  echo "warning: ${dir} is on Unraid's shfs. Set" >&2
  echo "         DSH_AUTH_DATA_DIR=/mnt/cache/appdata/$(basename "${dir}")/data in .env," >&2
  echo "         and move ${dir}/data there." >&2
fi

key="${dir}/secrets/pocket_id_encryption_key"
if [[ ! -s "${key}" ]]; then
  # 32 random bytes, base64: what the Pocket ID image expects.
  openssl rand -base64 32 > "${key}"
  chmod 600 "${key}"
  echo "generated: secrets/pocket_id_encryption_key"
else
  echo "kept: secrets/pocket_id_encryption_key"
fi

api="${dir}/secrets/pocket_id_api_key"
if [[ ! -s "${api}" ]]; then
  openssl rand -hex 32 > "${api}"
  chmod 600 "${api}"
  echo "generated: secrets/pocket_id_api_key"
else
  echo "kept: secrets/pocket_id_api_key"
fi

client="${dir}/secrets/dsh_oidc_client_secret"
if [[ ! -s "${client}" ]]; then
  # Pocket ID requires at least 16 characters; this is 43 base64url characters.
  openssl rand -base64 32 | tr '+/' '-_' | tr -d '=' > "${client}"
  chmod 600 "${client}"
  echo "generated: secrets/dsh_oidc_client_secret"
else
  echo "kept: secrets/dsh_oidc_client_secret"
fi

if [[ "$(id -u)" == 0 ]]; then
  echo
  echo "You ran this as root; the container runs as ${DSH_AUTH_UID:-1000}:${DSH_AUTH_GID:-1000}"
  echo "(99:100 on Unraid). Give it the files:"
  echo "  chown -R ${DSH_AUTH_UID:-1000}:${DSH_AUTH_GID:-1000} ${dir}"
fi

cat <<EOF

Done. Next:
 1. cp .env.pocket-id.example .env and fill in:
      DSH_AUTH_DIR=${dir}
      DSH_AUTH_PUBLIC_URL=https://<pocket-id host>
      DSH_AUTH_OWNER=<username>
      DSH_OIDC_PUBLIC_URL=https://<dsh host>
      DSH_OIDC_ALLOWED_EMAILS=<your e-mail>
    then: docker compose -f compose.yaml -f compose.pocket-id.yaml up -d
 2. Register the admin, the client, its secret and a login link:
      docker compose -f compose.yaml -f compose.pocket-id.yaml run --rm pocket-id-bootstrap
 3. Open the link it prints, click Add Passkey. Done.
EOF
