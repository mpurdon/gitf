# Deploying GiTF to AWS

One Graviton EC2 instance, zero inbound ports, Tailscale as the front door,
idle-stop so a quiet factory costs ~$3/month. Companion assets:

- `infra/aws/` — Terraform for everything AWS-side
- `rel/install-systemd.sh` — installs the release on the box
- `.github/workflows/ci.yml` — builds the arm64 release tarball

## Prerequisites

- AWS account + credentials with admin (or equivalent) in the target region
- Terraform ≥ 1.5
- A [Tailscale](https://tailscale.com) account (free tier is fine)

## 1. Provision

```sh
cd infra/aws
terraform init
terraform apply
```

Creates: a `t4g.small` Ubuntu 24.04 arm64 instance (no inbound security
group, IMDSv2, stop-on-shutdown), a 40 GB gp3 data volume mounted at
`/var/lib/gitf`, an instance role (SSM Session Manager, `/gitf/*` Parameter
Store reads, Bedrock invoke, backup-bucket access), daily DLM snapshots of
the data volume, a versioned S3 backup bucket, and the wake Lambda.

Cloud-init installs git, bubblewrap, gh, awscli, and Tailscale, and seeds
`/etc/gitf/gitf.env` with the operational defaults (`GITF_SANDBOX_REQUIRED=1`,
JSON logs, idle-stop settings, the backup bucket name).

## 2. Join the tailnet

```sh
aws ssm start-session --target $(terraform output -raw instance_id)
sudo tailscale up          # prints an auth URL; open it on your phone/laptop
sudo tailscale serve --bg 4000   # HTTPS dashboard at https://<host>.<tailnet>.ts.net
```

### Optional: the real domain, still private

`tailscale serve` gives you `https://<host>.<tailnet>.ts.net` with zero
setup. To use **ghostinthefactory.com** instead — still without exposing
anything:

1. Publish a public DNS A record `factory.ghostinthefactory.com` → the
   box's Tailscale IP (`tailscale ip -4`). Publishing a 100.x address is
   harmless; only your tailnet can route to it.
2. Run Caddy on the box with a **DNS-01** Let's Encrypt challenge (needs an
   API token for your DNS provider) — real certificate, zero inbound ports.
3. Set `GITF_CHECK_ORIGIN=https://factory.ghostinthefactory.com` in
   `/etc/gitf/gitf.env` and restart.

Do this before creating the GitHub OAuth app for SSO, so the callback URL
(`https://factory.ghostinthefactory.com/auth/callback`) never churns.

## 3. Install the release

Grab `gitf-release-arm64` from the latest `main` CI run (or build locally in
the Dockerfile's builder image), then on the box:

```sh
# from your machine, e.g. via the backup bucket:
aws s3 cp gitf-*.tar.gz s3://$(terraform output -raw backup_bucket)/artifacts/

# on the box (SSM session):
cd /tmp && aws s3 cp s3://<bucket>/artifacts/gitf-<version>.tar.gz .
git clone https://github.com/mpurdon/gitf && cd gitf   # for rel/ scripts, or scp them
sudo rel/install-systemd.sh /tmp/gitf-<version>.tar.gz
journalctl -u gitf -f      # JSON logs should be flowing
```

The installer creates the `gitf` user with `HOME=/var/lib/gitf` (so the
store, `~/.config/gitf`, and sector repos all live on the data volume),
generates missing secrets into `/etc/gitf/gitf.env` (mode 0600), and
enables three units: `gitf`, `gitf-idle-stop.timer`, `gitf-backup.timer`.

Provider keys: put `GEMINI_API_KEY` (and friends) in `/etc/gitf/gitf.env`,
or skip keys entirely for Anthropic models by putting `bedrock` in the
provider priority — the instance role signs those requests.

## 4. Authenticate the CLI from your machine

```sh
gitf login https://<host>.<tailnet>.ts.net \
  --key "$(aws ssm start-session ... 'grep GITF_API_KEY /etc/gitf/gitf.env')"
```

(Or just read the key during an SSM session and paste it at the prompt.)

## 5. Verify the cheapness loop

```sh
curl https://<host>.<tailnet>.ts.net/api/v1/health        # "idle":true when quiet
sudo systemctl start gitf-idle-stop.service               # dry-run the check
# after GITF_IDLE_STOP_MINUTES of idleness the box powers off (= EC2 "stopped")
curl "$(terraform output -raw wake_url)"                  # starts it again (~60s to ready)
```

- Pause idle-stop without config edits: `sudo touch /etc/gitf/idle-stop-disabled`
- Backups: hourly `aws s3 sync` of the store (`gitf-backup.timer`) +
  daily EBS snapshots. Restore = new volume from snapshot, or
  `aws s3 sync` back into `/var/lib/gitf/.gitf/store`.

## 6. Alerting to your phone

Approval requests (critical), ghost stalls (high), and budget events reach
you through two channels; enable either or both in the **gitf user's**
`~/.config/gitf/config.toml` on the box:

```toml
[observability]
# Any URL that accepts a JSON POST (ntfy.sh topic, Slack webhook, ...)
webhook_url = "https://ntfy.sh/<your-private-topic>"

[plugins.channels.telegram]
token = "<bot token from @BotFather>"
chat_id = "<your chat id>"
```

Telegram sends critical/high alerts immediately (lower severities are
batched into digests) and also accepts commands (`/ghost list`,
`/mission show <id>`). Set `[server] url` to your dashboard URL
(e.g. `https://factory.ghostinthefactory.com`) and approval alerts carry a
deep link to `/dashboard/approvals`.

This is what makes idle-stop trustworthy: the box can sleep because
anything needing you pings your phone first.

## Webhooks (optional, off by default here)

A zero-inbound box can't receive GitHub webhooks. Either poll, or expose
*only* the webhook route publicly:

```sh
sudo tailscale funnel --bg --set-path /api/v1/webhooks 4000
```

and set `GITF_GITHUB_WEBHOOK_SECRET` (HMAC is verified). Do not funnel the
root path — the dashboard has no authentication yet.

## Upgrades

CI builds the tarball on every `main` push. Re-run
`sudo rel/install-systemd.sh <new-tarball>` — it stops the service, swaps
`/opt/gitf`, and restarts. State lives on the data volume, untouched.

## Costs (us-east-1, on-demand, Aug 2026)

| Scenario | ≈ monthly |
|---|---|
| Stopped (EBS + snapshots only) | $3 |
| t4g.small always-on | $18 |
| t4g.medium at ~8 h/day (idle-stop) | $12 |
| t4g.medium always-on | $31 |

LLM spend (capped by `[costs] daily_budget_usd`, default $100/day) dominates
all of these.

## What this deliberately does not do

- **No public exposure and no second user** until the auth track (GitHub
  SSO, role enforcement) lands — the tailnet is the trust boundary.
- **No Docker on the box** — bubblewrap works on a plain VM and is denied in
  most container runtimes, where the sandbox would degrade. The box sets
  `GITF_SANDBOX_REQUIRED=1` so degraded means refused, not silent.
- **No NAT gateway, no load balancer, no EKS** — each would multiply the bill
  for nothing at this scale.
