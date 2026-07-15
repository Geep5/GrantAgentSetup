#!/usr/bin/env python3
"""Discord ⇄ omp agent bridge — one work-session per cron fire.

The blueprint bot: a Discord channel is the conversation surface, an `omp`
RPC agent (with the SYSTEM_PROMPT.md persona) is the brain, and an Anytype
board is the durable task memory. Everything project-specific comes from
.env and SYSTEM_PROMPT.md — this file should not need editing per install.

Lifecycle: cron runs start.sh every ~10 minutes. This script gates itself
(lockfile + state/next_run) and exits silently when no session is due. A
session runs until the agent emits [SESSION_END] after the human confirms
the task is done and names the next run time; the agent writes that time to
state/next_run before ending.

Battle-tested fixes baked in (do not regress these):
- _extract_text collects ALL assistant text of a turn, not just the last
  message (long tool-using turns end with a terse sign-off; the substantive
  answer lives in intermediate messages). Its turn boundary is a
  bridge-formatted user message ("[Discord message from" / "[System]") —
  omp-injected user-role entries (rule interrupts, summaries) must NOT
  truncate the walk.
- One prompt can produce SEVERAL agent_start/agent_end cycles (omp's rule
  engine and todo reminders interrupt/restart the agent mid-turn), and each
  agent_end may carry only its own slice of messages. _wait_for_response
  waits for quiescence and _merge_turn_texts stitches every cycle's text —
  returning at the first agent_end posts a fragment and orphans the answer.
- THE LOAD-BEARING ONE: agent_end.messages is UNRELIABLE — sometimes the
  whole run, sometimes ONLY the final message (proven by sandbox replay; a
  38-minute turn's 16k-char analysis arrived as a 309-char sign-off). The
  session .jsonl is the only complete record, so _collect_turn_text reads
  everything appended since _session_snapshot() marked the file at
  prompt-send; event-derived text is a fallback only. Never go back to
  trusting agent_end for content.
- A wait period (state/next_run) only schedules the auto-ping — it never
  means "stop listening". The cron gate wakes early when a human posted
  after the bot's last message, and the kickoff watermark starts at the
  bot's own last post so messages sent while asleep are steered in, not
  skipped.
- Attachments are downloaded and images injected inline via omp's @file
  syntax; attachment-only messages count as real messages.
- Message steering mid-turn; stale-event draining; fatal-kickoff backoff.
- Deferred sends ("Send Date" property) can wake sessions early.
"""

import json
import logging
import os
import queue
import re
import shutil
import subprocess
import sys
import threading
import time
import urllib.error
import urllib.request
from datetime import datetime, timezone

# ---------------------------------------------------------------------------
# Config — everything project-specific comes from .env
# ---------------------------------------------------------------------------

def load_env(path: str):
    try:
        with open(path) as f:
            for line in f:
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if "=" in line:
                    k, v = line.split("=", 1)
                    os.environ[k.strip()] = v.strip()
    except FileNotFoundError:
        pass

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
load_env(os.path.join(SCRIPT_DIR, ".env"))

AGENT_NAME = os.environ.get("AGENT_NAME", "agent")

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(AGENT_NAME)

BOT_TOKEN = os.environ["DISCORD_BOT_TOKEN"]
CHANNEL_ID = os.environ["DISCORD_CHANNEL_ID"]
OMP_MODEL = os.environ.get("OMP_MODEL", "opus")
OMP_BIN = os.environ.get("OMP_BIN", os.path.expanduser("~/.local/bin/omp"))
POLL_INTERVAL = float(os.environ.get("POLL_INTERVAL", "3"))
# Bot accounts allowed to wake/steer this bot like a human (e.g. the hub
# coordinator relaying Grant's messages). Comma-separated user ids.
WAKE_BOT_IDS = {i.strip() for i in os.environ.get("WAKE_BOT_IDS", "").split(",") if i.strip()}
AGENT_TIMEOUT = float(os.environ.get("AGENT_TIMEOUT", "3000"))  # per prompt

