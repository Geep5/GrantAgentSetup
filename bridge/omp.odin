// omp RPC bridge — the Odin port of bot.py's OmpAgent.
//
// omp runs as a child process in `--mode rpc`: newline-delimited JSON in on
// stdin, newline-delimited events out on stdout. A reader thread drains stdout
// into a queue so the main thread can wait on turn boundaries without blocking
// the child's pipe (a full pipe deadlocks the agent).
//
// THREE BEHAVIOURS HERE WERE LEARNED THE HARD WAY. They look like paranoia and
// are not; each one silently truncated real answers before it was fixed:
//
//  1. agent_end.messages is UNRELIABLE. Sometimes it carries the whole run,
//     sometimes ONLY the final message -- a 38-minute turn's 16k-char analysis
//     once arrived as a 309-char sign-off. The session .jsonl is the only
//     complete record, so the turn's text is read from the file, from the
//     offset marked when the prompt went out. Events are a fallback only.
//
//  2. One prompt can produce SEVERAL agent_start/agent_end cycles, because
//     omp's rule engine and todo reminders interrupt and restart the agent
//     mid-turn. Returning at the first agent_end posts a fragment and orphans
//     the rest. So: collect every cycle, linger QUIET_SECS after each end, and
//     merge.
//
//  3. A turn's substantive answer often sits in INTERMEDIATE assistant
//     messages, with a terse sign-off last. Taking only the final message
//     drops the answer.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

QUIET_SECS :: 6 * time.Second   // linger after an agent_end before calling it done
FIRST_EVENT_WAIT :: 30 * time.Second

Omp :: struct {
	process:      os.Process,
	stdin:        ^os.File,
	stdout_r:     ^os.File,
	alive:        bool,

	// Reader thread -> main thread. A mutex + slice is enough; the volume is
	// low and this avoids depending on a channel implementation.
	mutex:        sync.Mutex,
	events:       [dynamic]string,
	closed:       bool,           // stdout hit EOF: the child is gone
	// When omp last emitted ANYTHING. It streams tool_execution_* and
	// agent_start/end continuously while working, so a recent event means
	// alive and a long silence means wedged. Better than timing the wall
	// clock, which cannot tell a slow job from a dead one.
	last_event:   time.Time,

	// Where the session transcript ended when the prompt went out.
	turn_file:    string,
	turn_offset:  i64,
}

// ------------------------------------------------------------- lifecycle ----

omp_start :: proc(cfg: Config, o: ^Omp) -> bool {
	session_dir := bot_session_dir(cfg)
	os.make_directory_all(session_dir)

	prompt, rerr := os.read_entire_file(bot_system_prompt(cfg), context.allocator)
	if rerr != nil {
		fmt.eprintfln("graiced: cannot read %s", bot_system_prompt(cfg))
		return false
	}

	args := make([dynamic]string, context.temp_allocator)
	append(&args, cfg.omp_bin, "--mode", "rpc", "--model", cfg.omp_model,
	       "--system-prompt", string(prompt), "--session-dir", session_dir)
	// Resuming keeps the agent's context across restarts; without it every
	// restart is an amnesiac reintroduction.
	if session_has_transcript(session_dir) {
		append(&args, "--continue")
		fmt.println("graiced: resuming interrupted session")
	}

	in_r, in_w, perr1 := os.pipe()
	out_r, out_w, perr2 := os.pipe()
	if perr1 != nil || perr2 != nil {
		fmt.eprintln("graiced: pipe() failed")
		return false
	}

	desc := os.Process_Desc {
		command     = args[:],
		working_dir = cfg.bot_dir,
		stdin       = in_r,
		stdout      = out_w,
		stderr      = os.stderr,
	}
	p, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("graiced: failed to start omp: %v", err)
		return false
	}
	// The child owns its ends now; holding them open here would mean stdout
	// never reports EOF when the child dies.
	os.close(in_r)
	os.close(out_w)

	o.process = p
	o.stdin = in_w
	o.stdout_r = out_r
	o.alive = true
	o.events = make([dynamic]string)
	o.closed = false

	thread.create_and_start_with_poly_data(o, omp_reader)
	fmt.printfln("graiced: omp RPC ready (model=%s)", cfg.omp_model)
	return true
}

