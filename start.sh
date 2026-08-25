#!/bin/sh
# Cron entry point — safe to fire every ~10 minutes; the bot gates itself on
# state/lock and exits silently when a session is already running.
#
# This used to exec bot.py. The bridge is Odin now: one binary, `graiced bot`,
# sharing its transport with the middleware supervisor. No Python anywhere.
cd "$(dirname "$0")" || exit 1
mkdir -p logs

GRAICED="${GRAICED_BIN:-/path/to/bridge/graiced}"
if [ ! -x "$GRAICED" ]; then
  echo "$(date '+%F %T') graiced binary missing at $GRAICED — build it with:" >> logs/bot.log
  echo "  cd /path/to/bridge && odin build . -out:graiced" >> logs/bot.log
  exit 1
fi

# The bot talks to the middleware graiced's LaunchAgent supervises. If that is
# down there is nothing to talk to, so fail quietly and let the next fire try.
if ! nc -z 127.0.0.1 "${GRAICED_API_PORT:-31010}" 2>/dev/null; then
  echo "$(date '+%F %T') middleware not listening — is com.graice.graiced loaded?" >> logs/bot.log
  exit 1
fi

# .env carries ANYTYPE_* config; GRAICE_DIR tells the bot where SYSTEM_PROMPT.md,
# sessions/ and state/ live (this directory).
set -a
[ -f .env ] && . ./.env
set +a
export GRAICE_DIR="$(pwd)"

exec "$GRAICED" bot >> logs/bot.log 2>&1
