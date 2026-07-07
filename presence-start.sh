#!/bin/sh
# Optional: keeps the bot showing "online" in Discord. Cron: */5 * * * *
cd "$(dirname "$0")"
mkdir -p state logs
if [ -f state/presence.lock ] && kill -0 "$(cat state/presence.lock)" 2>/dev/null; then
  exit 0
fi
PY=$(grep '^PYTHON_BIN=' .env 2>/dev/null | cut -d= -f2-)
[ -z "$PY" ] && PY=python3
"$PY" presence.py >> logs/presence.log 2>&1 &
echo $! > state/presence.lock
