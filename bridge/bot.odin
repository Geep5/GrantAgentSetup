// The session loop — Anytype <-> omp.
//
// One agent, many surfaces. A turn answers exactly ONE surface, so a message
// arriving elsewhere mid-turn is NOT steered in: the reply would post to the
// turn's surface rather than the one that asked. It waits for the poll loop,
// which answers it in the right place.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

SESSION_END_MARKER :: "[SESSION_END]"
// Anytype accepts far more than Discord's 2000: measured on this build, 6000
// posts and 8000 returns 500. 4000 keeps a margin, since the ceiling may be
// bytes and non-ASCII costs 2-4x.
MAX_MESSAGE_CHARS :: 4000
SEED_BACKLOG :: 3          // unanswered messages to pick up in a new surface

KICKOFF :: "[System] A new session has started. You are a discussion partner, " +
	"not an executor: do NOT pick a task and start working. Post one short " +
	"greeting saying you are around, then wait for Grant. Do not open a task, " +
	"write a deliverable, or edit any object until he asks."

Mark :: struct {
	chat:  string,
	order: string,
}

Bot :: struct {
	cfg:      Config,
	omp:      ^Omp,
	surfaces: ^Surfaces,
	bodies:   ^Body_Cache,
	marks:    map[string]string,   // chat id -> newest order_id we have handled
	reply_to: map[string]string,   // chat id -> message we are answering
}

// ------------------------------------------------------------- gating ------

lock_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/state/lock", cfg.bot_dir)
}

// Another live session means stand down; a stale lock means take over.
gate_or_exit :: proc(cfg: Config) -> bool {
	os.make_directory_all(fmt.tprintf("%s/state", cfg.bot_dir))
	if data, err := os.read_entire_file(lock_path(cfg), context.temp_allocator); err == nil {
		if pid, ok := strconv.parse_int(strings.trim_space(string(data))); ok && pid > 0 {
			// process_info on a live pid succeeds; on a dead one it errors.
			if _, ierr := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator);
			   ierr == nil {
				fmt.println("graiced: another session is running")
				return false
			}
			fmt.println("graiced: stale lock (pid gone), taking over")
		}
	}
	_ = os.write_entire_file(lock_path(cfg),
		transmute([]u8)fmt.tprintf("%d", os.get_pid()))
	return true
}

release_lock :: proc(cfg: Config) {
	os.remove(lock_path(cfg))
}

// ------------------------------------------------------- watermarking ------

// Where to start in a surface we have just discovered.
//
// Seeding at the NEWEST message eats the first thing anyone says: you create
// an object, type a question, and by the time discovery runs that question IS
// the newest message. Seeding at "" replays an entire history. So: start after
// our own last message, else take the last few.
seed_mark :: proc(b: ^Bot, chat_id: string) -> string {
	ms := messages(b.cfg, chat_id, 50, "", context.temp_allocator)
	for m in ms {                       // newest first
		if m.is_bot {
			return strings.clone(m.id)
		}
	}
	if len(ms) > SEED_BACKLOG {
		return strings.clone(ms[SEED_BACKLOG].id)
	}
	return ""
}

// ---------------------------------------------------------- formatting -----

