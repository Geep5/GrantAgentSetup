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

## Join a meeting

```bash
browseruse --profile Support --session meet --headed open "https://meet.google.com/xxx-xxxx-xxx"
browseruse --session meet state          # read the screen
```

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
- **Mute immediately on joining.** Click the "Turn off microphone" control. A
  listener must never broadcast — the room may otherwise hear the machine.
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
- Joining needs a **GUI session** on the machine — Chrome opens a real window.

## Rules

- **Never join a meeting Grant didn't ask you to join.** A bot appearing in
  someone's call unannounced is a real intrusion, not a quirk.
- **Say which identity joined.** "Joined as Matcherino Support", not "joined".
  The other participants see that name.
- **Mute on entry, always.**
- People are being recorded/observed when you're in a room. If Grant hasn't
  said the others know, ask before joining — some jurisdictions require every
  party to consent.