SYSTEM_PROMPT_PATH = os.path.join(SCRIPT_DIR, "SYSTEM_PROMPT.md")
STATE_DIR = os.path.join(SCRIPT_DIR, "state")
LOCK_FILE = os.path.join(STATE_DIR, "lock")
NEXT_RUN_FILE = os.path.join(STATE_DIR, "next_run")
SESSION_DIR = os.path.join(SCRIPT_DIR, "sessions", "main")
ATTACH_DIR = os.path.join(SCRIPT_DIR, "attachments")
SESSION_END_MARKER = "[SESSION_END]"

# Optional: Anytype deferred-send watching (all three must be set to enable)
ANYTYPE_API_KEY = os.environ.get("ANYTYPE_API_KEY", "")
ANYTYPE_SPACE_ID = os.environ.get("ANYTYPE_SPACE_ID", "")
ANYTYPE_BOARD_ID = os.environ.get("ANYTYPE_BOARD_ID", "")
SEND_DATE_KEY = os.environ.get("SEND_DATE_KEY", "send_date")
# Boards to watch for deferred sends. Either the single pair above, or
# ANYTYPE_BOARDS="<space>:<board>,<space>:<board>" for multi-board bots.
ANYTYPE_BOARDS = [tuple(p.split(":", 1)) for p in
                  os.environ.get("ANYTYPE_BOARDS", "").split(",") if ":" in p]
if not ANYTYPE_BOARDS and ANYTYPE_SPACE_ID and ANYTYPE_BOARD_ID:
    ANYTYPE_BOARDS = [(ANYTYPE_SPACE_ID, ANYTYPE_BOARD_ID)]
SENDS_ENABLED = bool(ANYTYPE_API_KEY and ANYTYPE_BOARDS)

# Optional: mirror pending sends into a Crony dashboard file
CRONY_TOML = os.environ.get("CRONY_TOML", "")
SEND_EMOJI = os.environ.get("SEND_EMOJI", "✉️")
SENDS_BEGIN = f"# >>> {AGENT_NAME}-sends (auto-managed, do not edit by hand)"
SENDS_END = f"# <<< {AGENT_NAME}-sends"

DISCORD_API = "https://discord.com/api/v10"
HEADERS = {
    "Authorization": f"Bot {BOT_TOKEN}",
    "Content-Type": "application/json",
    "User-Agent": f"{AGENT_NAME}Bot (agent-bridge, 1.0)",
}

# ---------------------------------------------------------------------------
# Deferred sends — tasks with a "Send Date" that the agent must ping about
# ---------------------------------------------------------------------------

def fetch_pending_sends() -> list[dict]:
    """Open (not-done) tasks carrying a Send Date, soonest first.

    A date-only value is treated as 9am local so pings land in the morning.
    """
    if not SENDS_ENABLED:
        return []
    rows = []
    for space_id, board_id in ANYTYPE_BOARDS:
        url = (f"http://localhost:31009/v1/spaces/{space_id}/lists/"
               f"{board_id}/views/default/objects?limit=100")
        req = urllib.request.Request(url, headers={
            "Authorization": f"Bearer {ANYTYPE_API_KEY}",
            "Anytype-Version": "2025-11-08",
        })
        with urllib.request.urlopen(req, timeout=15) as resp:
            rows.extend(json.loads(resp.read()).get("data", []))

    pending = []
    for obj in rows:
        props = {p.get("key"): p for p in obj.get("properties", [])}
        if props.get("done", {}).get("checkbox"):
            continue  # board views don't always filter done — check ourselves
        for p in obj.get("properties", []):
            if p.get("key") == SEND_DATE_KEY and p.get("date"):
                due = datetime.fromisoformat(
                    p["date"].replace("Z", "+00:00")).astimezone()
                if (due.hour, due.minute) == (0, 0):  # date-only → 9am
                    due = due.replace(hour=9)
                pending.append({"name": obj.get("name", "?"), "id": obj["id"], "due": due})
    return sorted(pending, key=lambda t: t["due"])


