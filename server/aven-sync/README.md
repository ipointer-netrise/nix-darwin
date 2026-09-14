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

**1. Create the droplet.** Ubuntu 24.04 LTS, Basic / Regular, 1 GB RAM — the
smallest tier is ample for a Rust binary and a SQLite file. Pick a region near
you; sync is chatty but tiny.

```sh
doctl auth init                     # once, with a DO API token from 1Password
doctl compute droplet create aven-sync \
  --image ubuntu-24-04-x64 \
  --size s-1vcpu-1gb \
  --region nyc3 \
  --ssh-keys "$(doctl compute ssh-key list --format ID --no-header | head -1)" \
  --wait
doctl compute droplet list aven-sync
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
