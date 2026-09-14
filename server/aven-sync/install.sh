#!/usr/bin/env bash
# Provision an aven sync server on a Linux VPS, reachable only over Tailscale.
# Idempotent: safe to re-run to upgrade the binary or repair the unit.
set -euo pipefail

AVEN_PORT="${AVEN_PORT:-3000}"
AVEN_USER="aven"
CONFIG_DIR="/etc/aven"
DATA_DIR="/var/lib/aven"
BIN="/usr/local/bin/aven"
UNIT_SRC="$(dirname "$(readlink -f "$0")")/aven-sync.service"

info() { printf '\033[1;34m==> %s\033[0m\n' "$1"; }
error() { printf '\033[1;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

[[ "$(id -u)" -eq 0 ]] || error "Run as root (sudo $0)."
[[ -f "$UNIT_SRC" ]] || error "aven-sync.service not found next to this script."
command -v tailscale >/dev/null || error "Install and log in to Tailscale first: https://tailscale.com/download/linux"
tailscale status >/dev/null 2>&1 || error "Tailscale is installed but not connected. Run: tailscale up"

# --- Resolve the release asset for this architecture ---
case "$(uname -m)" in
  x86_64|amd64) ASSET="aven-linux-amd64" ;;
  aarch64|arm64) ASSET="aven-linux-arm64" ;;
  *) error "Unsupported architecture: $(uname -m). Build from source with cargo." ;;
esac

info "Installing aven ($ASSET)..."
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
BASE="https://github.com/raine/aven/releases/latest/download"
curl -fsSL --retry 3 "$BASE/${ASSET}.tar.gz" -o "$TMP/${ASSET}.tar.gz"
curl -fsSL --retry 3 "$BASE/${ASSET}.sha256" -o "$TMP/${ASSET}.sha256"

# The .sha256 is standard sha256sum output and names the asset itself, so it
# only verifies from within $TMP alongside a file of that exact name.
( cd "$TMP" && sha256sum -c "${ASSET}.sha256" ) \
  || error "Checksum verification failed -- refusing to install."

tar -xzf "$TMP/${ASSET}.tar.gz" -C "$TMP"
install -m 0755 "$(find "$TMP" -type f -name aven -perm -u+x | head -1)" "$BIN"
info "Installed $("$BIN" --version)"

# --- Service account and directories ---
if ! id -u "$AVEN_USER" >/dev/null 2>&1; then
  info "Creating system user '$AVEN_USER'..."
  useradd --system --home-dir "$DATA_DIR" --shell /usr/sbin/nologin "$AVEN_USER"
fi
install -d -o "$AVEN_USER" -g "$AVEN_USER" -m 0750 "$DATA_DIR"
install -d -o root -g "$AVEN_USER" -m 0750 "$CONFIG_DIR"

# --- Auth token: generate once, never rotate on re-run ---
# aven reads sync.auth_token from config.yaml only; there is no env var for it.
if [[ ! -f "$CONFIG_DIR/config.yaml" ]]; then
  TOKEN="$(head -c 32 /dev/urandom | base64 | tr -d '=+/' | cut -c1-40)"
  info "Generating sync auth token..."
  umask 027
  cat > "$CONFIG_DIR/config.yaml" <<EOF
# Managed by nix-darwin/server/aven-sync/install.sh
# The server reads only sync.auth_token; clients need the same value.
sync:
  enabled: false
  server_url: null
  interval_seconds: 30
  auth_token: '$TOKEN'
EOF
  chown root:"$AVEN_USER" "$CONFIG_DIR/config.yaml"
  chmod 0640 "$CONFIG_DIR/config.yaml"
else
  info "Keeping existing $CONFIG_DIR/config.yaml (token unchanged)."
fi

# --- systemd unit ---
info "Installing systemd unit..."
sed "s|--bind 127.0.0.1:3000|--bind 127.0.0.1:${AVEN_PORT}|" \
  "$UNIT_SRC" > /etc/systemd/system/aven-sync.service
systemctl daemon-reload
systemctl enable --now aven-sync.service
systemctl is-active --quiet aven-sync.service \
  || error "aven-sync failed to start. Inspect: journalctl -u aven-sync -n 50"

# --- Expose on the tailnet with TLS ---
# `tailscale serve` terminates TLS using the tailnet cert; aven has none.
info "Exposing on the tailnet via tailscale serve..."
tailscale serve --bg --https=443 "http://127.0.0.1:${AVEN_PORT}" \
  || error "tailscale serve failed. Enable HTTPS certificates and MagicDNS in the Tailscale admin console, then re-run."

# `tailscale status --json` pretty-prints as `"DNSName": "host.tailnet.ts.net."`
# -- the space after the colon matters, and an unmatched grep would abort the
# whole script under `set -o pipefail`.
HOSTNAME_TS="$(tailscale status --json \
  | grep -oE '"DNSName": *"[^"]*"' | head -1 | cut -d'"' -f4 | sed 's/\.$//' || true)"
[[ -n "$HOSTNAME_TS" ]] || HOSTNAME_TS="<your-host>.<your-tailnet>.ts.net"
TOKEN_OUT="$(grep "auth_token:" "$CONFIG_DIR/config.yaml" | sed "s/.*auth_token: *'\(.*\)'/\1/")"

cat <<EOF

$(printf '\033[1;32m==> aven sync server is up\033[0m')

On each client machine, add this to ~/.config/aven/config.yaml
(create it with \`aven config init\` if it does not exist):

sync:
  enabled: true
  server_url: "https://${HOSTNAME_TS}"
  interval_seconds: 30
  auth_token: '${TOKEN_OUT}'

Then verify with:
  aven sync status

Store the token in 1Password -- it is the only credential protecting this server.
EOF
