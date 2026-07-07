#!/usr/bin/env python3
"""Ask a peer bot a question and print its reply.

A peer bot is another agent living in a shared Discord channel (set
PEER_CHANNEL_ID in .env). This posts a question there, waits for the reply
(collecting multi-message answers until they go quiet), and prints it.

Usage:
  ask_peer.py "<self-contained question>"
  ask_peer.py --listen    # wait for a reply to the last question WITHOUT re-posting

The peer bot is an agent — answers routinely take 3-6 minutes. If this
script times out, the question IS already posted: never re-ask; use --listen.
"""

import json
import os
import sys
import time
import urllib.error
import urllib.request

CHANNEL_ID = ""  # set below from .env: PEER_CHANNEL_ID
FIRST_REPLY_TIMEOUT = 2400  # agentic bot — give it up to 40 minutes
QUIET_PERIOD = 10           # reply considered complete after 10s of silence
POLL_INTERVAL = 3

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
CHANNEL_ID = os.environ.get("PEER_CHANNEL_ID", "")
if not CHANNEL_ID:
    raise SystemExit("PEER_CHANNEL_ID is not set in .env — no peer bot configured")
HEADERS = {
    "Authorization": f"Bot {os.environ['DISCORD_BOT_TOKEN']}",
    "Content-Type": "application/json",
    "User-Agent": "GraiceBot (https://matcherino.com, 1.0)",
}


def discord(method, path, body=None):
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(
        f"https://discord.com/api/v10{path}", data=data, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=30) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        detail = e.read().decode(errors="replace")[:200]
        if e.code == 429:
            time.sleep(json.loads(detail).get("retry_after", 5))
            return discord(method, path, body)
        raise SystemExit(f"discord {method} {path} -> {e.code}: {detail}")


def post_question(me: dict, question: str) -> str:
    """Post the question; if the POST errors ambiguously, check whether it
    actually landed before letting the caller believe it didn't."""
    try:
        sent = discord("POST", f"/channels/{CHANNEL_ID}/messages", {"content": question[:2000]})
        return sent["id"]
    except (SystemExit, OSError) as e:
        time.sleep(3)
        for m in discord("GET", f"/channels/{CHANNEL_ID}/messages?limit=5") or []:
            if m["author"]["id"] == me["id"] and m.get("content", "") == question[:2000]:
                return m["id"]  # it landed despite the error — do not re-post
        raise SystemExit(f"posting the question failed ({e}) and it is NOT in the "
                         "channel — safe to re-run this script")


def last_own_message_id(me: dict) -> str:
    for m in discord("GET", f"/channels/{CHANNEL_ID}/messages?limit=50") or []:
        if m["author"]["id"] == me["id"]:
            return m["id"]
    raise SystemExit("--listen: no previous question of mine found in the channel")


def main():
    if len(sys.argv) < 2 or not sys.argv[1].strip():
        raise SystemExit('usage: ask_peer.py "<question>"  |  ask_peer.py --listen')

    me = discord("GET", "/users/@me")
    if sys.argv[1].strip() == "--listen":
        watermark = last_own_message_id(me)
    else:
        question = " ".join(sys.argv[1:]).strip()
        watermark = post_question(me, question)

    replies, last_reply_at = [], None
    deadline = time.time() + FIRST_REPLY_TIMEOUT
    while True:
        now = time.time()
        if not replies and now > deadline:
            raise SystemExit(
                f"no reply from the peer bot within {FIRST_REPLY_TIMEOUT}s. "
                "The question IS posted — do NOT re-ask it. To keep waiting, run: "
                "python3 ask_peer.py --listen")
        if replies and now - last_reply_at > QUIET_PERIOD:
            break
        time.sleep(POLL_INTERVAL)
        msgs = discord("GET", f"/channels/{CHANNEL_ID}/messages?limit=20&after={watermark}") or []
        for m in sorted(msgs, key=lambda m: m["id"]):
            watermark = max(watermark, m["id"])
            if m["author"]["id"] == me["id"]:
                continue
            text = m.get("content", "").strip()
            if text:
                replies.append(text)
                last_reply_at = time.time()

    print("\n".join(replies))


if __name__ == "__main__":
    main()
