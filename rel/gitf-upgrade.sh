#!/usr/bin/env bash
# Installs a newer GiTF release, if one has been published, BEFORE the
# daemon starts.
#
# Run by gitf-upgrade.service (as root, Before=gitf.service). A ministry
# box sleeps to $0 and wakes on demand, so the boot path is a free upgrade
# window: nothing is running, nothing is in flight, and the daemon that
# comes up is the new one. No live restart, no box serving requests
# half-upgraded, and the Cabinet's existing /health poll — which already
# reports `version` — observes the result with no new machinery.
#
# THE ONE RULE: this script must never stop a box from booting. Every
# failure path exits 0 and leaves the version already on disk to start.
# A box that cannot upgrade is a box that needs a look; a box that cannot
# boot is an outage, and an unreachable S3 or a typo'd pointer must not
# be able to cause one across the whole fleet at once.
#
# Artifacts (same private bucket as backups, artifacts/ prefix):
#   artifacts/current                        the version to run, e.g. 0.65.369
#   artifacts/gitf-<version>.tar.gz          the release
#   artifacts/gitf-installer-<version>.tar.gz  rel/ + bin/ (the box has no checkout)
#
# Escape hatches, both of which win over the pointer:
#   /etc/gitf/upgrade-disabled   never upgrade (same shape as idle-stop's)
#   /etc/gitf/pin-version        a version to hold at, e.g. 0.65.360
set -uo pipefail

# Deliberately NOT `set -e`: a failure here must fall through to "boot what
# is on disk", never abort the unit in a way that blocks gitf.service.

log() { logger -t gitf-upgrade "$*"; echo "gitf-upgrade: $*"; }
give_up() { log "$*— booting the installed version"; exit 0; }

[[ -f /etc/gitf/upgrade-disabled ]] && give_up "disabled by /etc/gitf/upgrade-disabled "

BUCKET="${GITF_BACKUP_BUCKET:-}"
[[ -n "$BUCKET" ]] || give_up "no GITF_BACKUP_BUCKET "
command -v aws >/dev/null 2>&1 || give_up "no aws CLI "

# What is installed. start_erl.data is "<erts vsn> <release vsn>" and is
# written by the release itself, so it cannot drift from what will boot.
installed=""
if [[ -f /opt/gitf/releases/start_erl.data ]]; then
  installed=$(awk '{print $2}' /opt/gitf/releases/start_erl.data 2>/dev/null)
fi

# What we want. A pin outranks the pointer — that is the whole point of a
# pin, and it is the brake if a bad release is already published.
if [[ -f /etc/gitf/pin-version ]]; then
  wanted=$(tr -d '[:space:]' < /etc/gitf/pin-version)
  log "pinned to ${wanted}"
else
  wanted=$(aws s3 cp "s3://${BUCKET}/artifacts/current" - 2>/dev/null | tr -d '[:space:]')
fi

[[ -n "$wanted" ]] || give_up "no published version "

# Refuse anything that is not a version. This string is interpolated into
# paths below, and it arrives from outside this box.
[[ "$wanted" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || give_up "bad version '${wanted}' "

if [[ "$wanted" == "$installed" ]]; then
  log "already on ${installed}"
  exit 0
fi

log "installed ${installed:-none}, wanted ${wanted} — upgrading"

work=$(mktemp -d /tmp/gitf-upgrade.XXXXXX) || give_up "no temp dir "
trap 'rm -rf "$work"' EXIT

rel="${work}/gitf-${wanted}.tar.gz"
inst="${work}/installer.tar.gz"

aws s3 cp "s3://${BUCKET}/artifacts/gitf-${wanted}.tar.gz" "$rel" --only-show-errors 2>/dev/null \
  || give_up "release ${wanted} not in the bucket "
aws s3 cp "s3://${BUCKET}/artifacts/gitf-installer-${wanted}.tar.gz" "$inst" --only-show-errors 2>/dev/null \
  || give_up "installer for ${wanted} not in the bucket "

# Both must be readable archives before anything is touched. A truncated
# download that reached the installer would swap /opt/gitf for rubble.
tar tzf "$rel" >/dev/null 2>&1 || give_up "release tarball is not readable "
tar tzf "$inst" >/dev/null 2>&1 || give_up "installer tarball is not readable "

mkdir -p "${work}/inst"
tar xzf "$inst" -C "${work}/inst" 2>/dev/null || give_up "installer would not unpack "
[[ -x "${work}/inst/rel/install-systemd.sh" ]] || give_up "installer has no install-systemd.sh "

# The installer swaps /opt/gitf (keeping the old tree as /opt/gitf.old) and
# reinstalls the units. NO_START matters: we run before gitf.service, so an
# installer that started it would block on a unit systemd has ordered after
# this one — a deadlock ending at TimeoutStartSec with nothing booted.
# Enabled, not started; systemd starts it when this oneshot returns.
if GITF_INSTALL_NO_START=1 "${work}/inst/rel/install-systemd.sh" "$rel" \
     >>/var/log/gitf-upgrade.log 2>&1; then
  now=""
  [[ -f /opt/gitf/releases/start_erl.data ]] && now=$(awk '{print $2}' /opt/gitf/releases/start_erl.data)

  if [[ "$now" == "$wanted" ]]; then
    log "upgraded ${installed:-none} -> ${wanted}"
  else
    # Exit 0 regardless: the installer leaves a working tree either way,
    # and refusing to boot over a version mismatch helps nobody.
    log "installer succeeded but the tree reports '${now}', wanted ${wanted}"
  fi
else
  log "install of ${wanted} FAILED (see /var/log/gitf-upgrade.log) "
fi

exit 0
