// Deciding when to re-send an object's body.
//
// The body is what makes "this" concrete, so it has to be there -- but sending
// it on every message piles duplicate copies into the agent's transcript, which
// then carries nine stale copies alongside the current one.
//
// The rule is time: re-send if it has been more than BODY_REANCHOR_MINUTES
// since we last sent this object's body. Plus the base case -- if she has never
// seen it in THIS transcript she gets it regardless, or a session reset would
// leave her with no body at all until the timer happened to fire.
//
// Deliberate trade-off: an edit made inside the window is NOT picked up, so the
// body she holds can be up to BODY_REANCHOR_MINUTES stale. The prompt says so
// rather than claiming the block is always current, and tells her to re-read the
// object when freshness actually matters (right after an edit, before acting on
// what it says).
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

// How long a gap before the body is re-sent even though nothing changed.
BODY_REANCHOR_MINUTES :: 30

Body_Seen :: struct {
	hash:       u64,
	sent_unix:  i64,
	transcript: string, // resets when the transcript does; see session_id()
}

Body_Cache :: struct {
	seen: map[string]Body_Seen,
}

body_cache_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/state/body_cache.json", cfg.bot_dir)
}

// What "this session" means, concretely.
//
// NOT the process: `omp_start` passes --continue whenever a transcript exists,
// so a restart (or [SESSION_END]) resumes the same conversation. Keying on the
// process would mark a body "already sent" while the transcript that holds it
// was replaced -- she would be reading a stale copy with no refresh coming.
//
// The transcript file IS the context, so its name is the session identity.
session_id :: proc(cfg: Config) -> string {
	dir := fmt.tprintf("%s/sessions/main", cfg.bot_dir)
	d, err := os.open(dir)
	if err != nil {
		return ""
	}
	defer os.close(d)
	entries, rerr := os.read_dir(d, -1, context.temp_allocator)
	if rerr != nil {
		return ""
	}
	newest, newest_time := "", i64(0)
	for e in entries {
		if !strings.has_suffix(e.name, ".jsonl") {
			continue
		}
		t := time.time_to_unix(e.modification_time)
		if t >= newest_time {
			newest, newest_time = e.name, t
		}
	}
	return strings.clone(newest)
}

fnv1a :: proc(s: string) -> u64 {
	h: u64 = 0xcbf29ce484222325
	for i in 0 ..< len(s) {
		h ~= u64(s[i])
		h *= 0x100000001b3
	}
	return h
}

body_cache_load :: proc(cfg: Config) -> ^Body_Cache {
	c := new(Body_Cache)
	c.seen = make(map[string]Body_Seen)
	data, err := os.read_entire_file(body_cache_path(cfg), context.temp_allocator)
	if err != nil {
		return c
	}
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	if jerr != nil {
		return c
	}
	obj, ok := v.(json.Object)
	if !ok {
		return c
	}
	for k, val in obj {
		e := Body_Seen{}
		if h := jstr(val, "hash"); len(h) > 0 {
			if parsed, pok := strconv.parse_u64(h); pok {
				e.hash = parsed
			}
		}
		if t := jstr(val, "sent"); len(t) > 0 {
			if parsed, pok := strconv.parse_i64(t); pok {
				e.sent_unix = parsed
			}
		}
		e.transcript = strings.clone(jstr(val, "transcript"))
		c.seen[strings.clone(k)] = e
	}
	return c
}

body_cache_save :: proc(cfg: Config, c: ^Body_Cache) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	first := true
	for k, e in c.seen {
		if !first {
			strings.write_string(&b, ",")
		}
		first = false
		json_write_string(&b, k)
		strings.write_string(&b, ":{\"hash\":")
		json_write_string(&b, fmt.tprintf("%d", e.hash))
		strings.write_string(&b, ",\"sent\":")
		json_write_string(&b, fmt.tprintf("%d", e.sent_unix))
		strings.write_string(&b, ",\"transcript\":")
		json_write_string(&b, e.transcript)
		strings.write_string(&b, "}")
	}
	strings.write_string(&b, "}")
	os.make_directory_all(fmt.tprintf("%s/state", cfg.bot_dir))
	_ = os.write_entire_file(body_cache_path(cfg), transmute([]u8)strings.to_string(b))
}

Body_Decision :: enum {
	Send,       // never seen in this transcript
	Send_Stale, // the timer elapsed
	Skip,
}

body_decide :: proc(cfg: Config, c: ^Body_Cache, chat_id, body: string) -> Body_Decision {
	now := time.time_to_unix(time.now())
	sid := session_id(cfg)
	h := fnv1a(body)

	prev, seen := c.seen[chat_id]
	decision := Body_Decision.Send
	switch {
	case !seen || prev.transcript != sid:
		decision = .Send                      // new context: she has not seen it here
	case now - prev.sent_unix > i64(BODY_REANCHOR_MINUTES * 60):
		decision = .Send_Stale                // the timer, and the only staleness rule
	case:
		decision = .Skip
	}

	if decision != .Skip {
		c.seen[strings.clone(chat_id)] = Body_Seen{
			hash = h, sent_unix = now, transcript = strings.clone(sid),
		}
		body_cache_save(cfg, c)
	}
	return decision
}
