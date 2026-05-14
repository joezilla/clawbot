I want you to set up **The Claw Loop** — an autonomous development workflow where you (my Clawdbot) orchestrate Claude Code running in a tmux session.

This prompt has two parts:
- **PART 1: CONCEPTS** — Read this to understand how the system works. No actions required.
- **PART 2: EXECUTE SETUP** — Follow these steps in order to activate the loop.

After setup, a scheduled tick fires every <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes (via a user LaunchAgent on macOS) with a **lightweight ping** that tells you to continue working. The full procedure is saved to a reference file (`memory/claw-loop-procedure.md`) during setup — you read it when needed (first fire, after `/clear`, or if you lose track), not every cycle. This keeps tick payloads small and prevents context window bloat from repeated prompt injection.

---

# PART 1: CONCEPTS — Read and Internalize

*This section teaches you how the Claw Loop works. Read it carefully. No actions to take yet.*

---

## 1.1 What Is the Claw Loop?

You are an **orchestrator**. Claude Code (CC) is the **worker**. CC runs inside a tmux terminal session and executes slash commands to build software. But CC can't drive itself — it finishes a task and sits there waiting. It hits context limits and stalls. It crashes and needs restarting. That's where you come in.

**Your job:** A scheduled tick wakes you up every <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes. Each time, you look at what CC is doing (by capturing the tmux pane), decide if it needs help, act if necessary, and then report back to your human. You are the supervisor on the factory floor — you check the machine, adjust if needed, and log what happened.

**Key facts:**
- **CC is powerful but not autonomous.** It can write code, run tests, and review its own work — but it can't chain tasks together or recover from failures on its own.
- **You bridge that gap.** You read CC's output, detect when it's done/stuck/crashed, send it the next command, and keep the pipeline moving.
- **The state file is your brain.** You wake up fresh every tick fire with no memory of the last one. The JSON state file tells you where you are. Always read it, always update it.
- **Reporting is not optional.** Your human should never wonder what's happening. Every cycle, they get a short update. Even "CC working, no action needed" is valuable — it means the loop is alive.

## 1.2 Core Principles

1. **Observe before acting** — Always capture the pane first. Never assume what CC is doing.
2. **One action per cycle** — Send one command or one response per tick fire. Don't stack multiple actions.
3. **Clear context between every major step** — Use `/clear` between phases. A CC instance that has been working for 20+ minutes has a full context window. If you send it a new command in that state, it will hallucinate, repeat old work, or fail silently. Every new step needs a cleared context.
4. **Text and Enter are always separate** — This is a tmux quirk. Combining them causes dropped input.
5. **The state file is the source of truth** — Not your memory, not the pane. The state file decides what step you're on.
6. **Fail gracefully** — CC will crash, hit rate limits, and run out of context. These are expected events, not emergencies.
7. **Report everything** — Your human trusts you because they can see what you're doing.
8. **Never advance a broken story** — If code review found HIGH/CRITICAL issues, re-run code-review (up to <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> passes). Dev-story runs exactly once.

## 1.3 Why Context Clearing Matters

When CC runs a slash command like `/bmad-dev-story`, the command itself contains everything CC needs: it loads the story file, reads the architecture docs, discovers the codebase, and builds a plan. CC doesn't need memory from the previous step — the slash command IS the context.

But if you try to run `/bmad-code-review` in the same CC session that just ran `/bmad-dev-story`, CC's context window is 60-100% full of the dev work it just did. The code-review command tries to load fresh files but there's no room. CC starts cutting corners, skipping files, or hallucinating that it already reviewed things.

**The fix is simple: send `/clear` then send the next command.** `/clear` wipes all conversation history. The slash command fills it with exactly what's needed for that step.

**Why `/clear` instead of kill+restart:**
- `/clear` achieves the same clean context (all history wiped)
- CLAUDE.md and slash commands stay loaded (no re-discovery needed)
- No 8-second boot delay — saves ~10 seconds per transition
- `/model` command works in the same session for model switching
- Only kill+restart when CC has crashed/exited to shell or is completely unresponsive

## 1.4 Intelligent Model Strategy

Different steps benefit from different models. The Claw Loop uses a **pre-computed model strategy file** (`claw-loop-model-strategy.yaml`) that assigns the right model tier per epic and story based on complexity analysis.

**Two model tiers (never use the lowest-tier model for development):**

| Tier | Current Model | Purpose |
|------|--------------|---------|
| `highest` | Best reasoning model available (currently Opus) | Complex stories: auth, payments, concurrency, algorithms, RLS policies |
| `standard` | Fast execution model available (currently Sonnet) | Straightforward stories: UI components, CRUD, scaffolding, config |

**Step-level defaults:**

| Step | Tier | Why |
|------|------|-----|
| create-story | `highest` — always | Story creation requires deep architecture analysis |
| code-review | `highest` — always | Adversarial review requires deep reasoning |
| dev-story | **varies by epic/story** | Determined by `claw-loop-model-strategy.yaml` |

**How model resolution works at runtime:**
1. Read `claw-loop-model-strategy.yaml`
2. For create-story or code-review → always use `model_tier_mapping.highest`
3. For dev-story: check `story_overrides[current_story_key]` → `epic_overrides[current_epic]` → `step_defaults.dev_story`
4. Map the tier name to actual model via `model_tier_mapping`
5. Send `/model <resolved-model-name>`

**NEVER hardcode model names.** Always resolve from the strategy file. When Anthropic releases new models, you update two lines in the mapping section — every epic/story decision still works.

### The claw-loop-model-strategy.yaml File

This file lives at `_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml`. It's generated once during pre-sprint setup (Step B2) and updated optionally after epic completions.

```yaml
# ============================================================
# CLAW LOOP MODEL STRATEGY
# ============================================================
# Generated by: The Claw Loop v2.4 — Autonomous Dev Orchestrator
#
# TIER DEFINITIONS:
# highest: Best available reasoning model. Use for complex logic.
# standard: Fast execution model. Use for established patterns.
#
# IMPORTANT: Never use lowest-tier models (e.g., Haiku) for development.
# FUTURE-PROOFING: Update ONLY model_tier_mapping when new models release.

model_tier_mapping:
  highest: opus      # Update this line when new models release
  standard: sonnet   # Update this line when new models release

step_defaults:
  create_story: highest    # Always — deep reasoning for architecture analysis
  code_review: highest     # Always — adversarial review needs depth
  dev_story: standard      # Default for implementation, overridden below

epic_overrides:
  epic-1:
    dev_model: standard
    rationale: "Project scaffolding, design system, basic forms"
  epic-2:
    dev_model: highest
    rationale: "AI-assisted creation, randomization algorithm"
  # ... (populated by pre-sprint analysis)

story_overrides:
  1-3-owner-registration-and-account-creation:
    dev_model: highest
    rationale: "RLS policy setup, auth flow — security-critical"
  # ... (populated by pre-sprint analysis)
```

### Complexity Criteria — The Classification Rubric

During pre-sprint analysis (Step B2), you give CC these **explicit, measurable criteria** to classify each epic. CC does NOT decide what's complex — it applies these rules.

**HIGHEST tier required — if the epic/story involves ANY of these:**
- Database schema design, RLS policies, or row-level security
- Authentication, authorization, JWT handling, or session management
- External API integration (Stripe, Twilio, SendGrid, Groq, or any third-party)
- Webhook handling or signature verification
- Concurrency, race conditions, or atomic operations (e.g., `UPDATE...RETURNING`)
- State machines or multi-state lifecycle management
- Algorithms beyond simple CRUD (randomization, scoring, escalation chains, scheduling)
- Real-time data (subscriptions, live updates, WebSocket, polling)
- Financial calculations, billing, proration, or payment processing
- Background jobs, cron tasks, queue processing, or worker functions
- Data migration, retention policies, cleanup jobs, or archival logic
- Multi-tenant data isolation or cross-tenant security boundaries
- Complex form validation with interdependent fields
- Image processing, compression pipelines, or media handling

**STANDARD tier sufficient — ALL of the following must be true:**
- Primarily UI components following the project's established design system
- Standard CRUD operations using existing service layer patterns
- Configuration, scaffolding, or boilerplate setup
- No new RLS policies or auth changes introduced
- No external API calls or webhook handlers
- No concurrency concerns or atomic operations
- No new algorithms or complex business logic

**The rule is conservative:** When in doubt, classify as `highest`.

## 1.5 BMAD V6 Implementation Cycle

The Claw Loop orchestrates BMAD V6's **quality-gated loop** with conditional branching and a **double-review pattern**:

```
create-story → dev-story (runs ONCE) → code-review (pass 1)
                                            |
                                            ├── CLEAN (0 HIGH/CRITICAL) → advance to next story
                                            └── HIGH/CRITICAL found → fix in-place → code-review (pass 2)
                                                                                        |
                                                                                        ├── CLEAN → advance
                                                                                        └── HIGH/CRITICAL found → fix → code-review (pass <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->, FINAL)
                                                                                                                          |
                                                                                                                          └── advance (max <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> passes)
```

