---
name: meet-join
description: Join a Google Meet call as a participant and observe it. Use when asked to sit in on, join, attend, or listen to a meeting, or to create a meeting link. Also covers reading a meeting's transcript and participant list afterwards.
---

# Joining a Google Meet

## What is and isn't possible

The **Meet REST API cannot join a meeting.** It manages spaces and reads
after-the-fact artifacts. There is no join endpoint. Anyone who tells you
otherwise is guessing.

Joining happens through a **real browser session** signed in as a Google
identity, driven with `browseruse`. Live audio access is a separate Google
product (the Meet **Media API**, developer preview, requires allowlisting) —
until that's approved, treat "listen" as either (a) sitting in the room as a
visible participant, or (b) reading the transcript afterwards.

## Recording a meeting — the normal case

**Use the Recorder, not a browser on Grant's machine.** It joins as
**graice@matcherino.com** from inside a container whose screen and speakers
exist only in that container: nothing appears on Grant's display, nothing plays
through his speakers, and he can sit in the same call with no echo. It records
video + audio and transcribes locally (whisper.cpp, no API).

```bash
/Users/sharky/projekt/2/Recorder/start-recording.sh <meeting-url> [minutes]
```

This returns IMMEDIATELY with a job id — it does NOT block for the length of
the meeting. Never run `record-meeting.sh` directly from a conversation; it
blocks until the call ends and would freeze your session for an hour.

Then report the job to Grant and carry on. To check later:

```bash
/Users/sharky/projekt/2/Recorder/recording-status.sh [job]
```

When it finishes, `out/meeting-<stamp>.mp4` and `out/meeting-<stamp>.txt`
(the transcript) exist. Read the transcript to answer questions about what was
said — that is the point of the whole thing.

Default to 60 minutes unless Grant says otherwise. The recorder leaves on its
own when the call ends, so a generous limit costs nothing.

### Talking WITH Grant in the call

When Grant wants a conversation in the call — not just a recording — use:

```bash
BOT_DIR=<your bot dir> /Users/sharky/projekt/2/Recorder/join-call.sh <url> [minutes]
```

This joins with a microphone AND wires the call into your session. From then
on, **anything said out loud that includes your name arrives as a message,
exactly like a Discord message**, and whatever you reply is spoken back into
the call as well as posted to Discord. You do not poll anything; it just
arrives.

Use plain `start-recording.sh` instead when he only wants it recorded.

How to behave once you are in:

- **Only what names you reaches you.** People talking amongst themselves is not
  routed to you, by design — you are not in the conversation unless addressed.
- **One or two sentences.** Your answer is spoken aloud, and a paragraph
  arrives long after the moment has passed.
- **Never interject**, and do not narrate what you are doing.
- Roughly **2-4 seconds** pass between someone finishing a sentence and you
  hearing it. Expect to be slightly behind and do not fight it.
- You will not hear your own voice — that is deliberate, so you cannot end up
  answering yourself.
- The call ending stops all of this automatically.

### Never join twice

Once `start-recording.sh` returns a job, **you are already in the room.** Do not
also open a browser to "check", "verify", or "watch" — that puts a SECOND
participant in the call under a different name, and a browser on Grant's
machine plays meeting audio through his speakers, which is an echo loop when
he's in the same call. If you want to know what's happening, read the log via
`recording-status.sh`, not a browser.

The recorder has its own persistent login as graice@matcherino.com. **Never ask
Grant to sign a Chrome profile in for a meeting** — if a browser looks signed
out, that is irrelevant to recording, and asking him to fix it is a dead end.

### Live transcript, during the call

It starts **automatically** with every recording — you never set it up. Text
lands in `out/live-<container>/live.txt`, roughly **two seconds** behind the
speaker, one line per utterance with a timestamp:

```
[23:47:29] Revenue is up 11% this quarter.
```

Read that file to answer "what are they saying right now". The container name
comes from `recording-status.sh`.

It cuts on silence rather than on a timer, so lines appear when someone stops
talking. A long monologue flushes every 25s.

Runs locally by default (whisper.cpp on Metal) — free, and the audio never
leaves the machine. If a call has hard audio (several speakers, accents, bad
mics) and the transcript is visibly dropping words, rerun with `ASR=openai`,
which is more accurate but uploads each utterance.

### Talking in the call — OFF by default, and that is deliberate

**Do not use `--voice` unless Grant asks for it in that conversation.** The
normal job is to join, listen like any other participant, and record the
screen. Grant weighed the round-trip delay against the value and chose silence:
you answer in Discord, where there is no latency problem, not out loud.

Add `--voice` only when he explicitly asks you to speak in a call:

```bash
/Users/sharky/projekt/2/Recorder/start-recording.sh --voice <meeting-url> [minutes]
/Users/sharky/projekt/2/Recorder/speak.sh <container> "what you want to say"
```

`--voice` gives the browser a real microphone (a virtual one — the room hears
only what `speak.sh` plays into it, so you are still silent by default). Without
it there is no mic at all and `speak.sh` will refuse.

To sit in a call and answer when addressed:

```bash
/Users/sharky/projekt/2/Recorder/meet-listen.sh out/live-<id> --wait 120
```

It blocks until someone says your name (whisper mangles it — Gracie, Grace —
so it matches loosely), prints what they said, and exits. Loop it: listen →
think → `speak.sh` → listen again. Between calls you are still on Discord.

**Latency is real: ~20-35s** from someone finishing a sentence to you replying.
Say so rather than letting Grant think you are quick. Consequences:

- **Never interject.** Only speak when addressed by name. By the time you have
  something to say the topic has moved, and talking over people is worse than
  silence.
- Keep spoken replies to a sentence or two. Long answers arrive stale.
- If asked something you cannot answer fast, say a short "let me check" out
  loud and put the real answer in Discord.

