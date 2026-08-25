# Task object template

The shape every task object should hold. Not a form to fill — a worktop that
shows, at a glance, where the job is and what happens next.

Two constraints drive it:

- **Grant reads it on a phone.** Checklists scan; prose does not.
- **Graice re-reads it into her context every ~30 minutes.** Anything left in
  it is paid for again and again, and crowds out the conversation itself. Keep
  it under ~2000 characters or the bridge truncates it and she works from half
  a task.

---

```markdown
**Vitals** · started YYYY-MM-DD · touched YYYY-MM-DD · status <one word>

**Done means:** one sentence Grant would agree to before the work starts.

## Now
- [ ] the single next thing, or "waiting on Grant: <what>"

## Checklist
- [x] finished
- [ ] not yet

## Decided
- the decision, one line — not the argument for it

## Deliverable
- what shipped and where it lives (commit, file, link)

## Log
- YYYY-MM-DD — one line, only for things worth remembering later
```

---

## Rules

**Vitals is machine-writable.** One line, fixed order, ` · ` separated. A cron
job will eventually own it — keep it parseable and never bury it in prose.

**One `## Now` item.** If there are two, one of them is not now. If the answer
is "waiting on Grant", say exactly what is being waited for.

**The checklist is the state of the work**, not a plan. Tick items as they
land; delete items that stopped mattering. It should shrink as the job
converges.

**`## Decided` holds conclusions, not reasoning.** "Password accounts have no
pass key — one secret per credential" is a decision. Three paragraphs on why is
an argument, and it belongs in the discussion, not here.

**`## Log` is for what a future reader needs**, which is almost nothing. One
line per real event. If it grows past a handful, the top entries have stopped
earning their place.

**Sections may be dropped.** A task with no deliverable yet has no
`## Deliverable`. An empty heading is noise.

## What does not belong

Rationale essays · Q&A transcripts · explanations of work already finished ·
paths considered and rejected · anything written to prove effort. All of that
happened in the discussion, and the discussion is already the record.
