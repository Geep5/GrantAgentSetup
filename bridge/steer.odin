// Mid-turn steering — folding a follow-up into the turn already running.
//
// Without this, saying "actually, do X instead" while the agent is working
// waits for the whole turn to finish, and by then it has done the wrong thing.
// A steer is delivered into the running agent, so it can change course.
//
// ONLY the surface being answered is steered. A message arriving in a DIFFERENT
// chat or discussion is deliberately left alone: a turn produces one reply and
// posts it to the surface it belongs to, so folding in a question from
// elsewhere would answer it in the wrong place. Those wait for the poll loop,
// which handles them in their own surface -- correct beats fast.
package main

import "core:fmt"
import "core:strings"
import "core:sync"
import "core:thread"
import "core:time"

STEER_POLL :: 5 * time.Second

Steer :: struct {
	bot:     ^Bot,
	chat:    Chat,
	mark:    string,          // advanced as we steer, so nothing repeats
	stop:    bool,
	mutex:   sync.Mutex,
	running: bool,
}

steer_start :: proc(b: ^Bot, c: Chat, from_mark: string) -> ^Steer {
	s := new(Steer)
	s.bot = b
	s.chat = c
	s.mark = strings.clone(from_mark)
	s.running = true
	// self_cleanup: the thread detaches and frees its own ^Thread on exit.
	// Without it every turn leaks a pthread (its stack is kept until join).
	thread.run_with_poly_data(s, steer_loop)
	return s
}

steer_stop :: proc(s: ^Steer) -> string {
	sync.mutex_lock(&s.mutex)
	s.stop = true
	sync.mutex_unlock(&s.mutex)
	// Let the loop notice; it checks between polls.
	for i in 0 ..< 40 {
		sync.mutex_lock(&s.mutex)
		running := s.running
		sync.mutex_unlock(&s.mutex)
		if !running {
			break
		}
		time.sleep(50 * time.Millisecond)
	}
	return s.mark
}

steer_loop :: proc(s: ^Steer) {
	for {
		time.sleep(STEER_POLL)
		// This thread has its OWN temp arena (it is thread-local) and nothing
		// else resets it: without this, a long turn chains a 4 MiB block per
		// poll for as long as the turn runs.
		defer free_all(context.temp_allocator)
		sync.mutex_lock(&s.mutex)
		stopping := s.stop
		sync.mutex_unlock(&s.mutex)
		if stopping {
			break
		}

		b := s.bot
		fresh := messages(b.cfg, s.chat.id, 10, s.mark, context.temp_allocator)
		if len(fresh) == 0 {
			continue
		}
		// Blank text over REST means the blocks format; recover it or the
		// steer would deliver an empty message.
		_ = fill_blank_text(b.cfg, b.surfaces, s.chat.id, fresh, context.temp_allocator)

		#reverse for m in fresh {          // oldest first
			if m.id > s.mark {
				s.mark = strings.clone(m.id)
			}
			if m.is_bot {
				continue
			}
			if len(strings.trim_space(m.text)) == 0 && len(m.attachments) == 0 {
				continue
			}
			fmt.printfln("graiced: steering into the running turn: %s",
				m.text[:min(len(m.text), 60)])
			if !omp_send(b.omp, "steer", build_user_message(b, s.chat, m)) {
				fmt.eprintln("graiced: steer failed to send")
			}
		}
	}
	sync.mutex_lock(&s.mutex)
	s.running = false
	sync.mutex_unlock(&s.mutex)
}
