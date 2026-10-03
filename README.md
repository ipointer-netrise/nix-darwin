# nix-darwin

Declarative macOS system configuration using [nix-darwin](https://github.com/nix-darwin/nix-darwin).

## What it does

- Installs system packages (neovim, git, chezmoi, etc.) and Homebrew casks (1Password, Ghostty, etc.)
- Configures 1Password SSH agent and `~/.ssh/config` for SSH auth
- Sets up `/etc/gitconfig` to rewrite GitLab HTTPS URLs to SSH
- Bootstraps `~/.config/1Password/ssh/agent.toml` for the correct vault
- Configures system preferences (dock, keyboard layouts, Touch ID sudo, etc.)
- Installs CLI tooling through Nix where available (including Hermes Agent), plus Homebrew taps
  (e.g. `aven`), npm, and official user-level installers; harnesses retain their built-in update paths
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

### Pinned npm tarballs

One `npmGlobals` entry pins against a locally packed tarball under
`~/.local/share/npm-packages/` rather than npm's registry, because it is not published:
the private Jev hook. That tarball is a build artifact and no repo carries it, so a fresh
machine has to rebuild it before the first switch will install the package. Activation
warns and leaves the entry alone when the tarball is missing, so a `darwin-rebuild switch`
is safe in the meantime.

```sh
git clone git@github-personal:ivanpointer/graft-jev.git ~/Source/graft-jev
cd ~/Source/graft-jev && npm ci && npm run check
npm pack --pack-destination ~/.local/share/npm-packages
mv ~/.local/share/npm-packages/ivanpointer-graft-jev-0.1.0.tgz \
   ~/.local/share/npm-packages/ivanpointer-graft-jev-0.1.0-ed99762.tgz
```

The commit in the filename is the pin token. Repacking under the same name is a no-op on
switch, so bump the filename in `flake.nix` whenever the source commit moves. The clone
needs the `github-personal` SSH alias: plain `github.com` resolves to the work account,
which cannot see the repo.

### Graft

Graft is **not** an npm global. It is built from source by the `graft` package in
`flake.nix`, pinned by the `graft-src` flake input to a commit of the `ivanpointer/Graft`
dogfood fork, and installed into `environment.systemPackages`. Nothing has to be packed by
hand, and a fresh machine gets it from the first switch.

```sh
nix build /etc/nix-darwin#graft     # just the package, no system rebuild
nix flake lock --update-input graft-src   # after moving the pin in flake.nix
```

Building from source rather than packing a tarball is load-bearing, not a preference.
`buildNpmPackage` installs from graft's committed `package-lock.json`; `npm install` of a
packed tarball ignores the lockfile inside it and re-resolves every semver range. Graft
depends on `tree-sitter-wasm@^1.1.6`, and 1.1.6 is the only release in that range that
carries the Terraform and HCL grammars -- upstream dropped them in 1.1.8 and restored them
in 2.0. Re-resolved, the range lands on 1.1.8 and every `.tf` file is skipped in silence.

Three paths depend on where the package lands, and all three move together when the pin
moves, because the store path changes:

| Path | Who uses it |
| --- | --- |
| `/run/current-system/sw/bin/graft` | `scripts/graft-refresh.sh`, the raw binary |
| `/usr/local/bin/graft` | harness MCP configs; a symlink activation maintains |
| `/usr/local/share/graft/module` | `graft-refresh.sh`'s crux-patch check; `dist/claude` under it is what the Claude statusline shim, `graft-usage` and chezmoi's skill refresh import |

`~/.local/bin/graft` (chezmoi) stays the entrypoint for interactive shells and agent
harnesses -- it loads `~/.config/graft/environment` first, which the raw binary does not.

## Applying changes

After editing `flake.nix`:

```sh
sudo darwin-rebuild switch --flake /etc/nix-darwin#default
```

Or re-run the bootstrap script — it's idempotent and will skip already-completed steps:

```sh
sudo /etc/nix-darwin/bootstrap.sh
```
