#!/usr/bin/env bash
# Syncs the GiTF store and configs to S3. Run by gitf-backup.timer (as root).
#
# The bucket (GITF_BACKUP_BUCKET in /etc/gitf/gitf.env) is versioned, so this
# deliberately does NOT pass --delete: point-in-time recovery comes from
# bucket versioning + the daily EBS snapshot, not from sync semantics.
# Credentials come from the instance IAM role — nothing to configure here.
set -euo pipefail

ENV_FILE=/etc/gitf/gitf.env
[[ -f $ENV_FILE ]] && set -a && . "$ENV_FILE" && set +a

BUCKET="${GITF_BACKUP_BUCKET:-}"
[[ -n "$BUCKET" ]] || exit 0

GITF_HOME="${GITF_HOME:-/var/lib/gitf}"
HOST_PREFIX="s3://${BUCKET}/$(hostname)"

aws s3 sync "${GITF_HOME}/.gitf/store" "${HOST_PREFIX}/store" --only-show-errors

# Global config dir holds config.toml (keys redacted? no — may hold provider
# keys) — keep it in the same private bucket; exclude the socket and pidfile.
if [[ -d "${GITF_HOME}/.config/gitf" ]]; then
  aws s3 sync "${GITF_HOME}/.config/gitf" "${HOST_PREFIX}/config" \
    --exclude "mcp.sock*" --exclude "llm_db/*" --only-show-errors
fi

logger -t gitf-backup "store synced to ${HOST_PREFIX}"
