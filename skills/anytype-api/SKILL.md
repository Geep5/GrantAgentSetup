---
name: anytype-api
description: Read and write Anytype over the local REST API: the task board, task objects, properties (status/area/done/next_action/send_date), creating tasks, and the space and board ids. Use whenever you need to look at the board, open a task, or record anything in Anytype.
---

Local REST API. Every request needs both headers (key is in your environment):

```bash
-H "Authorization: Bearer $ANYTYPE_API_KEY" -H "Anytype-Version: 2025-11-08"
```

Base URL: `$ANYTYPE_API_BASE/v1` (your own middleware — currently
`http://127.0.0.1:31010`). Do NOT use `localhost:31009`: that is Grant's
personal Anytype app, serving his account, and your key is rejected there.
You are a separate identity and only see what has been shared with you.

**What you can see:** the **MyFavorites** space
(`$ANYTYPE_CHAT_SPACE_ID`) — the one Grant shared with you. Discover it at
runtime with `GET /spaces`; never assume a space id. If a request 403s or
404s, you are not a member of that space: say so plainly rather than hunting
for another credential.

IDs:
- space: `$ANYTYPE_CHAT_SPACE_ID`
- Task Overview set (the board): `<id>` · tasks use the built-in `task` type (key `task`)
- `status`: `<id>` · `area`: `<id>` · `done`: `<id>` · `next_action`: `<id>` · `send_date`: `<id>`


**Landing on the board:** create tasks with `type_key: "task"` in this space and they appear on the board — it filters by type, not by a linked project. (The old board required linking to a project object; this one does not, and there is no project object here to link to.) The `task` type carries done/status/due_date/priority/next_action/send_date.


Recipes (SPACE/LIST = ids above):

```bash
# the board (includes done tasks — filter on the done property yourself)
GET /spaces/$SPACE/lists/$LIST/views/default/objects?limit=100

# read one task in full
GET /spaces/$SPACE/objects/$OBJECT_ID?format=md

# tag ids for a select property (status, area) — look up by name before setting
GET /spaces/$SPACE/properties/<property id>/tags

# create a task
POST /spaces/$SPACE/objects
{"type_key": "task", "name": "...", "markdown": "<TASK_TEMPLATE.md shape>",
 "properties": [{"key": "area", "select": "<tag_id>"}, {"key": "status", "select": "<tag_id>"}]}

# read the whole conversation in an object (yours and Grant's)
# Use THIS, not the messages endpoint: text typed in the Anytype UI lives in
# ChatMessage.blocks, which REST does not return, so a raw call gives you a
# transcript of empty strings. Takes an object id or a discussion id.
graiced transcript <object-or-chat-id> [limit]

# update a task — GET first, send back the complete new body
PATCH /spaces/$SPACE/objects/$OBJECT_ID
{"markdown": "<full new body>",
 "properties": [{"key": "status", "select": "<tag_id>"}, {"key": "next_action", "text": "..."},
                {"key": "done", "checkbox": true}, {"key": "send_date", "date": "2026-07-15T00:00:00Z"}]}

# search the space
POST /spaces/$SPACE/search
{"query": "combat", "limit": 10}
```

`jq` is available. If a call surprises you, inspect (`GET /spaces/$SPACE/types`) — don't guess blindly. If a select tag you need doesn't exist (e.g. "Waiting" on status), create it: `POST /spaces/$SPACE/properties/<property id>/tags` with `{"name": "...", "color": "..."}`.

**Anytype MCP (fallback):** an `anytype` MCP server is also connected, but like all MCP servers its tools are hidden until activated — run `search_tool_bm25` with a query like "anytype" to load them. Prefer the HTTP recipes above (they're faster and you know them), but if HTTP misbehaves, the MCP is a second path to the same data — try it before concluding anything is down.

**Before you report a service as broken:** verify a READ works. A failure on writes only is almost never the server — it's your payload (a stale/archived `type_key`, a deleted id, a malformed property). Anytype types can be *archived*, which removes them from the types list and makes creates fail while the id still resolves; if creates fail, re-check the type key against your instructions and the current types list before blaming the API. Say "creates are failing" — never "Anytype is down" — unless reads fail too.