// Name the surface so a question about "this" is grounded. A Discussion means
// its object IS the subject; a chat has no single subject.
build_user_message :: proc(b: ^Bot, c: Chat, m: Message) -> string {
	h := host_info(b.cfg, c)

	parts := make([dynamic]string, context.temp_allocator)
	if c.kind == "chat" {
		append(&parts, fmt.tprintf("[Anytype message from %s · in chat %q (id %s)]",
			m.author, h.name, c.id))
	} else {
		append(&parts, fmt.tprintf("[Anytype message from %s · in %s %q (id %s)]",
			m.author, h.kind, h.name, c.host_id))
		// Inline the object body. Without it the agent must remember to fetch
		// the object before "this" means anything -- which depends on a skill
		// being loaded and on it bothering. An empty body is signal too: it
		// means Grant is starting something, not that there is nothing to say.
		switch body_decide(b.cfg, b.bodies, c.id, h.body) {
		case .Skip:
			// Sent recently; she still has it further up in this conversation.
			append(&parts, fmt.tprintf(
				"[contents of this %s were included earlier in this conversation and may have changed since — re-read the object if it matters]",
				h.kind))
		case .Send, .Send_Stale:
			if len(h.body) > 0 {
				append(&parts, fmt.tprintf("--- contents of this %s, as of now ---\n%s%s\n--- end ---",
					h.kind, h.body,
					h.truncated ? "\n[…truncated; read the object for the rest]" : ""))
			} else {
				append(&parts, fmt.tprintf("--- this %s is empty ---", h.kind))
			}
		}
	}
	if len(strings.trim_space(m.text)) > 0 {
		append(&parts, m.text)
	}
	// Images go inline via omp's @file syntax so the agent actually sees them;
	// other files are named by path for its read tool. An attachment-only
	// message is still a real message -- do not drop it for having no text.
	for target in m.attachments {
		a := fetch_attachment(b.cfg, target)
		if !a.ok {
			append(&parts, fmt.tprintf("[attachment %s could not be downloaded]", target))
			continue
		}
		if a.is_image {
			append(&parts, fmt.tprintf("@%s", a.path))
			append(&parts, fmt.tprintf("[attached image, shown above; saved at %s]", a.path))
		} else {
			append(&parts, fmt.tprintf("[attached file: %s — read it with your file tools]", a.path))
		}
	}
	return strings.join(parts[:], "\n", context.temp_allocator)
}

split_message :: proc(text: string, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	rest := text
	for len(rest) > MAX_MESSAGE_CHARS {
		cut := strings.last_index(rest[:MAX_MESSAGE_CHARS], "\n")
		if cut <= 0 {
			cut = MAX_MESSAGE_CHARS
		}
		append(&out, rest[:cut])
		rest = strings.trim_left(rest[cut:], "\n")
	}
	if len(rest) > 0 {
		append(&out, rest)
	}
	return out[:]
}

// Walk up to the top of a thread, as far as the fetched window allows.
// Depth beyond the window is not resolvable -- the API gives only an immediate
// parent per message -- but a reply is always near its parent in practice.
thread_root :: proc(window: []Message, m: Message) -> string {
	id := m.message_id
	parent := m.reply_to
	for hops := 0; len(parent) > 0 && hops < 8; hops += 1 {
		id = parent
		found := false
		for w in window {
			if w.message_id == parent {
				parent = w.reply_to
				found = true
				break
			}
		}
		if !found {
			break            // parent outside the window: treat it as the root
		}
	}
	return strings.clone(id)
}

// Post an answer. Returns true when the agent signalled the session should end.
post_response :: proc(b: ^Bot, chat_id, response: string) -> bool {
	ended := strings.contains(response, SESSION_END_MARKER)
	stripped, _ := strings.replace_all(response, SESSION_END_MARKER, "", context.temp_allocator)
	text := strings.trim_space(stripped)
	if len(text) == 0 {
		return ended
	}
	// Only the FIRST chunk threads under the question; pointing every chunk at
	// it would render one answer as a pile of quoted replies.
	target := b.reply_to[chat_id] or_else ""
	delete_key(&b.reply_to, chat_id)
	for chunk, i in split_message(text) {
		send_message(b.cfg, chat_id, chunk, i == 0 ? target : "")
		time.sleep(400 * time.Millisecond)
	}
	return ended
}

// --------------------------------------------------------------- turn ------

