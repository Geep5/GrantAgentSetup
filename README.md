# Agent Blueprint

A portable **Anytype ⇄ AI-agent bridge**: a bot whose brain is an
[omp](https://github.com/can-ozkan/omp) agent, whose conversation surface is
Anytype, and whose durable memory is the Anytype objects themselves. You talk to
it in a chat or in any object's discussion, from desktop or the phone app, and it
answers there — under its own name and avatar, not yours.

This repo is a **starting point**, not a source of truth to sync from. Copy it,
stand a bot up, and let it grow its own way. Nothing machine- or
project-specific lives in the code.

## Why the bot has its own identity

The Anytype desktop app serves exactly one account, so a bot posting through it
speaks *as you*. Giving it a name of its own means a second Anytype middleware
signed into the bot's own account — which is most of what `bridge/` does.

That middleware cannot expose its own JSON API (port 31009 is hardcoded), so the
bridge relocates it at runtime and mints the bot its own scoped key.

## Contents

| Path | What |
|---|---|
| `bridge/*.odin` | The whole bridge: middleware supervisor, Anytype transport, omp RPC, session loop |
| `SETUP.md` | Stand one up from scratch |
| `SYSTEM_PROMPT.template.md` | The persona: identity, brevity, discussion-partner mission, task shape |
| `TASK_TEMPLATE.md` | The shape of a task object |
| `start.sh` | Cron entry point for the bot session |
| `GWS.md` | Google Workspace auth for a fleet |
| `COORDINATION.md` | How several bots hand work to each other |
| `skills/` | Capability docs loaded on demand, not in the prompt |

## Build

```sh
cd bridge && odin build . -out:graiced
```

One binary, several subcommands:

```sh
graiced bootstrap      # sign the middleware in as the bot (once)
graiced                # supervise the middleware (LaunchAgent runs this)
graiced bot            # the Anytype ⇄ omp session loop (cron runs this)
graiced surfaces       # list every chat and discussion it watches
graiced transcript ID  # the full conversation in an object
graiced selftest       # round-trip formatting, attachments, threading
```

## What it handles, and why

Each of these exists because the obvious approach silently failed:

- **Object discussions**, not just chats. Their ids are only visible through
  `ObjectShow` — REST has no property, no search hit, nothing.
- **Block-format messages.** Text typed in the Anytype app lives in
  `ChatMessage.blocks`, which the REST DTO does not map. Read over REST alone and
  the bot is deaf to everything you type. Recovered over grpc-web.
- **Formatting as marks.** Anytype renders bold/italic/code but does not parse
  markdown, and mark offsets are code points, not bytes.
- **Threaded replies to the thread root**, because a reply-to-a-reply is stored
  correctly and displayed nowhere.
- **Watermarks seeded at the bot's own last message**, so a newly discovered
  discussion neither replays its history nor swallows the first question.

## Requirements

Anytype desktop, [omp](https://github.com/can-ozkan/omp), and an
[Odin](https://odin-lang.org) compiler. macOS as written — the middleware paths
and Keychain use are platform-specific.
