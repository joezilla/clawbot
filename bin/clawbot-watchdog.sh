#!/usr/bin/env bash
# clawbot-watchdog.sh — secondary scheduled task that detects a dead tick and recovers it.
# Fires on its own schedule (every 10 min via the ai.clawbot.watchdog LaunchAgent).
# Compares the lastCronFire heartbeat in state.json against current time; if stale > 10 min
# while status==running, notifies the human and kicks/re-bootstraps the tick LaunchAgent.

set -euo pipefail

# launchd starts agents with a minimal PATH that omits Homebrew and the user's local bin.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ACTIVE_FILE="$INSTALL_DIR/etc/active-project"
NOTIFY="$SCRIPT_DIR/clawbot-notify.sh"
TICK_SCRIPT="$SCRIPT_DIR/clawbot-tick.sh"
TICK_PLIST="$HOME/Library/LaunchAgents/ai.clawbot.tick.plist"
TICK_LABEL="ai.clawbot.tick"

WATCHDOG_THRESHOLD_MIN=10

if [[ ! -f "$ACTIVE_FILE" ]]; then
  exit 0  # nothing to watch
fi

PROJECT_DIR="$(head -n1 "$ACTIVE_FILE")"
STATE_FILE="$PROJECT_DIR/memory/bmad-dev-state.json"
ACTIVITY_LOG="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-activity.log"

if [[ ! -f "$STATE_FILE" ]]; then
  exit 0
fi

STATUS="$(jq -r '.status' "$STATE_FILE")"
if [[ "$STATUS" != "running" ]]; then
  exit 0  # paused / stopped / halted — no watchdog work
fi

LAST_FIRE="$(jq -r '.cronHealth.lastCronFire // empty' "$STATE_FILE")"
if [[ -z "$LAST_FIRE" || "$LAST_FIRE" == "null" ]]; then
  exit 0  # not yet initialized
fi

# Convert both timestamps to epoch seconds. `date -j -f` is the macOS form.
NOW_EPOCH="$(date -u +%s)"
LAST_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_FIRE" +%s 2>/dev/null || echo 0)"

if [[ "$LAST_EPOCH" -eq 0 ]]; then
  exit 0  # couldn't parse — bail silently
fi

ELAPSED_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))

if [[ "$ELAPSED_MIN" -le "$WATCHDOG_THRESHOLD_MIN" ]]; then
  exit 0  # healthy
fi

# Stale → recover. If the tick LaunchAgent isn't loaded, bootstrap it; otherwise
# force a fire with launchctl kickstart. (Activity-log tag stays CRON_RECOV for
# grep continuity with older logs.)
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
RECOV_ACTION="kickstart"
if ! launchctl print "gui/$(id -u)/${TICK_LABEL}" >/dev/null 2>&1; then
  if [[ -f "$TICK_PLIST" ]]; then
    launchctl bootstrap "gui/$(id -u)" "$TICK_PLIST" 2>/dev/null || true
    RECOV_ACTION="bootstrap"
  else
    RECOV_ACTION="plist-missing"
  fi
else
  launchctl kickstart "gui/$(id -u)/${TICK_LABEL}" 2>/dev/null || true
fi
printf '%s | CRON_RECOV | downtime:%dmin | action:watchdog-%s\n' "$TS" "$ELAPSED_MIN" "$RECOV_ACTION" >> "$ACTIVITY_LOG"

# Mark tick health as recovered in state.
TMP="$(mktemp)"
jq --arg ts "$TS" '.cronHealth.cronStatus = "recovered" | .cronHealth.lastSkipReason = null | .lastUpdated = $ts' "$STATE_FILE" > "$TMP"
mv "$TMP" "$STATE_FILE"

"$NOTIFY" "[TICK-DEAD]" "Tick hasn't fired in ${ELAPSED_MIN} min. Recovery: ${RECOV_ACTION}."
