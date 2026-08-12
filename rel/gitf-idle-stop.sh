#!/usr/bin/env bash
# Powers the machine off after sustained factory idleness.
#
# Run by gitf-idle-stop.timer (as root). Polls the daemon's liveness endpoint;
# when it has reported idle (no active ghosts, no non-terminal missions)
# continuously for GITF_IDLE_STOP_MINUTES, issues `systemctl poweroff`.
# On EC2 with instance_initiated_shutdown_behavior=stop this stops the
# instance, so billing drops to the EBS volume until something starts it
# again (wake Lambda, EventBridge schedule, or the console).
#
# Safety properties:
# - Never fires within GITF_IDLE_STOP_GRACE_MINUTES of boot.
# - An unreachable or unhealthy daemon RESETS the countdown (a crashed
#   factory is a thing to debug, not to power off and hide).
# - Touch /etc/gitf/idle-stop-disabled to suspend without config edits.
set -euo pipefail

ENV_FILE=/etc/gitf/gitf.env
[[ -f $ENV_FILE ]] && set -a && . "$ENV_FILE" && set +a

IDLE_MINUTES="${GITF_IDLE_STOP_MINUTES:-0}"
GRACE_MINUTES="${GITF_IDLE_STOP_GRACE_MINUTES:-15}"
PORT="${GITF_PORT:-4000}"
STATE=/run/gitf-idle-since

# Disabled?
[[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || exit 0
[[ "$IDLE_MINUTES" -gt 0 ]] || exit 0
[[ -e /etc/gitf/idle-stop-disabled ]] && { rm -f "$STATE"; exit 0; }

# Boot grace period
uptime_s=$(cut -d. -f1 /proc/uptime)
[[ "$uptime_s" -ge $((GRACE_MINUTES * 60)) ]] || exit 0

body=$(curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/v1/health" 2>/dev/null || true)

if ! grep -q '"idle":true' <<<"$body"; then
  # Busy, unreachable, or unhealthy: reset the countdown.
  rm -f "$STATE"
  exit 0
fi

now=$(date +%s)
if [[ ! -f $STATE ]]; then
  echo "$now" >"$STATE"
  exit 0
fi

idle_since=$(cat "$STATE")
elapsed=$((now - idle_since))

if [[ $elapsed -ge $((IDLE_MINUTES * 60)) ]]; then
  logger -t gitf-idle-stop "factory idle for $((elapsed / 60))m — powering off"
  systemctl poweroff
fi