### Never join twice

Once `start-recording.sh` returns a job, **you are already in the room.** Do not
also open a browser to "check", "verify", or "watch" — that puts a SECOND
participant in the call under a different name, and a browser on Grant's
machine plays meeting audio through his speakers, which is an echo loop when
he's in the same call. If you want to know what's happening, read the log via
`recording-status.sh`, not a browser.

The recorder has its own persistent login as graice@matcherino.com. **Never ask
Grant to sign a Chrome profile in for a meeting** — if a browser looks signed
out, that is irrelevant to recording, and asking him to fix it is a dead end.

### Live transcript, during the call

```bash
/Users/sharky/projekt/2/Recorder/live-transcribe.sh <container> &
```

The container name comes from `recording-status.sh` (e.g. `rec-30392`). Text
lands in `out/live-<id>/live.txt` and grows about once a minute — read that
file to answer "what are they saying right now". It runs a second audio tap and
does not disturb the recording.

Roughly a minute behind live, because whisper needs a closed chunk to work on.
Say that rather than implying it is instant. The in-progress mp4 itself is
unreadable until the call ends, so `live.txt` is the only live source.

**Say what you did**: "recording as Graice Matcherino, job rec-…". Grant cannot
see a container, so if you don't say it, he has no way to know it worked.

## Joining visibly (only when Grant asks to watch)

The browser path below runs on Grant's own machine as whichever Chrome profile you pick. It is the fallback, not the default.

Omit `--headed`. Headless is not a fallback, it is the right mode: no window
opens on Grant's screen, and headless Chrome reports **no microphone and no
speaker**, so the bot cannot broadcast and cannot pipe meeting audio back out
of Grant's speakers (which causes an echo loop when he's in the same call).

```bash
browseruse --profile Support --session meet open "https://meet.google.com/xxx-xxxx-xxx"
browseruse --session meet state
```

The headless join takes **two clicks**, both of which must be read out of
`state` (indices change every run — never hardcode them):

1. **"Join now"** — a normal button.
2. **"Continue without microphone"** — Meet asks this because headless has no
   mic. It lives inside a shadow-DOM dialog ("Do you want people to hear you in
   the meeting?"). `state` still lists it with an index; click that index.
   Until this is dismissed the page sits on "Still trying to get in…" and you
   are NOT in the meeting, even though in-call controls are visible.

Then confirm with the participants API below — the screen alone will mislead
you here.

Use `--headed` only when Grant explicitly wants to watch.

Notes that matter:

- `--profile` selects a **real Chrome profile**, which is what supplies the
  Google identity in the room. Run `browseruse --profile` with a bad name once
  to list the available profiles. Pick deliberately: whoever that profile is
  signed in as is who appears to the other participants.
- Pass `--profile` only on the FIRST call of a session. Repeating it on later
  calls errors with "session already running with different config" — after
  opening, just use `--session meet <command>`.
- After `open`, read `state`. Two shapes to distinguish:
  - **Pre-join**: a "Join now" / "Ask to join" button → click it, then re-read.
  - **Already in**: mic/camera toggles, meeting code, "Meeting details" →
    you're in the room.
- **Muting is automatic when headless** (there is no mic to broadcast). In
  `--headed` mode you MUST click "Turn off microphone" yourself, and be aware
  that the browser will also play meeting audio through Grant's speakers — if
  he is in the same call, that is an echo loop.
- Leave with `browseruse --session meet close`.

## Create a meeting (for tests, or to hand someone a link)

```bash
./gws-as <account> meet spaces create --params '{}'
```

Returns a `meetingUri` and `meetingCode`. To end it:

```bash
./gws-as <account> meet spaces endActiveConference --params '{"name":"spaces/XXXX"}'
```

## Confirm you really joined — don't trust the screen

```bash
./gws-as <account> meet conferenceRecords list --params '{"pageSize":1,"filter":"space.meeting_code=\"xxx-xxxx-xxx\""}'
./gws-as <account> meet conferenceRecords participants list --params '{"parent":"conferenceRecords/XXXX"}'
```

The participant list names who is actually in the room. Use it to verify your
own presence before telling Grant you're in, and to report who else is there.

## Afterwards

```bash
./gws-as <account> meet conferenceRecords transcripts list --params '{"parent":"conferenceRecords/XXXX"}'
./gws-as <account> meet conferenceRecords recordings list  --params '{"parent":"conferenceRecords/XXXX"}'
```

Transcripts exist only if transcription was turned on for that meeting, and
availability depends on the Workspace tier. If there's no transcript, say so —
don't summarize a meeting you have no record of.

## Requirements and failure modes

- Needs the Meet scopes (`meetings.space.created`, `.readonly`, `.settings`).
  If a Meet call 403s with "insufficient authentication scopes", that account
  was authorized without them — Grant must re-run `gws-bootstrap.sh` with the
  full scope list (a re-login REPLACES scopes, so it must include the existing
  ones too). You cannot fix this yourself.
- Headless needs no GUI session and opens no window. `--headed` does open a
  real window on whatever display the machine is signed into.
- Headless has **no speaker**, so the bot cannot hear live audio. That is fine
  for attending and for reading the transcript afterwards; it is the reason a
  live-listening setup needs either a virtual audio device in `--headed` mode
  or the Meet Media API.

## Rules

- **Never join a meeting Grant didn't ask you to join.** A bot appearing in
  someone's call unannounced is a real intrusion, not a quirk.
- **Say which identity joined.** "Joined as Matcherino Support", not "joined".
  The other participants see that name.
- **Mute on entry, always.**
- People are being recorded/observed when you're in a room. If Grant hasn't
  said the others know, ask before joining — some jurisdictions require every
  party to consent.
