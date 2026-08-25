// Showing whether the agent is actually working.
//
// Anytype has no typing or presence API, so the signal is a reaction on the
// message being answered. What drives it matters more than the emoji:
//
// omp streams events continuously while it works -- agent_start, every
// tool_execution_start/end, agent_end. So "did omp say anything recently?" is a
// real busy signal, not a guess. An earlier version escalated on elapsed time,
// which cannot tell a slow job from a dead one: a long build and a wedged
// process look identical to a clock.
//
//   working   omp emitted something within STALL_AFTER
//   stalled   it has gone quiet mid-turn -- that is the problem worth seeing
//   failed    the turn ended badly; the marker stays
package main

import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

WORKING_EMOJI :: "👀"   // omp is emitting events
STALLED_EMOJI :: "⚠️"   // silent mid-turn, or the turn failed

// How long omp may be silent before it counts as stalled. Generous: a single
// long model call emits nothing while it runs, and that is normal.
STALL_AFTER :: 90 * time.Second

Working :: struct {
	bot:     ^Bot,
	chat:    string,
	message: string,
	shown:   string, // emoji currently on the message, "" for none
	stop:    bool,
	running: bool,
	mutex:   sync.Mutex,
}

working_start :: proc(b: ^Bot, chat_id, message_id: string) -> ^Working {
	if len(message_id) == 0 {
		return nil
	}
	w := new(Working)
	w.bot = b
	w.chat = strings.clone(chat_id)
	w.message = strings.clone(message_id)
	w.running = true
	thread.create_and_start_with_poly_data(w, working_loop)
	return w
}

// Swap the marker. The endpoint toggles, so the old one must come off first or
// the message ends up wearing both.
working_show :: proc(w: ^Working, emoji: string) {
	if w.shown == emoji {
		return
	}
	if len(w.shown) > 0 {
		toggle_reaction(w.bot.cfg, w.chat, w.message, w.shown)
	}
	if len(emoji) > 0 {
		toggle_reaction(w.bot.cfg, w.chat, w.message, emoji)
	}
	w.shown = emoji
}

working_loop :: proc(w: ^Working) {
	for {
		sync.mutex_lock(&w.mutex)
		stop := w.stop
		sync.mutex_unlock(&w.mutex)
		if stop {
			break
		}

		sync.mutex_lock(&w.bot.omp.mutex)
		last := w.bot.omp.last_event
		sync.mutex_unlock(&w.bot.omp.mutex)

		// A zero timestamp means omp has not spoken since it started; treat
		// that as working rather than stalled until the window elapses.
		quiet := time.since(last)
		if last._nsec == 0 {
			quiet = 0
		}
		working_show(w, quiet > STALL_AFTER ? STALLED_EMOJI : WORKING_EMOJI)

		time.sleep(3 * time.Second)
	}

	sync.mutex_lock(&w.mutex)
	w.running = false
	sync.mutex_unlock(&w.mutex)
}

// Clear the marker. `failed` leaves the warning in place instead: a turn that
// crashed must not look the same as one that answered.
working_stop :: proc(w: ^Working, failed: bool) {
	if w == nil {
		return
	}
	sync.mutex_lock(&w.mutex)
	w.stop = true
	sync.mutex_unlock(&w.mutex)
	for i in 0 ..< 40 {
		sync.mutex_lock(&w.mutex)
		running := w.running
		sync.mutex_unlock(&w.mutex)
		if !running {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	working_show(w, failed ? STALLED_EMOJI : "")
}