def sync_crony_sends(pending: list[dict]):
    """Mirror pending sends into the Crony dashboard as one-shot `at` jobs."""
    if not CRONY_TOML:
        return
    block = [SENDS_BEGIN]
    for t in pending:
        block += [
            "",
            "[[jobs]]",
            f'name = "{SEND_EMOJI} Send: {t["name"][:50]}"',
            f'at = "{t["due"].strftime("%Y-%m-%d %H:%M")}"',
            f'folder = "{SCRIPT_DIR}"',
            'description = "approved item waiting — the agent pings when this comes due"',
            'tags = ["send"]',
        ]
    block.append(SENDS_END)
    new_block = "\n".join(block)
    try:
        text = open(CRONY_TOML).read()
    except FileNotFoundError:
        return
    if SENDS_BEGIN in text:
        head, rest = text.split(SENDS_BEGIN, 1)
        tail = rest.split(SENDS_END, 1)[1] if SENDS_END in rest else "\n"
        updated = head + new_block + tail
    else:
        updated = text.rstrip("\n") + "\n\n" + new_block + "\n"
    if updated != text:
        open(CRONY_TOML, "w").write(updated)
        log.info("Synced %d pending send(s) to dashboard", len(pending))


# ---------------------------------------------------------------------------
# Startup gates — safe to run every few minutes from cron
# ---------------------------------------------------------------------------

def unseen_human_messages() -> bool:
    """True if a human posted after the bot's last message — someone is
    talking to a sleeping bot. A wait period only schedules the auto-ping;
    it never means "stop listening"."""
    try:
        me = get_bot_user_id()
        recent = get_messages(CHANNEL_ID, limit=25)
    except Exception as e:
        log.warning("Unseen-message check failed (continuing): %s", e)
        return False
    for m in sorted(recent, key=lambda m: m["id"], reverse=True):
        if m["author"]["id"] == me:
            return False  # we spoke last — nothing pending
        if (not m["author"].get("bot") or m["author"]["id"] in WAKE_BOT_IDS) and (
                m.get("content", "").strip() or m.get("attachments")):
            return True
    return False


def gate_or_exit() -> list[dict]:
    os.makedirs(STATE_DIR, exist_ok=True)

    # Gate 1: another session already running?
    if os.path.exists(LOCK_FILE):
        try:
            pid = int(open(LOCK_FILE).read().strip())
            os.kill(pid, 0)  # raises if dead
            sys.exit(0)  # alive — quietly stand down
        except (ValueError, ProcessLookupError, PermissionError):
            log.info("Stale lock (pid gone), taking over")

    # Deferred sends: a due send overrides next_run.
    due_sends: list[dict] = []
    try:
        pending = fetch_pending_sends()
        sync_crony_sends(pending)
        now_local = datetime.now().astimezone()
        due_sends = [t for t in pending if t["due"] <= now_local]
    except Exception as e:
        log.warning("Pending-send check failed (continuing): %s", e)

    # Gate 2: is it time yet?
    if not due_sends:
        try:
            next_run = open(NEXT_RUN_FILE).read().strip()
            due = datetime.fromisoformat(next_run.replace("Z", "+00:00"))
            if datetime.now(timezone.utc) < due:
                if not unseen_human_messages():
                    sys.exit(0)  # not yet — quietly stand down
                log.info("Waking early — new message arrived during the wait")
        except FileNotFoundError:
            pass  # no next_run recorded → a session is due
        except ValueError as e:
            log.warning("Unparseable next_run (%s) — treating session as due", e)

    with open(LOCK_FILE, "w") as f:
        f.write(str(os.getpid()))
    return due_sends


def release_lock():
    try:
        os.remove(LOCK_FILE)
    except FileNotFoundError:
        pass

# ---------------------------------------------------------------------------
# Discord REST helpers
# ---------------------------------------------------------------------------

