# aven sync server (DigitalOcean + Tailscale)

[aven](https://github.com/raine/aven) sync is **self-hosted only** — there is no
hosted service. This directory provisions a sync server on a DigitalOcean droplet
that is reachable only over Tailscale.

## Design

- aven binds **loopback only** (`127.0.0.1:3000`).
- `tailscale serve` exposes it on the tailnet and **terminates TLS** — aven ships
  no TLS of its own.
- Nothing listens on the public internet. The droplet's only public service is
  SSH, which you can close once Tailscale is up.

> **Why not bind the tailnet address directly?** Tailscale uses 100.64.0.0/10
> (CGNAT), not RFC1918. aven classifies an RFC1918 bind as *private* (needs only
> `sync.auth_token`) but may treat CGNAT as *public*, which additionally demands
> `--unsafe-public-bind` and still leaves you without TLS. Loopback plus
> `tailscale serve` sidesteps both problems.

## Provision

**1. Create the droplet.** Ubuntu 24.04 LTS x64, Basic / Regular,
`s-1vcpu-1gb` ($6/mo: 1 vCPU, 1 GiB RAM, 25 GB SSD). Pick a region near you;
sync payloads are tiny.

Don't drop to the $4 tier to save $2. Its disk is 10 GB, but aven's *default*
attachment quota is 10 GiB (`local.attachment_lifecycle.quota_bytes`) plus
0.5 GiB of previews — you would fill the disk before aven ever enforced its own
quota. 25 GB leaves room for attachments, the OS, and apt upgrades. If you
expect heavy image attachments, size up or lower `quota_bytes` in
`/etc/aven/config.yaml`.

```sh
./provision-droplet.sh
```

`provision-droplet.sh` reads the API token from 1Password at invocation time and
passes it to `doctl` through the environment only. It deliberately does **not**
run `doctl auth init`, which would persist the token in plaintext at
`~/.config/doctl/config.yaml`. The script is idempotent — if the droplet already
exists it prints the IP and exits.

Override any default with an environment variable:

| Variable | Default |
|---|---|
| `OP_TOKEN_REF` | `op://Personal/DigitalOcean - Aven Setup API Token/password` |
| `DROPLET_NAME` | `aven-sync` |
| `DROPLET_SIZE` | `s-1vcpu-1gb` |
| `DROPLET_IMAGE` | `ubuntu-24-04-x64` |
| `DROPLET_REGION` | `nyc3` |
| `SSH_KEY_NAME` | *(unset — uses all registered keys)* |

**Prerequisite: register an SSH key with DigitalOcean first.** Without one, DO
provisions the droplet with an emailed root password instead of key auth, and
the installer can't reach it. Add a public key under *Settings → Security → SSH
Keys* in the console, or re-mint the token with the `ssh_key: create` scope and
use `doctl compute ssh-key import`. To keep a dedicated key in 1Password rather
than reusing a Git key:

```sh
op item create --category 'SSH Key' --title 'Aven Sync Droplet SSH Key' \
  --vault 'SSH Credentials' --ssh-generate-key ed25519
```

**2. Install and connect Tailscale** on the droplet:

```sh
ssh root@<droplet-ip>
curl -fsSL https://tailscale.com/install.sh | sh
tailscale up
```

In the Tailscale admin console, enable **MagicDNS** and **HTTPS Certificates**
(Settings → DNS). `tailscale serve` cannot issue a cert without them.

**3. Run the installer.** Copy this directory to the droplet and run it:

```sh
scp -r server/aven-sync root@<droplet-ip>:/tmp/
ssh root@<droplet-ip> 'bash /tmp/aven-sync/install.sh'
```

It is idempotent — re-run it to upgrade the aven binary or repair the unit. The
auth token is generated once and preserved across re-runs.

The script prints the client config block when it finishes. **Save the auth token
to 1Password** — it is the only credential protecting the server.

**4. Public access is closed automatically.** `install.sh` enables `ufw` with
default-deny inbound, allowing only the `tailscale0` interface and UDP 41641
(direct peer connections; without it Tailscale falls back to DERP relays). After
it runs, port 22 is unreachable from the internet — reach the box over the
tailnet:

```sh
ssh root@aven-sync.<your-tailnet>.ts.net
```

Set `SKIP_FIREWALL=1` to opt out. This is a host firewall rather than a DO cloud
firewall so it needs no extra API token scope; if you lock yourself out, DO's web
recovery console still works.

## Adding another machine

Any device that should sync must be **on the tailnet** — the server is reachable
only there, by design. There is no public endpoint to fall back on.

This repo is public, so the real tailnet hostname and the auth token are not
written here. Both live in the 1Password item **`Aven Sync Auth Token`**
(`Personal` vault): the token in the `password` field, the URL in `server_url`.

### Path A — a Mac managed by this flake

Almost everything is automatic. Run the [bootstrap](../../README.md#bootstrap-a-new-mac),
then:

```sh
tailscale up                                    # interactive browser login
chezmoi init --apply git@gitlab.com:netrise/ivan/dotfiles.git
```

That is the whole client setup. The flake installs aven, Tailscale, and the sync
daemon; chezmoi writes `~/.config/aven/config.yaml` with the token pulled from
1Password. Skip to [Verify](#verify).

> `chezmoi apply` needs `op` signed in (`eval $(op signin)`), or the token
> renders empty and sync silently fails to authenticate.

### Path B — any other machine

For anything not managed by this flake (another Linux box, a work laptop, a
machine you do not control):

**1. Join the tailnet** — the same tailnet, same login identity.
<https://tailscale.com/download>. On iOS/Android use the Tailscale app, then
`aven sync pair` instead of the steps below.

**2. Install aven** — <https://github.com/raine/aven>:

```sh
curl -fsSL https://raw.githubusercontent.com/raine/aven/main/scripts/install | bash
```

**3. Configure sync.** Create the config if absent, then set the `sync:` block.
Read both values out of 1Password — do not copy them from a chat log or a
ticket:

```sh
aven config init      # only if ~/.config/aven/config.yaml does not exist
op read "op://Personal/Aven Sync Auth Token/server_url"
op read "op://Personal/Aven Sync Auth Token/password"
```

```yaml
sync:
  enabled: true
  server_url: "<server_url from 1Password>"
  interval_seconds: 30
  auth_token: '<password from 1Password>'
```

Then `chmod 600 ~/.config/aven/config.yaml` — it now holds a credential.

**4. Install the sync daemon.** Easy to miss, and nothing works on a timer
without it:

```sh
aven daemon install
```

Without the daemon aven syncs *only* when you run `aven sync` by hand;
`interval_seconds` has no effect at all. This is the single most common reason a
new machine looks configured but never actually syncs.

### Verify

```sh
tailscale status | grep aven-sync    # the server should be listed
aven sync                            # expect: complete=true
aven sync status                     # expect: Sync: healthy
aven daemon status                   # expect: Daemon: healthy, running yes
```

`aven sync status` reporting `degraded` immediately after setup usually just
means no sync has run yet — run `aven sync` once and re-check.

To prove it end to end, create a task on one machine and confirm it appears on
another after a sync. Note that checking the **server** is misleading: the
server stores only the change log, so `select count(*) from tasks` on
`/var/lib/aven/db.sqlite` stays at 0 by design. Tasks are materialized
client-side.

## How the client config is managed on flake-managed Macs

`~/.config/aven/config.yaml` is owned by **chezmoi**, not by this repo, at
`dot_config/aven/modify_private_config.yaml.tmpl` in the dotfiles repo. It is a
`modify_` script rather than a static file: aven owns most of that document and
adds keys across releases, so a static file would freeze those defaults and
fight aven on every upgrade. The script enforces only the `sync:` block and
passes everything else through. The token comes from 1Password via
`onepasswordRead`, so it never lands in either repo.

Edit it with `chezmoi edit ~/.config/aven/config.yaml` — a direct edit is
clobbered on the next `chezmoi apply`.

The sync **daemon** is installed declaratively by this flake (`mkAvenDaemon` in
`flake.nix`, run from `postActivation`), so flake-managed Macs get step 4 for
free.

## Seeding the server from an existing machine

The server starts empty. To carry existing tasks over, enable sync on the machine
that already has them **first** and let it push a full cycle before enabling sync
anywhere else. Confirm with `aven sync status` that pending changes reach zero.

## Secrets

Nothing secret is committed to this repo.

| Secret | Where it lives | How it is read |
|---|---|---|
| DigitalOcean API token | 1Password, `Personal` vault | `op read` at invocation; env-only, never on disk |
| aven `sync.auth_token` | Generated on the server into `/etc/aven/config.yaml` (`0640 root:aven`) | Printed once by `install.sh` — save it to 1Password |
| Droplet SSH key | 1Password, `SSH Credentials` vault | 1Password SSH agent |

The aven sync token has to be literal in each client's
`~/.config/aven/config.yaml` — aven reads it only from that file and exposes no
environment variable for it (there is `AVEN_SYNC_SERVER`, but no
`AVEN_SYNC_AUTH_TOKEN`). Keep the canonical copy in 1Password and treat the
client file as a deployed artifact, not the source of truth.

## Operations

```sh
systemctl status aven-sync
journalctl -u aven-sync -f
tailscale serve status
```

Back up the server database the same way as a client — the WAL footgun applies
here too (see the repo root README):

```sh
sqlite3 /var/lib/aven/db.sqlite ".backup '/root/aven-backup.sqlite'"
```
