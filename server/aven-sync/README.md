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

**4. Lock down SSH (optional but recommended).** Once Tailscale works, add a DO
cloud firewall that drops public inbound except what you need, and reach the box
over the tailnet instead.

## Client setup

On each Mac (Tailscale is already installed by the flake via
`services.tailscale.enable`; run `tailscale up` once to log in):

```sh
aven config init      # only if ~/.config/aven/config.yaml does not exist yet
```

Then set the `sync:` block to the values the installer printed:

```yaml
sync:
  enabled: true
  server_url: "https://aven-sync.<your-tailnet>.ts.net"
  interval_seconds: 30
  auth_token: '<token from 1Password>'
```

Verify:

```sh
aven sync status
aven doctor      # the Sync section should show enabled / server configured
```

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
