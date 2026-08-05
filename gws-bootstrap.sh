#!/bin/sh
# gws-bootstrap.sh <account@domain> [comma,separated,scopes]
#   Authorize ONE Google account straight into the vault.
#
# Run this yourself, on a machine with a browser. It never touches
# ~/.config/gws (the shared dir), so bootstrapping one account cannot destroy
# another.
#
# DESIGN NOTE — why the login happens IN the vault dir:
# An earlier version logged in to a scratch dir and then copied/exported the
# result. Both variants failed silently in different ways (nothing to copy with
# the file keyring; an empty export). Logging in directly where the credentials
# must live removes the whole class of bug: whatever `auth login` writes IS the
# vaulted credential.
#
# The one thing that must be handled is shadowing: a plaintext credentials.json
# takes precedence over an encrypted credentials.enc, so a stale plaintext file
# would mask the new login (and make gws report the OLD identity). It is moved
# aside before the login and deleted only once the new session is proven.

set -e
ACCOUNT="$1"
[ -z "$ACCOUNT" ] && { echo "usage: $0 <account@domain> [comma,separated,scopes]"; exit 1; }
SCOPES="$2"

VAULT="${GWS_VAULT:-$HOME/.config/gws-vault}"
DEST="$VAULT/$ACCOUNT"
mkdir -p "$DEST"; chmod 700 "$VAULT" "$DEST"

# cron cannot unlock the OS keychain, so every agent uses the file backend —
# bootstrap on the same backend or the credentials are unreadable later.
export GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file
export GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DEST"

# Reuse the shared OAuth client if this account doesn't have one yet.
if [ ! -f "$DEST/client_secret.json" ]; then
  for SRC in "$VAULT"/*/client_secret.json "$HOME/.config/gws/client_secret.json"; do
    [ -f "$SRC" ] && { cp "$SRC" "$DEST/client_secret.json"; break; }
  done
fi
[ -f "$DEST/client_secret.json" ] || { echo "No client_secret.json anywhere. Run 'gws auth setup' once."; exit 1; }

# Keep the current credentials recoverable, and un-shadow the new login.
STAMP=$(date +%Y%m%d-%H%M%S)
for f in credentials.json credentials.enc token_cache.json; do
  [ -f "$DEST/$f" ] && mv "$DEST/$f" "$DEST/.bak-$STAMP-$f"
done

echo "Logging in as $ACCOUNT — a browser will open."
echo "IMPORTANT: pick $ACCOUNT, and tick EVERY consent checkbox."
[ -n "$SCOPES" ] && echo "Requesting scopes: $SCOPES"
if [ -n "$SCOPES" ]; then gws auth login --scopes "$SCOPES"; else gws auth login; fi

# Never trust the browser to have used the account you intended.
GOT=$(gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null \
      | sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
if [ "$GOT" != "$ACCOUNT" ]; then
  echo "Expected $ACCOUNT but got '${GOT:-nothing}'. Rolling back to the previous credentials." >&2
  rm -f "$DEST/credentials.json" "$DEST/credentials.enc" "$DEST/token_cache.json"
  for f in credentials.json credentials.enc; do
    [ -f "$DEST/.bak-$STAMP-$f" ] && mv "$DEST/.bak-$STAMP-$f" "$DEST/$f"
  done
  exit 1
fi

find "$DEST" -type f -exec chmod 600 {} \; 2>/dev/null || true
find "$DEST" -type d -exec chmod 700 {} \; 2>/dev/null || true

echo
echo "✅ $ACCOUNT authorized in $DEST"
gws auth status 2>/dev/null | sed -n 's/.*"scopes".*/  (scope list below)/p'
echo "Previous credentials kept as $DEST/.bak-$STAMP-* — delete once you're happy."
echo
echo "Next: add $ACCOUNT to GWS_ACCOUNTS in a bot's .env (comma-separated), then:"
echo "  ./gws-seed.sh <bot-runtime-dir>"
echo
echo "If Google returns 403 serviceusage/serviceUsageConsumer, grant that account"
echo "roles/serviceusage.serviceUsageConsumer on the OAuth client's GCP project."
