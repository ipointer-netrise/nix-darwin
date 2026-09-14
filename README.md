# nix-darwin

Declarative macOS system configuration using [nix-darwin](https://github.com/nix-darwin/nix-darwin).

## What it does

- Installs system packages (neovim, git, chezmoi, etc.) and Homebrew casks (1Password, Ghostty, etc.)
- Configures 1Password SSH agent and `~/.ssh/config` for SSH auth
- Sets up `/etc/gitconfig` to rewrite GitLab HTTPS URLs to SSH
- Bootstraps `~/.config/1Password/ssh/agent.toml` for the correct vault
- Configures system preferences (dock, keyboard layouts, Touch ID sudo, etc.)
- Installs CLI tooling that isn't in nixpkgs via Homebrew taps (e.g. `aven`) and via
  npm/uv activation scripts (see `npmGlobals` / `uvTools` in `flake.nix`)
- Installs the `aven` coding-agent skill for Claude Code, OpenCode, Codex, Pi, and
  Hermes (the first four via `aven skill install`; Hermes by mirroring the generated
  file, since aven's installer doesn't know about it).
  antigravity-cli (`agy`) needs no entry of its own: it discovers skills from
  `~/.claude/skills` (verified with `fs_usage` -- it also probes `~/.agents/skills`
  and `~/.copilot/skills`), so it picks up the Claude Code copy already.
- Runs the Tailscale daemon (`services.tailscale.enable`); `tailscale up` still needs
  one interactive login per machine

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
4. Restore any data listed under [Data this repo does *not* carry](#data-this-repo-does-not-carry)

## Data this repo does not carry

`darwin-rebuild` reproduces *tools and configuration*, not *state*. These have to be
moved by hand when migrating to a new machine.

### aven tasks

Every task, note, and attachment lives in one local SQLite database. There is no hosted
sync service — sync is self-hosted only — so nothing leaves the machine on its own.
For continuous multi-device sync, see [`server/aven-sync/`](server/aven-sync/), which
provisions a Tailscale-only sync server on a DigitalOcean droplet.

**Footgun:** most of the data is usually sitting in the write-ahead log
(`db.sqlite-wal`), not in `db.sqlite`. Copying `db.sqlite` alone will silently lose
almost everything. Use SQLite's `.backup`, which checkpoints the WAL into one
consistent file:

```sh
# On the old machine
sqlite3 ~/.local/state/aven/db.sqlite ".backup '$HOME/aven-backup.sqlite'"

# On the new machine, after bootstrap and after quitting any aven TUI/daemon
mkdir -p ~/.local/state/aven
cp ~/aven-backup.sqlite ~/.local/state/aven/db.sqlite
aven doctor   # confirms schema version and task count
```

Also copy `~/.config/aven/config.yaml` if it exists (it is only created once you run
`aven config init` or set a value; defaults are used otherwise).

### firecrawl secrets

`~/.local/share/firecrawl/.env` is bootstrapped with placeholders on a fresh machine.
Re-set `BULL_AUTH_KEY` and `OPENAI_API_KEY` from 1Password.

## Applying changes

After editing `flake.nix`:

```sh
sudo darwin-rebuild switch --flake /etc/nix-darwin#default
```

Or re-run the bootstrap script — it's idempotent and will skip already-completed steps:

```sh
sudo /etc/nix-darwin/bootstrap.sh
```