// Drains stdout line by line. Runs until EOF, which is how we learn the child
// exited even if nobody called process_wait.
omp_reader :: proc(o: ^Omp) {
	buf: [8192]u8
	pending := strings.builder_make()
	for {
		n, err := os.read(o.stdout_r, buf[:])
		if err != nil || n <= 0 {
			sync.mutex_lock(&o.mutex)
			o.closed = true
			sync.mutex_unlock(&o.mutex)
			return
		}
		strings.write_bytes(&pending, buf[:n])
		text := strings.to_string(pending)
		for {
			nl := strings.index_byte(text, '\n')
			if nl < 0 {
				break
			}
			line := strings.trim_space(text[:nl])
			if len(line) > 0 {
				sync.mutex_lock(&o.mutex)
				o.last_event = time.now()
				append(&o.events, strings.clone(line))
				sync.mutex_unlock(&o.mutex)
			}
			text = text[nl + 1:]
		}
		// keep the partial tail for the next read
		strings.builder_reset(&pending)
		strings.write_string(&pending, text)
	}
}

omp_stop :: proc(o: ^Omp) {
	if !o.alive {
		return
	}
	if o.stdin != nil {
		os.close(o.stdin)
	}
	_ = os.process_kill(o.process)
	o.alive = false
}

omp_is_alive :: proc(o: ^Omp) -> bool {
	sync.mutex_lock(&o.mutex)
	closed := o.closed
	sync.mutex_unlock(&o.mutex)
	return o.alive && !closed
}

// ------------------------------------------------------------------ RPC -----

omp_send :: proc(o: ^Omp, kind, message: string) -> bool {
	if o.stdin == nil {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"type":`)
	json_write_string(&b, kind)
	strings.write_string(&b, `,"message":`)
	json_write_string(&b, message)
	strings.write_string(&b, "}\n")
	_, err := os.write(o.stdin, transmute([]u8)strings.to_string(b))
	return err == nil
}

omp_next_event :: proc(o: ^Omp, timeout: time.Duration) -> (string, bool) {
	deadline := time.now()._nsec + i64(timeout)
	for {
		sync.mutex_lock(&o.mutex)
		if len(o.events) > 0 {
			ev := o.events[0]
			ordered_remove(&o.events, 0)
			sync.mutex_unlock(&o.mutex)
			return ev, true
		}
		closed := o.closed
		sync.mutex_unlock(&o.mutex)
		if closed {
			return "", false          // EOF: caller decides how to report it
		}
		if time.now()._nsec >= deadline {
			return "", false
		}
		time.sleep(50 * time.Millisecond)
	}
}

// ------------------------------------------------------------- selftest -----

// Drives a real omp turn end to end: spawn, prompt, collect. This is the piece
// that decides whether the Odin bridge works at all, so it is exercised
// against the real binary rather than a mock.
cmd_ask :: proc(cfg: Config) -> int {
	if len(cfg.bot_dir) == 0 {
		fmt.eprintln("set GRAICE_DIR to the bot directory (SYSTEM_PROMPT.md, sessions/)")
		return 1
	}
	question := len(os.args) > 2 ? os.args[2] : "Reply with exactly: ODIN BRIDGE OK"
	fmt.printfln("bot dir : %s", cfg.bot_dir)
	fmt.printfln("omp     : %s (%s)", cfg.omp_bin, cfg.omp_model)
	fmt.printfln("asking  : %q\n", question)

	o := new(Omp)
	if !omp_start(cfg, o) {
		return 1
	}
	defer omp_stop(o)

	turn_snapshot(cfg, o)
	if !omp_send(o, "prompt", question) {
		fmt.eprintln("graiced: failed to send prompt")
		return 1
	}
	reply := omp_wait_for_response(cfg, o)
	fmt.printfln("\n--- reply (%d chars) ---\n%s", len(reply), reply)
	return 0
}