def discord_request(method: str, path: str, body=None, timeout: int = 30):
    url = f"{DISCORD_API}{path}"
    data = json.dumps(body).encode() if body else None
    req = urllib.request.Request(url, data=data, headers=HEADERS, method=method)
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        error_body = e.read().decode(errors="replace")
        log.error("Discord %s %s → %s: %s", method, path, e.code, error_body)
        if e.code == 429:
            time.sleep(json.loads(error_body).get("retry_after", 5))
        return None
    except (urllib.error.URLError, TimeoutError, OSError) as e:
        log.error("Discord %s %s → network error: %s", method, path, e)
        return None


def get_bot_user_id() -> str:
    me = discord_request("GET", "/users/@me")
    if not me:
        raise RuntimeError("Failed to fetch bot user — check DISCORD_BOT_TOKEN")
    log.info("Bot user: %s (id=%s)", me["username"], me["id"])
    return me["id"]


def get_messages(channel_id: str, limit: int = 10, after: str | None = None) -> list[dict]:
    qs = f"?limit={limit}"
    if after:
        qs += f"&after={after}"
    return discord_request("GET", f"/channels/{channel_id}/messages{qs}") or []


def send_message(channel_id: str, content: str):
    return discord_request("POST", f"/channels/{channel_id}/messages", {"content": content})


def send_typing(channel_id: str):
    discord_request("POST", f"/channels/{channel_id}/typing")


def build_user_message(msg: dict) -> str:
    """Format a Discord message for the agent, downloading any attachments.

    Images are injected inline via omp's @file syntax so the agent sees them
    directly; other files are referenced by path for its read tool.
    """
    name = msg["author"].get("global_name") or msg["author"].get("username", "user")
    parts = [f"[Discord message from {name}]"]
    content = msg.get("content", "").strip()
    if content:
        parts.append(content)
    for a in msg.get("attachments", []):
        os.makedirs(ATTACH_DIR, exist_ok=True)
        safe_name = re.sub(r"[^\w.-]", "_", a.get("filename", "file"))
        path = os.path.join(ATTACH_DIR, f"{msg['id']}-{safe_name}")
        try:
            if not os.path.exists(path):
                req = urllib.request.Request(
                    a["url"], headers={"User-Agent": HEADERS["User-Agent"]})
                with urllib.request.urlopen(req, timeout=60) as resp:
                    with open(path, "wb") as f:
                        f.write(resp.read())
            rel = os.path.relpath(path, SCRIPT_DIR)
            ctype = a.get("content_type", "")
            if ctype.startswith("image/"):
                parts.append(f"@{rel}")
                parts.append(f"[attached image, shown above; saved at {rel}]")
            else:
                parts.append(f"[attached file ({ctype}): {rel} — read it with your file tools]")
        except Exception as e:
            log.error("Attachment download failed (%s): %s", a.get("filename"), e)
            parts.append(f"[attachment {a.get('filename')} failed to download: {e}]")
    return "\n".join(parts)


def split_message(text: str, max_len: int = 2000) -> list[str]:
    if len(text) <= max_len:
        return [text]
    chunks = []
    while text:
        if len(text) <= max_len:
            chunks.append(text)
            break
        cut = text.rfind("\n", 0, max_len)
        if cut <= 0:
            cut = max_len
        chunks.append(text[:cut])
        text = text[cut:].lstrip("\n")
    return chunks

# ---------------------------------------------------------------------------
# omp RPC agent
# ---------------------------------------------------------------------------

