# Setting up a bot

Read this end to end before starting. Every step has a check; if a check fails,
stop there rather than continuing — later steps assume the earlier ones held.

The person doing this needs to be at the machine: two steps require the Anytype
app and one requires typing a recovery phrase, and none of them can be done by
an agent over SSH.

---

## 0. What you are building

```
Anytype app  ──┐
(you, @you)    │
               ├── your desktop middleware  :31009   ← your account
               │
bot account ───┴── graiced's middleware     :31010   ← the bot's account
                          ▲
                          │  REST + grpc-web
                   graiced bot  ── stdio ──  omp agent
```

Two Anytype accounts, two middlewares, one bot process. The bot talks only to
its own middleware, which is why its messages arrive as the bot rather than as
you.

---

## 1. Create the bot's Anytype account

In the Anytype app: sign out, create a new account, give it a name and avatar —
these are what people will see in chat. Write the recovery phrase down.

Then sign back into your own account.

**Check:** two account directories exist.

```sh
ls -1d ~/Library/Application\ Support/anytype/data/*/ | wc -l   # ≥ 2
```

> The phrase cannot be rotated: it *is* the account. Treat it like a private
> key, and never paste it into a chat window — including a chat with an agent
> helping you set this up.

---

## 2. Share a space with the bot

As **your** account, pick the space the bot will work in.

1. Space settings → Share → create an invite link.
2. Open the link as the **bot** account and request to join.
3. Back as yourself: Members → approve it as **Editor**.

Editor is required — the bot maintains task objects. Viewer makes it read-only.

**Check:** the space lists two active members.

---

## 3. Build

```sh
cd bridge && odin build . -out:graiced
```

**Check:** `./graiced version` prints a middleware version.

---

## 4. Bootstrap the bot's middleware

```sh
./graiced bootstrap
```

It starts a private middleware, asks for the **bot's** recovery phrase (nothing
echoes), signs in, relocates the JSON API to :31010 and mints a scoped API key.

**Check:** it ends with `account selected ✓` and prints an
`ANYTYPE_BOT_IDENTITY=` line. Keep that value.

Store the phrase in the login Keychain so the daemon can sign in unattended:

```sh
security add-generic-password -a graiced -s graiced-mnemonic -U -w
```

It prompts twice and echoes nothing, so the phrase never reaches your shell
history or the process table.

> The phrase is needed at *every* start, not once: Anytype's own app does the
> same thing, which is why it keeps yours in the Keychain too. No app token is
> issued that could replace it.

---

## 5. Run the middleware under launchd, not cron

Copy `com.graice.graiced.plist` to `~/Library/LaunchAgents/`, adjust the paths,
then:

```sh
launchctl bootstrap gui/$(id -u) ~/Library/LaunchAgents/com.graice.graiced.plist
```

**Check:** `curl -s -o /dev/null -w '%{http_code}' -H "Authorization: Bearer $(cat ~/.graiced/account/api_key)" \
  -H 'Anytype-Version: 2025-11-08' http://127.0.0.1:31010/v1/spaces` prints `200`.

> **Cron cannot do this step.** Cron jobs have no access to the login Keychain,
> so the phrase read fails, the middleware never signs in, and the API never
> opens — silently, every boot. A LaunchAgent runs inside your GUI session where
> the Keychain is reachable. This was found the hard way.

---

## 6. Configure the bot

Copy `.env.template` to your bot directory as `.env` and fill in:

| Key | Where it comes from |
|---|---|
| `ANYTYPE_API_BASE` | `http://127.0.0.1:31010` |
| `ANYTYPE_API_KEY` | `~/.graiced/account/api_key` |
| `ANYTYPE_BOT_IDENTITY` | printed by `bootstrap` — makes attribution exact |
| `ANYTYPE_CHAT_SPACE_ID` | the shared space |
| `ANYTYPE_CHAT_ID` | a chat in it (`graiced surfaces` lists them) |
| `OMP_BIN`, `OMP_MODEL` | your omp install |

Copy `SYSTEM_PROMPT.template.md` to `SYSTEM_PROMPT.md` and edit the identity
paragraph and mission. Leave the length rule alone until you have watched it
run — it exists because replies were averaging 1,800 characters, which is
unreadable on a phone.

**Check:** `graiced surfaces` lists the chats and discussions it can see.

---

## 7. Run the bot

```sh
./start.sh          # by hand
*/10 * * * * /path/to/start.sh    # or from cron; it gates itself on state/lock
```

Cron is fine *here* — this step needs no Keychain.

**Check:** send a message in the space. Within ~3s the log shows
`message from …`, a 👀 appears on your message, and a reply arrives under it.

---

## Troubleshooting

| Symptom | Cause |
|---|---|
| `no phrase in the Keychain` | started from cron — use the LaunchAgent |
| Messages read as empty | block-format text; needs the grpc fallback (built in) |
| Bot answers as *you* | pointed at :31009 — check `ANYTYPE_API_BASE` |
| Replies invisible in the app | replying to a reply; the bridge threads to the root |
| Asterisks in messages | markdown not converted to marks |
| 👀 never clears | the turn crashed — see `logs/bot.log` |
| Bot silent after a restart | it is finishing a kickoff turn before polling |