// `steer_from` is the surface whose follow-ups should be folded into this
// turn. Empty means no steering (the kickoff, which belongs to no message).
run_turn :: proc(b: ^Bot, prompt: string, c: Chat = {}, steer_from: string = "") -> string {
	turn_snapshot(b.cfg, b.omp)
	if !omp_send(b.omp, "prompt", prompt) {
		return "[Agent error: could not send prompt]"
	}
	st: ^Steer
	if len(c.id) > 0 {
		st = steer_start(b, c, steer_from)
	}
	reply := omp_wait_for_response(b.cfg, b.omp)
	if st != nil {
		// Anything steered in was consumed by this turn, so the poll loop must
		// not answer it a second time -- take the mark the steerer reached.
		b.marks[strings.clone(c.id)] = steer_stop(st)
	}
	return reply
}

// --------------------------------------------------------------- loop ------

cmd_bot :: proc(cfg: Config) -> int {
	if len(cfg.bot_dir) == 0 {
		fmt.eprintln("set GRAICE_DIR to the bot directory")
		return 1
	}
	if !gate_or_exit(cfg) {
		return 0
	}
	defer release_lock(cfg)

	b := new(Bot)
	b.cfg = cfg
	b.marks = make(map[string]string)
	b.reply_to = make(map[string]string)
	b.surfaces = new(Surfaces)
	discussions_load(cfg, b.surfaces)
	b.bodies = body_cache_load(cfg)

	b.omp = new(Omp)
	if !omp_start(cfg, b.omp) {
		return 1
	}
	defer omp_stop(b.omp)

	// Seed every surface BEFORE the kickoff, so nothing said while we were
	// down is replayed as if it just arrived -- and nothing is swallowed.
	chats := discover_all(cfg, b.surfaces)
	for c in chats {
		b.marks[strings.clone(c.id)] = seed_mark(b, c.id)
	}

	primary := env_or("ANYTYPE_CHAT_ID", len(chats) > 0 ? chats[0].id : "")
	fmt.printfln("graiced: session start, primary surface %s", primary)

	reply := run_turn(b, KICKOFF)
	if strings.has_prefix(reply, "[Agent error:") || strings.has_prefix(reply, "[Agent process crashed") {
		fmt.eprintfln("graiced: fatal kickoff failure: %s", reply)
		return 1
	}
	if post_response(b, primary, reply) {
		fmt.println("graiced: session ended at kickoff")
		return 0
	}

	poll := time.Duration(env_int("POLL_INTERVAL", 3)) * time.Second
	last_discovery := time.now()._nsec
	fmt.printfln("graiced: polling every %v", poll)

	for {
		time.sleep(poll)
		// Everything below allocates into the temp arena — HTTP bodies, JSON
		// trees, message clones — and nothing else reclaims it. Odin's default
		// temp allocator is a growing arena of 4 MiB heap blocks, so a loop
		// that never resets it chains one block after another forever: this is
		// what grew the bot to ~90 GB of footprint (23k blocks) in two days.
		// Anything that must outlive an iteration is heap-cloned explicitly.
		defer free_all(context.temp_allocator)

		// Rediscover periodically: objects and chats appear over time, and a
		// new one should not need a restart to be noticed.
		if time.now()._nsec - last_discovery > i64(60 * time.Second) {
			chats = discover_all(cfg, b.surfaces)
			last_discovery = time.now()._nsec
		}

		for c in chats {
			if _, seen := b.marks[c.id]; !seen {
				b.marks[strings.clone(c.id)] = seed_mark(b, c.id)
				name, _ := host_label(cfg, c)
				fmt.printfln("graiced: watching new surface %q", name)
			}
			after := b.marks[c.id] or_else ""
			fresh := messages(cfg, c.id, 10, after, context.temp_allocator)
			// REST returns blank text for UI-written messages that use blocks;
			// re-read those over grpc or the bot is deaf to them.
			if n := fill_blank_text(cfg, b.surfaces, c.id, fresh, context.temp_allocator); n > 0 {
				fmt.printfln("graiced: recovered %d message(s) via grpc blocks", n)
			}
			// oldest first, so a burst is answered in order
			#reverse for m in fresh {
				if m.id > (b.marks[c.id] or_else "") {
					b.marks[c.id] = strings.clone(m.id)
				}
				if m.is_bot {
					continue
				}
				// Attachment-only messages carry no text but are real messages.
				if len(strings.trim_space(m.text)) == 0 && len(m.attachments) == 0 {
					continue
				}
				fmt.printfln("graiced: message from %s: %s", m.author,
					m.text[:min(len(m.text), 60)])
				// Reply to the ROOT of the thread, not to the message itself.
				// Anytype's UI renders one level of replies under a root: a
				// reply-to-a-reply has nowhere to display, so the answer is
				// stored correctly and shown nowhere. Grant replying inside an
				// existing thread is the common case, so this is not an edge.
				// Heap-cloned: thread_root returns an id out of `fresh`, which
				// is temp-allocated and gone at the end of this iteration.
				b.reply_to[strings.clone(c.id)] = strings.clone(thread_root(fresh, m))
				// Mark the message while the turn runs. Driven by omp's event
				// stream, so a frozen marker means wedged, not merely slow.
				w := working_start(b, c.id, m.message_id)
				answer := run_turn(b, build_user_message(b, c, m), c, b.marks[c.id] or_else "")
				working_stop(w, strings.has_prefix(answer, "[Agent error:") ||
					strings.has_prefix(answer, "[Agent process crashed") ||
					strings.has_prefix(answer, "[Agent timed out"))
				if post_response(b, c.id, answer) {
					// Ending a session is only about refreshing context; it
					// must never cost availability, so restart and keep going.
					fmt.println("graiced: session complete — restarting, staying reachable")
					omp_stop(b.omp)
					b.omp = new(Omp)
					if !omp_start(cfg, b.omp) {
						return 1
					}
				}
			}
		}
	}
}

