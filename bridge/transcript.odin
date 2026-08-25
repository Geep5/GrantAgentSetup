// `graiced transcript <id> [limit]` — the conversation in one object.
//
// The agent sees messages one at a time as they arrive, so it has no way to
// review a discussion it was part of days ago, or to catch up on one it has
// only just been pointed at. This gives it the whole thread on demand.
//
// It exists as a command rather than an API recipe because a raw REST call
// would hand back a transcript full of empty strings: messages typed in the
// Anytype UI store their text in ChatMessage.blocks, which the REST DTO does
// not map. This reuses the bridge's own read path, blocks fallback included, so
// what comes back is what was actually said.
//
// Takes either an object id (what a link gives you) or a discussion id, since
// the agent has both and the difference is not obvious from looking at them.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

TRANSCRIPT_DEFAULT :: 50

// An object id needs resolving to its discussion; a discussion id is already
// usable. Cheapest reliable test: ask discovery what it knows.
resolve_to_chat :: proc(cfg: Config, s: ^Surfaces, id: string) -> (chat: string, label: string) {
	discussions_load(cfg, s)
	if did, ok := s.discussions[id]; ok {
		return did, "discussion of that object"
	}
	for oid, did in s.discussions {
		if did == id {
			return id, fmt.tprintf("discussion of %s", oid[:12])
		}
	}
	// Not in the cache: could be a chat object, or an object whose discussion
	// has never been probed. Probe it, then fall back to treating it as a chat.
	if surfaces_session(cfg, s) {
		if did := object_discussion(cfg, s, id); len(did) > 0 {
			s.discussions[strings.clone(id)] = did
			discussions_save(cfg, s)
			return did, "discussion of that object (newly found)"
		}
	}
	return id, "chat"
}

cmd_transcript :: proc(cfg: Config) -> int {
	if len(os.args) < 3 {
		fmt.eprintln("usage: graiced transcript <object-or-chat-id> [limit]")
		return 1
	}
	id := os.args[2]
	limit := TRANSCRIPT_DEFAULT
	if len(os.args) > 3 {
		if n, ok := strconv.parse_int(os.args[3]); ok && n > 0 {
			limit = n
		}
	}

	s := new(Surfaces)
	chat, label := resolve_to_chat(cfg, s, id)

	ms := messages(cfg, chat, limit, "", context.temp_allocator)
	if len(ms) == 0 {
		fmt.printfln("(no messages in the %s)", label)
		return 0
	}
	// Without this the UI-written messages come back blank, which is most of
	// them in a real conversation.
	recovered := fill_blank_text(cfg, s, chat, ms, context.temp_allocator)

	fmt.printfln("# transcript — %s (%d messages%s)", label, len(ms),
		recovered > 0 ? fmt.tprintf(", %d recovered via grpc", recovered) : "")
	fmt.println()

	// messages() returns newest-first; a transcript reads oldest-first.
	#reverse for m in ms {
		who := m.is_bot ? "Graice" : (len(m.author) > 0 ? m.author : "Grant")
		stamp := ""
		if m.created > 0 {
			t := time.unix(m.created, 0)
			y, mo, d := time.date(t)
			h, mi, _ := time.clock(t)
			stamp = fmt.tprintf("%4d-%02d-%02d %02d:%02d", y, int(mo), d, h, mi)
		}
		text := strings.trim_space(m.text)
		if len(text) == 0 {
			text = "(no text — attachment or unreadable)"
		}
		fmt.printfln("[%s] %s:", stamp, who)
		for line in strings.split_lines(text, context.temp_allocator) {
			fmt.printfln("    %s", line)
		}
		fmt.println()
	}
	return 0
}
