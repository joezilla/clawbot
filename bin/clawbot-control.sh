#!/usr/bin/env bash
# clawbot-control.sh — human-facing control surface for the Claw Loop.
# All operations mutate state.json directly via jq — no LLM call.
#
# Subcommands:
#   status                Print current story/step/queue
#   pause                 Set status=paused (tick.sh exits early)
#   resume                Set status=running
#   stop                  Set status=stopped, kill tmux session
#   skip                  Advance currentStory to next in queue, log SKIP
#   quarantine <story>    Move <story> to quarantinedStories, advance
#   unquarantine <story>  Remove <story> from quarantinedStories
#   force-advance         Override quality gate and advance to next story (USE WITH CAUTION)
#   findings              Print last epic-review findings file path
#   clear-rate-limit      Force-clear a rate-limited status (resume immediately)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
ACTIVE_FILE="$INSTALL_DIR/etc/active-project"

if [[ ! -f "$ACTIVE_FILE" ]]; then
  echo "No active project registered. Run clawbot-setup.sh first." >&2
  exit 3
fi

PROJECT_DIR="$(head -n1 "$ACTIVE_FILE")"
STATE_FILE="$PROJECT_DIR/memory/bmad-dev-state.json"
ACTIVITY_LOG="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-activity.log"
SOCKET="$HOME/.clawbot/clawdbot.sock"
SESSION="bmad-agent"

if [[ ! -f "$STATE_FILE" ]]; then
  echo "State file not found at $STATE_FILE" >&2
  exit 4
fi

if ! command -v jq >/dev/null 2>&1; then
  echo "jq is required. Install with: brew install jq" >&2
  exit 5
fi

ts() { date -u +%Y-%m-%dT%H:%M:%SZ; }

log_event() {
  local event="$1"
  printf '%s | %s\n' "$(ts)" "$event" >> "$ACTIVITY_LOG"
}

# Edit state.json atomically: read, jq-transform, write to temp, mv into place.
# First arg is the jq filter; remaining args (e.g. --arg foo "bar") are passed through to jq.
state_edit() {
  local jq_expr="$1"
  shift
  local tmp
  tmp="$(mktemp)"
  jq "$@" "$jq_expr | .lastUpdated = \"$(ts)\"" "$STATE_FILE" > "$tmp"
  mv "$tmp" "$STATE_FILE"
}

cmd="${1:-status}"
shift || true

