#!/usr/bin/env bash
# Installs the GiTF release under systemd on a Linux host.
#
# Usage: sudo rel/install-systemd.sh <release-tarball.tar.gz>
#
# Idempotent: safe to re-run for upgrades (stops the service, replaces
# /opt/gitf, restarts). Creates the gitf user, directories, env file with
# generated secrets, and installs the daemon + idle-stop + backup units.
set -euo pipefail

TARBALL="${1:?usage: install-systemd.sh <release-tarball.tar.gz>}"
HERE="$(cd "$(dirname "$0")" && pwd)"

[[ $EUID -eq 0 ]] || { echo "run as root (sudo)"; exit 1; }

# User + directories. HOME must live on the data volume: the store is under
# $GITF_HOME/.gitf, but ~/.config/gitf (global config, mcp.sock, llm_db)
# resolves via the user's home, so they need to be the same tree.
# The recursive chown of the data volume runs on first install only — on
# upgrades it would walk every sector repo and the whole store.
if ! id -u gitf >/dev/null 2>&1; then
  useradd --system --create-home --home /var/lib/gitf --shell /usr/sbin/nologin gitf
  chown -R gitf:gitf /var/lib/gitf
else
  # Upgrades: repair ownership of the STORE tree only (cheap — no sector
  # repos). An `aws s3 sync` restore run as root leaves root-owned files
  # there; the daemon then reads fine but every flush fails EACCES and
  # the store silently diverges from disk until the next restart eats it.
  chown -R gitf:gitf /var/lib/gitf/.gitf /var/lib/gitf/.config 2>/dev/null || true
fi
mkdir -p /opt/gitf /var/lib/gitf /etc/gitf

# Release payload: unpack to a staging dir, then swap with two renames —
# no second full copy, and the old tree survives as /opt/gitf.old.
if systemctl is-active --quiet gitf; then systemctl stop gitf; fi
rm -rf /opt/gitf.new
mkdir -p /opt/gitf.new
tar xf "$TARBALL" -C /opt/gitf.new
chown -R gitf:gitf /opt/gitf.new
rm -rf /opt/gitf.old
[[ -d /opt/gitf/bin ]] && mv /opt/gitf /opt/gitf.old
rm -rf /opt/gitf
mv /opt/gitf.new /opt/gitf

# Env file + secrets (only fills in what's missing)
if [[ ! -f /etc/gitf/gitf.env ]]; then
  install -m 0600 "$HERE/env.example" /etc/gitf/gitf.env
fi
"$HERE/../bin/gen-secrets" /etc/gitf/gitf.env

# Ubuntu's AppArmor userns restriction (kernel.apparmor_restrict_unprivileged_userns)
# transitions unconfined processes that create user namespaces into a profile that
# denies cap sys_admin — bwrap then dies at "setting up uid map: Permission denied"
# and every sandboxed validation fails. Grant bwrap alone the userns permission
# (the same pattern Ubuntu ships for browsers); the OS restriction stays on for
# everything else. No-op on hosts without AppArmor.
if command -v apparmor_parser >/dev/null 2>&1 && command -v bwrap >/dev/null 2>&1; then
  cat > /etc/apparmor.d/bwrap <<'APPARMOR'
abi <abi/4.0>,
include <tunables/global>
profile bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}
APPARMOR
  apparmor_parser -r /etc/apparmor.d/bwrap || echo "WARN: apparmor bwrap profile failed to load"
fi

# Distributed-Erlang reachability for the live console: on EC2+Tailscale the
# short hostname resolves to IPv6 (tailnet ULA) only, while BEAM distribution
# listens on IPv4 — every local rpc/remote died with :noconnection. Pin the
# primary IPv4.
HOST_IP=$(hostname -I | awk '{print $1}')
HOST_NAME=$(hostname -s)
if [[ -n "$HOST_IP" ]] && ! grep -q "$HOST_IP $HOST_NAME" /etc/hosts; then
  echo "$HOST_IP $HOST_NAME" >> /etc/hosts
fi

# Live console wrapper: `gitf-console` opens a remote IEx shell on the
# running daemon; `gitf-console rpc '<elixir>'` evaluates one expression
# (e.g. `gitf-console rpc 'GiTF.Config.Provider.reload()'` for hot config
# reload — no restart). Tries the env cookie, falls back to the cookie file
# (which is what a node with a broken -setcookie flag actually uses).
cat > /usr/local/bin/gitf-console <<'CONSOLE'
#!/bin/bash
set -euo pipefail
COOKIE=$(grep '^RELEASE_COOKIE=' /etc/gitf/gitf.env 2>/dev/null | cut -d= -f2- | tr -d '"')
FILE_COOKIE=$(cat /var/lib/gitf/.erlang.cookie 2>/dev/null || true)
NODE="gitf@$(hostname -s)"
try() {
  sudo -u gitf env HOME=/var/lib/gitf RELEASE_COOKIE="$1" RELEASE_NODE="$NODE" \
    RELEASE_DISTRIBUTION=sname /opt/gitf/bin/gitf "${@:2}"
}
CMD=${1:-remote}
shift || true
try "${COOKIE:-$FILE_COOKIE}" "$CMD" "$@" 2>/dev/null || try "$FILE_COOKIE" "$CMD" "$@"
CONSOLE
chmod 0755 /usr/local/bin/gitf-console

# Units
install -m 0644 "$HERE/gitf.service" /etc/systemd/system/gitf.service
install -m 0644 "$HERE/gitf-idle-stop.service" /etc/systemd/system/gitf-idle-stop.service
install -m 0644 "$HERE/gitf-idle-stop.timer" /etc/systemd/system/gitf-idle-stop.timer
install -m 0644 "$HERE/gitf-backup.service" /etc/systemd/system/gitf-backup.service
install -m 0644 "$HERE/gitf-backup.timer" /etc/systemd/system/gitf-backup.timer
install -m 0755 "$HERE/gitf-idle-stop.sh" /usr/local/bin/gitf-idle-stop
install -m 0755 "$HERE/gitf-backup.sh" /usr/local/bin/gitf-backup

systemctl daemon-reload
systemctl enable --now gitf
systemctl enable --now gitf-idle-stop.timer
# Backups only make sense with a bucket configured; enable but let the script
# no-op when GITF_BACKUP_BUCKET is unset.
systemctl enable --now gitf-backup.timer

echo
echo "GiTF installed. Check: journalctl -u gitf -f"
echo "API key for 'gitf login': grep GITF_API_KEY /etc/gitf/gitf.env"
