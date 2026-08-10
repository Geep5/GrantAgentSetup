---
name: auth-sessions
description: Get Grant signed in to a service a bot is blocked on (QuickBooks and similar). Use when a bot reports needs-auth in a Graice-Auth channel, when Grant says "open a login" / "I'm ready" / "let's do the auth", or when he asks what is blocked on a sign-in.
---

# Getting Grant signed in

A bot hits a login wall, says so in its Graice-Auth channel, and carries on with
other work. You turn that into one short sitting for Grant, at a moment that
suits him, and confirm it worked.

**You never type a credential.** Grant signs in on the service's own page —
password, MFA, CAPTCHA. That is not a limitation to work around; it is the
point. Do not offer to do it for him and do not ask him for a password.

## When he says "open a login" (or "ready", or "go")

```bash
cd /Users/sharky/projekt/2/AuthSessions
./auth-spawn.sh quickbooks              # several services if they share a profile
```

It prints `url=…`. **Give him that link immediately** — it is a browser page,
he does not need a VNC client. Then tell him what he is looking at.

## While he is signing in

```bash
./auth-look.sh intuit-grant             # the profile name auth-spawn printed
```

Returns the URL, the page title, and the visible text. Poll it every ~15s and
narrate: which step he is on, if it is asking for MFA, if it wants a company
file, if it silently bounced back to the login page.

`"sensitive": true` means the page text is withheld — a password field or a
code entry. You still get URL and title, which is enough to say "that's the
MFA step". **Do not ask him to read a code out to you.** You never need it.

## When he says he is done

```bash
./auth-finish.sh intuit-grant quickbooks
```

This stops the browser CLEANLY, which is what writes the session to disk —
killing it throws the sign-in away — then probes to confirm it stuck.

- `✅ signed in` → tell him, and post `<service> ready, retry` into the
  channel of every bot that was blocked (see `sessions.json` → `auth_channel`).
- `⚠️ EXPIRED` → the login did not take. Say so plainly and offer to reopen it.
- `❓ couldn't tell` → the probe markers are wrong for the page, not
  necessarily a failed login. Say that, and check `auth-look.sh` output before
  claiming either way.

## Rules

- **One sitting, many services.** Services sharing a `profile` in
  `sessions.json` are cleared together. Never make him do two sittings for one
  account.
- **Never spawn a sitting he did not ask for.** A browser sitting open with a
  live session, unattended, is a standing risk. If he goes quiet for ~15
  minutes, run `./auth-finish.sh <profile>` to tear it down and tell him you
  will reopen it whenever he is ready.
- **Do not nag.** The nudge that got his attention already weighed whether it
  was worth interrupting him. Once he has been asked, wait.
- **Report back.** The bot that reported the problem is still blocked until you
  tell it otherwise.

## What is blocked right now

```bash
cd /Users/sharky/projekt/2/AuthSessions && python3 authstate.py
```

Shows each dead credential, which bots need it, and when they next run.