class OmpAgent:
    def __init__(self):
        self.proc: subprocess.Popen | None = None
        self.event_queue: queue.Queue = queue.Queue()
        self._lock = threading.Lock()

    def start(self):
        os.makedirs(SESSION_DIR, exist_ok=True)
        with open(SYSTEM_PROMPT_PATH) as f:
            system_prompt = f.read()

        has_prior_session = any(f.endswith(".jsonl") for f in os.listdir(SESSION_DIR))
        cmd = [
            OMP_BIN,
            "--mode", "rpc",
            "--model", OMP_MODEL,
            "--system-prompt", system_prompt,
            "--session-dir", SESSION_DIR,
        ]
        if has_prior_session:
            cmd.append("--continue")
            log.info("Resuming interrupted session")
        self.proc = subprocess.Popen(
            cmd,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            cwd=SCRIPT_DIR,
            env=os.environ.copy(),
        )
        self.event_queue = queue.Queue()
        threading.Thread(target=self._read_stdout, daemon=True).start()
        threading.Thread(target=self._read_stderr, daemon=True).start()

        try:
            ev = self.event_queue.get(timeout=30)
            if ev is None:
                raise RuntimeError("omp exited before ready")
            if json.loads(ev).get("type") != "ready":
                raise RuntimeError(f"Expected ready event, got: {ev}")
            log.info("omp RPC ready (model=%s)", OMP_MODEL)
        except queue.Empty:
            raise RuntimeError("Timed out waiting for omp ready event")

    def _read_stdout(self):
        assert self.proc and self.proc.stdout
        for line in self.proc.stdout:
            decoded = line.decode("utf-8", errors="replace").strip()
            if decoded:
                self.event_queue.put(decoded)
        self.event_queue.put(None)

    def _read_stderr(self):
        assert self.proc and self.proc.stderr
        for line in self.proc.stderr:
            text = line.decode("utf-8", errors="replace").strip()
            if text:
                log.info("omp stderr: %s", text)

    def is_alive(self) -> bool:
        return self.proc is not None and self.proc.poll() is None

    def _send_rpc(self, msg_type: str, text: str):
        assert self.proc and self.proc.stdin
        self.proc.stdin.write((json.dumps({"type": msg_type, "message": text}) + "\n").encode())
        self.proc.stdin.flush()

    def send_prompt(self, text: str, channel_id: str, bot_user_id: str, watermark: str) -> tuple[str, str]:
        """Send a prompt, block until agent_end. Steers mid-task replies into
        the running agent. Returns (response, watermark)."""
        with self._lock:
            if not self.is_alive():
                log.warning("omp not alive, restarting...")
                self.start()

            while not self.event_queue.empty():
                try:
                    self.event_queue.get_nowait()
                except queue.Empty:
                    break

            self._session_snapshot()
            self._send_rpc("prompt", text)

            typing_stop = threading.Event()

            def background_loop():
                nonlocal watermark
                while not typing_stop.is_set():
                    if typing_stop.wait(5):
                        break
                    send_typing(channel_id)
                    try:
                        new_msgs = get_messages(channel_id, limit=10, after=watermark)
                    except Exception:
                        continue
                    for m in sorted(new_msgs, key=lambda m: m["id"]):
                        if m["id"] > watermark:
                            watermark = m["id"]
                        if m["author"]["id"] == bot_user_id or not (
                                m.get("content", "").strip() or m.get("attachments")):
                            continue
                        log.info("Steering message: %s", m.get("content", "")[:100])
                        try:
                            self._send_rpc("steer", build_user_message(m))
                        except Exception as e:
                            log.error("Failed to steer: %s", e)

            bg = threading.Thread(target=background_loop, daemon=True)
            send_typing(channel_id)
            bg.start()
            try:
                return self._wait_for_response(), watermark
            finally:
                typing_stop.set()
                bg.join(timeout=2)

    def _wait_for_response(self) -> str:
        """Wait for the turn to FULLY finish and return ALL of its text.

        One prompt does not always mean one agent_end: omp's rule engine and
        todo reminders can interrupt/restart the agent mid-turn, producing
        several agent_start/agent_end cycles per prompt — and each cycle's
        agent_end may carry only ITS OWN slice of messages. So: extract text
        from EVERY agent_end, keep waiting while the agent keeps cycling
        (linger QUIET_SECS after each end), and merge the pieces at the end."""
        QUIET_SECS = 6.0
        deadline = time.time() + AGENT_TIMEOUT
        agent_started = False
        texts: list[str] = []
        while True:
            remaining = deadline - time.time()
            if remaining <= 0:
                done = self._collect_turn_text(self._merge_turn_texts(texts))
                if done and texts:
                    return done
                if done:
                    return done + "\n\n[Agent timed out mid-task - more may follow next session]"
                return "[Agent timed out - the task may still be running]"
            timeout = min(remaining, QUIET_SECS if texts else 30)
            try:
                ev = self.event_queue.get(timeout=timeout)
            except queue.Empty:
                if texts:  # quiet after an agent_end: turn is done
                    return (self._collect_turn_text(self._merge_turn_texts(texts))
                            or "[No response from agent]")
                continue
            if ev is None:
                done = self._collect_turn_text(self._merge_turn_texts(texts))
                if texts:
                    return done or "[No response from agent]"
                # crashed mid-turn: deliver whatever the agent DID say
                return ((done + "\n\n") if done else "") + \
                    "[Agent process crashed - will resume next session]"
            try:
                data = json.loads(ev)
            except json.JSONDecodeError:
                continue
            ev_type = data.get("type")
            if ev_type == "agent_start":
                agent_started = True
            if ev_type in ("tool_execution_start", "tool_execution_end"):
                tool = (data.get("tool", {}) or {}).get("name") or data.get("toolName") or "tool"
                log.info("omp %s: %s", "start" if ev_type.endswith("start") else "done", tool)
            if ev_type == "response" and not data.get("success"):
                error = data.get("error", "unknown error")
                if not agent_started and not texts:
                    return f"[Agent error: {error}]"
                log.warning("Steer error (continuing): %s", error)
            if ev_type == "agent_end":
                texts.append(self._extract_text(data))

    def _latest_session_file(self):
        try:
            files = [os.path.join(SESSION_DIR, f) for f in os.listdir(SESSION_DIR)
                     if f.endswith(".jsonl")]
            return max(files, key=os.path.getmtime) if files else None
        except FileNotFoundError:
            return None

    def _session_snapshot(self):
        """Mark where the session file ends as a prompt goes out; the turn's
        text is everything the agent appends after this point."""
        f = self._latest_session_file()
        self._turn_file = f
        self._turn_offset = os.path.getsize(f) if f else 0

    @staticmethod
    def _entry_text(msg: dict) -> str:
        c = msg.get("content")
        if isinstance(c, str):
            return c
        if isinstance(c, list):
            return "\n".join(b.get("text", "") for b in c
                             if isinstance(b, dict) and b.get("type") == "text"
                             and b.get("text", "").strip())
        return ""

    def _collect_turn_text(self, event_text: str) -> str:
        """The session .jsonl is the source of truth for what the agent said.

        agent_end events carry an UNRELIABLE subset of the turn's messages
        (sometimes the whole run, sometimes only the final message), so a
        long turn's substantive answer can be missing from every event. Read
        everything appended to the session file since the prompt went out;
        fall back to the event-derived text only if the file yields nothing.
        """
        f = self._latest_session_file()
        if f is None:
            return event_text
        offset = self._turn_offset if f == getattr(self, "_turn_file", None) else 0
        tail = (event_text or "").strip()[-60:]
        for attempt in range(3):
            parts = []
            try:
                with open(f, "rb") as fh:
                    fh.seek(offset)
                    data = fh.read().decode("utf-8", errors="replace")
            except OSError as e:
                log.warning("Session-file read failed (%s) - using event text", e)
                return event_text
            for line in data.splitlines():
                line = line.strip()
                if not line:
                    continue
                try:
                    e = json.loads(line)
                except json.JSONDecodeError:
                    continue  # partial trailing line mid-flush
                if e.get("type") != "message":
                    continue
                m = e.get("message", {})
                if m.get("role") != "assistant":
                    continue
                t = self._entry_text(m).strip()
                if t:
                    parts.append(t)
            text = "\n\n".join(parts)
            # if omp hasn't flushed the final message yet, wait and re-read
            if not tail or tail in text or attempt == 2:
                if text:
                    return text
                break
            time.sleep(1.5)
        return event_text

    @staticmethod
    def _merge_turn_texts(texts: list[str]) -> str:
        """Merge per-cycle extractions into one turn: a later piece that
        contains what we have replaces it (full-history agent_end); a piece
        already inside what we have is dropped; anything else is new text."""
        final = ""
        for t in texts:
            t = (t or "").strip()
            if not t:
                continue
            if final and final in t:
                final = t          # superset — later end carried full history
            elif t in final:
                continue           # duplicate slice
            elif final:
                final = final + "\n\n" + t
            else:
                final = t
        return final

    @staticmethod
    def _extract_text(agent_end_event: dict) -> str:
        """Collect ALL assistant text of the current turn (everything since the
        last real user message). Long tool-using turns put the substantive
        answer in intermediate assistant messages and end with a brief
        sign-off - returning only the last message silently drops the answer.
        Tool results arrive as role "toolResult" (not "user"), so breaking on
        "user" bounds exactly one turn."""
        parts: list[str] = []
        error = ""
        for msg in reversed(agent_end_event.get("messages", [])):
            role = msg.get("role")
            if role == "user":
                c = msg.get("content")
                text = c if isinstance(c, str) else "".join(
                    b.get("text", "") for b in (c or [])
                    if isinstance(b, dict) and b.get("type") == "text")
                if text.lstrip().startswith(("[Discord message from", "[System]")):
                    break  # a real bridge prompt - this bounds the turn
                continue  # injected rule-interrupt/summary, not a turn boundary
            if role != "assistant":
                continue  # toolResult / developer entries
            texts = [b.get("text", "") for b in msg.get("content", [])
                     if isinstance(b, dict) and b.get("type") == "text"]
            text = "\n".join(t for t in texts if t.strip())
            if text:
                parts.append(text)
            if msg.get("stopReason") == "error" and msg.get("errorMessage"):
                error = f"[Agent error: {msg['errorMessage']}]"
        parts.reverse()
        return "\n\n".join(parts) or error

    def stop(self):
        if self.proc:
            self.proc.terminate()
            try:
                self.proc.wait(timeout=5)
            except subprocess.TimeoutExpired:
                self.proc.kill()
            self.proc = None

