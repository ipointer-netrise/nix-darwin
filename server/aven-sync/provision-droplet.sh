#!/usr/bin/env bash
# Create the aven-sync droplet on DigitalOcean.
#
# The API token is read from 1Password at invocation time and passed to doctl
# through the environment only. It is never written to disk: we deliberately do
# NOT run `doctl auth init`, which would persist the token in plaintext at
# ~/.config/doctl/config.yaml.
set -euo pipefail

OP_TOKEN_REF="${OP_TOKEN_REF:-op://Personal/DigitalOcean - Aven Setup API Token/password}"
DROPLET_NAME="${DROPLET_NAME:-aven-sync}"
DROPLET_SIZE="${DROPLET_SIZE:-s-1vcpu-1gb}"
DROPLET_IMAGE="${DROPLET_IMAGE:-ubuntu-24-04-x64}"
DROPLET_REGION="${DROPLET_REGION:-nyc3}"
SSH_KEY_NAME="${SSH_KEY_NAME:-}"

info() { printf '\033[1;34m==> %s\033[0m\n' "$1"; }
error() { printf '\033[1;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

command -v op >/dev/null || error "1Password CLI (op) not found."
command -v doctl >/dev/null || error "doctl not found."
op account list >/dev/null 2>&1 || error "1Password CLI is not signed in. Run: eval \$(op signin)"

info "Reading DigitalOcean token from 1Password..."
DIGITALOCEAN_ACCESS_TOKEN="$(op read "$OP_TOKEN_REF")" \
  || error "Could not read $OP_TOKEN_REF"
[[ -n "$DIGITALOCEAN_ACCESS_TOKEN" ]] || error "Token at $OP_TOKEN_REF is empty."
export DIGITALOCEAN_ACCESS_TOKEN

# --- Idempotence: don't create a second droplet ---
EXISTING_IP="$(doctl compute droplet list --format Name,PublicIPv4 --no-header \
  | awk -v n="$DROPLET_NAME" '$1 == n { print $2 }')"
if [[ -n "$EXISTING_IP" ]]; then
  info "Droplet '$DROPLET_NAME' already exists at $EXISTING_IP -- nothing to do."
  echo "$EXISTING_IP"
  exit 0
fi

# --- SSH key is mandatory: without one DO emails a root password we can't use ---
if [[ -n "$SSH_KEY_NAME" ]]; then
  SSH_KEY_IDS="$(doctl compute ssh-key list --format ID,Name --no-header \
    | awk -v n="$SSH_KEY_NAME" '$2 == n { print $1 }')"
  [[ -n "$SSH_KEY_IDS" ]] || error "No DigitalOcean SSH key named '$SSH_KEY_NAME'."
else
  SSH_KEY_IDS="$(doctl compute ssh-key list --format ID --no-header | paste -sd, -)"
fi

if [[ -z "$SSH_KEY_IDS" ]]; then
  error "No SSH keys registered with DigitalOcean.

Register one first, otherwise DO provisions the droplet with an emailed root
password instead of key auth. Either:
  * Add a public key in the DO console (Settings -> Security -> SSH Keys), or
  * Re-mint the API token with the 'ssh_key: create' scope and upload one:
      doctl compute ssh-key import aven-sync --public-key-file <path>

To mint a dedicated key in 1Password rather than reusing a Git key:
  op item create --category 'SSH Key' --title 'Aven Sync Droplet SSH Key' \\
    --vault 'SSH Credentials' --ssh-generate-key ed25519"
fi

info "Creating droplet '$DROPLET_NAME' ($DROPLET_SIZE, $DROPLET_IMAGE, $DROPLET_REGION)..."
doctl compute droplet create "$DROPLET_NAME" \
  --image "$DROPLET_IMAGE" \
  --size "$DROPLET_SIZE" \
  --region "$DROPLET_REGION" \
  --ssh-keys "$SSH_KEY_IDS" \
  --wait \
  --format Name,PublicIPv4,Status

IP="$(doctl compute droplet list --format Name,PublicIPv4 --no-header \
  | awk -v n="$DROPLET_NAME" '$1 == n { print $2 }')"

cat <<EOF

$(printf '\033[1;32m==> Droplet ready: %s\033[0m' "$IP")

Next:
  ssh root@$IP 'curl -fsSL https://tailscale.com/install.sh | sh && tailscale up'
  scp -r server/aven-sync root@$IP:/tmp/
  ssh root@$IP 'bash /tmp/aven-sync/install.sh'
EOF