case "$cmd" in
  status)
    jq -r '
      "Status:        " + .status,
      "Current step:  " + .currentStep,
      "Current story: " + (.currentStoryNumber // "?") + " (" + (.currentStory // "?") + ")",
      "Current epic:  " + (.currentEpic | tostring),
      "Stories done:  " + (.totalStoriesCompleted | tostring) + " / " + (.storyQueue | length | tostring),
      "Epics done:    " + (.totalEpicsCompleted | tostring),
      "Escalation:    " + .escalationMode,
      "Last cron:     " + .cronHealth.lastCronFire,
      "Cron status:   " + .cronHealth.cronStatus,
      "Epic review:   " + ((.epicReview.findings | length) | tostring) + " findings, pass " + (.epicReview.passNumber | tostring) + "/3"
    ' "$STATE_FILE"
    if [[ "$(jq -r '.status' "$STATE_FILE")" == "rate-limited" ]]; then
      RESUME_AT="$(jq -r '.rateLimit.resumeAt // "?"' "$STATE_FILE")"
      DETECTED_AT="$(jq -r '.rateLimit.detectedAt // "?"' "$STATE_FILE")"
      HITS="$(jq -r '.rateLimit.hitCount // 0' "$STATE_FILE")"
      if [[ "$RESUME_AT" != "?" && "$RESUME_AT" != "null" ]]; then
        RESUME_EPOCH="$(date -u -j -f "%Y-%m-%dT%H:%M:%SZ" "$RESUME_AT" +%s 2>/dev/null || echo 0)"
        NOW_EPOCH="$(date -u +%s)"
        if [[ "$RESUME_EPOCH" -gt 0 ]]; then
          REMAINING_MIN=$(( (RESUME_EPOCH - NOW_EPOCH) / 60 ))
          if [[ "$REMAINING_MIN" -gt 0 ]]; then
            echo "Rate limit:    detected $DETECTED_AT, resumes $RESUME_AT (~${REMAINING_MIN}m remaining), hits=$HITS"
          else
            echo "Rate limit:    detected $DETECTED_AT, resumes $RESUME_AT (window elapsed, next cron will flip back to running), hits=$HITS"
          fi
        fi
      fi
    fi
    ;;

  pause)
    state_edit '.status = "paused"'
    log_event "HUMAN_CMD | command:pause"
    echo "Loop paused."
    ;;

  resume)
    state_edit '.status = "running"'
    log_event "HUMAN_CMD | command:resume"
    echo "Loop resumed."
    ;;

  stop)
    state_edit '.status = "stopped"'
    log_event "HUMAN_CMD | command:stop"
    if tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null; then
      tmux -S "$SOCKET" kill-session -t "$SESSION"
      echo "Tmux session killed."
    fi
    echo "Loop stopped."
    ;;

  skip)
    current="$(jq -r '.currentStory' "$STATE_FILE")"
    state_edit '
      .completedStories += [.currentStory] |
      .currentStory = (.storyQueue | map(select(. != $cur)) | .[0] // null) |
      .currentStep = "create-story" |
      .currentStoryFilePath = null |
      .reviewPassNumber = 1 |
      .failureCount = 0
    ' --arg cur "$current"
    log_event "HUMAN_CMD | command:skip | story:$current"
    echo "Skipped $current."
    ;;

  quarantine)
    target="${1:?Usage: quarantine <story-key>}"
    state_edit "
      .quarantinedStories += [\"$target\"] |
      .storyQueue = (.storyQueue | map(select(. != \"$target\")))
    "
    log_event "QUARANTINE | story:$target | reason:human-command"
    echo "Quarantined $target."
    ;;

  unquarantine)
    target="${1:?Usage: unquarantine <story-key>}"
    state_edit "
      .quarantinedStories = (.quarantinedStories | map(select(. != \"$target\"))) |
      .storyQueue += [\"$target\"]
    "
    log_event "HUMAN_CMD | command:unquarantine | story:$target"
    echo "Unquarantined $target."
    ;;

  force-advance)
    current="$(jq -r '.currentStory' "$STATE_FILE")"
    state_edit '
      .completedStories += [.currentStory] |
      .currentStory = (.storyQueue | map(select(. != $cur)) | .[0] // null) |
      .currentStep = "create-story" |
      .currentStoryFilePath = null |
      .reviewPassNumber = 1 |
      .failureCount = 0 |
      .totalStoriesCompleted += 1
    ' --arg cur "$current"
    log_event "HUMAN_CMD | command:force-advance | story:$current"
    echo "Force-advanced past $current. Use with care."
    ;;

  findings)
    findings_file="$(jq -r '.epicReview.lastFindingsFile // "none"' "$STATE_FILE")"
    echo "Last findings file: $findings_file"
    if [[ "$findings_file" != "none" && -f "$findings_file" ]]; then
      echo "---"
      cat "$findings_file"
    fi
    ;;

  clear-rate-limit)
    cur_status="$(jq -r '.status' "$STATE_FILE")"
    if [[ "$cur_status" != "rate-limited" ]]; then
      echo "Status is '$cur_status', not 'rate-limited' — nothing to clear." >&2
      exit 0
    fi
    state_edit '
      .status = "running" |
      .rateLimit.lastResumedAt = $ts |
      .rateLimit.resumeAt = null |
      .stallCount = 0
    ' --arg ts "$(ts)"
    log_event "HUMAN_CMD | command:clear-rate-limit"
    echo "Rate limit cleared. Next cron fire (~3min) will resume the loop."
    ;;

  *)
    echo "Unknown command: $cmd" >&2
    echo "Usage: $0 {status|pause|resume|stop|skip|quarantine <story>|unquarantine <story>|force-advance|findings|clear-rate-limit}" >&2
    exit 1
    ;;
esac
