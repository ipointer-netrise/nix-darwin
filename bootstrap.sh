#!/usr/bin/env bash
set -euo pipefail

REPO_URL="https://github.com/ipointer-netrise/nix-darwin.git"
FLAKE_DIR="/etc/nix-darwin"
DARWIN_CONFIG="Ivans-MacBook-Pro-2"

info() { printf '\033[1;34m==> %s\033[0m\n' "$1"; }
error() { printf '\033[1;31mError: %s\033[0m\n' "$1" >&2; exit 1; }

# --- Preflight checks ---
[[ "$(uname)" == "Darwin" ]] || error "This script only runs on macOS."

# --- Install Nix via Determinate Systems installer ---
if ! command -v nix &>/dev/null; then
  info "Installing Nix (Determinate Systems installer)..."
  curl --proto '=https' --tlsv1.2 -sSf -L \
    https://install.determinate.systems/nix | sh -s -- install
  # Source nix in current shell
  if [[ -f /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh ]]; then
    . /nix/var/nix/profiles/default/etc/profile.d/nix-daemon.sh
  fi
else
  info "Nix already installed."
fi

# Verify nix is available
command -v nix &>/dev/null || error "Nix installation failed or is not in PATH. Open a new terminal and re-run."

# --- Clone the nix-darwin config ---
if [[ -d "${FLAKE_DIR}/.git" ]]; then
  info "nix-darwin repo already cloned at ${FLAKE_DIR}."
else
  info "Cloning nix-darwin config to ${FLAKE_DIR}..."
  sudo mkdir -p "${FLAKE_DIR}"
  sudo chown "$(whoami):staff" "${FLAKE_DIR}"
  git clone "${REPO_URL}" "${FLAKE_DIR}"
fi

# --- Run nix-darwin switch ---
info "Running initial darwin-rebuild switch (this may take a while)..."
nix run nix-darwin -- switch --flake "${FLAKE_DIR}#${DARWIN_CONFIG}"

info "Done! Next steps:"
echo "  1. Open 1Password → Settings → Developer → enable 'Use the SSH Agent'"
echo "  2. Lock and unlock 1Password"
echo "  3. Run: chezmoi init --apply git@gitlab.com:netrise/ivan/dotfiles.git"
