#!/bin/sh
# gws-bootstrap.sh <account@domain> — authorize ONE Google account into the vault.
#
# Run this yourself, on a machine with a browser. It never touches ~/.config/gws
# (the shared dir), so bootstrapping a second account cannot destroy the first.
#
# What it does:
#   1. makes a scratch config dir for the login
#   2. runs `gws auth login` there (browser opens)
#   3. asserts the account you got is the account you asked for
#   4. copies the credentials into ~/.config/gws-vault/<account>/
#
# Agents are seeded FROM the vault by gws-seed.sh, so a bot that loses or
# corrupts its credentials is re-seeded in a second with no browser step.
#
# Once per account, plus whenever Google revokes the refresh token (password
# change, 6 months unused, or explicit revocation).

set -e
ACCOUNT="$1"
[ -z "$ACCOUNT" ] && { echo "usage: $0 <account@domain>"; exit 1; }

VAULT="${GWS_VAULT:-$HOME/.config/gws-vault}"
DEST="$VAULT/$ACCOUNT"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# The keychain cannot be unlocked from cron, so every agent runs on the file
# backend. Bootstrap on the same backend or the credentials are unreadable later.
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$WORK"

# The OAuth client is shared across accounts; reuse it if one already exists.
for SRC in "$VAULT"/*/client_secret.json "$HOME/.config/gws/client_secret.json"; do
  [ -f "$SRC" ] && { cp "$SRC" "$WORK/client_secret.json"; break; }
done
if [ ! -f "$WORK/client_secret.json" ]; then
  echo "No client_secret.json found. Run 'gws auth setup' once to create the"
  echo "OAuth client, then re-run this script."
  exit 1
fi

echo "Logging in as $ACCOUNT — a browser will open."
echo "IMPORTANT: pick $ACCOUNT, and tick EVERY consent checkbox (a missed box"
echo "means a scope you'll only discover as a 403 days later)."
gws auth login

# Never trust the browser to have used the account you intended.
GOT=$(gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null \
      | sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ -z "$GOT" ]; then
  echo "Login did not produce a working session — nothing written to the vault."
  exit 1
fi
if [ "$GOT" != "$ACCOUNT" ]; then
  echo "You asked for $ACCOUNT but logged in as $GOT."
  echo "Nothing written to the vault. Re-run and choose the right account."
  exit 1
fi

mkdir -p "$DEST"
chmod 700 "$VAULT" "$DEST"
# gws keeps user credentials either encrypted or plain depending on how it was
# authed; take whichever exists. The token cache is deliberately NOT copied —
# it is per-config-dir state and a stale one is exactly what breaks agents.
for f in credentials.json credentials.enc client_secret.json; do
  [ -f "$WORK/$f" ] && cp "$WORK/$f" "$DEST/$f"
done
chmod 600 "$DEST"/* 2>/dev/null || true

echo
echo "✅ $ACCOUNT vaulted at $DEST"
echo "Next: add $ACCOUNT to GWS_ACCOUNTS in a bot's .env (comma-separated), then:"
echo "  ./gws-seed.sh <bot-runtime-dir>"
echo
echo "If Google returns 403 serviceusage/serviceUsageConsumer for this account,"
echo "grant it that role on the OAuth client's GCP project — it is required"
echo "once per account and is not something the agent can fix at runtime."
