#!/usr/bin/env bash
# clawbot-watchdog.sh — secondary cron that detects a dead tick cron and recovers it.
# Fires on a separate schedule (default every 10 min). Compares the lastCronFire
# heartbeat in state.json against current time; if stale > 10 min while status==running,
# notifies the human and re-registers the tick crontab entry.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ACTIVE_FILE="$INSTALL_DIR/etc/active-project"
NOTIFY="$SCRIPT_DIR/clawbot-notify.sh"
TICK_SCRIPT="$SCRIPT_DIR/clawbot-tick.sh"

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

# Stale → recover.
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s | CRON_RECOV | downtime:%dmin | action:watchdog-recreated-cron\n' "$TS" "$ELAPSED_MIN" >> "$ACTIVITY_LOG"

# Re-register the tick crontab entry if it's missing.
CRON_LINE="*/3 * * * * $TICK_SCRIPT >> $PROJECT_DIR/_bmad-output/implementation-artifacts/clawbot.log 2>&1"
CURRENT_CRONTAB="$(crontab -l 2>/dev/null || true)"
if ! grep -Fq "$TICK_SCRIPT" <<<"$CURRENT_CRONTAB"; then
  ( echo "$CURRENT_CRONTAB"; echo "$CRON_LINE" ) | crontab -
fi

# Mark cron as recovered in state.
TMP="$(mktemp)"
jq --arg ts "$TS" '.cronHealth.cronStatus = "recovered" | .cronHealth.lastSkipReason = null | .lastUpdated = $ts' "$STATE_FILE" > "$TMP"
mv "$TMP" "$STATE_FILE"

"$NOTIFY" "[CRON-DEAD]" "Tick cron hasn't fired in ${ELAPSED_MIN} min. Re-registered crontab entry."
