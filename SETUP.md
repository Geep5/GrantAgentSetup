# Agent Setup — instructions for the INSTALLING AGENT

You are an AI agent setting up this bridge bot on a new machine. This repo is
the blueprint; your job is to fill in the blanks, verify each layer as you
wire it, and leave a working, self-scheduling Discord agent behind. A human
is available to answer questions and do the steps only they can do (OAuth
clicks, Discord portal, secrets).

Work through the phases in order. **Verify each phase before moving on** —
every check here exists because skipping it cost a real debugging session.

## Phase 0 — interview the human

Collect (ask in ONE batched message, not a drip):

1. **Agent identity**: display name, one-line role, project description.
2. **Discord**: bot token (create an app at discord.com/developers if needed —
   the bot needs no privileged intents; REST polling only), the channel ID for
   conversations (developer mode → right-click channel → Copy ID), and the
   server invite if the bot isn't in the guild yet
   (`https://discord.com/oauth2/authorize?client_id=<APP_ID>&scope=bot&permissions=117824`).
3. **Anytype**: is Anytype installed and running locally? Which space? Get an
   app key (Anytype → Settings → API keys, or reuse an existing MCP
   registration's bearer). If no Anytype: the bot still works, but loses the
   task board + deferred sends — confirm they want that.
4. **omp**: is `omp` installed (`omp --version`)? Which model (default: opus)?
5. **Optional extras**: peer bot channel? Crony dashboard file? Remotion?
   browseruse? presence daemon (bot shows online 24/7)?

## Phase 1 — prerequisites (verify, don't assume)

- **Python ≥ 3.10**: `python3 --version`. On macOS python.org installs, HTTPS
  fails until certificates are installed — test with
  `python3 -c "import urllib.request; urllib.request.urlopen('https://discord.com')"`.
  If SSL errors: run `/Applications/Python*/Install Certificates.command`.
  Record the working interpreter as `PYTHON_BIN` in .env.
- **omp**: `omp -p --no-session "Reply with exactly: OK"` must print OK. If it
  errors about credentials, the human runs `omp` interactively and `/login`.
  Note: omp's OAuth refresh tokens can expire — this exact failure mode will
  recur someday; the bot posts a clear error to the channel when it does.
- **Anytype API** (if used): `curl -s http://localhost:31009/v1/spaces -H
  "Authorization: Bearer <key>" -H "Anytype-Version: 2025-11-08"` returns JSON.

## Phase 2 — Anytype board (if used)

1. Find or create the task type in the target space (layout `action`), e.g.
   key `myproject_task`. The type object's ID doubles as the list/board ID —
   `GET /spaces/$S/lists/<type_id>/views/default/objects` works directly.
2. Ensure these properties exist in the space and are attached to the type
   (create with explicit snake_case keys — auto-generated keys from emoji
   names come out mangled like `[?]_send_date`):
   - `status` (select; tags: To Do / In Progress / Waiting / Done)
   - `next_action` (text) · `done` (checkbox) · `send_date` (date)
   - optionally `area` (select) for project bots
3. Record space ID, board/type ID, type key, and the actual `send_date` key.

## Phase 3 — configure

1. `cp .env.template .env` and fill every value from the interview. Set
   `PATH=` explicitly in .env — **cron's PATH is minimal** and this is the #1
   silent breakage (omp, npx, browseruse all live outside /usr/bin).
   `chmod 600 .env`.
2. `cp SYSTEM_PROMPT.template.md SYSTEM_PROMPT.md`, replace every
   `{{PLACEHOLDER}}`, delete OPTIONAL sections that don't apply. Read the
   whole thing — it encodes hard-won behavior rules (bias-to-action,
   whole-turn honesty, session close-out protocol).
3. If this runtime lives inside a project repo, gitignore it:
   `state/ logs/ sessions/ attachments/ .env`  (a `.gitignore` ships in this
   repo for the standalone case).

## Phase 4 — verify the wiring (before any cron)

Run each; fix before proceeding:

```bash
# token + channel reachable
python3 - <<'EOF'
import bot  # imports validate .env; then:
print(bot.get_bot_user_id())
print(bot.get_messages(bot.CHANNEL_ID, limit=1) is not None and "channel OK")
EOF
```

Then a live smoke test: `./start.sh`, watch `logs/bot.log` until
"Polling channel" appears and the kickoff message lands in the channel. The
first session is REAL — the agent will greet the human and start work.

## Phase 5 — cron

```
*/10 * * * * /abs/path/to/start.sh
```

(Stagger the minute — `2-59/10` etc. — if multiple bots share the machine.)
Optional presence daemon: `*/5 * * * * /abs/path/to/presence-start.sh`.

The scheduling model: the tick is cheap; `state/next_run` is the real gate,
and the agent sets it itself by asking "when should I run next?" at each
close-out. Due Send-Date items override next_run.

## Phase 6 — optional extras

- **Skills for omp**: two scopes. Global — symlink into `~/.agents/skills/`
  (every agent on the machine gets it). Per-bot — symlink into
  `<bot cwd>/.agents/skills/` (omp walks up from its cwd), useful when a
  skill should reach some bots but not others. Gitignore `.agents/` if the
  bot cwd lives inside a project repo.
- **browseruse**: `pipx/npm` per its repo; symlink the venv binaries into
  `~/.local/bin` and keep that dir in .env PATH.
- **Remotion**: scaffold a workspace (`npx create-video`), note its path in
  the prompt's Video section.
- **Crony dashboard**: if the human runs the Crony TUI, set CRONY_TOML in
  .env and add a job entry for this bot so it shows countdowns.

## Operational lore (read once, save yourself the debugging)

- **Prompt edits hot-reload** by killing the omp child process
  (`pgrep -P $(cat state/lock) -f omp | xargs kill`) — the bridge restarts it
  with `--continue` + fresh prompt on the next message. **bot.py edits need a
  full process restart** (kill the pid in `state/lock`, rm the lock, run
  start.sh; the session resumes).
- **Never regress the answer-extraction pipeline** — this broke four
  different ways before it stuck, and every regression looks the same from
  the outside: the bot posts a terse sign-off ("Parked", "see the link
  above" with no link) while its real answer sits unposted in the session
  file. The invariants: (1) `_extract_text` returns ALL assistant text of
  the turn, not just the last message; (2) its turn boundary is a
  bridge-formatted user message (`[Discord message from` / `[System]`) —
  omp injects other user-role entries (rule interrupts, summaries) that
  must not cut the walk short; (3) one prompt can produce SEVERAL
  agent_start/agent_end cycles (omp's rule engine and todo reminders
  restart the agent mid-turn) and each agent_end may carry only its own
  message slice — `_wait_for_response` must wait for quiescence and
  `_merge_turn_texts` must stitch every cycle's text. If the symptom ever
  returns, diff the channel posts against the session `.jsonl` first.
- **A wait period is not deafness.** `state/next_run` only schedules the
  auto-ping. The cron gate wakes early when a human posted after the bot's
  last message (`unseen_human_messages`), and the kickoff watermark starts
  at the bot's own last post so anything sent while no session was running
  is steered into the kickoff turn instead of silently skipped. Worst-case
  reply latency during a wait = one cron interval.
- Restrictive prompt language over-generalizes: every "never do X" needs a
  "this does NOT restrict Y" or the model over-complies (see Bias to action).
- Peer-bot bridges: agents answering can take minutes; on timeout NEVER
  re-ask (the question posted) — `--listen` re-attaches.
- macOS keychain-backed CLIs (gws, gh, etc.) can fail from cron/background
  shells; prefer file-based credential backends where offered. For GitHub
  pushes specifically: put `GH_TOKEN=$(gh auth token)` in .env — the gh git
  credential helper honors it without touching the keychain.
- If a session wedges: kill pid in `state/lock`, `rm state/lock`, next tick
  resumes it. `rm -rf sessions/main` forces a fresh session (history lost).

## Done criteria

- Kickoff message posted in the channel and the human replied successfully.
- A full close-out happened at least once (task marked done on the board,
  next_run written, [SESSION_END] observed, session archived to
  `sessions/done-*`).
- Cron tick verified: `grep "stand" logs/bot.log` shows gated ticks, or a
  session starts when due.
