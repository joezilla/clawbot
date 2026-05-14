#!/usr/bin/env bash
# clawbot-tick.sh — per-fire driver of the Claw Loop.
# Invoked every 3 minutes by the ai.clawot.tick LaunchAgent (StartInterval=180).
# Captures pane, reads state, applies cheap shell guards (kill-switch + quality
# gates), then hands off to `claude -p` with lib/procedure.md as the system
# prompt. The headless Claude does all the heavy lifting via tool calls (Bash
# for tmux, Read/Write for state, etc.)
#
# Must run as a user LaunchAgent loaded into gui/$(id -u) so `claude -p` can
# read its OAuth token from the macOS login keychain. cron jobs run outside
# the GUI session and will get "Please run /login" instead.

set -euo pipefail

# launchd starts agents with a minimal PATH that omits Homebrew and the user's
# local bin, so flock/tmux/claude resolve to "command not found". Prepend them here.
export PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:$PATH"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ACTIVE_FILE="$INSTALL_DIR/etc/active-project"
PROCEDURE_FILE="$INSTALL_DIR/lib/procedure.md"
NOTIFY="$SCRIPT_DIR/clawbot-notify.sh"

CLAWBOT_SOCKET="$HOME/.clawbot/clawdbot.sock"
CLAWBOT_SESSION="bmad-agent"
export CLAWBOT_SOCKET CLAWBOT_SESSION

# --- Lockfile: prevent overlapping ticks ---
LOCK="/tmp/clawbot-tick.lock"
exec 9>"$LOCK"
if ! flock -n 9; then
  echo "Already running"
  exit 0  # another tick is running — silently skip
fi

[[ -f "$ACTIVE_FILE" ]] || { echo "No active project" >&2; exit 0; }
PROJECT_DIR="$(head -n1 "$ACTIVE_FILE")"

STATE_FILE="$PROJECT_DIR/memory/bmad-dev-state.json"
ACTIVITY_LOG="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-activity.log"
MODEL_STRATEGY="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml"

[[ -f "$STATE_FILE" ]] || { echo "State file missing at $STATE_FILE" >&2; exit 0; }
[[ -f "$PROCEDURE_FILE" ]] || { echo "Procedure file missing at $PROCEDURE_FILE" >&2; exit 0; }

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_event() {
  printf '%s | %s\n' "$(ts)" "$1" >> "$ACTIVITY_LOG"
}

# Atomically mutate state.json with a jq filter.
state_mutate() {
  local expr="$1"; shift
  local tmp; tmp="$(mktemp)"
  jq "$@" "$expr | .lastUpdated = \"$(ts)\"" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

# --- Always-write heartbeat (clawbot.md §Step 0a) ---
state_mutate '
  .cronHealth.lastCronFire = $ts |
  .cronHealth.consecutiveFires += 1 |
  .cronHealth.cronStatus = "healthy"
' --arg ts "$(ts)"

# --- Cheap kill-switch (Gate, pre-LLM) ---
STATUS="$(jq -r '.status' "$STATE_FILE")"
case "$STATUS" in
  paused|halted|stopped|human-review-needed)
    log_event "CRON_SKIP | reason:status=$STATUS"
    exit 0
    ;;
esac

# --- Max-plan rate-limit gate (pre-LLM) ---
# When status=rate-limited, sleep silently until rateLimit.resumeAt has passed,
# then flip back to running and let this fire continue normally. Avoids burning
# claude -p calls during the cooldown window.
if [[ "$STATUS" == "rate-limited" ]]; then
  RESUME_AT="$(jq -r '.rateLimit.resumeAt // empty' "$STATE_FILE")"
  if [[ -z "$RESUME_AT" || "$RESUME_AT" == "null" ]]; then
    # No resume time → treat as paused; human must clear-rate-limit manually.
    log_event "CRON_SKIP | reason:rate-limited(no-resume-at)"
    exit 0
  fi
  NOW_EPOCH="$(date -u +%s)"
  RESUME_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$RESUME_AT" +%s 2>/dev/null || echo 0)"
  if [[ "$RESUME_EPOCH" -eq 0 ]]; then
    log_event "CRON_SKIP | reason:rate-limited(unparseable resumeAt=$RESUME_AT)"
    exit 0
  fi
  if [[ "$NOW_EPOCH" -lt "$RESUME_EPOCH" ]]; then
    REMAINING_MIN=$(( (RESUME_EPOCH - NOW_EPOCH) / 60 ))
    log_event "CRON_SKIP | reason:rate-limited | remaining_min:$REMAINING_MIN | resumeAt:$RESUME_AT"
    exit 0
  fi
  # Cooldown elapsed — flip back to running and let the rest of the fire proceed.
  HIT_COUNT="$(jq -r '.rateLimit.hitCount // 0' "$STATE_FILE")"
  state_mutate '
    .status = "running" |
    .rateLimit.lastResumedAt = $ts |
    .rateLimit.resumeAt = null |
    .stallCount = 0
  ' --arg ts "$(ts)"
  log_event "RATE_LIMIT_RESUMED | resumeAt:$RESUME_AT | hitCount:$HIT_COUNT"
  "$NOTIFY" "[RATE-LIMIT-RESUMED]" "Max plan window expired ($RESUME_AT). Loop resuming."
  STATUS="running"
fi