# ---------------------------------------------------------------------------
# Session
# ---------------------------------------------------------------------------

KICKOFF_PROMPT = (
    "[System] A new work-session has started. Follow your mission: read the "
    "task board, pick the task you'd recommend for this session (resume any "
    "task already In Progress), then greet the user in the channel with your "
    "recommendation, why, and a quick rundown of what else is on the board so "
    "they can redirect. Once the task is settled, dig in and present your "
    "outline with your first question."
)

RESUME_PROMPT = (
    "[System] The previous session was interrupted and has been resumed. "
    "IMPORTANT: anything you wrote after the human's last message may have "
    "died with the interruption and NEVER reached Discord — do not assume "
    "they saw your latest answer, recommendation, or question. Re-read the "
    "tail of the conversation, and if your last substantive message came "
    "after theirs, RESTATE it in full now (not a summary of it). Then "
    "re-read the task object to re-ground yourself and pick up exactly "
    "where things left off."
)


def archive_session():
    """Move the finished session out of the way so the next fire starts fresh."""
    if os.path.isdir(SESSION_DIR) and os.listdir(SESSION_DIR):
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
        shutil.move(SESSION_DIR, os.path.join(SCRIPT_DIR, "sessions", f"done-{stamp}"))


def post_response(channel_id: str, response: str) -> bool:
    """Post agent text to Discord. Returns True if the session should end."""
    ended = SESSION_END_MARKER in response
    text = response.replace(SESSION_END_MARKER, "").strip()
    if text:
        for chunk in split_message(text):
            send_message(channel_id, chunk)
            time.sleep(0.5)
    return ended


