#!/usr/bin/env bash
# Cloud-init for the GiTF box: mounts the data volume at /var/lib/gitf,
# installs runtime packages + Tailscale + gh, and seeds /etc/gitf/gitf.env.
# The release itself is installed by rel/install-systemd.sh (see the
# runbook) — this script only prepares the host.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Data volume ------------------------------------------------------------
# Wait for the second NVMe device (the /dev/sdf attachment), format on first
# boot only, mount at /var/lib/gitf via fstab.
DATA_DEV=""
for _ in $(seq 1 60); do
  DATA_DEV=$(lsblk -dno NAME,TYPE | awk '$2=="disk" && $1!="nvme0n1" {print "/dev/"$1; exit}')
  [ -n "$DATA_DEV" ] && break
  sleep 2
done

if [ -n "$DATA_DEV" ]; then
  if ! blkid "$DATA_DEV" >/dev/null 2>&1; then
    mkfs.ext4 -L gitf-data "$DATA_DEV"
  fi
  mkdir -p /var/lib/gitf
  if ! grep -q "LABEL=gitf-data" /etc/fstab; then
    echo "LABEL=gitf-data /var/lib/gitf ext4 defaults,nofail 0 2" >>/etc/fstab
  fi
  mount -a
fi

# ---- Packages ---------------------------------------------------------------
apt-get update
apt-get install -y \
  git bubblewrap curl ca-certificates openssl libncurses6 locales unzip jq awscli

locale-gen en_US.UTF-8

# GitHub CLI (official apt repo)
install -dm 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
apt-get update && apt-get install -y gh

# Tailscale (the operator runs `tailscale up` interactively afterwards)
curl -fsSL https://tailscale.com/install.sh | sh

# ---- GiTF env seed ----------------------------------------------------------
mkdir -p /etc/gitf
if [ ! -f /etc/gitf/gitf.env ]; then
  cat >/etc/gitf/gitf.env <<EOF
GITF_PORT=4000
GITF_HOST=127.0.0.1
GITF_SANDBOX_REQUIRED=1
GITF_LOG_STDOUT=1
GITF_LOG_FORMAT=json
GITF_IDLE_STOP_MINUTES=30
GITF_IDLE_STOP_GRACE_MINUTES=15
GITF_BACKUP_BUCKET=${backup_bucket}
EOF
  chmod 0600 /etc/gitf/gitf.env
fi