# --- Smart-skip (clawbot.md §Step 0b) ---
CURRENT_STEP="$(jq -r '.currentStepType // .currentStep' "$STATE_FILE")"
LAST_ACTION_AT="$(jq -r '.lastActionAt // empty' "$STATE_FILE")"
if [[ -n "$LAST_ACTION_AT" && "$LAST_ACTION_AT" != "null" ]]; then
  LAST_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$LAST_ACTION_AT" +%s 2>/dev/null || echo 0)"
  NOW_EPOCH="$(date -u +%s)"
  ELAPSED_MIN=$(( (NOW_EPOCH - LAST_EPOCH) / 60 ))
  SKIP_REASON=""
  case "$CURRENT_STEP" in
    dev-story)            [[ $ELAPSED_MIN -lt 5 ]] && SKIP_REASON="smart-skip(dev<5min)" ;;
    code-review)          [[ $ELAPSED_MIN -lt 4 ]] && SKIP_REASON="smart-skip(review<4min)" ;;
    create-story)         [[ $ELAPSED_MIN -lt 2 ]] && SKIP_REASON="smart-skip(create<2min)" ;;
    epic-review)          [[ $ELAPSED_MIN -lt 4 ]] && SKIP_REASON="smart-skip(epic-review<4min)" ;;
    epic-remediation)     [[ $ELAPSED_MIN -lt 5 ]] && SKIP_REASON="smart-skip(epic-remediation<5min)" ;;
  esac
  if [[ -n "$SKIP_REASON" ]]; then
    log_event "CRON_SKIP | step:$CURRENT_STEP | reason:$SKIP_REASON"
    state_mutate '.metrics.totalCronSkips += 1 | .cronHealth.lastSkipReason = $r' --arg r "$SKIP_REASON"
    exit 0
  fi
fi

# --- Quality gate guards: enforce in shell, regardless of LLM decisions ---
PENDING_AUTOFIX="$(jq '[.epicReview.findings[]? | select(.auto_fix == true and .status == "pending")] | length' "$STATE_FILE")"
PASS_NUM="$(jq '.epicReview.passNumber // 0' "$STATE_FILE")"

# Gate 2: if findings are pending and step somehow drifted away from epic-* steps, snap back.
if [[ "$PENDING_AUTOFIX" -gt 0 && "$PASS_NUM" -le 3 ]]; then
  case "$CURRENT_STEP" in
    epic-review|epic-remediation)
      ;;  # OK — gate is in progress
    *)
      log_event "QUALITY_GATE_CORRECTION | gate:2 | corrected_from:$CURRENT_STEP | corrected_to:epic-remediation | pending:$PENDING_AUTOFIX"
      state_mutate '.currentStep = "epic-remediation" | .currentStepType = "epic-remediation"'
      "$NOTIFY" "[QUALITY-GATE-CORRECTION]" "Snapped step back to epic-remediation ($PENDING_AUTOFIX pending fixes)."
      CURRENT_STEP="epic-remediation"
      ;;
  esac
fi

# --- Capture pane ---
if ! tmux -S "$CLAWBOT_SOCKET" has-session -t "$CLAWBOT_SESSION" 2>/dev/null; then
  log_event "CRON_FIRE | error:tmux-session-missing"
  "$NOTIFY" "[TICK-ERROR]" "Tmux session $CLAWBOT_SESSION not found on socket. Run clawbot-setup.sh."
  exit 1
fi

PANE="$(tmux -S "$CLAWBOT_SOCKET" capture-pane -p -J -t "${CLAWBOT_SESSION}:0.0" -S -50 2>/dev/null || true)"

# --- Compose user prompt for headless Claude ---
STATE_JSON="$(cat "$STATE_FILE")"
USER_PROMPT="TICK FIRE at $(ts).

STATE_FILE_PATH: $STATE_FILE
ACTIVITY_LOG: $ACTIVITY_LOG
MODEL_STRATEGY: $MODEL_STRATEGY
TMUX_SOCKET: $CLAWBOT_SOCKET
TMUX_SESSION: $CLAWBOT_SESSION
NOTIFIER: $NOTIFY
PROJECT_DIR: $PROJECT_DIR

Captured pane (last 50 lines):
<pane>
$PANE
</pane>

Current state:
<state>
$STATE_JSON
</state>

Execute the tick procedure end-to-end. Update the state file before exiting. Call \$NOTIFIER before exiting. If you ran the Epic Review Gate, ensure you logged EPIC_REVIEW_START/FINDINGS/REMEDIATION/DONE entries as appropriate.
"

# --- Hand off to headless Claude ---
log_event "CRON_FIRE | step:$CURRENT_STEP | invoking-claude-p"

claude_log="$PROJECT_DIR/_bmad-output/implementation-artifacts/clawbot.log"
SYSTEM_PROMPT="$(cat "$PROCEDURE_FILE")"

# claude -p reads stdin or arg; we use --append-system-prompt for the procedure.
# Allowed tools are kept tight: Bash for tmux/curl/notifier, Read/Write/Edit for state/files.
set +e
echo "=== $(ts) — claude -p invocation ===" >> "$claude_log"
claude -p \
  --append-system-prompt "$SYSTEM_PROMPT" \
  --allowed-tools "Bash,Read,Write,Edit" \
  --permission-mode bypassPermissions \
  --output-format text \
  "$USER_PROMPT" </dev/null >> "$claude_log" 2>&1
RC=$?
set -e

if [[ $RC -ne 0 ]]; then
  log_event "CRON_FIRE | error:claude-exit-$RC"
  "$NOTIFY" "[TICK-ERROR]" "claude -p exited $RC. See $claude_log."
fi

state_mutate '.metrics.totalCronFires += 1 | .metrics.currentStoryCronFires += 1'

exit 0