def main():
    due_sends = gate_or_exit()
    log.info("Session due — starting %s (%d due send(s))", AGENT_NAME, len(due_sends))
    try:
        resumed = os.path.isdir(SESSION_DIR) and any(
            f.endswith(".jsonl") for f in os.listdir(SESSION_DIR))

        bot_user_id = get_bot_user_id()
        channel_id = CHANNEL_ID
        log.info("Channel: %s", channel_id)

        initial = get_messages(channel_id, limit=25)
        # Watermark starts at OUR last post, not the channel's newest message:
        # anything a human sent while no session was running is then steered
        # into the kickoff turn instead of being silently skipped.
        bot_msgs = [m["id"] for m in initial if m["author"]["id"] == bot_user_id]
        if bot_msgs:
            watermark = max(bot_msgs)
        else:
            watermark = initial[0]["id"] if initial else "0"
        unseen = [m for m in initial
                  if m["id"] > watermark and m["author"]["id"] != bot_user_id
                  and (m.get("content", "").strip() or m.get("attachments"))]

        agent = OmpAgent()
        agent.start()

        kickoff = RESUME_PROMPT if resumed else KICKOFF_PROMPT
        if unseen:
            kickoff += (
                f"\n[System] {len(unseen)} message(s) arrived while you were "
                "asleep; they will be delivered to you right after this. Answer "
                "them directly — skip the generic session greeting.")
        if due_sends:
            listing = "; ".join(
                f'"{t["name"]}" (send date {t["due"].strftime("%b %-d %H:%M")})'
                for t in due_sends)
            kickoff += (
                f"\n[System] PRIORITY: these tasks have reached their Send Date: {listing}. "
                "Before anything else, ping the user about getting them out the door — "
                "the items are already approved; remind them where each one lives and "
                "offer to help with any final tweaks.")
        response, watermark = agent.send_prompt(
            kickoff, channel_id, bot_user_id, watermark)

        # A kickoff that dies before the agent even starts (auth, config) can't
        # recover mid-session: tell the user once, back off, let a later fire retry.
        if response.startswith(("[Agent error:", "[Agent process crashed")):
            log.error("Fatal kickoff failure: %s", response[:200])
            from datetime import timedelta
            retry_at = datetime.now(timezone.utc) + timedelta(hours=2)
            with open(NEXT_RUN_FILE, "w") as f:
                f.write(retry_at.strftime("%Y-%m-%dT%H:%M:%SZ"))
            send_message(channel_id,
                         f"⚠️ I couldn't start my brain: {response[:500]}\n"
                         f"I'll retry in ~2h. To retry sooner once it's fixed: "
                         f"delete state/next_run in my folder (I fire within 10 min).")
            agent.stop()
            shutil.rmtree(SESSION_DIR, ignore_errors=True)  # retry fresh, not resumed
            return

        if post_response(channel_id, response):
            log.info("Session ended at kickoff")
            agent.stop()
            archive_session()
            return

        log.info("Polling channel every %.0fs — session runs until %s",
                 POLL_INTERVAL, SESSION_END_MARKER)
        while True:
            time.sleep(POLL_INTERVAL)
            try:
                messages = get_messages(channel_id, limit=10, after=watermark)
            except Exception as e:
                log.error("Failed to fetch messages: %s", e)
                continue
            for msg in sorted(messages, key=lambda m: m["id"]):
                if msg["id"] > watermark:
                    watermark = msg["id"]
                if msg["author"]["id"] == bot_user_id or not (
                        msg.get("content", "").strip() or msg.get("attachments")):
                    continue
                log.info("Message from %s: %s (%d attachments)",
                         msg["author"].get("username", "?"),
                         msg.get("content", "")[:100], len(msg.get("attachments", [])))
                try:
                    response, watermark = agent.send_prompt(
                        build_user_message(msg),
                        channel_id, bot_user_id, watermark)
                except Exception as e:
                    log.error("Agent error: %s", e)
                    response = f"[Bot error: {e}]"
                if post_response(channel_id, response):
                    log.info("Session complete")
                    agent.stop()
                    archive_session()
                    return
    finally:
        release_lock()


if __name__ == "__main__":
    main()
