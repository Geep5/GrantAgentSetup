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
exec "$PY" bot.py >> logs/bot.log 2>&1
