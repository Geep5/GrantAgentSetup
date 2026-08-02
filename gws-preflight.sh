#!/bin/sh
# gws-preflight.sh [bot-runtime-dir] — prove each account is who it claims.
#
# An agent silently operating as the WRONG Google identity is far worse than one
# that refuses to start: it drafts from the wrong mailbox and reads the wrong
# inbox, and nothing looks broken. So assert every account before work, and
# record the verdict in state/gws_status for the agent to read.

BOT="${1:-$(pwd)}"
cd "$BOT" || exit 1
mkdir -p state gws

ACCOUNTS=$(grep '^GWS_ACCOUNTS=' .env 2>/dev/null | cut -d= -f2- | tr -d '"'"'"' ' | tr ',' ' ')
[ -z "$ACCOUNTS" ] && exit 0   # bot doesn't use gws

: > state/gws_status
FAILED=0
for ACCOUNT in $ACCOUNTS; do
  DIR="$BOT/gws/$ACCOUNT"
  if [ ! -d "$DIR" ]; then
    echo "FAILED $ACCOUNT — not seeded (run ./gws-seed.sh)" >> state/gws_status
    FAILED=1; continue
  fi
  GOT=$(GOOGLE_WORKSPACE_CLI_CONFIG_DIR="$DIR" GOOGLE_WORKSPACE_CLI_KEYRING_BACKEND=file \
        gws gmail users getProfile --params '{"userId":"me"}' 2>/dev/null \
        | sed -n 's/.*"emailAddress"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p')
  if [ -z "$GOT" ]; then
    echo "FAILED $ACCOUNT — no working session (re-seed, or re-bootstrap)" >> state/gws_status
    FAILED=1
  elif [ "$GOT" != "$ACCOUNT" ]; then
    echo "FAILED $ACCOUNT — identity mismatch, got $GOT" >> state/gws_status
    FAILED=1
  else
    echo "ok $ACCOUNT" >> state/gws_status
  fi
done
cat state/gws_status
exit $FAILED
