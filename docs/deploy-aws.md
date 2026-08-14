# Deploying GiTF to AWS

One Graviton EC2 instance, zero inbound ports, Tailscale as the front door,
idle-stop so a quiet factory costs ~$3/month. Companion assets:

- `infra/aws/` — Terraform for everything AWS-side
- `rel/install-systemd.sh` — installs the release on the box
- `.github/workflows/ci.yml` — builds the arm64 release tarball

## Prerequisites

- AWS account + credentials with admin (or equivalent) in the target region.
  The real deployment lives in **GhostInTheFactory-Production (515020252848)**,
  a member account of the purdonmoi org (managed in the
  `purdonmoi-organizations` repo). Local profiles: `gitf` (IAM Identity
  Center, `aws sso login --profile gitf`, role AccountAdmin) or `gitf-prod`
  (OrganizationAccountAccessRole hop from the management account).
- Terraform ≥ 1.10 (S3-native state locking). State lives in
  `s3://gitf-terraform-state-515020252848`.
- A [Tailscale](https://tailscale.com) account (free tier is fine)

## 1. Provision

```sh
cd infra/aws
AWS_PROFILE=gitf terraform init
AWS_PROFILE=gitf terraform apply
```

Creates: a `t4g.small` Ubuntu 24.04 arm64 instance (no inbound security
group, IMDSv2, stop-on-shutdown), a 40 GB gp3 data volume mounted at
`/var/lib/gitf`, an instance role (SSM Session Manager, `/gitf/*` Parameter
Store reads, Bedrock invoke, Route53 DNS-01, backup-bucket access), daily
DLM snapshots of the data volume, a versioned S3 backup bucket, the wake
Lambda, the `ghostinthefactory.com` hosted zone, and a monthly AWS Budget
(default $100, alerts at 50/80/100% to the owner's email — the EC2 side is
capped by design; this watches for LLM spend escaping the factory's caps).

Cloud-init installs git, bubblewrap, gh, awscli, and Tailscale, and writes
the AWS-specific values (the backup bucket name) to `/etc/gitf/aws.env`.
The operator-owned `/etc/gitf/gitf.env` comes from `rel/env.example` when
you run the installer in step 3 — one canonical template; the systemd units
load both files.

## 2. Join the tailnet

```sh
aws ssm start-session --target $(terraform output -raw instance_id)
sudo tailscale up          # prints an auth URL; open it on your phone/laptop
sudo tailscale serve --bg 4000   # HTTPS dashboard at https://<host>.<tailnet>.ts.net
```

### The real domain, still private (deployed 2026-08-14)

`tailscale serve` gives you `https://<host>.<tailnet>.ts.net` with zero
setup (requires enabling Serve/HTTPS once via the URL it prints). The
production setup uses **factory.ghostinthefactory.com** instead — still
without exposing anything. Note: Caddy and `tailscale serve` are mutually
exclusive on :443 — `tailscale serve --https=443 off` before starting
Caddy.

1. Delegate the domain once: terraform created a Route53 hosted zone; set
   the four `terraform output zone_name_servers` values as the NS records
   at the registrar.
2. Publish the dashboard record: after `tailscale up`, re-apply with the
   box's Tailscale IP — `terraform apply -var factory_tailnet_ip=$(tailscale
   ip -4)` creates `factory.ghostinthefactory.com` → 100.x.y.z. Publishing
   a 100.x address is harmless; only your tailnet can route to it.
3. Install Caddy with the route53 DNS module (as root on the box):

   ```sh
   curl -fsSL -o /usr/local/bin/caddy \
     "https://caddyserver.com/api/download?os=linux&arch=arm64&p=github.com%2Fcaddy-dns%2Froute53"
   chmod +x /usr/local/bin/caddy
   useradd --system --home /var/lib/caddy --create-home --shell /usr/sbin/nologin caddy
   ```

   `/etc/caddy/Caddyfile`:

   ```
   factory.ghostinthefactory.com {
       tls {
           dns route53
       }
       reverse_proxy 127.0.0.1:4000
   }
   ```

   The systemd unit MUST set `Environment=HOME=/var/lib/caddy` (Caddy
   stores its certs under `$HOME`; without it the service crash-loops on
   "neither $XDG_CONFIG_HOME nor $HOME are defined") and
   `AmbientCapabilities=CAP_NET_BIND_SERVICE` to bind :443 as non-root.
   The **DNS-01** Let's Encrypt challenge is signed by the instance role
   (the `Dns01Challenge*` IAM statements) — real certificate, zero inbound
   ports, no resident API token anywhere.
4. Set `GITF_CHECK_ORIGIN=https://factory.ghostinthefactory.com` in
   `/etc/gitf/gitf.env` and restart — LiveView rejects websocket
   connections from unlisted origins (comma-separate multiple origins to
   also allow the ts.net name).
5. Re-run `gitf login` with the new URL on client machines. Known issue:
   `gitf login` pings the previously-configured server before storing the
   new URL, so if the old endpoint is dead, edit `[server] url` in
   `~/.config/gitf/config.toml` by hand.

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
or skip keys entirely with Bedrock — the instance role signs those
requests. The production box runs keyless Bedrock (2026-08-14):

```sh
# /etc/gitf/gitf.env
GITF_EXECUTION_MODE=bedrock
```

```toml
# /var/lib/gitf/.config/gitf/config.toml — model tiers as FULL
# inference-profile ARNs. This matters: only `arn:aws:bedrock:...` strings
# route through BedrockDirect (SigV4 via the instance role); an
# `amazon_bedrock:<id>` spec falls through to ReqLLM's model registry,
# which doesn't know Bedrock inference profiles → {:api_error, :not_found}.
[llm.bedrock_models]
thinking = "arn:aws:bedrock:us-east-1:<account>:inference-profile/us.anthropic.claude-sonnet-5"
general  = "arn:aws:bedrock:us-east-1:<account>:inference-profile/us.anthropic.claude-sonnet-5"
fast     = "arn:aws:bedrock:us-east-1:<account>:inference-profile/us.anthropic.claude-haiku-4-5-20251001-v1:0"
```

Find the ARNs with `aws bedrock list-inference-profiles`. Two access gates
to know about (both bit us on day one):

- **Anthropic use-case form**: a new account gets a handful of grace
  invocations, then every Anthropic model returns
  `ResourceNotFoundException: Model use case details have not been
  submitted` account-wide. One-time console form (Bedrock → Model access
  → Anthropic), ~15 min to propagate.
- **Per-model availability**: newest models (e.g. claude-sonnet-5) can
  return `403: not available for this account` until access is granted,
  while older tiers work. Verify with a one-line
  `aws bedrock-runtime converse` from the box before blaming the factory.

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

## Deployment record — what the first real deploy taught us (2026-08-14)

Landmines already defused in code (fixed for releases built after commit
`74f5c19`; older tarballs need the hot-patches described in git history):

- **Phoenix compile-env mismatches** aborted the first release boot —
  `debug_errors`/`code_reloader` set in `runtime.exs` without matching
  compile-time values. Rule: compile-env keys in runtime.exs must match
  `config/prod.exs` exactly.
- **CI's HOME baked into the release** — a module-attribute
  `System.user_home!()` resolved at build time to `/github/home` and
  crashed the MCP listener at boot. Rule: never resolve paths in module
  attributes.
- **Spawn gate silently blocking**: a homedir store without
  `.gitf/config.toml` makes `gitf_dir/0` fail, which Major's preflight
  reports as "degraded (disk)" and NO ghosts ever spawn. The daemon now
  seeds the config on first boot.
- **`gitf mission show` crashed in remote mode** on string timestamps from
  the REST API.

Environment facts that stay true:

- The org's production SCP **denies unencrypted S3 PutObject** — every
  manual `aws s3 cp/sync` into this account needs `--sse AES256` (the
  backup script passes it; remember it for release staging and site
  deploys).
- The org SCP's MFA-deletion guard exempts Identity Center roles
  (`aws:MultiFactorAuthPresent` never exists for SSO sessions — see the
  purdonmoi-organizations README for the full story).
- Ubuntu 24.04 has **no `awscli` apt package** — cloud-init installs AWS
  CLI v2 from the official arm64 zip.
- Instance replacement is safe: the data volume's placement is pinned to
  a subnet, not derived from the instance, so `terraform apply -replace`
  of the instance never touches `/var/lib/gitf`.
- New org member accounts can land on AWS's "free plan" with every billed
  service gated (`NotSignedUp`) — see the purdonmoi-organizations README
  ("Verify service activation") for the probe/fix.

## What this deliberately does not do

- **No public exposure and no second user** until the auth track (GitHub
  SSO, role enforcement) lands — the tailnet is the trust boundary.
- **No Docker on the box** — bubblewrap works on a plain VM and is denied in
  most container runtimes, where the sandbox would degrade. The box sets
  `GITF_SANDBOX_REQUIRED=1` so degraded means refused, not silent.
- **No NAT gateway, no load balancer, no EKS** — each would multiply the bill
  for nothing at this scale.
