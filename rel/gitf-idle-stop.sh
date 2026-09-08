#!/usr/bin/env bash
# Powers the machine off after sustained factory idleness.
#
# Run by gitf-idle-stop.timer (as root). Polls the daemon's liveness endpoint;
# when it has reported idle (no active ghosts, no RUNNING missions — a
# mission holding for a person does not count) continuously for
# GITF_IDLE_STOP_MINUTES, issues `systemctl poweroff`.
# On EC2 with instance_initiated_shutdown_behavior=stop this stops the
# instance, so billing drops to the EBS volume until something starts it
# again (wake Lambda, EventBridge schedule, or the console).
#
# Safety properties:
# - Never fires within GITF_IDLE_STOP_GRACE_MINUTES of boot.
# - An unreachable, down or stalled daemon RESETS the countdown (a crashed
#   or zombie factory is a thing to debug, not to power off and hide).
# - Touch /etc/gitf/idle-stop-disabled to suspend without config edits.
# - $GITF_HOME/idle-stop-override.json (written by GiTF.IdleStop, via MCP)
#   raises the idle threshold until its expiry. Expired or malformed
#   overrides are ignored, so the worst case is the configured default —
#   a bad override can never keep the box up indefinitely.
set -euo pipefail

# Configuration arrives via the unit's EnvironmentFile= (gitf.env/aws.env) —
# run through `systemctl start gitf-idle-stop.service`, not directly.
IDLE_MINUTES="${GITF_IDLE_STOP_MINUTES:-0}"
GRACE_MINUTES="${GITF_IDLE_STOP_GRACE_MINUTES:-15}"
PORT="${GITF_PORT:-4000}"
STATE=/run/gitf-idle-since
OVERRIDE="${GITF_HOME:-/var/lib/gitf}/idle-stop-override.json"

# An unexpired override raises the idle threshold. Every failure mode here
# falls through to the configured default: no file, bad JSON, missing keys,
# unparseable date, past expiry, or no jq. The override can only ever make
# the box MORE patient for a bounded window, never permanently.
apply_override() {
  [[ -f "$OVERRIDE" ]] || return 0
  command -v jq >/dev/null 2>&1 || return 0

  local expires idle expires_epoch now
  expires=$(jq -r '.expires_at // empty' "$OVERRIDE" 2>/dev/null) || return 0
  idle=$(jq -r '.idle_minutes // empty' "$OVERRIDE" 2>/dev/null) || return 0
  [[ -n "$expires" && -n "$idle" ]] || return 0
  [[ "$idle" =~ ^[0-9]+$ ]] || return 0

  expires_epoch=$(date -d "$expires" +%s 2>/dev/null) || return 0
  now=$(date +%s)

  if [[ "$now" -lt "$expires_epoch" ]]; then
    IDLE_MINUTES="$idle"
  else
    # Self-cleaning: an expired override is removed so the state is honest
    # to anyone reading the box rather than lingering as a stale file.
    rm -f "$OVERRIDE"
  fi
}

# Disabled?
[[ "$IDLE_MINUTES" =~ ^[0-9]+$ ]] || exit 0
[[ "$IDLE_MINUTES" -gt 0 ]] || exit 0
[[ -e /etc/gitf/idle-stop-disabled ]] && { rm -f "$STATE"; exit 0; }

# Applied after the disabled checks so an override cannot resurrect a
# deliberately disabled timer, and before the countdown so it changes the
# threshold rather than the elapsed time already accrued.
apply_override

# Boot grace period
uptime_s=$(cut -d. -f1 /proc/uptime)
[[ "$uptime_s" -ge $((GRACE_MINUTES * 60)) ]] || exit 0

body=$(curl -fsS --max-time 10 "http://127.0.0.1:${PORT}/api/v1/health" 2>/dev/null || true)

# Parse the idle flag properly with jq (installed by provisioning); the grep
# fallback keeps hand-installed boxes working but is coupled to the exact
# JSON serialization.
# Idle AND status ok: a stalled (zombie) factory answers 200 with
# status "stalled" and idle false, but the rule is stated here anyway so
# the countdown never depends on how the daemon happens to combine them.
if command -v jq >/dev/null 2>&1; then
  idle=$(jq -r 'if .data.idle == true and .data.status == "ok" then "true" else "false" end' <<<"$body" 2>/dev/null || echo "false")
  held=$(jq -r '.data.held_missions // 0' <<<"$body" 2>/dev/null || echo "?")
else
  idle=$(grep -q '"idle":true' <<<"$body" && grep -q '"status":"ok"' <<<"$body" && echo "true" || echo "false")
  held="?"
fi

if [[ "$idle" != "true" ]]; then
  # Busy, unreachable, down or stalled: reset the countdown.
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
  logger -t gitf-idle-stop "factory idle for $((elapsed / 60))m (held missions: $held) — powering off"
  systemctl poweroff
fi
