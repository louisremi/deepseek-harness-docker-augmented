#!/usr/bin/env bash
# Prepare a Pocket ID instance that signs the owner in to dsh web
# (README: "Optional: sign in with Pocket ID").
#
#   scripts/pocket-id-setup.sh <dir>
#
# Creates, under <dir>:
#   data/                                   Pocket ID's SQLite database
#   secrets/pocket_id_encryption_key        32-byte base64 key, mode 600
#   secrets/dsh_oidc_client_secret          empty; you fill it from Pocket ID
#
# There is no user file and no password to set: the account and its passkey are
# created in the browser at /setup, and Pocket ID's sign-up page stops working
# as soon as that account exists. Existing files are kept.
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

client="${dir}/secrets/dsh_oidc_client_secret"
[[ -e "${client}" ]] || : > "${client}"
chmod 600 "${client}"

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
      DSH_OIDC_PUBLIC_URL=https://<dsh host>
      DSH_OIDC_ALLOWED_EMAILS=<your e-mail>
    then: docker compose -f compose.yaml -f compose.pocket-id.yaml up -d
 2. Open https://<pocket-id host>/setup , create your account, add a passkey.
    That page stops working once the first account exists.
 3. Administration -> OIDC Clients -> Add OIDC Client:
      type: confidential
      callback URL: https://<dsh host>/auth/callback
    then its Access tab: All Users.
 4. Write the client secret shown once into:
      ${client}
    set DSH_OIDC_CLIENT_ID in .env, and:
      docker compose up -d deepseek-harness
EOF
