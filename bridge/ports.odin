// Clearing stale listeners before starting the middleware.
//
// The helper binds fixed ports, so a previous instance that outlived its
// supervisor (killed -9, crashed shell, a run started by hand) keeps 31011 and
// the fresh one dies with "address already in use". The supervisor then
// restarts it in a tight loop until the old process happens to exit -- observed
// live, three restarts before it settled.
//
// Only anytypeHelper processes are ever killed: something else on the port is
// reported and left alone, because taking down an unrelated service would be a
// far worse failure than refusing to start.
package main

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

port_of :: proc(addr: string) -> string {
	if i := strings.last_index(addr, ":"); i >= 0 {
		return addr[i + 1:]
	}
	return addr
}

Listener :: struct {
	pid:     int,
	command: string,
}

// Listeners on a TCP port. `lsof -F pc` emits one field per line -- "p<pid>"
// then "c<command>" -- so a single call yields both, with no second process
// whose failure would leave the command name blank and block the kill.
listeners :: proc(port: string, allocator := context.allocator) -> []Listener {
	desc := os.Process_Desc {
		command = []string{"/usr/sbin/lsof", "-nP", fmt.tprintf("-iTCP:%s", port),
		                   "-sTCP:LISTEN", "-F", "pc"},
	}
	state, out, errout, err := os.process_exec(desc, allocator)
	_ = state
	_ = errout
	if err != nil {
		return nil
	}
	found := make([dynamic]Listener, allocator)
	cur := Listener{}
	for line in strings.split_lines(string(out), context.temp_allocator) {
		if len(line) < 2 {
			continue
		}
		switch line[0] {
		case 'p':
			if cur.pid != 0 {
				append(&found, cur)
			}
			cur = Listener{}
			if pid, ok := strconv.parse_int(line[1:]); ok {
				cur.pid = pid
			}
		case 'c':
			cur.command = strings.clone(line[1:], allocator)
		}
	}
	if cur.pid != 0 {
		append(&found, cur)
	}
	return found[:]
}

// Make sure `addr` is free, clearing a leftover helper if that is what holds it.
// Returns false only when something we must not touch is in the way.
ensure_port_free :: proc(addr: string) -> bool {
	port := port_of(addr)
	holders := listeners(port, context.temp_allocator)
	if len(holders) == 0 {
		return true
	}
	for h in holders {
		// lsof truncates the command to 9 chars ("anytypeHe"), so match a prefix.
		if !strings.has_prefix(h.command, "anytypeHe") {
			fmt.eprintfln("graiced: port %s held by %q (pid %d) — not ours, refusing to kill",
				port, h.command, h.pid)
			return false
		}
		fmt.printfln("graiced: clearing stale helper on %s (pid %d)", port, h.pid)
		if p, err := os.process_open(h.pid); err == nil {
			_ = os.process_kill(p)
		}
	}
	// Give the kernel a moment to release the socket before rebinding.
	for _ in 0 ..< 50 {
		if len(listeners(port, context.temp_allocator)) == 0 {
			return true
		}
		time.sleep(100 * time.Millisecond)
	}
	fmt.eprintfln("graiced: port %s still busy after clearing", port)
	return false
}


// Only ONE supervisor may own the fixed ports. A second one sees the first's
// healthy helper as "stale", kills it, starts its own, and is killed right
// back -- observed as 2314 restarts with exit_code 9 in minutes. A pid file is
// the reliable guard: matching on process name breaks the moment the binary is
// called anything else (graiced.new, a copy, a test build).
supervisor_lock_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/supervisor.lock", cfg.root)
}

supervisor_claim :: proc(cfg: Config) -> bool {
	path := supervisor_lock_path(cfg)
	if data, err := os.read_entire_file(path, context.temp_allocator); err == nil {
		if pid, ok := strconv.parse_int(strings.trim_space(string(data))); ok && pid > 0 && pid != os.get_pid() {
			if _, ierr := os.process_info_by_pid(pid, {.Executable_Path}, context.temp_allocator);
			   ierr == nil {
				fmt.eprintfln("graiced: supervisor pid %d already owns these ports — exiting", pid)
				return false
			}
			fmt.printfln("graiced: stale supervisor lock (pid %d gone), taking over", pid)
		}
	}
	os.make_directory_all(cfg.root)
	_ = os.write_entire_file(path, transmute([]u8)fmt.tprintf("%d", os.get_pid()))
	return true
}
