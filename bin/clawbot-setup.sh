#!/usr/bin/env bash
# clawbot-setup.sh — one-time bootstrap for the Claw Loop.
# Usage: clawbot-setup.sh <absolute-bmad-project-path>
#
# Verifies deps, validates the BMAD project, creates the tmux session, seeds
# state/procedure/model-strategy files, installs and bootstraps the tick +
# watchdog LaunchAgents into gui/$(id -u), and prints the read-only tmux
# attach command. The pre-sprint model strategy is written in safe
# "all-highest" mode by default — edit the YAML to refine before the first
# tick fires if you want a different strategy.
#
# The agents must run as user LaunchAgents (not cron) so `claude -p` can read
# its OAuth token from the macOS login keychain.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$INSTALL_DIR/lib"
ETC_DIR="$INSTALL_DIR/etc"
TICK_SCRIPT="$SCRIPT_DIR/clawbot-tick.sh"
WATCHDOG_SCRIPT="$SCRIPT_DIR/clawbot-watchdog.sh"

CLAWBOT_SOCKET="$HOME/.clawbot/clawdbot.sock"
CLAWBOT_SESSION="bmad-agent"

die() { echo "ERROR: $*" >&2; exit 1; }
info() { echo "==> $*"; }

# --- 1. Verify args & deps ---
[[ $# -eq 1 ]] || die "Usage: $0 <absolute-bmad-project-path>"
PROJECT_DIR="$1"
[[ "$PROJECT_DIR" = /* ]] || die "Project path must be absolute. Got: $PROJECT_DIR"
[[ -d "$PROJECT_DIR" ]] || die "Project directory not found: $PROJECT_DIR"

for dep in claude tmux jq yq osascript flock; do
  command -v "$dep" >/dev/null 2>&1 || die "Missing dependency: $dep (install via brew)"
done

# --- 2. Validate BMAD project ---
SPRINT_STATUS="$PROJECT_DIR/_bmad-output/implementation-artifacts/sprint-status.yaml"
[[ -f "$SPRINT_STATUS" ]] || die "BMAD sprint-status.yaml not found at $SPRINT_STATUS. Run /bmad-sprint-planning first."

info "Project validated: $PROJECT_DIR"

# --- 3. Prompt for escalation mode ---
echo "Escalation mode controls how the loop handles stalls:"
echo "  autonomous   — handle Tier 1-3 automatically, pause only on Tier 4"
echo "  conservative — pause on any stall beyond Tier 1"
echo "  aggressive   — handle everything, skip stuck stories after 5 failures"
read -rp "Escalation mode [autonomous]: " ESCALATION
ESCALATION="${ESCALATION:-autonomous}"
case "$ESCALATION" in
  autonomous|conservative|aggressive) ;;
  *) die "Invalid escalation mode: $ESCALATION" ;;
esac

# --- 4. Create tmux session ---
mkdir -p "$(dirname "$CLAWBOT_SOCKET")"
if ! tmux -S "$CLAWBOT_SOCKET" has-session -t "$CLAWBOT_SESSION" 2>/dev/null; then
  info "Creating tmux session '$CLAWBOT_SESSION'..."
  tmux -S "$CLAWBOT_SOCKET" new-session -d -s "$CLAWBOT_SESSION" -c "$PROJECT_DIR"
  tmux -S "$CLAWBOT_SOCKET" send-keys -t "${CLAWBOT_SESSION}:0.0" 'claude'
  tmux -S "$CLAWBOT_SOCKET" send-keys -t "${CLAWBOT_SESSION}:0.0" Enter
  info "Waiting 10s for Claude Code to start..."
  sleep 10
else
  info "tmux session '$CLAWBOT_SESSION' already exists, reusing it."
fi

# --- 5. Copy procedure.md into the project ---
mkdir -p "$PROJECT_DIR/memory"
cp "$LIB_DIR/procedure.md" "$PROJECT_DIR/memory/claw-loop-procedure.md"
info "Procedure copied to $PROJECT_DIR/memory/claw-loop-procedure.md"

# --- 6. Render state.json from template ---
STATE_FILE="$PROJECT_DIR/memory/bmad-dev-state.json"
TS="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Parse sprint-status.yaml: extract story keys matching N-N-name (skip epic-N and *-retrospective).
# Order: epic-1's stories, then epic-2's, etc.
STORY_KEYS_JSON="$(
  yq -o=json '.' "$SPRINT_STATUS" \
    | jq -r '
        [
          .[] | objects |
          (keys_unsorted[]) as $k |
          select($k | test("^[0-9]+-[0-9]+-")) |
          select($k | test("retrospective$") | not) |
          $k
        ]
      ' 2>/dev/null || echo '[]'
)"

# Fallback: if the parse above produced nothing, try a flatter grep approach.
if [[ "$(echo "$STORY_KEYS_JSON" | jq 'length')" -eq 0 ]]; then
  # Grep keys like "  1-1-foo:" from the yaml file directly.
  STORY_KEYS_JSON="$(
    grep -E '^\s+[0-9]+-[0-9]+-[^:]+:' "$SPRINT_STATUS" \
      | grep -v 'retrospective' \
      | sed -E 's/^[[:space:]]+([^:]+):.*/\1/' \
      | jq -R . | jq -s .
  )"
fi

# Parse all story statuses from sprint-status.yaml so we can resume at the
# first non-done story instead of always restarting at story 1.1.
STORY_STATUS_JSON="$(
  grep -E '^\s+[0-9]+-[0-9]+-[^:]+:\s*[a-z-]+\s*$' "$SPRINT_STATUS" \
    | grep -v 'retrospective' \
    | sed -E 's/^[[:space:]]+([^:]+):[[:space:]]+([a-z-]+)[[:space:]]*$/\1 \2/' \
    | jq -R 'split(" ") | {(.[0]): .[1]}' \
    | jq -s 'add // {}'
)"

# First story whose status is NOT "done" (preserves storyQueue order from yaml).
FIRST_STORY="$(echo "$STORY_KEYS_JSON" | jq -r --argjson statuses "$STORY_STATUS_JSON" '
  map(select(($statuses[.] // "backlog") != "done"))[0] // .[0] // ""
')"
[[ -n "$FIRST_STORY" ]] || die "Could not parse any stories from sprint-status.yaml. Inspect $SPRINT_STATUS."

# Completed stories — preserve original sprint order.
COMPLETED_STORIES_JSON="$(echo "$STORY_KEYS_JSON" | jq --argjson statuses "$STORY_STATUS_JSON" '
  map(select(($statuses[.] // "backlog") == "done"))
')"

# Story number e.g. "1-1-foo-bar" -> "1.1"
FIRST_STORY_NUMBER="$(echo "$FIRST_STORY" | awk -F- '{print $1"."$2}')"
FIRST_EPIC="$(echo "$FIRST_STORY" | awk -F- '{print $1}')"

# Stories within first epic
EPIC_STORIES_JSON="$(echo "$STORY_KEYS_JSON" | jq --arg ep "$FIRST_EPIC-" '[.[] | select(startswith($ep))]')"

# Render state.json
jq -n \
  --slurpfile tmpl "$LIB_DIR/state.template.json" \
  --arg ts "$TS" \
  --arg first_story "$FIRST_STORY" \
  --arg first_num "$FIRST_STORY_NUMBER" \
  --argjson first_epic "$FIRST_EPIC" \
  --argjson queue "$STORY_KEYS_JSON" \
  --argjson epic_stories "$EPIC_STORIES_JSON" \
  --argjson completed "$COMPLETED_STORIES_JSON" \
  --arg escalation "$ESCALATION" \
  --arg msf "_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml" \
  --arg alf "_bmad-output/implementation-artifacts/claw-loop-activity.log" '
    $tmpl[0]
    | .currentStory = $first_story
    | .currentStoryNumber = $first_num
    | .currentEpic = $first_epic
    | .storyQueue = $queue
    | .currentEpicStories = $epic_stories
    | .completedStories = $completed
    | .totalStoriesCompleted = ($completed | length)
    | .lastUpdated = $ts
    | .lastActionAt = $ts
    | .sessionStartedAt = $ts
    | .escalationMode = $escalation
    | .modelStrategy.modelStrategyFile = $msf
    | .metrics.currentStoryStartedAt = $ts
    | .metrics.sprintStartedAt = $ts
    | .metrics.activityLogFile = $alf
    | .cronHealth.lastCronFire = $ts
  ' > "$STATE_FILE"
info "State file written: $STATE_FILE ($(echo "$STORY_KEYS_JSON" | jq 'length') stories queued)"

# --- 7. Write a safe "all-highest" model strategy ---
MODEL_STRATEGY="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml"
if [[ ! -f "$MODEL_STRATEGY" ]]; then
  cat > "$MODEL_STRATEGY" <<'YAML'
# Generated by clawbot-setup.sh — safe defaults.
# Edit epic_overrides / story_overrides to tune per-step model choice.
# Re-run pre-sprint model analysis manually if you want CC to classify epics.

model_tier_mapping:
  highest: opus
  standard: sonnet

step_defaults:
  create_story: highest
  code_review: highest
  dev_story: highest    # safe default — override per epic to use 'standard' for simple work

epic_overrides: {}
story_overrides: {}
YAML
  info "Model strategy seeded with safe defaults at $MODEL_STRATEGY"
else
  info "Model strategy already present, leaving as-is."
fi

# --- 8. Write activity log header ---
ACTIVITY_LOG="$PROJECT_DIR/_bmad-output/implementation-artifacts/claw-loop-activity.log"
PROJECT_NAME="$(basename "$PROJECT_DIR")"
TOTAL_STORIES="$(echo "$STORY_KEYS_JSON" | jq 'length')"

if [[ ! -f "$ACTIVITY_LOG" ]]; then
  cat > "$ACTIVITY_LOG" <<EOF
# ============================================================
# CLAW LOOP ACTIVITY LOG
# ============================================================
# Generated by: clawbot-setup.sh
# Project: $PROJECT_NAME
# Started: $TS
# Sprint: $TOTAL_STORIES stories
# ============================================================
EOF
  info "Activity log header written."
fi

# --- 9. Register active-project + LaunchAgents ---
mkdir -p "$ETC_DIR"
echo "$PROJECT_DIR" > "$ETC_DIR/active-project"

LAUNCHAGENTS_DIR="$HOME/Library/LaunchAgents"
TICK_LABEL="ai.clawbot.tick"
WATCHDOG_LABEL="ai.clawbot.watchdog"
TICK_PLIST="$LAUNCHAGENTS_DIR/${TICK_LABEL}.plist"
WATCHDOG_PLIST="$LAUNCHAGENTS_DIR/${WATCHDOG_LABEL}.plist"
LOG_PATH="$PROJECT_DIR/_bmad-output/implementation-artifacts/clawbot.log"
LAUNCHD_PATH="/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"

mkdir -p "$LAUNCHAGENTS_DIR"

write_plist() {
  local out="$1" label="$2" program="$3" interval="$4"
  cat > "$out" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
  <dict>
    <key>Label</key>
    <string>${label}</string>
    <key>ProgramArguments</key>
    <array>
      <string>${program}</string>
    </array>
    <key>StartInterval</key>
    <integer>${interval}</integer>
    <key>RunAtLoad</key>
    <false/>
    <key>StandardOutPath</key>
    <string>${LOG_PATH}</string>
    <key>StandardErrorPath</key>
    <string>${LOG_PATH}</string>
    <key>EnvironmentVariables</key>
    <dict>
      <key>HOME</key>
      <string>${HOME}</string>
      <key>PATH</key>
      <string>${LAUNCHD_PATH}</string>
    </dict>
  </dict>
</plist>
PLIST
  plutil -lint "$out" >/dev/null || die "Generated plist failed plutil -lint: $out"
}

reload_agent() {
  local label="$1" plist="$2"
  if launchctl print "gui/$(id -u)/${label}" >/dev/null 2>&1; then
    launchctl bootout "gui/$(id -u)/${label}" 2>/dev/null || true
  fi
  launchctl bootstrap "gui/$(id -u)" "$plist"
}

write_plist "$TICK_PLIST" "$TICK_LABEL" "$TICK_SCRIPT" 180
write_plist "$WATCHDOG_PLIST" "$WATCHDOG_LABEL" "$WATCHDOG_SCRIPT" 600
reload_agent "$TICK_LABEL" "$TICK_PLIST"
reload_agent "$WATCHDOG_LABEL" "$WATCHDOG_PLIST"
info "LaunchAgents installed and bootstrapped: $TICK_LABEL (180s), $WATCHDOG_LABEL (600s)"

# Migration: clean up legacy crontab entries if they exist.
CURRENT_CRONTAB="$(crontab -l 2>/dev/null || true)"
if grep -Fq -e "$TICK_SCRIPT" -e "$WATCHDOG_SCRIPT" <<<"$CURRENT_CRONTAB"; then
  REMAINING="$(grep -Fv -e "$TICK_SCRIPT" -e "$WATCHDOG_SCRIPT" <<<"$CURRENT_CRONTAB" || true)"
  if [[ -z "$REMAINING" ]]; then
    crontab -r 2>/dev/null || true
  else
    echo "$REMAINING" | crontab -
  fi
  info "Removed legacy crontab entries for clawbot-tick / clawbot-watchdog."
fi

# --- 10. Final report ---
cat <<EOF

================================================================
Claw Loop bootstrapped for project: $PROJECT_NAME
================================================================
State file:      $STATE_FILE
Activity log:    $ACTIVITY_LOG
Model strategy:  $MODEL_STRATEGY
Procedure:       $PROJECT_DIR/memory/claw-loop-procedure.md
Active-project:  $ETC_DIR/active-project

LaunchAgents:
  tick:     $TICK_PLIST          (StartInterval 180s)
  watchdog: $WATCHDOG_PLIST      (StartInterval 600s)

Inspect with:
  launchctl print gui/\$(id -u)/$TICK_LABEL
  launchctl print gui/\$(id -u)/$WATCHDOG_LABEL

Watch Claude Code work live (read-only):
  tmux -S "$CLAWBOT_SOCKET" attach -t $CLAWBOT_SESSION -r

Control commands:
  $SCRIPT_DIR/clawbot-control.sh status
  $SCRIPT_DIR/clawbot-control.sh pause
  $SCRIPT_DIR/clawbot-control.sh resume

The first tick fire will happen within 3 minutes. Inspect $LOG_PATH to see headless Claude output.
EOF
