---
name: gws-accounts
description: Use Google Workspace (Gmail, Docs, Drive, Calendar, Sheets) as a SPECIFIC Google account. Use whenever a task involves reading or drafting email, creating docs, checking a calendar, or any Google data — and especially when deciding WHICH mailbox/identity the work belongs to.
---

# Google Workspace, as a chosen account

This bot can act as more than one Google identity. Which one you pick is a real
decision — it determines whose mailbox a draft lands in and whose inbox you
read — so pick deliberately, never by habit.

## Running a command

Always through the wrapper, from the bot's own directory:

```bash
./gws-as <account> <normal gws args...>
```

Examples:

```bash
./gws-as support@matcherino.com gmail users getProfile --params '{"userId":"me"}'
./gws-as support@matcherino.com gmail users messages list --params '{"userId":"me","q":"is:unread"}'
./gws-as mark@matcherino.com drive files list
```

Never call bare `gws`. Without the wrapper there is no account selected, and
whatever credentials happen to be lying around get used — which is how a bot
ends up quietly operating as the wrong person.

## Which accounts exist

Read them; don't assume:

```bash
cat state/gws_status     # one line per account: "ok <account>" or "FAILED <account> — <why>"
ls gws/                  # the credential dirs themselves
```

`state/gws_status` is written at every boot by the preflight, which proves each
account is actually who it claims to be. Treat it as the source of truth.

## Accounts on this machine (as of 2026-08-01)

- **grant@matcherino.com** — Grant's own account; the default for most work, and
  the right identity for anything a recipient should read as coming from Grant.
- **support@matcherino.com** — the support/shared identity; use for customer and
  support correspondence that should NOT appear to come from Grant personally.
- **mark@matcherino.com** — ⚠️ a **departed employee's** account. Do not use it
  as a default or a fallback. Only touch it when Grant explicitly asks, and say
  so plainly when you do. Reading a former employee's mailbox by accident is
  exactly the kind of mistake this skill exists to prevent.

## Choosing the account

- **Match the identity to the work, not to convenience.** Customer or support
  correspondence goes out from the support identity; a person's own
  correspondence goes from their own account. If a task's right identity isn't
  obvious, ask Grant — one question now beats mail sent from the wrong mailbox.
- **Say which account you used.** Whenever you report a Google action, name the
  identity: "drafted in support@'s Drafts", not "drafted the email". Grant
  cannot verify what you don't state.
- **Never mix identities inside one task** without saying so explicitly.

## When something fails

- **`FAILED ... not seeded`** → run `./gws-seed.sh` (instant, no browser: it
  re-copies from Grant's vault).
- **`FAILED ... no working session`** → the refresh token is dead (revoked,
  password changed, or unused ~6 months). Only Grant can fix it, with a browser:
  `./gws-bootstrap.sh <account>`. Tell him exactly that; don't try workarounds.
- **`FAILED ... identity mismatch`** → STOP. Do no Google work with that
  account and tell Grant immediately. This means the credentials are not who
  they claim, which is a security problem, not an inconvenience.
- **403 `serviceusage.serviceUsageConsumer`** → that account lacks a role on the
  OAuth client's GCP project. One-time fix by Grant; it recurs for every new
  account, so name it precisely when you report it.
- **403 "insufficient authentication scopes"** → the login missed a consent
  checkbox. Needs `./gws-bootstrap.sh <account>` again with every box ticked.

Never "work around" an auth failure by trying another account. Using a
different identity than the task calls for is a worse outcome than the task
waiting.

## Standing rules that outrank convenience

- **You never send.** Drafts only, staged in the right account's Drafts. Grant
  sends. The sole exception is an instruction from Grant so explicit it names
  the recipient and the final text he has already seen.
- **Drafts are written in the voice the recipient expects** — for Grant's own
  accounts, first person as Grant; the recipient must never sense a bot wrote it.
- **Never read, echo, copy, or move credentials** — not the files under `gws/`,
  not tokens, not into Discord, not into a repo. If a task needs a secret
  handled, Grant does that part.