// ------------------------------------------------------------- selftest ----

// Exercises the pure logic that has bitten us before, without a live agent.
cmd_selftest :: proc(cfg: Config) -> int {
	fails := 0
	check :: proc(fails: ^int, name: string, ok: bool) {
		fmt.printfln("  %s  %s", ok ? "PASS" : "FAIL", name)
		if !ok { fails^ += 1 }
	}

	// merge_turn_texts: the three cases that decide whether a turn survives.
	a := []string{"hello"}
	check(&fails, "merge: single piece", merge_turn_texts(a) == "hello")
	b := []string{"part one", "part one\n\npart two"}
	check(&fails, "merge: later superset replaces", merge_turn_texts(b) == "part one\n\npart two")
	c := []string{"part one\n\npart two", "part two"}
	check(&fails, "merge: contained slice dropped", merge_turn_texts(c) == "part one\n\npart two")
	d := []string{"alpha", "beta"}
	check(&fails, "merge: disjoint pieces joined", merge_turn_texts(d) == "alpha\n\nbeta")

	// split_message: never exceed the ceiling, never lose text.
	long := strings.repeat("x", 9000, context.temp_allocator)
	parts := split_message(long)
	max_ok := true
	total := 0
	for p in parts {
		if len(p) > MAX_MESSAGE_CHARS { max_ok = false }
		total += len(p)
	}
	check(&fails, "split: every chunk within limit", max_ok)
	check(&fails, "split: no text lost", total == len(long))
	check(&fails, "split: short text stays one message", len(split_message("hi")) == 1)

	// Session-end detection must not leave the marker in the posted text.
	stripped, _ := strings.replace_all("done here [SESSION_END]", SESSION_END_MARKER, "",
		context.temp_allocator)
	check(&fails, "session end: marker stripped",
		!strings.contains(strings.trim_space(stripped), "SESSION_END"))

	fmt.printfln("\n%s", fails == 0 ? "all checks passed" : fmt.tprintf("%d FAILED", fails))
	return fails == 0 ? 0 : 1
}
