# Agent Blueprint

A portable, battle-tested **Discord ⇄ AI-agent bridge**: a cron-scheduled bot
whose brain is an [omp](https://github.com/can-ozkan/omp) agent, whose
conversation surface is a Discord channel, and whose durable task memory is an
Anytype board. It works one task per session, self-schedules its next run by
asking you, watches "Send Date" deferrals, handles image attachments inline,
and speaks in complete turns.

This repo is the **blueprint**: nothing machine- or project-specific lives in
code. An installing agent (Claude Code, omp, etc.) reads **SETUP.md**,

- **GWS.md** — Google Workspace auth for a fleet: one credential universe per account, why the OS keychain and shared config dirs break under cron, and the identity preflight that stops an agent acting as the wrong person.
interviews you, fills in `.env` + `SYSTEM_PROMPT.md` from the templates, and
verifies each layer.

## Contents

| File | What |
|---|---|
| `bot.py` | The bridge: gating, Discord polling, omp RPC, steering, attachments, deferred sends, whole-turn extraction |
| `start.sh` | Cron entry point (portable python discovery) |
| `SYSTEM_PROMPT.template.md` | The agent persona/mission with `{{PLACEHOLDERS}}` — encodes all learned behavior rules |
| `.env.template` | Every knob, documented |
| `SETUP.md` | **Start here** — instructions addressed to the installing agent |
| `COORDINATION.md` | How a bot hands a blocked credential to the coordinator instead of failing silently or stalling — two-channel model, the auth loop, browser sessions |
| `ask_peer.py` | Bridge to a sibling bot in a shared channel (ask → wait → collect) |
| `presence.py` + `presence-start.sh` | Optional: keeps the bot showing online in Discord |

## Quick start (human version)

1. Point your coding agent at this repo and say: *"Set this up — follow SETUP.md."*
2. Answer its interview (Discord token/channel, Anytype space, model).
3. Reply to the bot's first message in your channel.

## Requirements

macOS/Linux, Python ≥ 3.10, `omp` CLI (authenticated), a Discord bot token,
and optionally a local Anytype with its API enabled.