**Key rules:**
- **Dev-story runs exactly ONCE per story. It never re-runs.** Code-review always fixes issues in-place (Option 1).
- **Code-review re-runs only if it finds HIGH or CRITICAL issues.** It fixes them, then a fresh review verifies the fixes.
- **Maximum <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> code-review passes.** After the 3rd pass, the story advances regardless — no infinite loops.
- **Why re-review matters:** When code-review fixes HIGH/CRITICAL issues, those fixes are unreviewed code. A fresh `/clear` + re-review catches problems the first reviewer introduced.

### Story Lifecycle Through Sprint Status

BMAD V6 tracks every story in `sprint-status.yaml`:
```
backlog → ready-for-dev → in-progress → review → done
```
- **create-story** moves: `backlog` → `ready-for-dev`
- **dev-story** moves: `ready-for-dev` → `in-progress` → `review`
- **code-review** moves: `review` → `done` (approved) or back to `in-progress` (issues remain)

## 1.6 Stall Detection Philosophy

CC can get stuck in ways that aren't crashes. The Claw Loop uses a 4-tier escalation:

- **Tier 1 — Soft Stall:** Same output for 3 consecutive cycles. Send Enter (sometimes CC is waiting for a keypress).
- **Tier 2 — Context Overflow:** Pane mentions "context", "token limit", "compressing". `/clear` and re-send current command.
- **Tier 3 — Hard Stall:** 5+ consecutive cycles with no progress despite interventions. Kill CC, restart, re-send.
- **Tier 4 — Repeated Failure:** Same story fails 3+ times. Pause loop, alert human.

## 1.6a Claude Max Plan Rate-Limit Handling

The Max plan caps usage on a rolling 5-hour window (and a weekly ceiling). When CC hits the cap, its pane shows a banner like "5-hour limit reached • Your limit will reset at 3pm" — CC stops producing output, but it isn't crashed and isn't context-overflowed. Treating it as a stall would just kill-and-restart in a loop until the window resets.

The loop handles this with a dedicated path that runs *before* stall escalation:

1. **Detection (procedure Step 2.5, LLM-level):** the headless Claude matches the Max-plan banner patterns, parses the reset time, converts it to UTC ISO, and writes `state.status = "rate-limited"` plus `state.rateLimit.{detectedAt, resumeAt, raw, resumeStep, hitCount}`. It does **not** send any input to CC.
2. **Sleep (tick.sh, shell-level):** while `status == "rate-limited"` and `now < resumeAt`, every tick fire silently logs `CRON_SKIP | reason:rate-limited` and exits — no `claude -p` call is made, so the cooldown costs nothing in headless tokens.
3. **Auto-resume (tick.sh, shell-level):** the first fire after `resumeAt` flips `status` back to `"running"`, resets `stallCount`, notifies `[RATE-LIMIT-RESUMED]`, and falls through to the normal tick flow. Step 4's idle-CC handler re-sends the current step's slash command from state — no special resume command needed.
4. **Manual override:** `clawbot-control.sh clear-rate-limit` flips the status back early (e.g., if you've upgraded the plan).

If the banner has no parseable reset time, the procedure sets `resumeAt = NOW + 5h` as a safe upper bound for the rolling window.

## 1.7 Tick Health Monitoring & Context Efficiency

The tick fires every <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes, fixed. It never gets deleted, recreated, or adjusted. This eliminates the #1 cause of silent scheduler death: failed interval adjustments.

**Lightweight tick pattern:** Each tick fire sends a small payload (~800 chars) that tells you to continue working and where to find the full procedure. The full procedure lives in `memory/claw-loop-procedure.md` — you read it when you need it (first fire, after `/clear`, lost context), not every cycle. This prevents context window bloat: a full 18KB procedure repeated every 3 minutes would consume 500KB+ in under 2 hours, triggering context overflow and "rate limit" errors.

**Recommended tick settings:**
- **`sessionTarget: "isolated"`** — each tick fire gets a fresh session, preventing context accumulation
- **`lightContext: true`** — skips workspace bootstrap file injection, reducing per-run token cost

**Two-layer watchdog:**
- **Layer 1 (inside tick):** Every fire writes a heartbeat timestamp to the state file — even smart-skip fires.
- **Layer 2 (HEARTBEAT.md):** The Clawdbot's natural heartbeat checks the timestamp. If <!--CONFIG:WATCHDOG_THRESHOLD-->10<!--/CONFIG:WATCHDOG_THRESHOLD-->+ minutes stale → tick died → alert human + auto-recover (re-bootstrap the tick LaunchAgent via launchctl).

## 1.8 BMAD V6 Prompt Recognition

BMAD V6 workflows present specific decision points. Key patterns:

| CC Output | Response | Context |
|-----------|----------|---------|
| `[a] [c] [p] [y]` | Send `c` (Continue) | BMAD template-output checkpoint |
| `Choose [1], [2], or specify` | Send `1` (Fix automatically) | Code review decision |
| `Choose option [1], [2], [3], or [4]` | Send `1` (Run create-story) | Dev-story — no ready stories found |
| `(y/n)` or `(y/n/edit)` | Send `y` | Generic continue prompt |
| `HALT` | DO NOT respond | Stop condition — alert human |

<!--CONFIG:SECTION:REPORT_FORMAT_1_9-->
## 1.9 Response Format

Every tick report to the human MUST follow this exact format. No freestyling, no narrative paragraphs, no cheerleading.

**Calculate elapsed time:** `elapsed = NOW - metrics.currentStoryStartedAt` (round to nearest minute). This tracks total time on the current story across all phases (create-story, dev-story, code-review).

**Templates by status:**

**[WORKING]** — CC is active, no intervention needed:
```
[WORKING] Story X.X | step | elapsed min | Model
SAW: <one line — what CC is doing, context % if ≥50%>
ACTION: None — <brief reason>
PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
```

**[TRANSITION]** — Bot took action to advance the pipeline:
```
[TRANSITION] Story X.X | from-step → to-step | elapsed min
SAW: <one line — what triggered the transition>
ACTION: <commands sent>
PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
STATS: <elapsed> min | <N> cycles | <N> review passes | <model tier>
```

**[DONE]** — Story fully complete:
```
[DONE] Story X.X — Story Name ✅
SAW: <what confirmed completion>
ACTION: Advancing to story Y.Y
PROGRESS: Story N/Total complete | Epic N (M remaining)
STATS: <elapsed> min | <N> cycles | <N> review passes | <model tier>
```

**[STALL]** — Escalation triggered:
```
[STALL] Story X.X | step | Tier N ⚠️
SAW: <what indicates the stall>
ACTION: <recovery action taken>
PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
```

**[NEEDS-HUMAN]** / **[HALTED]** — Human intervention required:
```
[NEEDS-HUMAN] Story X.X | step ⚠️
SAW: <what went wrong>
ACTION: Loop paused — awaiting human input
PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
```

**Format rules:**
- Line 1 is ALWAYS `[STATUS] Story X.X | key-info` — glanceable in 1 second
- SAW is ALWAYS one line, max ~80 characters — forces compression
- ACTION is ALWAYS one line
- PROGRESS is ALWAYS `Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->` — consistent positioning
- STATS line ONLY on [DONE] and [TRANSITION] — not needed every <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes
- Context % ONLY when ≥50% — only surface when it matters
- No emojis except ✅ on [DONE] and ⚠️ on problems
- No "Next cycle:" predictions — speculative, often wrong
- No token counts, no fire/cycle counts in reports — these go in the activity log only
- No cheerleading, commentary, or narrative text — data only
<!--/CONFIG:SECTION:REPORT_FORMAT_1_9-->

---

# PART 2: EXECUTE SETUP — Follow These Steps in Order

*This section is procedural. Execute each step sequentially.*

---

## Step 0: Research the BMAD Method

Go research the BMAD Method to understand how it works. Search for "BMAD Method Claude Code" and "bmad-method" on GitHub/npm. Key things to learn:
- BMAD uses slash commands stored in `.claude/commands/` in the project
- The core cycle is: **create-story** → **dev-story** (once) → **code-review** (up to <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> passes if HIGH/CRITICAL found)
- Common BMAD slash commands:
  - `/bmad-create-story` — Generates a comprehensive story file with ACs, tasks, subtasks, and dev notes
  - `/bmad-dev-story` — Implements the story: writes code, migrations, components, hooks, and tests
  - `/bmad-code-review` — Adversarially reviews the implementation, finds issues, can fix them in-place
  - `/bmad-sprint-status` — Shows current sprint progress
- Each command is self-contained — it loads all the context it needs from project files
- Sprint-status.yaml is the authoritative queue — it tracks every story's state

**Important:** Don't just memorize commands — understand what each step DOES so you can recognize when CC has finished it and know what comes next.

## Step 1: Ask Setup Questions

Ask these questions **one at a time, wait for each answer**:

**1. What is the absolute file path to your project?**
- Ask for the **absolute file path** to the project directory (e.g., `/Users/jordan/my-project` or `C:\Users\jordan\my-project`)
- ⚠️ Do NOT accept relative paths like `~/my-project` or `./project` — you need the full absolute path for tmux commands
- Verify the directory exists
- Check for `_bmad-output/implementation-artifacts/sprint-status.yaml` — this is your queue
- Store this path — you'll use it for the tmux session working directory

**2. Where should I send status updates?**
- Detect what channel you're talking on right now (Telegram, Discord, etc.)
- Confirm: "I see you're on [channel]. Should I send loop updates here?"
- Store the channel and target ID
- Test the connection with a test message
- Do not proceed until the human confirms receipt

**3. Confirm your story queue from sprint-status.yaml**
- Parse all stories and their current statuses
- Present summary: "Found X stories across Y epics. Z are backlog, W are in-progress, V are done."
- Ask: "Should I start from the first backlog story, or do you want to specify a starting point?"

**4. What's your escalation preference?**
- **Autonomous:** Loop handles Tier 1-3 stalls automatically, only pauses for Tier 4
- **Conservative:** Loop pauses and alerts for any stall beyond Tier 1
- **Aggressive:** Loop handles everything including skipping stuck stories after 5 failures
- Default to autonomous if they don't have a preference

**5. Do you have Claude Code installed?**
- Verify: `which claude`
- Check it's authenticated: `claude --version`

## Step 1.5: Verify tmux Is Installed

Before proceeding, check if tmux is installed on the system:

```bash
which tmux
```

**IF tmux is found** (output shows a path like `/usr/bin/tmux` or `/opt/homebrew/bin/tmux`):
→ Proceed to Step 2.

**IF tmux is NOT found** (command returns nothing or "not found"):
→ Tell the human: "tmux is not installed on your system. The Claw Loop requires tmux to run. I can install it for you right now — should I go ahead?"

- **If they say yes**, install it:
  - **macOS:** `brew install tmux`
  - **Ubuntu/Debian:** `sudo apt-get install -y tmux`
  - **Fedora/RHEL:** `sudo dnf install -y tmux`
  - **Arch:** `sudo pacman -S tmux`
- After install, verify with `which tmux` again
- If install fails (e.g., Homebrew not installed on macOS), guide the human through installing the package manager first
- **If they say no**, stop setup and tell them: "The Claw Loop cannot run without tmux. Install it whenever you're ready and come back to set up the loop."

⛔ Do NOT proceed to Step 2 until tmux is confirmed installed.

## Step 2: Create/Find the tmux Session

```bash
SOCKET="$HOME/.clawbot/clawdbot.sock"
SESSION="bmad-agent"

# Check if session exists
tmux -S "$SOCKET" has-session -t "$SESSION" 2>/dev/null

# If not, create it in the project directory
tmux -S "$SOCKET" new-session -d -s "$SESSION" -c /path/to/project

# Start Claude Code in it
tmux -S "$SOCKET" send-keys -t "$SESSION":0.0 'claude' Enter
```

Wait 10 seconds for Claude Code to initialize, then verify it's running by capturing the pane.

**Give the human their watch command.** After creating the tmux session, send the human this message:

> **Want to watch Claude Code work in real-time?** Open a new terminal window and run this command:
>
> ```
> tmux -S "$HOME/.clawbot/clawdbot.sock" attach -t bmad-agent -r
> ```
>
> The `-r` flag makes it **read-only** — you can watch everything CC does without accidentally typing into the session. You'll see every file it reads, every edit it makes, every test it runs — live.
>
> **To detach** (stop watching without killing the session): press `Ctrl+B` then `D`.
>
> **Tip:** Keep this open in a side monitor or split terminal. It's like watching a developer code at 10x speed.

Do NOT proceed until you've sent this message to the human. They should know how to observe the loop before it starts.

## Step 3: Parse Sprint-Status and Build the Queue

```
1. Read _bmad-output/implementation-artifacts/sprint-status.yaml
2. Extract all story keys (pattern: N-N-name, NOT epic-N or epic-N-retrospective)
3. Group by epic number
4. Order: stories within each epic in sequence, epics in order
5. Identify the first story that is NOT "done" — this is your starting point
6. Store the full ordered queue in the state file
```

## Step 4: Run Pre-Sprint Model Strategy Analysis

This step generates `claw-loop-model-strategy.yaml`. You (the Clawdbot) are the orchestrator. CC is the analyst.

1. **Send CC the analysis prompt via tmux:**
   ```
   Read the following files:
   - _bmad-output/planning-artifacts/epics.md (or all epic*.md files)
   - _bmad-output/planning-artifacts/architecture.md

   For each epic, determine whether the dev-story step requires the "highest" or "standard" model tier. Apply these criteria EXACTLY — do not use judgment, apply the rules:

   HIGHEST required if the epic involves ANY of:
   - Database schema design, RLS policies, or row-level security
   - Authentication, authorization, JWT, or session management
   - External API integration (Stripe, Twilio, SendGrid, Groq, etc.)
   - Webhook handling or signature verification
   - Concurrency, race conditions, or atomic operations
   - State machines or multi-state lifecycle management
   - Algorithms beyond CRUD (randomization, scoring, escalation, scheduling)
   - Real-time data (subscriptions, live updates, WebSocket, polling)
   - Financial calculations, billing, proration, or payments
   - Background jobs, cron tasks, queue processing, or workers
   - Data migration, retention policies, cleanup, or archival
   - Multi-tenant data isolation or cross-tenant security
   - Complex form validation with interdependent fields
   - Image processing, compression pipelines, or media handling

   STANDARD sufficient only if ALL of:
   - Primarily UI components following established design system
   - Standard CRUD with existing service layer patterns
   - No new RLS policies or auth changes
   - No external API calls or webhook handlers
   - No concurrency concerns
   - No new algorithms or complex business logic

   When in doubt, classify as "highest."

   Also identify any INDIVIDUAL STORIES that should override their epic's classification.

   Output your analysis as a YAML block with this exact structure:
   epic_overrides:
     epic-1:
       dev_model: highest/standard
       rationale: "one line why"
   story_overrides:
     story-key-here:
       dev_model: highest/standard
       rationale: "one line why"
   ```

2. **Wait for CC to complete** (typically 2-5 minutes). Capture the pane output.

3. **Parse CC's YAML output.** Extract `epic_overrides` and `story_overrides`.

4. **Write `claw-loop-model-strategy.yaml`** to `_bmad-output/implementation-artifacts/` with the model_tier_mapping, step_defaults, and CC's analysis results.

5. **Show the human for approval.** List each epic with its classification. Ask: "Does this model strategy look right? Say 'approve' to continue or tell me what to change."

6. **`/clear` CC** — the analysis is done, CC is ready for the loop.

## Step 5: Create the State File

Create `memory/bmad-dev-state.json` in your workspace:

```json
{
  "currentStory": "1-1-project-initialization-and-development-environment",
  "currentStoryNumber": "1.1",
  "currentStoryFilePath": null,
  "currentEpic": 1,
  "currentStep": "create-story",
  "status": "running",
  "lastUpdated": "ISO-TIMESTAMP",
  "lastActionAt": "ISO-TIMESTAMP",
  "currentStepType": "create-story",
  "notes": "Claw Loop initialized from sprint-status.yaml.",
  "storyQueue": ["PARSED-FROM-SPRINT-STATUS"],
  "completedStories": [],
  "currentEpicStories": ["STORIES-IN-CURRENT-EPIC"],
  "stepOrder": ["create-story", "dev-story", "code-review"],
  "cronInterval": "<!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL-->min-fixed-with-smart-skip",
  "escalationMode": "autonomous",
  "paneFingerprint": "",
  "stallCount": 0,
  "failureCount": 0,
  "reviewPassNumber": 1,
  "totalStoriesCompleted": 0,
  "totalEpicsCompleted": 0,
  "sessionStartedAt": "ISO-TIMESTAMP",
  "lastReviewOutcome": null,
  "consecutiveIdleCycles": 0,
  "pendingPrompt": false,
  "pendingPromptText": null,
  "pendingPromptFirstSeen": null,
  "quarantinedStories": [],
  "gitVerification": {
    "pendingVerification": false,
    "verificationAttempts": 0,
    "lastVerifiedStory": null,
    "lastVerifiedCommit": null
  },
  "modelStrategy": {
    "currentModel": null,
    "currentModelTier": null,
    "modelSource": null,
    "fallbackActive": false,
    "modelStrategyFile": "_bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml",
    "lastModelSwitchAt": null
  },
  "cronHealth": {
    "lastCronFire": "ISO-TIMESTAMP",
    "consecutiveFires": 0,
    "lastSkipReason": null,
    "cronStatus": "healthy"
  },
  "metrics": {
    "currentStoryStartedAt": "ISO-TIMESTAMP",
    "currentStoryCronFires": 0,
    "sprintStartedAt": "ISO-TIMESTAMP",
    "totalCronFires": 0,
    "totalCronSkips": 0,
    "activityLogFile": "_bmad-output/implementation-artifacts/claw-loop-activity.log",
    "completedStoryMetrics": []
  }
}
```

## Step 6: Create the Activity Log

Create `_bmad-output/implementation-artifacts/claw-loop-activity.log`:

```
# ============================================================
# CLAW LOOP ACTIVITY LOG
# ============================================================
# Generated by: The Claw Loop v2.4 — Autonomous Dev Orchestrator
# Project: {project_name}
# Started: {ISO-TIMESTAMP}
# Sprint: {total_stories} stories across {total_epics} epics
#
# This file is an append-only audit trail of all Claw Loop
# activity. It is NOT a BMAD artifact — it is created and
# maintained by the Claw Loop orchestration system.
#
# Format: TIMESTAMP | EVENT | DETAILS...
# ============================================================
```

**Event types:**
```
CRON_FIRE   | story:X.X | step:STEP | model:MODEL(TIER) | action:ACTION
CRON_SKIP   | story:X.X | step:STEP | reason:REASON
TRANSITION  | story:X.X | from:STEP | to:STEP | model:OLD→NEW
PROMPT_RESP | story:X.X | step:STEP | prompt:TEXT | sent:RESPONSE
PROMPT_AUTO | story:X.X | step:STEP | prompt:TEXT | sent:RESPONSE
REVIEW_DONE | story:X.X | outcome:OUTCOME | pass:NofN | action:ACTION
STORY_DONE  | story:X.X | duration:NNmin | cron_fires:N | review_passes:N | dev_model:TIER
EPIC_DONE   | epic:N | stories:N | total_duration:NNmin | avg_review_loops:N.N
STALL_T1/T2/T3/T4 | story:X.X | step:STEP | stallCount:N | action:ACTION
MODEL_SWITCH | from:MODEL | to:MODEL | tier:TIER | source:SOURCE
MODEL_FALLBACK | reason:REASON | action:all-highest
GIT_VERIFIED | story:X.X | commit:HASH | files:N
GIT_UNCOMMITTED | story:X.X | action:requested-commit
GIT_ISSUE   | story:X.X | action:alerted-human-proceeding
QUARANTINE  | story:X.X | reason:REASON
HUMAN_CMD   | command:CMD | reason:REASON
CRON_HEALTH | status:STATUS | consecutiveFires:N
CRON_RECOV  | downtime:Nmin | action:watchdog-recreated-cron
```

## Step 7: Save the Tick Procedure File

Save the **entire TICK PROCEDURE** section below (everything between the ``` fences) to `memory/claw-loop-procedure.md` in your workspace. This is the detailed step-by-step procedure you'll reference on each tick fire. The tick payload itself will be lightweight — it just points you here.

⚠️ **Save the ENTIRE procedure block exactly as written. Do not edit or abbreviate it. This is your authoritative reference for tick execution.**

Verify the file was saved correctly and is readable.

## Step 8: Schedule the Tick (LaunchAgent)

Install a user LaunchAgent labelled `ai.clawbot.tick` that fires every **<!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes** (StartInterval = 180, fixed) with the **lightweight payload** below. The LaunchAgent must be loaded into the GUI session (`launchctl bootstrap gui/$(id -u) ...`) so the headless `claude -p` invocation can read its OAuth token from the macOS login keychain — cron jobs cannot.

**Why lightweight?** Each tick fire injects its payload into your session. A full 18KB procedure repeated every 3 minutes causes context window bloat — 28 fires = 500KB+ of duplicated instructions. The lightweight payload (~800 chars) tells you to continue working and where to find the full procedure if needed. This follows Anthropic's recommended "just-in-time context" pattern.

Use these tick settings for optimal token efficiency:
- **`sessionTarget: "isolated"`** — each tick fire gets a fresh session instead of accumulating in the main one
- **`lightContext: true`** — skips workspace bootstrap file injection, reducing per-run token cost

**Lightweight tick payload (copy this exactly):**

```
BMAD V6 DEV LOOP — Tick fire.

Full procedure: memory/claw-loop-procedure.md
State file: memory/bmad-dev-state.json
Model strategy: _bmad-output/implementation-artifacts/claw-loop-model-strategy.yaml
Activity log: _bmad-output/implementation-artifacts/claw-loop-activity.log

Continue the dev loop from where you left off. Execute steps 0-5 in order as documented in the procedure file.

If this is your first fire, after a /clear, or if you've lost track of the procedure:
→ Read memory/claw-loop-procedure.md end-to-end before acting.
Otherwise, continue from your current state — the state file tells you where you are.

TMUX SOCKET: $HOME/.clawbot/clawdbot.sock
TMUX SESSION: bmad-agent
CHANNEL: [CHANNEL]
TARGET_ID: [TARGET_ID]

Key rules (always active):
⛔ NEVER send Enter combined with text in tmux — always separate calls
⛔ NEVER advance with failing tests or unresolved HIGH/CRITICAL review issues
⛔ ALWAYS update state file after any action — it is your only memory
⛔ ALWAYS report every tick fire to the human — silence means the loop is dead
⛔ ALWAYS /clear between major step transitions
⛔ If a Claude Max plan limit banner appears, run Step 2.5 (rate-limit detection) — set status="rate-limited" with parsed resumeAt, notify, exit. The shell-level tick gate auto-resumes after the window.
```

Replace `[CHANNEL]` and `[TARGET_ID]` with the user's confirmed messaging details from setup.

## Step 9: Create the Daily Summary Tick

Create a second scheduled task called `claw-loop-daily-summary` that fires every **24 hours** (or at a specific time the human prefers) with this systemEvent:

```
CLAW LOOP DAILY SUMMARY — Read these files and generate a sprint progress report:

1. Read memory/bmad-dev-state.json
2. Read _bmad-output/implementation-artifacts/claw-loop-activity.log
3. Count for the last 24 hours:
   - Stories completed (list each with name and duration from STORY_DONE entries)
   - Stories currently in-progress
   - Any stories that required 3+ review passes (flag these specifically)
   - Stall events by tier (count from STALL_T1/T2/T3/T4 entries)
   - Any human interventions (HUMAN_CMD entries)
4. Calculate cumulative sprint progress:
   - Total stories done / total stories in queue
   - Epics completed / total epics
   - Current epic and story
5. Send to human on [CHANNEL]:

"CLAW LOOP DAILY SUMMARY — [DATE]
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
Stories completed today: X (Y total done / Z remaining)
Epics: N complete, M in progress
Current: Story X.X — [name]

Stories done today:
- X.X [name] (XX min, N review passes)
- X.X [name] (XX min, N review passes)

Flagged (3+ review passes): [list or 'None']
Stalls: X total (T1: a, T2: b, T3: c, T4: d)
Human interventions: X

Tick health: X fires, Y skips
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
```

## Step 10: Add Watchdog to Persistent Memory

Add to your **HEARTBEAT.md**:

```markdown
## Claw Loop Watchdog

If the file `memory/bmad-dev-state.json` exists AND its `status` field is "running":
1. Read `cronHealth.lastCronFire` timestamp (legacy field name — tracks the tick heartbeat)
2. Calculate how long ago that was
3. If more than <!--CONFIG:WATCHDOG_THRESHOLD-->10<!--/CONFIG:WATCHDOG_THRESHOLD--> minutes have passed:
   - The bmad-dev-loop tick has died silently
   - Alert the human: "[TICK-DEAD] Claw Loop tick hasn't fired in [X] minutes. Recovering now."
   - Recover by re-bootstrapping the `ai.clawbot.tick` LaunchAgent (`launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/ai.clawbot.tick.plist`) or kickstarting it if already loaded
   - Update state: cronHealth.cronStatus = "recovered"
   - Log: "CRON_RECOV | downtime:Xmin | action:watchdog-recovered"  (event tag kept for log-format continuity)
4. If less than <!--CONFIG:WATCHDOG_THRESHOLD-->10<!--/CONFIG:WATCHDOG_THRESHOLD--> minutes: tick is healthy, no action needed
```

Add to your **MEMORY.md**:

```markdown
## Active Automations
- **Claw Loop v2.4** is active for project [PROJECT_NAME] at [PROJECT_PATH]. State file: memory/bmad-dev-state.json. Activity log: [PROJECT_PATH]/_bmad-output/implementation-artifacts/claw-loop-activity.log. If status is "running", the bmad-dev-loop tick (LaunchAgent `ai.clawbot.tick`) should be firing every <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL--> minutes. See HEARTBEAT.md for watchdog instructions.
```

## Step 11: Verify Everything Works

☐ Capture the tmux pane and show the human what you see
☐ Show the parsed sprint-status.yaml queue summary
☐ Show the claw-loop-model-strategy.yaml summary
☐ Confirm the activity log was created with the branded header
☐ Confirm the HEARTBEAT.md watchdog was added
☐ Confirm the MEMORY.md entry was added
☐ Send a status update on the messaging channel
☐ Confirm the tick LaunchAgent is loaded (`launchctl print gui/$(id -u)/ai.clawbot.tick`) and will fire shortly
☐ Tell the human: "Claw Loop v2.4 is live. Fixed <!--CONFIG:CRON_INTERVAL-->3<!--/CONFIG:CRON_INTERVAL-->-min tick with smart-skip on [channel]. Starting: Story [X.X] [name] (model: [tier] → [model]). Queue: [N] stories across [M] epics. Model strategy: [X] epics highest, [Y] epics standard. Watchdog active. Say 'pause loop' anytime to stop."

---

# TICK PROCEDURE — Reference File Content

**This is the text that gets saved to `memory/claw-loop-procedure.md` during Step 7.**
**The Clawdbot reads this file on its first tick fire, after a `/clear`, or whenever it needs to re-orient. It is NOT injected into the tick payload every fire — the lightweight tick ping (Step 8) tells the bot where to find this file.**

```
<cron-rules>
⛔ IMMUTABLE RULES — These override everything below. Violating any of these is a critical failure.

1. NEVER send Enter to a working Claude Code — only send input when CC is idle or asking a question
2. NEVER advance a story with failing tests — re-run dev-story until tests pass
3. NEVER advance a story that code-review found HIGH/CRITICAL issues on — re-run code-review (max <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> passes)
4. NEVER skip a story automatically — after 3 failures, pause and alert the human
5. NEVER hardcode model names — always resolve from claw-loop-model-strategy.yaml
6. ALWAYS send text and Enter as SEPARATE tmux send-keys calls — never combine them
7. ALWAYS /clear between major step transitions (create→dev→review)
8. ALWAYS include story number in slash commands (e.g., /bmad-dev-story 8.1)
9. ALWAYS update the state file after any action — it is your only memory
10. ALWAYS report every tick fire to the human — silence means the loop is dead
11. ALWAYS respect HALTs — stop and alert, never respond to a HALT
12. The loop NEVER blocks more than one tick cycle — after one diagnostic cycle, take autonomous action
</cron-rules>

BMAD V6 DEV LOOP — Execute these steps IN ORDER, every tick fire:

<cron-step id="0" name="heartbeat-and-smart-skip">
☐ STEP 0: HEARTBEAT + SMART-SKIP (do this FIRST, every fire, no exceptions)

  ☐ 0a. Write heartbeat timestamp to state file:
    → state.cronHealth.lastCronFire = NOW
    → state.cronHealth.consecutiveFires += 1
    → state.cronHealth.cronStatus = "healthy"

  ☐ 0b. Smart-skip check:
    → Read state.lastActionAt and state.currentStepType
    → Calculate elapsed = NOW - lastActionAt

    IF currentStepType == "dev-story" AND elapsed < 5 min:
      THEN → skip this cycle (dev work needs time to load context)
      ACTION: Log to activity log: "CRON_SKIP | reason:smart-skip(elapsed<5min)"
      STATE: cronHealth updated (already done in 0a)
      → EXIT tick

    IF currentStepType == "code-review" AND elapsed < 4 min:
      THEN → skip this cycle
      ACTION: Log "CRON_SKIP | reason:smart-skip(elapsed<4min)"
      → EXIT tick

    IF currentStepType == "create-story" AND elapsed < 2 min:
      THEN → skip this cycle
      ACTION: Log "CRON_SKIP | reason:smart-skip(elapsed<2min)"
      → EXIT tick

    IF state is idle, transition, stall, or prompt detected:
      THEN → ALWAYS PROCEED (no skip)

    ELSE → PROCEED with full tick logic below
</cron-step>

<cron-step id="1" name="capture-pane">
☐ STEP 1: CAPTURE PANE

  ACTION: tmux -S "$HOME/.clawbot/clawdbot.sock" capture-pane -p -J -t bmad-agent:0.0 -S -50
  ℹ️ Capture 50 lines for better context
  ⛔ Text and Enter are ALWAYS separate tmux send-keys calls throughout this procedure
</cron-step>

<cron-step id="2" name="read-state-and-validate">
☐ STEP 2: READ STATE + VALIDATE MODEL STRATEGY

  ☐ 2a. Read memory/bmad-dev-state.json
    → Extract: currentStory, currentStoryNumber, currentStep, status, reviewPassNumber, failureCount, stallCount, paneFingerprint, modelStrategy, pendingPrompt, gitVerification

  ☐ 2b. Read + VALIDATE claw-loop-model-strategy.yaml from state.modelStrategy.modelStrategyFile

    VALIDATION — the file MUST contain ALL of these keys:
    - model_tier_mapping.highest (non-empty string)
    - model_tier_mapping.standard (non-empty string)
    - step_defaults.create_story, step_defaults.code_review, step_defaults.dev_story
    - epic_overrides (object, can be empty)

    IF VALIDATION FAILS (missing keys, YAML parse error, file not found):
      THEN → use safe fallback
      STATE: state.modelStrategy.fallbackActive = true
      ACTION: Use SAFE DEFAULTS: highest → opus, standard → sonnet, ALL steps use "highest"
      ACTION: Alert human: "[MODEL-FALLBACK] claw-loop-model-strategy.yaml is invalid. Using all-highest fallback."
      ACTION: Log "MODEL_FALLBACK | reason:<parse-error|missing-keys|file-not-found>"

    IF VALIDATION PASSES:
      STATE: state.modelStrategy.fallbackActive = false
      → Proceed normally
</cron-step>

<cron-step id="3" name="stall-detection">
☐ STEP 3: STALL DETECTION (semantic fingerprinting)

  ☐ 3a. Take captured pane (last 50 lines from Step 1)

  ☐ 3b. STRIP NOISE before fingerprinting — remove lines matching ANY of:
    - Spinner/progress characters (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏, ◐◓◑◒, ●○, etc.)
    - Lines starting with "Reading file", "Writing file", "Searching", "Editing file"
    - Lines that are only whitespace, box-drawing characters (─│┌┐└┘), or horizontal rules
    - Lines matching "Compressing conversation..." or "Context window:" percentage displays

  ☐ 3c. From remaining lines, take last 10 "meaningful" lines

  ☐ 3d. Hash those lines as paneFingerprint

  ☐ 3e. Compare to state.paneFingerprint:
    IF identical: → state.stallCount += 1
    IF different: → state.stallCount = 0, state.paneFingerprint = new hash

  ☐ 3f. Escalation:
    IF stallCount >= 3:
      THEN → Tier 1: Soft stall recovery
      ACTION: Send Enter key via tmux
      ACTION: Log "STALL_T1 | story:X.X | step:STEP | stallCount:N | action:sent-enter"

    IF stallCount >= 5 AND pane contains "context" or "token limit" or "compressing":
      THEN → Tier 2: Context overflow
      ACTION: Send '/clear' then Enter, wait 3s, re-send current step command
      ACTION: Log "STALL_T2 | action:clear-resend"

    IF stallCount >= 5 AND no context overflow detected:
      THEN → Tier 3: Hard stall
      ACTION: Kill CC, restart with 'claude' + Enter, wait 8s, re-send current command
      ACTION: Alert human: "Hard stall on story X.X — killed and restarted CC"
      ACTION: Log "STALL_T3 | action:kill-restart"

    IF failureCount >= 3:
      THEN → Tier 4: Repeated failure — STOP
      ACTION: state.status = "human-review-needed"
      ACTION: Alert human: "Story X.X has failed 3 times. Pausing for human review."
      ACTION: Log "STALL_T4 | action:paused-for-human"
      ⛔ Do NOT skip the story. Do NOT continue. Wait for human.
</cron-step>

<cron-step id="4" name="decide-and-act">
☐ STEP 4: DECIDE + ACT based on pane output

  Read the captured pane and match against these conditions in order.
  ⛔ For ALL tmux commands below: send text and Enter as SEPARATE send-keys calls.
  ⛔ For ALL slash commands below: ALWAYS include story number (e.g., /bmad-dev-story 8.1).

  <condition id="4a" trigger="CC is WORKING">
  IF pane shows spinner, tool calls, "Reading file", "Writing file", progress indicators:
    THEN → no action needed, CC is working
    STATE: consecutiveIdleCycles = 0
    → Proceed to STEP 5
  </condition>

  <condition id="4b" trigger="BMAD template-output checkpoint">
  IF pane shows "[a] Advanced Elicitation, [c] Continue, [p] Party-Mode, [y] YOLO":
    THEN → continue to next section
    ACTION: Send 'c' via tmux, then send Enter separately
    ⚠️ Do NOT send 'y' — that skips all remaining checkpoints and reduces quality
    ACTION: Log "PROMPT_RESP | prompt:[a][c][p][y] | sent:c"
    STATE: consecutiveIdleCycles = 0
  </condition>

  <condition id="4c" trigger="code-review decision point">
  IF pane shows "Choose [1], [2], or specify which issue to examine":
    THEN → fix automatically (autonomous fix path)
    ACTION: Send '1' via tmux, then send Enter separately
    ACTION: Log "PROMPT_RESP | prompt:Choose[1][2] | sent:1"
    STATE: consecutiveIdleCycles = 0
  </condition>

  <condition id="4d" trigger="dev-story discovery — no ready stories">
  IF pane shows "Choose option [1], [2], [3], or [4]" AND currentStep is dev-story:
    THEN → queue has no ready stories, need create-story first
    ACTION: Send '1' via tmux, then send Enter separately
    STATE: currentStep = "create-story"
    ACTION: Log "PROMPT_RESP | prompt:Choose-option[1-4] | sent:1"
  </condition>

  <condition id="4e" trigger="CC asks which story or file">
  IF pane shows "Which story", "what story", "which file", "story file", "What should I work on", "what would you like me to", "provide the story file path":
    THEN → CC doesn't know which story to work on — give it the file path directly
    ACTION: Run STORY FILE RESOLUTION to get path
    IF currentStoryFilePath is set:
      ACTION: Send '<currentStoryFilePath>' via tmux, then send Enter separately
      ℹ️ CC is waiting for a path — just send the path, CC will use it
    ELSE:
      ACTION: Send '_bmad-output/implementation-artifacts/' via tmux, then send Enter separately
      ℹ️ Fallback — gives CC the directory to search. It will find the story file itself.
    ACTION: Log "PROMPT_RESP | prompt:which-story | sent:<path>"
    STATE: consecutiveIdleCycles = 0
  </condition>

  <condition id="4e2" trigger="generic continue prompt">
  IF pane shows "(y/n)" or "(y/n/edit)" or "Continue to next step?":
    THEN → continue
    ACTION: Send 'y' via tmux, then send Enter separately
    ACTION: Log "PROMPT_RESP | prompt:(y/n) | sent:y"
  </condition>

  <condition id="4f" trigger="HALT detected">
  IF pane contains "HALT":
    THEN → STOP IMMEDIATELY
    ⛔ DO NOT send any input to CC
    STATE: status = "halted", notes = HALT message text
    ACTION: Alert human: "CC HALTED on story X.X: [halt reason]"
    ACTION: Log "STALL_T4 | action:halt-detected"
    → Do NOT continue. Wait for human.
  </condition>

  <condition id="4g" trigger="CC is IDLE">
  IF pane shows blank prompt, no command typed, CC is waiting for input:
    STATE: consecutiveIdleCycles += 1

    IF this is a step transition (CC just finished a step):
      THEN → execute STEP TRANSITIONS below (condition 4h)

    IF CC was already idle last cycle (consecutiveIdleCycles > 1):
      THEN → re-send current step command with story file path as argument
      ACTION: Build the command: '<current-slash-command> <currentStoryFilePath>'
        → For dev-story: '/bmad-dev-story <currentStoryFilePath>'
        → For code-review: '/bmad-code-review <currentStoryFilePath>'
        → For create-story: '/bmad-create-story <currentStoryNumber>'
      ACTION: Send the built command via tmux, then Enter separately
  </condition>

  <condition id="4h" trigger="step transition">
  STEP TRANSITIONS — Execute when CC has completed a step and is idle.
  ⛔ Use /clear for transitions, NOT kill+restart.

  --- STORY FILE RESOLUTION (use this to find the current story file path) ---
  The Clawdbot MUST know the story file path so CC never has to ask "which story?"

  WHY THIS MATTERS: BMAD slash commands accept the story file path as an argument.
  - dev-story uses it directly as {{story_path}} — skips auto-discovery entirely
  - code-review uses it as {{story_path}} — skips asking "which story file to review?"
  - create-story reads sprint-status.yaml — no path needed, but story number helps

  HOW TO RESOLVE:
  1. Check state.currentStoryFilePath — if set and non-null, use it
  2. IF null or after create-story completes:
     → Scan the pane output for the story file path (create-story prints it when it saves the file)
     → OR search the project directory for files matching: _bmad-output/implementation-artifacts/*<currentStory>*.md
     → OR read sprint-status.yaml to find the story key, then match to a file
  3. Store the resolved path: STATE: currentStoryFilePath = resolved path

  HOW TO USE: Pass the story file path directly as an argument to the slash command:
  ⛔ WRONG:  '/bmad-dev-story 2.3'           ← CC may not find the file
  ⛔ WRONG:  '/bmad-code-review'              ← CC will ask "which story?"
  ✅ RIGHT:  '/bmad-dev-story <currentStoryFilePath>'
  ✅ RIGHT:  '/bmad-code-review <currentStoryFilePath>'
  ✅ RIGHT:  '/bmad-create-story <currentStoryNumber>'

  The file path goes right after the slash command on the same line.
  CC reads it as the story_path argument and starts working immediately — no questions asked.
  --- END STORY FILE RESOLUTION ---

  --- MODEL RESOLUTION PROCEDURE (use this every time you need to set a model) ---
  1. Read claw-loop-model-strategy.yaml (loaded in Step 2b)
  2. IF step is create-story or code-review:
       → tier = "highest" (always)
     IF step is dev-story:
       → Check story_overrides[currentStoryKey] — use if found
       → ELSE check epic_overrides["epic-" + currentEpic] — use if found
       → ELSE use step_defaults.dev_story
  3. Map tier to model name: model_tier_mapping[tier] (e.g., "highest" → "opus")
  4. Send '/model <resolved-name>' via tmux, then Enter separately, wait 10s
  5. STATE: modelStrategy.currentModel = resolved name, modelStrategy.currentModelTier = tier, modelStrategy.modelSource = where it came from
  ⛔ NEVER send a hardcoded model name. ALWAYS resolve from the file.
  --- END MODEL RESOLUTION ---

  IF create-story just completed (pane shows story file path, "Story Status: ready-for-dev"):
    THEN → transition to dev-story
    ⚠️ CAPTURE STORY FILE PATH from pane output — create-story prints the path to the generated story file
    STATE: currentStoryFilePath = extracted path (e.g., "_bmad-output/implementation-artifacts/story-2-3-checklist-builder.md")
    ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
    ACTION: Run MODEL RESOLUTION for dev-story
    ACTION: Run STORY FILE RESOLUTION to confirm path is set
    ACTION: Send '/bmad-dev-story <currentStoryFilePath>' via tmux, then Enter separately
    ℹ️ The file path is passed as an argument — CC uses it as {{story_path}} and starts immediately, no questions
    STATE: currentStep = "dev-story", lastActionAt = NOW
    ACTION: Log "TRANSITION | from:create-story | to:dev-story | model:X→Y | storyFile:<path>"

  IF dev-story just completed (pane shows "Story status updated to review"):
    ⛔ FIRST: Check pane for test results before advancing

    IF pane contains "FAIL" or "failed" or "X failed" in test output:
      THEN → tests failed, DO NOT advance to code-review
      ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
      ACTION: Send '/bmad-dev-story <currentStoryFilePath>' via tmux, then Enter separately
      ℹ️ CC will re-read the story file and see failing tests — it knows what to fix
      STATE: failureCount += 1
      ACTION: Alert human: "Tests failing on story X.X — re-running dev-story"
      ACTION: Log "CRON_FIRE | action:test-failure-retry"
      IF failureCount >= 2 on consecutive test failures:
        STATE: status = "human-review-needed"
        ACTION: Alert human

    IF tests passed (pane shows "All tests pass", "Tests passed", 0 failures):
      THEN → transition to code-review
      ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
      ACTION: Run MODEL RESOLUTION for code-review (always highest)
      ACTION: Run STORY FILE RESOLUTION to confirm path is set
      ACTION: Send '/bmad-code-review <currentStoryFilePath>' via tmux, then Enter separately
      ℹ️ The file path is passed as an argument — CC uses it as {{story_path}} and reviews immediately, no questions
      STATE: currentStep = "code-review", lastActionAt = NOW
      ACTION: Log "TRANSITION | from:dev-story | to:code-review | storyFile:<path>"

  IF code-review just completed:
    ⚠️ CRITICAL QUALITY GATE — Parse pane for review outcome:
    → Extract: Story Status ("done" or "in-progress")
    → Extract: Issues Fixed count
    → Extract: Action Items Created count
    → Look for severity counts: "X High, Y Medium, Z Low"
    → Look for HIGH or CRITICAL issues found and fixed

    ⛔ Dev-story NEVER re-runs. Code-review always fixes issues in-place (Option 1).
    ⛔ The ONLY loop is code-review → code-review (max <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> passes total).

    IF pane shows HIGH or CRITICAL issues were found (regardless of whether status says "done"):
      → Issues were fixed in-place. Re-review needed to verify fixes.

      IF reviewPassNumber >= <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->:
        THEN → Max review passes reached. Story is DONE — move on.
        ACTION: Alert human: "Story X.X advancing after <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> review passes. Some issues may remain."
        ACTION: Log "REVIEW_DONE | outcome:max-passes-reached | pass:<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->of<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> | action:advancing"
        → Proceed to GIT VERIFICATION below

      ELSE:
        STATE: reviewPassNumber += 1, lastReviewOutcome = "high-found-rereviewing"
        ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
        ACTION: Run MODEL RESOLUTION for code-review (always highest)
        ACTION: Send '/bmad-code-review <currentStoryFilePath>' via tmux, then Enter separately
        ℹ️ Fresh context reviews the fixes from the previous pass
        STATE: lastActionAt = NOW
        ACTION: Log "REVIEW_DONE | outcome:high-found | pass:Nof3 | action:re-review"

    IF pane contains "Story Status: done" AND NO HIGH or CRITICAL issues found:
      → Story APPROVED — clean review. Proceed to GIT VERIFICATION:

        --- GIT VERIFICATION (mandatory after every STORY_DONE) ---
        1. Send '/clear' via tmux, then Enter separately, wait 3s
        2. Send: "Run git status and git log --oneline -5. Show me the output." via tmux
        3. On NEXT tick fire, capture pane and check:
           IF commit found referencing the story (story number, name, or "story" keyword):
             → Git verified
             ACTION: Log "GIT_VERIFIED | story:X.X | commit:<hash>"
             → Proceed to ADVANCE below
           IF no commit found OR uncommitted changes exist:
             → Request commit
             ACTION: Send '/clear' then: "There are uncommitted changes from story X.X. Please commit all changes with message: 'feat(story-X.X): <story name> — implementation complete'"
             STATE: gitVerification.pendingVerification = true, gitVerification.verificationAttempts += 1
             → Wait one cycle, verify on next fire
           IF gitVerification.verificationAttempts >= 2:
             → Give up on git, proceed anyway
             ACTION: Alert human: "[GIT-ISSUE] Story X.X completed but changes aren't committed."
             ACTION: Log "GIT_ISSUE | story:X.X | action:alerted-human-proceeding"
             → Proceed to ADVANCE below

        ℹ️ git works 100% locally. No GitHub remote is required.
        ℹ️ Story 1.1 (Project Initialization) MUST include git init.
        --- END GIT VERIFICATION ---

        ADVANCE to next story:
        STATE: Move currentStory to completedStories
        STATE: Advance currentStory to next in storyQueue
        STATE: currentStep = "create-story"
        STATE: Reset failureCount = 0, reviewPassNumber = 1
        STATE: totalStoriesCompleted += 1
        STATE: gitVerification.pendingVerification = false, gitVerification.verificationAttempts = 0

        ⚠️ EPIC BOUNDARY CHECK:
        IF all stories in currentEpic show "done" in sprint-status.yaml:
          STATE: totalEpicsCompleted += 1
          ACTION: Alert human: "Epic N complete! All X stories done."
          ACTION: Log "EPIC_DONE | epic:N | stories:X | total_duration:Nmin"
          ℹ️ Optionally suggest: "Consider running /bmad-retrospective for Epic N"
          ℹ️ RETROACTIVE MODEL ANALYSIS (recommended):
            - If "standard" epic averaged 3+ review passes → log warning, consider upgrading similar epics
            - If "highest" epic averaged <1 review loop → log note (do NOT auto-downgrade)

        ⚠️ SPRINT-STATUS SYNC: Read sprint-status.yaml to verify completed story shows "done"

        STATE: currentStoryFilePath = null (new story, no file yet — create-story will generate it)
        STATE: metrics.currentStoryStartedAt = NOW (new story timer starts)
        STATE: metrics.currentStoryCronFires = 0
        ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
        ACTION: Run MODEL RESOLUTION for create-story (always highest)
        ACTION: Send '/bmad-create-story <currentStoryNumber>' via tmux, then Enter separately
        ℹ️ create-story reads sprint-status.yaml; the story number helps it find the right one
        STATE: lastActionAt = NOW
        ACTION: Log "STORY_DONE | story:X.X | duration:NNmin | cron_fires:N | review_loops:N | review_passes:N | dev_model:TIER"
        ℹ️ duration = NOW - metrics.currentStoryStartedAt (of the COMPLETED story, calculated before resetting the timer)
        ACTION: Log "TRANSITION | from:code-review | to:create-story"

    IF pane contains "Story Status: in-progress" OR "Action Items Created: N" where N > 0:
      ℹ️ This means code-review chose Option 2 (action items) instead of Option 1 (fix in-place).
      ℹ️ The Claw Loop always sends "1" (fix automatically), so this should be rare.
      ℹ️ Treat this the same as HIGH issues found — re-run code-review to fix and verify.

      IF reviewPassNumber >= <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->:
        THEN → Max review passes reached. Story is DONE — move on.
        ACTION: Alert human: "Story X.X advancing after <!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> review passes. Action items may remain."
        ACTION: Log "REVIEW_DONE | outcome:max-passes-action-items | pass:<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->of<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES--> | action:advancing"
        → Proceed to GIT VERIFICATION above

      ELSE:
        STATE: reviewPassNumber += 1, lastReviewOutcome = "action-items-rereviewing"
        ACTION: Send '/clear' via tmux, then Enter separately, wait 3s
        ACTION: Run MODEL RESOLUTION for code-review (always highest)
        ACTION: Send '/bmad-code-review <currentStoryFilePath>' via tmux, then Enter separately
        ℹ️ Re-running code-review — it will fix issues in-place this time (Option 1)
        STATE: lastActionAt = NOW
        ACTION: Log "REVIEW_DONE | outcome:action-items | pass:Nof3 | action:re-review"
  </condition>

  <condition id="4i" trigger="CC exited to shell">
  IF pane shows shell prompt, no Claude Code running:
    THEN → restart CC (this is the ONLY time to restart)
    ACTION: Send 'claude' via tmux, then Enter separately, wait 8s
    ACTION: Re-send current step's slash command
    ACTION: Log "CRON_FIRE | action:cc-restarted"
  </condition>

  <condition id="4j" trigger="unrecognized prompt">
  IF pane shows CC asking something that doesn't match any pattern above:

    ⚠️ TWO-PASS PROTOCOL — the loop NEVER blocks more than one tick cycle

    IF state.pendingPrompt == false (FIRST encounter):
      THEN → diagnostic cycle — alert human but do NOT respond to CC
      STATE: pendingPrompt = true
      STATE: pendingPromptText = first 100 chars of the prompt
      STATE: pendingPromptFirstSeen = NOW
      ACTION: Alert human: "[UNKNOWN-PROMPT] CC is asking: '<text>'. Will auto-respond next cycle unless you send a command."
      ⛔ Do NOT send any input to CC this cycle.

    IF state.pendingPrompt == true (SECOND encounter — same prompt still visible):
      THEN → auto-respond using smart heuristic
      ACTION: Check if human sent a command since last cycle — if yes, execute human's command instead
      IF no human command:
        IF prompt contains explicit (y/n) → send 'y'
        IF prompt contains numbered options [1], [2]... → send '1'
        IF prompt contains "continue" or "proceed" → send 'y'
        ELSE → send 'c'
      STATE: pendingPrompt = false
      ACTION: Log "PROMPT_AUTO | prompt:<text> | sent:<response>"
  </condition>
</cron-step>

<cron-step id="4.5" name="post-command-verification">
☐ STEP 4.5: POST-COMMAND VERIFICATION (run after ANY command was sent to CC this cycle)

  IF you sent a slash command, response, or any input to CC during Step 4:

  ☐ 4.5a. Wait 10 seconds — give CC time to process the command

  ☐ 4.5b. Re-capture the pane:
    ACTION: tmux -S "$HOME/.clawbot/clawdbot.sock" capture-pane -p -J -t bmad-agent:0.0 -S -30

  ☐ 4.5c. Evaluate what CC is doing NOW:

    IF CC is WORKING (spinner, tool calls, "Reading file", progress indicators):
      → Command landed successfully. CC accepted it and is executing.
      STATE: notes = "Command accepted, CC working"
      → Proceed to STEP 5 (report and exit)

    IF CC is asking a QUESTION ("Which story", "which file", numbered options, y/n prompt):
      → Command landed but CC needs more info. Answer it NOW — don't wait for next tick.
      ACTION: Apply the same decision logic from Step 4 conditions (4b through 4e) to answer the question
      ACTION: Log "POST_VERIFY | action:answered-followup-question"
      STATE: notes = "Answered follow-up question after command"
      → Proceed to STEP 5

    IF CC is IDLE (blank prompt, command doesn't appear to have been received):
      → Command may not have landed. Re-send it.
      ACTION: Re-send the same command via tmux, then Enter separately
      ACTION: Log "POST_VERIFY | action:resent-command"
      STATE: notes = "Command didn't land, resent"
      → Proceed to STEP 5

    IF CC shows an ERROR or unexpected output:
      → Log what happened for the human
      ACTION: Log "POST_VERIFY | action:error-detected | details:<first 100 chars>"
      STATE: notes = "Error after command: <summary>"
      → Proceed to STEP 5

  IF you did NOT send any input to CC this cycle (CC was working, or cycle was skipped):
    → Skip this step entirely. Proceed to STEP 5.

  ℹ️ This step ensures the Clawdbot never goes to sleep without confirming CC is actually working.
  ℹ️ The 10-second window catches immediate failures, follow-up questions, and dropped commands.
</cron-step>

<cron-step id="5" name="log-report-verify">
☐ STEP 5: LOG, REPORT, AND VERIFY (do this EVERY cycle, including skips)

  ☐ 5a. Append activity log entry to _bmad-output/implementation-artifacts/claw-loop-activity.log:
    → Format: TIMESTAMP | EVENT_TYPE | story:X.X | step:STEP | model:MODEL(TIER) | action:ACTION
    → Log every tick fire (CRON_FIRE or CRON_SKIP)
    → On STORY_DONE: push completed story metrics to state.metrics.completedStoryMetrics

  ☐ 5b. Update state.metrics:
    → state.metrics.currentStoryCronFires += 1
    → state.metrics.totalCronFires += 1

  <!--CONFIG:SECTION:CRON_STEP_5C-->
☐ 5c. Send report to human on [CHANNEL] (target: [TARGET_ID]):

    ⛔ USE THIS EXACT FORMAT — no freestyling, no narrative, no cheerleading.

    → Calculate elapsed: NOW - metrics.currentStoryStartedAt (round to nearest minute)

    **[WORKING]** (CC active, no intervention):
    ```
    [WORKING] Story X.X | <step> | <elapsed> min | <Model>
    SAW: <1 line, max ~80 chars — what CC is doing, context % only if ≥50%>
    ACTION: None — <brief reason>
    PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
    ```

    **[TRANSITION]** (bot took action to advance pipeline):
    ```
    [TRANSITION] Story X.X | <from-step> → <to-step> | <elapsed> min
    SAW: <1 line — what triggered the transition>
    ACTION: <commands sent>
    PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
    STATS: <elapsed> min | <N> cycles | <N> review passes | <model tier>
    ```

    **[DONE]** (story complete — only on STORY_DONE):
    ```
    [DONE] Story X.X — <Story Name> ✅
    SAW: <what confirmed completion>
    ACTION: Advancing to story Y.Y
    PROGRESS: Story <N>/<Total> complete | Epic <N> (<M> remaining)
    STATS: <elapsed> min | <N> cycles | <N> review passes | <model tier>
    ```

    **[STALL]** (escalation triggered):
    ```
    [STALL] Story X.X | <step> | Tier <N> ⚠️
    SAW: <what indicates the stall>
    ACTION: <recovery action taken>
    PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
    ```

    **[NEEDS-HUMAN]** / **[HALTED]**:
    ```
    [NEEDS-HUMAN] Story X.X | <step> ⚠️
    SAW: <what went wrong>
    ACTION: Loop paused — awaiting human input
    PROGRESS: Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
    ```

    Format rules:
    - Line 1: ALWAYS [STATUS] + story + key info — glanceable in 1 second
    - SAW: ALWAYS one line, max ~80 chars
    - ACTION: ALWAYS one line
    - PROGRESS: ALWAYS same format — Story N/Total | Epic N | Review pass: N/<!--CONFIG:MAX_REVIEW_PASSES-->3<!--/CONFIG:MAX_REVIEW_PASSES-->
    - STATS: ONLY on [DONE] and [TRANSITION]
    - No emojis except ✅ on [DONE] and ⚠️ on problems
    - No "Next cycle:" predictions, no token counts, no fire counts, no commentary
<!--/CONFIG:SECTION:CRON_STEP_5C-->
☐ 5d. ⛔ MODEL VERIFICATION (after any /model command was sent this cycle):
    → On the NEXT cycle, capture pane and verify CC acknowledged the model switch
    → If pane doesn't reflect expected model, re-send the /model command

  <cron-checklist>
  ☐ CYCLE VERIFICATION — Before exiting, confirm ALL of these:
    ☐ state.lastUpdated written with current timestamp
    ☐ state.paneFingerprint updated (even if unchanged)
    ☐ Activity log entry appended (CRON_FIRE or CRON_SKIP)
    ☐ Report sent to human
    ☐ All state changes from this cycle written to state file
    ☐ No pending actions left unexecuted
  </cron-checklist>
</cron-step>
```

---

## How to Control the Loop

Tell your Clawdbot any of these:

- **"Pause the loop"** — Disables the tick, CC keeps running but won't get new commands
- **"Resume the loop"** — Re-enables the tick from where it left off
- **"Skip this story"** — Marks story as skipped in state, advances to next
- **"Stop the loop"** — Kills CC and disables the tick
- **"Loop status"** — Shows current story, step, test results, review loop count, queue remaining, epic progress
- **"Switch to conservative"** — Changes escalation mode, pauses on any stall
- **"Switch to autonomous"** — Returns to default autonomous stall handling
- **"Run retrospective"** — Pauses the loop and runs `/bmad-retrospective` for the current epic
- **"Force advance"** — Overrides quality gate and advances to next story (use with caution)
- **"Quarantine story X.X"** — Removes a problematic story from the queue without skipping:
  1. Mark story as "quarantined" in state (distinct from "skipped" or "done")
  2. Log: `QUARANTINE | story:X.X | reason:<human's reason>`
  3. Continue with next story
  4. Quarantined stories appear in daily summary
  5. Human can later say **"Unquarantine story X.X"** to restore it

---

## END OF PROMPT — STOP COPYING HERE

---

## Notes for the person sharing this:

- The recipient needs Clawdbot installed and running with at least one messaging channel
- They need Claude Code (`claude` CLI) installed and authenticated
- They need a BMAD V6 project with slash commands in `.claude/commands/`
- The project must have `_bmad-output/implementation-artifacts/sprint-status.yaml` (run `/bmad-sprint-planning` first)
- The prompt walks the Clawdbot through setup step by step
- Works with any messaging channel Clawdbot supports

## Key Differences from Previous Versions

| Feature | v1.2 | v2.2 | v2.3 | v2.4 |
|---------|------|------|------|------|
| Document structure | Single flow | Single flow | CONCEPTS + EXECUTE + self-contained CRON | CONCEPTS + EXECUTE + procedure file + lightweight cron |
| Cron systemEvent | Cross-references setup | Cross-references setup | Fully self-contained, zero external refs | Lightweight ping (~800 chars) + procedure reference file |
| Context management | None | None | None (18KB injected every fire) | Just-in-time: read procedure file only when needed |
| Session strategy | Shared main session | Shared main session | Shared main session | `isolatedSession` + `lightContext` recommended |
| Critical rules | End of document | End of document | TOP of cron as immutable preamble | Key rules in cron ping, full rules in procedure file |
| Cycle verification | None | None | End-of-cycle checklist with ☐ markers | End-of-cycle checklist with ☐ markers |
| Decision format | Prose paragraphs | Prose paragraphs | IF/THEN/ACTION/STATE blocks | IF/THEN/ACTION/STATE blocks |
| Structural markers | Markdown only | Markdown only | XML tags + severity markers (⛔/⚠️/ℹ️) | XML tags + severity markers (⛔/⚠️/ℹ️) |
| Model selection | Hardcoded | Pre-computed from YAML | Pre-computed + validate-on-read + fallback | Pre-computed + validate-on-read + fallback |
| Unrecognized prompts | Send `c` blindly | Two-pass protocol | Two-pass (inline in cron, no cross-ref) | Two-pass (inline in procedure file) |
| Git safety | None | Commit verification | Commit verification (inline in cron) | Commit verification (inline in procedure file) |
| Daily rollup | None | Separate cron | Separate cron | Separate cron |
| Quarantine | None | Quarantine command | Quarantine command | Quarantine command |
| Stall fingerprinting | Raw hash | Semantic (noise stripped) | Semantic (inline in cron) | Semantic (inline in procedure file) |
| Token cost per fire | ~18K chars | ~18K chars | ~18K chars | ~800 chars (96% reduction) |

*Based on The Claw Loop by Don't Sleep On AI — February 2026*
*Enhanced for BMAD V6 by ShiftCheck V3 project — March 2026*
*v2.3 structural rewrite overseen by Winston (BMAD Architect) with input from Amelia, Bob, and Paige*
*v2.4 context optimization: lightweight tick ping + procedure reference file pattern — March 2026*
*https://dontsleeponai.com*

---

**DISCLAIMER:** This prompt and the Claw Loop workflow are provided "as is" for research and educational purposes only. Don't Sleep On AI makes no warranties, express or implied, regarding the reliability, accuracy, or completeness of this workflow. Use at your own risk. The authors assume no responsibility or liability for any errors, omissions, damages, or losses arising from the use of this material, including but not limited to data loss, unintended code changes, API costs, or system disruptions. Users are solely responsible for reviewing all outputs, monitoring automated processes, and ensuring appropriate safeguards are in place before deploying any autonomous workflow. This is not professional software engineering advice. Always back up your work.

