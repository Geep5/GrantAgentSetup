#!/bin/sh
# Cron entry point — safe to fire every ~10 minutes; bot.py gates itself.
cd "$(dirname "$0")"
mkdir -p logs
# PYTHON_BIN from .env wins; otherwise find a python3 >= 3.10
PY=$(grep '^PYTHON_BIN=' .env 2>/dev/null | cut -d= -f2-)
if [ -z "$PY" ]; then
  for c in python3 /opt/homebrew/bin/python3 /usr/local/bin/python3 /usr/bin/python3; do
    if command -v "$c" >/dev/null 2>&1 && "$c" -c 'import sys; exit(0 if sys.version_info >= (3,10) else 1)' 2>/dev/null; then
      PY="$c"; break
    fi
  done
fi
[ -z "$PY" ] && { echo "no python3 >= 3.10 found; set PYTHON_BIN in .env" >> logs/bot.log; exit 1; }

# Google Workspace: this bot may hold SEVERAL Google identities, each in its own
# credential dir under gws/<account>/ (a shared dir would let one account's
# decrypt failure delete the others). The agent picks one per command via
# ./gws-as <account>. Verify them at boot so a wrong/dead identity is caught
# here rather than discovered as mail drafted from the wrong mailbox.
if grep -q '^GWS_ACCOUNTS=' .env 2>/dev/null; then
  [ -x ./gws-preflight.sh ] && ./gws-preflight.sh "$(pwd)" >> logs/bot.log 2>&1
fi

exec "$PY" bot.py >> logs/bot.log 2>&1
