# nix-darwin

Declarative macOS system configuration using [nix-darwin](https://github.com/nix-darwin/nix-darwin).

## What it does

- Installs system packages (neovim, git, chezmoi, etc.) and Homebrew casks (1Password, Ghostty, etc.)
- Configures 1Password SSH agent and `~/.ssh/config` for SSH auth
- Sets up `/etc/gitconfig` to rewrite GitLab HTTPS URLs to SSH
- Bootstraps `~/.config/1Password/ssh/agent.toml` for the correct vault
- Configures system preferences (dock, keyboard layouts, Touch ID sudo, etc.)

## Bootstrap a new Mac

Run this on a fresh macOS install:

```sh
curl -fsSL https://raw.githubusercontent.com/ipointer-netrise/nix-darwin/main/bootstrap.sh | bash
```

This will:

1. Install Nix via the [Determinate Systems installer](https://install.determinate.systems/nix)
2. Clone this repo to `/etc/nix-darwin`
3. Run `darwin-rebuild switch` to apply the full system configuration

### After bootstrap

1. Open **1Password → Settings → Developer** → enable **"Use the SSH Agent"**
2. Lock and unlock 1Password
3. Initialize dotfiles:
   ```sh
   chezmoi init --apply git@gitlab.com:netrise/ivan/dotfiles.git
   ```

## Applying changes

After editing `flake.nix`:

```sh
sudo darwin-rebuild switch --flake /etc/nix-darwin#default
```

Or re-run the bootstrap script — it's idempotent and will skip already-completed steps:

```sh
sudo /etc/nix-darwin/bootstrap.sh
```
