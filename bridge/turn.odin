// Turn collection — getting the COMPLETE text of one agent turn.
//
// See the header of omp.odin for why this is more involved than "read the
// agent_end event". In short: that event lies about how much of the turn it
// carries, so the session transcript is the source of truth and events are the
// fallback.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:time"

// Mark where the transcript ends as a prompt goes out. The turn's text is
// everything appended after this point.
turn_snapshot :: proc(cfg: Config, o: ^Omp) {
	f := latest_session_file(bot_session_dir(cfg))
	o.turn_file = f
	o.turn_offset = 0
	if len(f) > 0 {
		if fi, err := os.stat(f, context.temp_allocator); err == nil {
			o.turn_offset = i64(fi.size)
		}
	}
}

latest_session_file :: proc(dir: string) -> string {
	handle, err := os.open(dir)
	if err != nil {
		return ""
	}
	defer os.close(handle)
	entries, rerr := os.read_dir(handle, -1, context.temp_allocator)
	if rerr != nil {
		return ""
	}
	newest := ""
	newest_time: i64 = -1
	for e in entries {
		if !strings.has_suffix(e.name, ".jsonl") {
			continue
		}
		t := e.modification_time._nsec
		if t > newest_time {
			newest_time = t
			newest, _ = filepath.join({dir, e.name}, context.temp_allocator)
		}
	}
	return newest
}

session_has_transcript :: proc(dir: string) -> bool {
	return len(latest_session_file(dir)) > 0
}

// Wait for the turn to FULLY finish and return ALL of its text.
//
// One prompt is not one agent_end: omp's rule engine and todo reminders can
// interrupt and restart the agent, producing several cycles, each of whose
// agent_end may carry only its own slice. So collect every cycle and linger
// QUIET_SECS after each end before deciding the turn is over.
omp_wait_for_response :: proc(cfg: Config, o: ^Omp) -> string {
	deadline := time.now()._nsec + i64(cfg.agent_timeout)
	texts := make([dynamic]string, context.temp_allocator)
	agent_started := false

	for {
		remaining := deadline - time.now()._nsec
		if remaining <= 0 {
			done := collect_turn_text(cfg, o, merge_turn_texts(texts[:]))
			if len(done) > 0 && len(texts) > 0 {
				return done
			}
			if len(done) > 0 {
				return fmt.tprintf("%s\n\n[Agent timed out mid-task - more may follow next session]", done)
			}
			return "[Agent timed out - the task may still be running]"
		}
		// Once we have any text, a quiet gap means the turn is done; before
		// that, allow a long first wait while the agent boots.
		wait := len(texts) > 0 ? QUIET_SECS : FIRST_EVENT_WAIT
		if i64(wait) > remaining {
			wait = time.Duration(remaining)
		}

		ev, got := omp_next_event(o, wait)
		if !got {
			sync.mutex_lock(&o.mutex)
			closed := o.closed
			sync.mutex_unlock(&o.mutex)
			if closed {
				done := collect_turn_text(cfg, o, merge_turn_texts(texts[:]))
				if len(texts) > 0 {
					return len(done) > 0 ? done : "[No response from agent]"
				}
				// Crashed mid-turn: deliver whatever it DID say rather than
				// swallowing the work.
				if len(done) > 0 {
					return fmt.tprintf("%s\n\n[Agent process crashed - will resume next session]", done)
				}
				return "[Agent process crashed - will resume next session]"
			}
			if len(texts) > 0 {
				done := collect_turn_text(cfg, o, merge_turn_texts(texts[:]))
				return len(done) > 0 ? done : "[No response from agent]"
			}
			continue
		}

		data, jerr := json.parse(transmute([]u8)ev, allocator = context.temp_allocator)
		if jerr != nil {
			continue
		}
		ev_type := jstr(data, "type")
		switch ev_type {
		case "agent_start":
			agent_started = true
		case "tool_execution_start", "tool_execution_end":
			name := "tool"
			if tool, ok := jget(data, "tool"); ok {
				if n := jstr(tool, "name"); len(n) > 0 {
					name = n
				}
			}
			verb := strings.has_suffix(ev_type, "start") ? "start" : "done"
			fmt.printfln("graiced: omp %s: %s", verb, name)
		case "response":
			if ok, found := jget(data, "success"); found {
				if b, is := ok.(json.Boolean); is && !bool(b) {
					e := jstr(data, "error")
					if !agent_started && len(texts) == 0 {
						return fmt.tprintf("[Agent error: %s]", e)
					}
					fmt.eprintfln("graiced: steer error (continuing): %s", e)
				}
			}
		case "agent_end":
			append(&texts, extract_text(data))
		}
	}
}

