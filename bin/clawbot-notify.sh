#!/usr/bin/env bash
# clawbot-notify.sh — local notifier for the Claw Loop.
# Usage: clawbot-notify.sh <STATUS> <MESSAGE>
# Status is a bracketed tag like [WORKING], [TRANSITION], [DONE], [STALL],
# [NEEDS-HUMAN], [HALTED], [TICK-ERROR], [EPIC-DEFERRED], [EPIC-UNRESOLVED],
# [QUALITY-GATE-VIOLATION], [QUALITY-GATE-CORRECTION], [CRON-DEAD], [UNKNOWN-PROMPT].
#
# Reads the active project path from etc/active-project (relative to the
# orchestrator install dir) to know where to append the messages log.
# [WORKING] is log-only; everything else also triggers an osascript banner.

set -euo pipefail

if [[ $# -lt 2 ]]; then
  echo "Usage: $0 <STATUS> <MESSAGE>" >&2
  exit 2
fi

STATUS="$1"
shift
MESSAGE="$*"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ACTIVE_FILE="$INSTALL_DIR/etc/active-project"

if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "[clawbot-notify] No active project registered at $ACTIVE_FILE" >&2
  exit 3
fi

PROJECT_DIR="$(head -n1 "$ACTIVE_FILE")"
LOG_DIR="$PROJECT_DIR/_bmad-output/implementation-artifacts"
MSG_LOG="$LOG_DIR/clawbot-messages.log"

mkdir -p "$LOG_DIR"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf '%s | %s | %s\n' "$TS" "$STATUS" "$MESSAGE" >> "$MSG_LOG"

case "$STATUS" in
  '[WORKING]')
    # Log-only — banners every 3 min would be spam.
    ;;
  *)
    if command -v osascript >/dev/null 2>&1; then
      # Escape double-quotes for AppleScript string literal.
      ESCAPED_MSG="${MESSAGE//\"/\\\"}"
      ESCAPED_STATUS="${STATUS//\"/\\\"}"
      osascript -e "display notification \"$ESCAPED_MSG\" with title \"Claw Loop — $ESCAPED_STATUS\"" >/dev/null 2>&1 || true
    fi
    ;;
esac
