---
name: quickbooks
description: Read Matcherino's QuickBooks Online — reports, invoices, transactions, balances. Use for any question about the books, money owed, spending, or anything an accountant would look up.
---

# QuickBooks, through the signed-in holder

**Check the session before starting work that depends on it:**

```bash
/Users/sharky/projekt/2/AuthSessions/check-session.sh quickbooks
```

Exit 0 = usable. Anything else = report it and wait, rather than discovering it
halfway through and throwing the work away.

```bash
/Users/sharky/projekt/2/AuthSessions/qbo.sh /app/reports
/Users/sharky/projekt/2/AuthSessions/qbo.sh "https://qbo.intuit.com/app/invoices"
/Users/sharky/projekt/2/AuthSessions/qbo.sh /app/homepage html      # raw HTML
```

You are driving a browser that is **already signed in as Grant**. There is no
login step, no token to fetch, and no password anywhere. Never go looking for
credentials — they do not exist on this path by design.

Intuit's REST API is not available here: it needs an approval from Intuit that
Grant does not have. Do not suggest it as the fix; this is the way in.

## When it says the session expired

```
the holder's session has expired — Grant needs to sign in again
```

That is not something you can repair. Report it and move on to other work:

```bash
BOT_NAME=<your name> /Users/sharky/projekt/2/AuthSessions/needs-auth.sh quickbooks "session expired mid-task"
```

That tells Graice, who picks a moment that suits Grant and walks him through a
sign-in. **Do not stall** waiting for it — one dead credential should cost the
work that needs it, not your whole session.

## Reading what comes back

You get the page's visible text, which is what a person would see. It is a
single-page app, so a page that looks thin usually means it had not finished
rendering — ask for it again before concluding the data is not there.

Useful entry points:

| | |
|---|---|
| `/app/homepage` | dashboard, cash at a glance |
| `/app/reports` | every report, including P&L and balance sheet |
| `/app/invoices` | invoices and their status |
| `/app/expenses` | bills and spending |
| `/app/banking` | bank feed, uncategorised transactions |

## Rules

- **Read-only unless Grant explicitly asks otherwise.** These are the real
  books; do not create, edit, void, or send anything on your own initiative.
- **Never paste figures you did not just read.** If a number matters, fetch the
  page again rather than recalling it from earlier in the session.
- The holder is shared. Do not leave it parked on some deep page — it costs
  nothing to navigate, and the next reader expects to start clean.
