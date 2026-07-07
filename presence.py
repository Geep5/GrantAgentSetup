#!/usr/bin/env python3
"""Keep the bot showing as online in Discord.

The Graice bots talk to Discord over REST only, so without a gateway
connection the bot user always shows offline. This daemon holds a minimal
gateway session (no privileged intents, ignores all events) purely to project
presence: online, "Watching Grant's tasks". One instance covers every bot
that shares the token. Managed by presence-start.sh via cron.
"""

import asyncio
import json
import logging
import os
import random
import sys

import websockets

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s",
                    datefmt="%H:%M:%S")
log = logging.getLogger("presence")

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))


def load_env(path):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    os.environ.setdefault(k.strip(), v.strip())
    except FileNotFoundError:
        pass


load_env(os.path.join(SCRIPT_DIR, ".env"))
TOKEN = os.environ["DISCORD_BOT_TOKEN"]
GATEWAY = "wss://gateway.discord.gg/?v=10&encoding=json"

IDENTIFY = {
    "op": 2,
    "d": {
        "token": TOKEN,
        "intents": 0,
        "properties": {"os": "macos", "browser": "graice", "device": "graice"},
        "presence": {
            "status": "online",
            "since": None,
            "afk": False,
            "activities": [{"name": os.environ.get("PRESENCE_ACTIVITY", "the task board"), "type": 3}],  # "Watching"
        },
    },
}


async def heartbeat(ws, interval_ms):
    await asyncio.sleep(random.random() * interval_ms / 1000)
    while True:
        await ws.send(json.dumps({"op": 1, "d": None}))
        await asyncio.sleep(interval_ms / 1000)


async def session():
    async with websockets.connect(GATEWAY, max_size=2**23) as ws:
        hello = json.loads(await ws.recv())
        interval = hello["d"]["heartbeat_interval"]
        hb = asyncio.create_task(heartbeat(ws, interval))
        try:
            await ws.send(json.dumps(IDENTIFY))
            log.info("Connected — bot is online")
            async for raw in ws:
                msg = json.loads(raw)
                if msg.get("op") == 7:      # server asks for reconnect
                    log.info("Reconnect requested")
                    return
                if msg.get("op") == 9:      # invalid session
                    log.warning("Invalid session")
                    return
                # op 11 heartbeat-ack and dispatch events: nothing to do
        finally:
            hb.cancel()


async def main():
    backoff = 5
    while True:
        try:
            await session()
            backoff = 5  # clean server-initiated cycle → quick reconnect
        except Exception as e:
            log.warning("Gateway error: %s — retrying in %ds", e, backoff)
            await asyncio.sleep(backoff)
            backoff = min(backoff * 2, 300)
        await asyncio.sleep(2)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        sys.exit(0)
