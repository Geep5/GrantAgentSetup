# Google Workspace auth for a fleet of agents

**Audience:** whoever installs or debugs a bot from this repo — human or agent.

Every rule here was paid for. On 2026-08-01 three production agents silently ran
as a departed employee's Google account for an unknown length of time. Nothing
errored. They just read and drafted from the wrong person's mailbox.

---

## The problem

`gws` keeps credentials in a config directory, `~/.config/gws` by default. That
gives you **one account per machine** and one shared, mutable token cache. For a
single developer that's fine. For a fleet it fails three ways:

1. **The default keyring is the OS keychain, which cron cannot unlock.** Every
   scheduled agent hits this.
2. **`gws` DELETES the credentials file when it cannot decrypt it.** In a shared
   directory, one bot's bad run destroys auth for every bot.
3. **One directory holds one account.** Authorizing a second account silently
   repoints every agent at it — the exact failure above.

## The model

`GOOGLE_WORKSPACE_CLI_CONFIG_DIR` selects the credential universe, so an agent's
Google identity is decided entirely by which directory it points at.

```
~/.config/gws-vault/<account>/     the vault — bootstrapped once per account,
                                   with a browser; the durable copy
<bot>/gws/<account>/               per-bot working copy, seeded from the vault
```

Per-bot copies rather than pointing every bot at the vault: two bots sharing one
directory share a mutable `token_cache.json`, and a concurrent-write decrypt
failure triggers rule 2 above for *every* bot on that account. Isolation keeps
the blast radius to one bot, and re-seeding is instant because the vault — never
touched at runtime — stays clean.

Two variables must be set for every call. `gws-as` does it for you:

```bash
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="<bot>/gws/<account>"
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file   # mandatory, see failure 1
```

## The scripts

| Script | Who runs it | When |
|---|---|---|
| `gws-bootstrap.sh <account>` | **a human, with a browser** | once per account, and again only if the refresh token dies |
| `gws-seed.sh [bot-dir]` | anyone, any time | vault → per-bot dirs; no browser; safe to re-run |
| `gws-preflight.sh [bot-dir]` | `start.sh`, every boot | asserts each identity, writes `state/gws_status` |
| `gws-as <account> <args>` | **the agent, always** | every single Google command |

`.env` carries `GWS_ACCOUNTS=a@x.com,b@x.com`. The agent never calls bare `gws`.

## Identity preflight is not optional

An agent on the wrong Google identity is far worse than one that refuses to
start: nothing fails, it just acts as the wrong person. So before work:

```bash
gws gmail users getProfile --params '{"userId":"me"}'   # compare to the expected account
```

`gws-preflight.sh` does this for every account at boot and records the verdict in
`state/gws_status`. The `gws-accounts` skill tells the agent to read that file
and to **never** fall back to a different identity when one fails.

## Bootstrapping a new account

Needs a human and a browser — an agent cannot do this alone, must not attempt it
headless, and must never ask the user for tokens, passwords or auth codes.

```bash
./gws-bootstrap.sh new@example.com
```

It logs in inside a scratch directory, **refuses to save anything if the browser
returns a different account than you asked for**, then vaults the credentials.
Tick every consent checkbox — a missed one becomes a 403 days later.

Then grant the account API access on the GCP project that owns the OAuth client
(run as the project owner):

```bash
gcloud projects add-iam-policy-binding <PROJECT_ID> \
  --member='user:new@example.com' \
  --role='roles/serviceusage.serviceUsageConsumer'
```

Without it every call fails `403 Caller does not have required permission to use
project …`. That is an IAM error, not an auth error — the token is fine. It
recurs for **every** new account.

## Hard rules

1. **Never run `gws` under `sudo`.** It sets `HOME=/var/root`, silently using a
   different config dir and leaving root-owned files that later break non-root
   reads with `Permission denied (os error 13)`.
2. **Never write credentials into the default `~/.config/gws`.** It shadows
   every other source for any agent that forgets to set `CONFIG_DIR`.
3. **`credentials.json` (plaintext) SHADOWS `credentials.enc`.** So `auth login`
   and `auth export` must run as one unit in a directory with no stale plaintext
   file — otherwise login writes the new account to `.enc` while export reads the
   *old* `.json` and emits the wrong identity. This is precisely how three agents
   became someone else.
4. **Never copy credentials between accounts.** Mint each with its own login.
   Copying propagates an identity silently. (Copying the *same* account from the
   vault to a bot is what `gws-seed.sh` does and is fine — the preflight proves
   it afterwards.)
5. **Never point two agents needing different accounts at one config dir.**
6. Credentials are plaintext refresh tokens on disk, `chmod 600`. They don't
   expire unless revoked, unused ~6 months, or the password changes.
7. **Departed employees' accounts are not fallbacks.** Name them in the skill so
   an agent can't drift into one.

## Known limitation

`gws` supports OAuth user credentials only — no service accounts, no
domain-wide delegation (the vendored `yup-oauth2` crate can do both; the CLI
exposes no way in). So every account needs a one-time interactive browser login
and a refresh token at rest.

Past a handful of accounts, DWD is the correct upgrade: one service-account key
impersonating any user in the domain by subject, no per-user browser step, no
refresh tokens on disk. That needs either a `gws` feature or a thin
`google-api-python-client` shim alongside it.