// The transcript is the source of truth; `event_text` is the fallback.
collect_turn_text :: proc(cfg: Config, o: ^Omp, event_text: string) -> string {
	f := latest_session_file(bot_session_dir(cfg))
	if len(f) == 0 {
		return event_text
	}
	offset := f == o.turn_file ? o.turn_offset : 0

	// The tail of the event text tells us whether omp has flushed the final
	// message yet; if not, wait and re-read rather than truncating the answer.
	tail := strings.trim_space(event_text)
	if len(tail) > 60 {
		tail = tail[len(tail) - 60:]
	}

	for attempt in 0 ..< 3 {
		data, rerr := os.read_entire_file(f, context.temp_allocator)
		if rerr != nil {
			return event_text
		}
		if offset > i64(len(data)) {
			offset = 0
		}
		parts := make([dynamic]string, context.temp_allocator)
		for line in strings.split_lines(string(data[offset:]), context.temp_allocator) {
			trimmed := strings.trim_space(line)
			if len(trimmed) == 0 {
				continue
			}
			e, jerr := json.parse(transmute([]u8)trimmed, allocator = context.temp_allocator)
			if jerr != nil {
				continue          // partial trailing line mid-flush
			}
			if jstr(e, "type") != "message" {
				continue
			}
			m, has := jget(e, "message")
			if !has || jstr(m, "role") != "assistant" {
				continue
			}
			t := strings.trim_space(entry_text(m))
			if len(t) > 0 {
				append(&parts, t)
			}
		}
		text := strings.join(parts[:], "\n\n", context.temp_allocator)
		if len(tail) == 0 || strings.contains(text, tail) || attempt == 2 {
			if len(text) > 0 {
				return text
			}
			break
		}
		time.sleep(1500 * time.Millisecond)
	}
	return event_text
}

// A transcript message's content is either a plain string or a list of blocks.
entry_text :: proc(m: json.Value) -> string {
	c, has := jget(m, "content")
	if !has {
		return ""
	}
	if s, is := c.(json.String); is {
		return string(s)
	}
	if arr, is := c.(json.Array); is {
		parts := make([dynamic]string, context.temp_allocator)
		for b in arr {
			if jstr(b, "type") != "text" {
				continue
			}
			if t := jstr(b, "text"); len(strings.trim_space(t)) > 0 {
				append(&parts, t)
			}
		}
		return strings.join(parts[:], "\n", context.temp_allocator)
	}
	return ""
}

// Merge per-cycle extractions into one turn: a later piece containing what we
// already have REPLACES it (that cycle carried the full history), a piece
// already contained is dropped, anything else is appended.
merge_turn_texts :: proc(texts: []string) -> string {
	final := ""
	for raw in texts {
		t := strings.trim_space(raw)
		if len(t) == 0 {
			continue
		}
		if len(final) > 0 && strings.contains(t, final) {
			final = t
		} else if len(final) > 0 && strings.contains(final, t) {
			continue
		} else if len(final) > 0 {
			final = fmt.tprintf("%s\n\n%s", final, t)
		} else {
			final = t
		}
	}
	return final
}

// ALL assistant text of the current turn -- everything since the last real
// bridge prompt. Long tool-using turns put the answer in intermediate messages
// and end with a sign-off, so taking only the last message drops it.
//
// Tool results arrive with role "toolResult", not "user", so breaking on a
// bridge-formatted user message bounds exactly one turn.
extract_text :: proc(event: json.Value) -> string {
	msgs, has := jget(event, "messages")
	if !has {
		return ""
	}
	arr, is := msgs.(json.Array)
	if !is {
		return ""
	}
	parts := make([dynamic]string, context.temp_allocator)
	#reverse for m in arr {
		role := jstr(m, "role")
		if role == "user" {
			text := entry_text(m)
			lead := strings.trim_left_space(text)
			// "[Discord message from" stays listed: sessions resumed from
			// before the Anytype switch still carry it, and dropping it would
			// silently un-bound those turns.
			if strings.has_prefix(lead, "[Anytype message from") ||
			   strings.has_prefix(lead, "[Discord message from") ||
			   strings.has_prefix(lead, "[System]") {
				break
			}
			continue          // injected rule-interrupt/summary, not a boundary
		}
		if role != "assistant" {
			continue
		}
		if t := strings.trim_space(entry_text(m)); len(t) > 0 {
			append(&parts, t)
		}
	}
	slice.reverse(parts[:])
	return strings.join(parts[:], "\n\n", context.temp_allocator)
}
