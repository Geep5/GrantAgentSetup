#!/bin/sh
# gws-seed.sh [bot-runtime-dir] — give a bot a private credential dir for EVERY
# account listed in its GWS_ACCOUNTS.
#
# Idempotent: re-run any time credentials are lost or corrupted. The vault is
# the durable copy, so re-seeding needs no browser.
#
# One dir per account per bot, because gws DELETES the credentials file on a
# decrypt failure — isolation keeps that blast radius to a single account of a
# single bot instead of the whole fleet.

set -e
BOT="${1:-$(pwd)}"
cd "$BOT"
[ -f .env ] || { echo "no .env in $BOT"; exit 1; }

ACCOUNTS=$(grep '^GWS_ACCOUNTS=' .env | cut -d= -f2- | tr -d '"'"'"' ' | tr ',' ' ')
[ -z "$ACCOUNTS" ] && { echo "GWS_ACCOUNTS not set in $BOT/.env — nothing to seed"; exit 0; }
VAULT_ROOT="${GWS_VAULT:-$HOME/.config/gws-vault}"

mkdir -p gws && chmod 700 gws
for ACCOUNT in $ACCOUNTS; do
  SRC="$VAULT_ROOT/$ACCOUNT"
  if [ ! -d "$SRC" ]; then
    echo "  ✗ $ACCOUNT — not in the vault. Run: ./gws-bootstrap.sh $ACCOUNT"
    continue
  fi
  DEST="gws/$ACCOUNT"
  mkdir -p "$DEST" && chmod 700 "$DEST"
  for f in credentials.json credentials.enc client_secret.json; do
    [ -f "$SRC/$f" ] && cp "$SRC/$f" "$DEST/$f"
  done
  # Never copy the token cache or encryption key: they are per-dir state, and a
  # cache encrypted under a different key is exactly what makes gws start
  # deleting credentials.
  rm -f "$DEST/token_cache.json" "$DEST/.encryption_key"
  find "$DEST" -type f -exec chmod 600 {} \; 2>/dev/null || true
  find "$DEST" -type d -exec chmod 700 {} \; 2>/dev/null || true
  echo "  ✓ $ACCOUNT seeded"
done

exec "$(dirname "$0")/gws-preflight.sh" "$BOT"
