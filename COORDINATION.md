# Coordination: how bots ask for help without interrupting Grant

A worker bot that hits a wall it cannot climb — an expired login, a credential
it must never handle — has two bad options and one good one. It can fail
silently (Grant finds out days later), it can stall waiting for a human (one
dead credential kills the whole session), or it can **hand the problem to the
coordinator and carry on**. This is how the third one is wired.

The worked example is **Marco (finance)** and QuickBooks. Copy its shape.

---

## Two channels per bot

Every worker bot has two Discord channels, and the distinction is load-bearing:

| Channel | Who talks | What belongs there |
|---|---|---|
| `DISCORD_CHANNEL_ID` | Grant ↔ the bot | his actual conversation with it |
| `COORD_CHANNEL_ID` | Graice ↔ the bot | fleet plumbing: auth hand-offs, retries, status chases |

The bot **listens on both** and replies to whichever asked. Grant's channel
stays readable as a conversation; the machinery lives next door.

In the bot's `.env`:

```bash
DISCORD_CHANNEL_ID=1523130306599718963   # Grant's channel with this bot
COORD_CHANNEL_ID=1536155892255297596     # the Graice-Auth channel for this bot
NEEDS=quickbooks                          # services it cannot work without
```

`NEEDS` is what lets the coordinator say *"Marco is blocked"* rather than
*"something is blocked"*.

> **The failure this prevents, and it has happened three times:** a message that
> looks routed but is never read. Before adding any hop, check that the
> recipient actually polls that channel. A bot ignores its own messages, so a
> bot-to-bot relay on a shared Discord identity also needs the `[relay]` prefix.

---

## The loop

```
bot's job fails on a dead credential
  → needs-auth.sh          reports in COORD_CHANNEL_ID, then CARRIES ON
  → Graice                 judges whether it is worth interrupting Grant
  → Grant                  "ready"
  → Graice                 spawns the sign-in, he signs in, she verifies
  → tell-bot.sh            all-clear into COORD_CHANNEL_ID
  → bot                    retries and finishes
```

Only the coordinator makes judgements. Every other step is a script.

### What the bot does

```bash
BOT_NAME=Marco-Finance $HOME/projekt/2/AuthSessions/needs-auth.sh \
    quickbooks "hit the Intuit sign-in page, no session"
```

Then **keep working on everything else**. A blocked credential should cost the
work that needs it, not the session.

### What the coordinator does

Its `auth-sessions` skill has the detail. In short: decide whether to interrupt,
run the sitting when Grant says go, verify it took, tell the bot, tell Grant.

**Never post plumbing into Grant's channel with a bot.** If you are about to
write "retry your job" where Grant talks to Marco, you have the wrong channel.

---

## Adding a service

One entry in `AuthSessions/sessions.json`:

```jsonc
"quickbooks": {
  "label": "QuickBooks Online (Matcherino)",
  "profile": "intuit-grant",        // keyed by ACCOUNT, not service
  "login_url":  "https://app.qbo.intuit.com/app/homepage",
  "probe_url":  "https://app.qbo.intuit.com/app/homepage",
  "signed_in":  ["Bank transactions", "Get things done"],
  "signed_out": ["accounts.intuit.com"],
  "importance": "high",
  "stakes":     "The books. Blocks month-end close and invoice chasing.",
  "owner_bot":     "$HOME/projekt/1/Graice-Finance",
  "auth_channel":  "1536155892255297596",
  "cookie_domains": [".intuit.com"]
}
```

Three fields decide behaviour and are worth thinking about:

- **`profile` is per ACCOUNT.** Two accounts on the same provider cannot share
  one — the second sign-in silently replaces the first. Services that *do* share
  an account are batched into one sitting, so Grant faces MFA once.
- **`importance` + `stakes`** are what the coordinator weighs when deciding
  whether to interrupt. `stakes` is a plain sentence about consequences; it is
  read by a model, not matched by code, so write it for a human.
- **`signed_in` wins over `signed_out`.** A dashboard may contain the words
  "sign in" somewhere in its chrome; a login page never contains the dashboard.

---

## Why browser sessions, not API keys

Some services simply will not give an agent a usable credential. QuickBooks has
a REST API that needs an approval Intuit did not grant. So the login happens in
a **real Chrome on Grant's own desktop** — clipboard, password manager and MFA
all work — and the session is taken from the running browser over DevTools,
where it comes back already decrypted.

Nothing in this repo ever handles a password. That is not a limitation to
engineer around; automated sign-in is exactly what these services defend
against, and it is the line the agents are told not to cross.

### The part that surprises people

Services like Intuit keep the login in **session cookies**, which exist only
while a browser is running. Close the window and the session is gone no matter
how carefully it was captured. So the session is transplanted into a headless
**holder** that never closes, and bots read through that.

**A QuickBooks session lasts about an hour** — measured, not estimated. Two
consequences worth designing around:

- There is no point signing in ahead of a job later today.
- Scheduled overnight work against such a service will always find a dead
  session. Either the work happens right after a sign-in, or that service is
  the wrong fit for a cron job.

---

## Scheduled work that needs a credential

A cron job that just messages a bot leaves nothing behind if the bot never gets
to it. Have the job **create the board task itself**, then tell the bot to work
it — an open task is visible, a missed message is not.

The bot marks it Done only when the deliverable is actually delivered. Not
drafted, not "figures gathered" — delivered.

Two guards worth copying from `Graice-Finance/monthly-qbo-report.sh`:

- **`DRY=1`** prints what it would do and touches nothing. A monthly job is run
  by hand far more often than it fires, and every hand-run is a live write.
- **A date guard.** Run by hand on the wrong day, a "last month" calculation
  names the wrong month and creates a real task for it. Refuse unless the date
  is right, with `FORCE=1` to override.

## Checklist for a new bot

1. Create its coordination channel in the Graice-Auth category.
2. `COORD_CHANNEL_ID` and `NEEDS` in its `.env`.
3. Its service in `AuthSessions/sessions.json`, with `auth_channel` pointing at
   that channel.
4. Give it the skill for the service it uses (see `skills/quickbooks`).
5. Tell it, in its prompt, to run `needs-auth.sh` and keep working — never to
   stall, and never to go looking for a password.
6. **Verify the recipient actually polls the channel** before believing any of
   it works.
