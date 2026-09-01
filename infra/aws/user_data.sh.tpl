#!/usr/bin/env bash
# Cloud-init for the GiTF box: mounts the data volume at /var/lib/gitf,
# installs runtime packages + Tailscale + gh, and seeds /etc/gitf/gitf.env.
# The release itself is installed by rel/install-systemd.sh (see the
# runbook) — this script only prepares the host.
set -euxo pipefail

export DEBIAN_FRONTEND=noninteractive

# ---- Data volume ------------------------------------------------------------
# Wait for the non-root disk (the /dev/sdf attachment; NVMe enumeration order
# is not guaranteed, so identify the root disk via the mounted rootfs rather
# than assuming it is nvme0n1). Format on first boot only, mount via fstab.
ROOT_DISK=$(lsblk -no PKNAME "$(findmnt -no SOURCE /)" | head -1)
DATA_DEV=""
for _ in $(seq 1 60); do
  DATA_DEV=$(lsblk -dno NAME,TYPE | awk -v root="$ROOT_DISK" \
    '$2=="disk" && $1!=root {print "/dev/"$1; exit}')
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

# ---- Swap -------------------------------------------------------------------
# The BEAM under ghost load spiked past physical RAM on the first real
# mission (OOM-killed 56x on t4g.small). Swap turns future spikes into
# slowdowns instead of SIGKILLs.
if ! grep -q swapfile /etc/fstab; then
  fallocate -l 4G /swapfile  # debug Tauri builds on 4 GiB RAM need it
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo "/swapfile none swap sw 0 0" >>/etc/fstab
fi

# ---- Packages ---------------------------------------------------------------
apt-get update
# NB: no `awscli` here — Ubuntu 24.04 dropped the apt package; the official
# v2 installer below replaces it.
apt-get install -y \
  git bubblewrap curl ca-certificates openssl libncurses6 locales unzip jq

locale-gen en_US.UTF-8

# AWS CLI v2 (official arm64 installer; idempotent via --update)
curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-aarch64.zip" -o /tmp/awscliv2.zip
unzip -qo /tmp/awscliv2.zip -d /tmp
/tmp/aws/install --update
rm -rf /tmp/aws /tmp/awscliv2.zip

# Runtime-verification probe deps (priv/probes/cora): the app is BUILT and
# DRIVEN under Xvfb + tauri-driver/WebKitWebDriver during validation. These
# lived only on the root volume and were lost in the 2026-09-01 instance
# replacement — cloud-init owns them now. (tauri-driver + cargo live in
# /var/lib/gitf/.cargo on the data volume.)
apt-get install -y xvfb webkit2gtk-driver sqlite3 build-essential pkg-config \
  libssl-dev libwebkit2gtk-4.1-dev libgtk-3-dev libayatana-appindicator3-dev \
  librsvg2-dev libxdo-dev file

# GitHub CLI (official apt repo)
install -dm 0755 /etc/apt/keyrings
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=arm64 signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  >/etc/apt/sources.list.d/github-cli.list
apt-get update && apt-get install -y gh

# Node.js (nodesource LTS) — sector validation_commands routinely need
# npm/npx (typecheck, builds, future playwright probes)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# Tailscale (the operator runs `tailscale up` interactively afterwards)
curl -fsSL https://tailscale.com/install.sh | sh

# ---- GiTF host overrides ----------------------------------------------------
# AWS-provisioned values only. The operator-owned /etc/gitf/gitf.env comes
# from rel/env.example via install-systemd.sh — one canonical template, so
# defaults can't diverge between cloud-init and the installer. Every gitf
# systemd unit loads both files (EnvironmentFile=).
mkdir -p /etc/gitf
cat >/etc/gitf/aws.env <<EOF
GITF_BACKUP_BUCKET=${backup_bucket}
EOF
chmod 0600 /etc/gitf/aws.env
