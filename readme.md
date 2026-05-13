# Clawbot — The Claw Loop

An autonomous orchestrator that drives [Claude Code](https://claude.com/claude-code) through a [BMAD V6](https://github.com/bmad-code-org/BMAD-METHOD) development sprint without human babysitting. A cron job wakes up every 3 minutes, looks at what Claude Code is doing inside a tmux pane, and decides whether to advance it, recover it, or pause for human input.

The "Clawdbot" is the supervisor. Claude Code (CC) is the worker. CC runs the slash commands; Clawbot keeps the conveyor belt moving.

## What it does

For each story in your sprint, Clawbot drives CC through the BMAD quality-gated loop:

```
create-story → dev-story → code-review (≤3 passes) → next story
                                       ↓
                           epic boundary → epic-review → epic-remediation (≤3 passes) → next epic
```

It detects when CC is working, idle, prompting, stalled, context-overflowed, crashed, or rate-limited, and takes the appropriate action. State is persisted to JSON between cron fires — Clawbot has no memory across fires except the state file.

## How it works

```
┌─────────────────────────────────────────────────────────────────────┐
│  cron (every 3 min)                                                 │
│     ↓                                                               │
│  bin/clawbot-tick.sh                                                │
│     • acquire flock                                                 │
│     • write heartbeat to state.cronHealth                           │
│     • cheap kill-switch (paused / halted / stopped / human-review)  │
│     • rate-limit gate (skip if cooldown active; auto-resume)        │
│     • smart-skip (dev<5m, review<4m, create<2m)                     │
│     • shell-level quality-gate snap-back                            │
│     • capture tmux pane                                             │
│     • invoke `claude -p` with lib/procedure.md as system prompt     │
│                                                                     │
│        ┌────────────────────────────────────────────────────────┐   │
│        │ headless Claude (the Clawdbot)                         │   │
│        │   reads state.json, captured pane, model strategy      │   │
│        │   detects rate-limit banner → writes status            │   │
│        │   runs stall fingerprint + tier escalation             │   │
│        │   decides next slash command, sends via tmux send-keys │   │
│        │   updates state.json, notifies human                   │   │
│        └────────────────────────────────────────────────────────┘   │
│                                                                     │
│     • increment metrics, release lock                               │
└─────────────────────────────────────────────────────────────────────┘
        ↓                       ↓                        ↓
  state.json              activity.log              tmux session "bmad-agent"
  (single source          (append-only audit         (where the actual
   of truth)               trail)                     Claude Code runs)
```

A second cron (`clawbot-watchdog.sh`, every 10 min) checks the heartbeat and re-registers the tick crontab entry if it's been silent for 10+ minutes.

## Repo layout

```
clawot/
├── bin/
│   ├── clawbot-setup.sh       one-time bootstrap for a BMAD project
│   ├── clawbot-tick.sh        per-cron-fire driver (the hot path)
│   ├── clawbot-watchdog.sh    re-registers dead cron entries
│   ├── clawbot-control.sh     human control surface (status/pause/resume/...)
│   └── clawbot-notify.sh      osascript banners + clawbot-messages.log
├── lib/
│   ├── procedure.md           the procedure passed to `claude -p` each tick
│   └── state.template.json    the schema for memory/bmad-dev-state.json
├── etc/
│   └── active-project         single-line path to the currently-managed project
├── clawbot.md                 long-form design doc / source-of-truth concepts
└── readme.md                  this file
```

Per-project files are written *into the BMAD project*, not into this repo:

```
<your-bmad-project>/
├── memory/
│   ├── bmad-dev-state.json    Clawbot's "brain" — read every cron fire
│   └── claw-loop-procedure.md copy of lib/procedure.md
└── _bmad-output/
    └── implementation-artifacts/
        ├── claw-loop-model-strategy.yaml   per-epic / per-story model tiers
        ├── claw-loop-activity.log          append-only event log
        ├── clawbot.log                     raw `claude -p` stdout/stderr
        ├── clawbot-messages.log            human-facing notifications
        └── sprint-status.yaml              authored by BMAD `/bmad-sprint-planning`
```

## Prerequisites

- macOS (the notifier and `date -j -f` parsing are macOS-specific)
- `claude` CLI installed and logged in (Claude Max plan recommended)
- `tmux`, `jq`, `yq`, `flock`, `osascript`, `crontab`
- A BMAD V6 project with `_bmad-output/implementation-artifacts/sprint-status.yaml` already authored (run `/bmad-sprint-planning` inside CC first)
- macOS may need **Full Disk Access** granted to `/usr/sbin/cron` in System Settings → Privacy & Security

## Setup

```bash
./bin/clawbot-setup.sh /absolute/path/to/your/bmad-project
```

This:

1. Verifies dependencies and validates the BMAD project
2. Prompts for escalation mode (`autonomous` / `conservative` / `aggressive`)
3. Creates the tmux session `bmad-agent` on its own socket and starts `claude` inside it
4. Copies `lib/procedure.md` into the project's `memory/` directory
5. Renders `memory/bmad-dev-state.json` from `lib/state.template.json`, seeded from `sprint-status.yaml` (resumes at the first non-done story)
6. Seeds `claw-loop-model-strategy.yaml` with safe "all-highest" defaults
7. Registers the `*/3` tick and `*/10` watchdog crontab entries
8. Prints the read-only tmux attach command

The first cron fire happens within 3 minutes.

## Operating the loop

All human control goes through `bin/clawbot-control.sh`:

| Command | Effect |
|---|---|
| `status` | Prints current story/step/queue, cron health, epic-review state, rate-limit info if active |
| `pause` | `state.status = "paused"` — tick exits early; no LLM call |
| `resume` | `state.status = "running"` |
| `stop` | `state.status = "stopped"` and kills the tmux session |
| `skip` | Advance past the current story (logged as SKIP) |
| `quarantine <story>` | Remove a story from the queue, set aside |
| `unquarantine <story>` | Restore a quarantined story to the queue |
| `force-advance` | Override quality gates and advance (use with care) |
| `findings` | Print the last epic-review findings file |
| `clear-rate-limit` | Force-clear a rate-limited status (resume immediately, e.g., after upgrading plan) |

## Watching the loop

```bash
# Live read-only view of Claude Code in the tmux pane (Ctrl-b then d to detach):
tmux -S "$HOME/.clawbot/clawdbot.sock" attach -t bmad-agent -r

# Raw output from headless Claude each tick:
tail -f <project>/_bmad-output/implementation-artifacts/clawbot.log

# Append-only event audit trail:
tail -f <project>/_bmad-output/implementation-artifacts/claw-loop-activity.log

# Just the human-facing notifications:
tail -f <project>/_bmad-output/implementation-artifacts/clawbot-messages.log
```

macOS Notification Center banners fire for everything except `[WORKING]` (which would be every 3 minutes — spam).

## Stall handling

The procedure runs a 4-tier escalation after fingerprinting the last 10 "meaningful" lines of the pane:

| Tier | Trigger | Action |
|---|---|---|
| 1 — Soft | Same pane fingerprint for 3 cycles | Send Enter |
| 2 — Context overflow | 5+ cycles AND pane mentions "context" / "token limit" / "compressing" | `/clear`, wait 3s, re-send the current step's command |
| 3 — Hard stall | 5+ cycles, no context overflow | Kill CC, restart `claude`, wait 8s, re-send |
| 4 — Repeated failure | `failureCount >= 3` on the same story | `status = "human-review-needed"`, alert and wait |

## Claude Max plan rate-limit handling

The Max plan caps usage on a rolling 5-hour window (and a weekly ceiling). When CC hits the cap its pane shows a banner like:

```
5-hour limit reached • Your limit will reset at 3pm
```

CC isn't crashed and isn't context-overflowed — it just won't process input until the window resets. Treating it as a hard stall would kill-and-restart in a loop.

The loop handles this with a dedicated path that runs *before* the stall tiers:

1. **Detection** (`lib/procedure.md` Step 2.5, LLM-level): the headless Claude matches the banner patterns, parses the reset time (local-time strings, `in N hours`, etc.), converts to UTC ISO with a 60-second safety buffer, and writes:
   ```json
   {
     "status": "rate-limited",
     "rateLimit": {
       "detectedAt": "2026-05-13T18:42:11Z",
       "resumeAt":   "2026-05-13T22:00:00Z",
       "raw":        "5-hour limit reached • Your limit will reset at 3pm",
       "resumeStep": "/bmad-dev-story 3.2",
       "hitCount":   1
     }
   }
   ```
   It does **not** send any input to CC.
2. **Sleep** (`bin/clawbot-tick.sh`, shell-level): while `status == "rate-limited"` and `now < resumeAt`, every cron fire logs `CRON_SKIP | reason:rate-limited | remaining_min:N` and exits — no `claude -p` invocation, so the cooldown costs zero headless tokens.
3. **Auto-resume** (`bin/clawbot-tick.sh`): the first fire after `resumeAt` flips `status` back to `"running"`, resets `stallCount`, fires `[RATE-LIMIT-RESUMED]`, and falls through to the normal tick flow. Step 4's idle-CC handler re-sends the current step's slash command from state — no special resume command needed.
4. **Manual override**: `clawbot-control.sh clear-rate-limit` flips status back early.

If the banner has no parseable reset time, the procedure sets `resumeAt = NOW + 5h` as a safe upper bound for the 5-hour window.

`clawbot-control.sh status` shows remaining cooldown:

```
Status:        rate-limited
...
Rate limit:    detected 2026-05-13T18:42:11Z, resumes 2026-05-13T22:00:00Z (~198m remaining), hits=1
```

## Model strategy

`<project>/_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml` controls which model is used per step / epic / story:

```yaml
model_tier_mapping:
  highest: opus      # complex reasoning, code review, story authoring
  standard: sonnet   # straightforward CRUD / UI / config work

step_defaults:
  create_story: highest   # always
  code_review:  highest   # always
  dev_story:    highest   # safe default; override below for simple work

epic_overrides:
  3: standard              # all stories in epic 3 use sonnet for dev-story
story_overrides:
  4-2-billing-totals: highest   # one-off override for a specific story
```

Resolution order at runtime: `story_overrides` → `epic_overrides` → `step_defaults`. Never hardcode model names in the procedure — when Anthropic releases new models, just edit two lines under `model_tier_mapping`.

If the YAML is missing or malformed, the procedure falls back to "all-highest" and notifies `[MODEL-FALLBACK]`.

## State file fields you'll care about

```jsonc
{
  "status": "running",          // running | paused | halted | stopped | human-review-needed | rate-limited
  "currentStory": "3-2-billing-totals",
  "currentStoryNumber": "3.2",
  "currentStep": "dev-story",   // create-story | dev-story | code-review | epic-review | epic-remediation
  "reviewPassNumber": 1,        // increments per code-review pass; max 3
  "failureCount": 0,            // increments on per-story failures; >= 3 → tier 4
  "stallCount": 0,              // increments on identical pane fingerprint
  "storyQueue": ["3-2-...", "3-3-...", ...],
  "completedStories": [...],
  "quarantinedStories": [...],
  "modelStrategy": { ... },
  "cronHealth": {
    "lastCronFire": "...",      // watchdog uses this — if >10m stale, recover cron
    "consecutiveFires": 42,
    "cronStatus": "healthy"
  },
  "rateLimit": {                // populated when status=rate-limited (see above)
    "detectedAt": null,
    "resumeAt": null,
    "raw": null,
    "resumeStep": null,
    "hitCount": 0,
    "lastResumedAt": null
  },
  "epicReview": {               // populated during the epic-boundary quality gate
    "passNumber": 0,
    "findings": [],
    "lastFindingsFile": null,
    "autoFixedCount": 0,
    "deferredCount": 0,
    "unresolvedCount": 0
  },
  "metrics": { ... }
}
```

## Troubleshooting

| Symptom | Where to look |
|---|---|
| Nothing happening for 10+ minutes | `clawbot-control.sh status` — check `Last cron`; watchdog re-registers a dead crontab automatically every 10 min |
| `[TICK-ERROR]` Tmux session missing | Run `bin/clawbot-setup.sh <project>` again — recreates the session |
| Repeated `[QUALITY-GATE-CORRECTION]` | Epic-review found pending auto-fixes but the LLM drifted off the gate; shell forces it back to `epic-remediation`. If this loops, run `clawbot-control.sh findings` to see the open items |
| Loop stuck in `human-review-needed` | A story has failed 3+ times. Inspect the activity log around the last STORY/STALL_T4 entry, fix the underlying issue (or `quarantine` the story), then `resume` |
| `[RATE-LIMIT-HIT]` | Expected; the loop will auto-resume at `resumeAt`. To resume early after upgrading the plan: `clawbot-control.sh clear-rate-limit` |
| Headless Claude exited non-zero | `tail` the `clawbot.log` for the stack — usually a transient API error; the next tick (3 min) retries |
| Want to fully reset state for the active project | Stop the loop, delete `<project>/memory/bmad-dev-state.json`, re-run `bin/clawbot-setup.sh` |

## Design references

The long-form design doc lives in [`clawbot.md`](./clawbot.md). The procedure that the headless Claude reads each tick lives in [`lib/procedure.md`](./lib/procedure.md). Both are kept human-readable on purpose — they are also the runtime artifacts.
