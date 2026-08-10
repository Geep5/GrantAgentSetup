---
name: auth-sessions
description: Get Grant signed in to a service a bot is blocked on, then tell that bot to retry. Use when a bot reports needs-auth in a Graice-Auth channel, when Grant says "ready" / "open a login" / "let's do the auth", or when he asks what is blocked on a sign-in.
---

# Unblocking a bot that hit bad credentials

The loop, start to finish:

```
bot's cron job fails on a dead credential
   → it posts needs-auth in its Graice-Auth channel, and carries on with other work
you  → decide whether it is worth interrupting Grant (see below)
     → Grant says "ready"
     → you spawn the sign-in, he signs in, you verify
     → you tell the bot in ITS OWN channel to retry
bot finishes the job
```

You are the only part of that chain that thinks. Everything else is a script.

**You never type a credential.** Grant signs in on the service's own page —
password, MFA, CAPTCHA. Do not offer to do it for him and never ask him for a
password.

## 1. When a bot reports

Read it, and leave it. A separate job decides whether to interrupt Grant and
writes him the DM. Do not also ping him — two of you asking is worse than one.

If he asks what is blocked:

```bash
cd /Users/sharky/projekt/2/AuthSessions && python3 authstate.py
```

## 2. When Grant says he is ready

```bash
cd /Users/sharky/projekt/2/AuthSessions
./auth-local.sh quickbooks          # several at once if they share a profile
```

A Chrome window opens **on his own desktop** — clipboard, password manager and
MFA all work there. Tell him it is open, and that you will wait.

**Tell him to leave it open when he is done.** Services like Intuit keep the
login in session cookies, which exist only while that browser runs; closing it
first destroys the session no matter what we captured.

## 3. When he says he is signed in

```bash
python3 auth-token.py quickbooks && python3 auth-holder.py start quickbooks
```

The first takes the live session out of his browser; the second transplants it
into a headless browser that stays running, so the session survives him closing
his window. `auth-holder.py start` prints whether it is genuinely signed in.

- `✅ signed in` → go to step 4. Tell him he can close his window now.
- `⚠️ signed out` → the session was already dead. Say so and offer to reopen it.
- `❓ couldn't tell` → NOT a failed login. The page markers are wrong for what
  loaded. Say that plainly rather than making him sign in again.

## 4. Tell the bot to retry — do not skip this

```bash
./tell-bot.sh quickbooks
python3 auth-cleared.py quickbooks
```

`tell-bot.sh` posts into the bot's **coordination channel** — the private
Graice↔bot one it reported into, which it also listens to. `auth-cleared.py`
verifies and clears the flag.

**Never post fleet plumbing into a bot's own channel with Grant.** That channel
is his conversation with that bot; auth hand-offs, retries and status belong in
the coordination channel. If you find yourself about to write "retry your job"
where Grant talks to Marco, you have the wrong channel.

**You CAN post in every bot's channel.** Your token has access; this has been
tested. If you find yourself about to tell Grant "I can't post there, that one's
yours" — you can, and asking him to do your job is the failure. Run the command.

The one thing to check before claiming success: `auth-cleared.py` must say the
session verified. Telling a bot to retry against a dead session moves the
failure somewhere less obvious.

## 5. Tell Grant it is done

One line: which service, which bot is unblocked. He does not need the mechanics.

## Timing, honestly

**A QuickBooks session lasts about an hour** — measured, not guessed. So the
bot should do its work promptly after a sign-in, and there is no point signing
in "ahead of time" for a job later today. If Grant offers to do it early, tell
him it will have expired.

## Rules

- **One sitting, many services.** Services sharing a `profile` are cleared
  together. Never make him sign in twice for one account.
- **Never spawn a sitting he did not ask for.**
- **Never claim a login worked without running the verify step.** Telling a bot
  to retry against a dead session just moves the failure somewhere less obvious.
