// graiced — runs a private Anytype middleware for a bot identity.
//
// Why this exists: the Anytype desktop app serves exactly one account, so a bot
// posting through it speaks as the human who owns it. Giving a bot its own name
// and avatar means a second middleware signed in as the bot's own account.
//
// A second anytypeHelper can be told where to put its gRPC, grpc-web and
// gateway listeners, but NOT its JSON API — port 31009 is hardcoded, so the
// second instance cannot expose a REST API of its own. Everything a bot needs
// therefore has to go over grpc-web, and graiced re-exposes it on a fixed local
// port that the Python bot talks to instead of :31009.
//
// Stage 1 (this file): supervise the helper — own ports, own data directory,
// restart if it dies.
package main

import "core:fmt"
import "core:net"
import "core:os"
import "core:strconv"
import "core:strings"
import "core:time"

GRAICED_VERSION :: "graiced/0.1"
DEFAULT_HELPER :: "/Applications/Anytype.app/Contents/Resources/app.asar.unpacked/dist/anytypeHelper"

Config :: struct {
	helper:       string, // path to the anytypeHelper binary
	root:         string, // wallet/account data directory (NOT the desktop's)
	grpc_addr:    string, // helper's gRPC listener
	grpcweb_addr: string, // helper's grpc-web listener — what we speak
	gateway_addr: string, // helper's file gateway (attachment downloads)
	listen_addr:  string, // graiced's own JSON API, which the bot talks to
	// --- bot side (graiced bot) ---
	space_id:     string, // the space whose chats/discussions we watch
	api_key:      string, // JsonAPI key minted at bootstrap
	bot_identity: string, // our identity key, for exact bot/human attribution
	bot_dir:      string, // where SYSTEM_PROMPT.md, sessions/ and state/ live
	omp_bin:      string,
	omp_model:    string,
	agent_timeout: time.Duration,
}

env_or :: proc(key, fallback: string) -> string {
	if v, ok := os.lookup_env(key, context.allocator); ok && len(v) > 0 {
		return v
	}
	return fallback
}

config_load :: proc() -> Config {
	home := env_or("HOME", "")
	return Config {
		helper       = env_or("GRAICED_HELPER", DEFAULT_HELPER),
		// Must not be the desktop app's directory: two middlewares over one
		// account store would fight over the same badger/sqlite files.
		root         = env_or("GRAICED_ROOT", fmt.tprintf("%s/.graiced/account", home)),
		grpc_addr    = env_or("GRAICED_GRPC_ADDR", "127.0.0.1:31011"),
		grpcweb_addr = env_or("GRAICED_GRPCWEB_ADDR", "127.0.0.1:31012"),
		gateway_addr = env_or("GRAICED_GATEWAY_ADDR", "127.0.0.1:31013"),
		listen_addr  = env_or("GRAICED_LISTEN_ADDR", "127.0.0.1:31010"),
		space_id     = env_or("ANYTYPE_CHAT_SPACE_ID", env_or("ANYTYPE_SPACE_ID", "")),
		api_key      = env_or("ANYTYPE_API_KEY", api_key_load_quiet()),
		bot_identity = env_or("ANYTYPE_BOT_IDENTITY", ""),
		bot_dir      = env_or("GRAICE_DIR", ""),
		omp_bin      = env_or("OMP_BIN", fmt.tprintf("%s/.local/bin/omp", home)),
		omp_model    = env_or("OMP_MODEL", "opus"),
		agent_timeout = time.Duration(env_int("AGENT_TIMEOUT", 3000)) * time.Second,
	}
}

// A TCP connect is enough: the helper binds its listeners only once it is
// actually ready to serve, so "accepts a connection" means "booted".
port_open :: proc(addr: string) -> bool {
	sock, err := net.dial_tcp_from_hostname_and_port_string(addr)
	if err != nil {
		return false
	}
	net.close(sock)
	return true
}

wait_for_port :: proc(addr: string, timeout: time.Duration) -> bool {
	deadline := time.now()._nsec + i64(timeout)
	for time.now()._nsec < deadline {
		if port_open(addr) {
			return true
		}
		time.sleep(200 * time.Millisecond)
	}
	return false
}

helper_start :: proc(cfg: Config) -> (os.Process, bool) {
	if !os.exists(cfg.helper) {
		fmt.eprintfln("graiced: helper not found at %s", cfg.helper)
		return {}, false
	}
	if err := os.make_directory_all(cfg.root); err != nil && err != .Exist {
		fmt.eprintfln("graiced: cannot create root %s: %v", cfg.root, err)
		return {}, false
	}

	// The helper takes the gRPC and grpc-web addresses positionally, the way
	// the desktop app launches it ("127.0.0.1:0 127.0.0.1:0" for ephemeral).
	// We pin them so the bot has a stable address to talk to across restarts.
	env := []string {
		fmt.tprintf("ANYTYPE_GRPC_ADDR=%s", cfg.grpc_addr),
		fmt.tprintf("ANYTYPE_GRPCWEB_ADDR=%s", cfg.grpcweb_addr),
		fmt.tprintf("ANYTYPE_GATEWAY_ADDR=%s", cfg.gateway_addr),
		fmt.tprintf("HOME=%s", env_or("HOME", "")),
		fmt.tprintf("PATH=%s", env_or("PATH", "/usr/bin:/bin")),
	}
	// Pass the middleware's stdout/stderr through. Discarding them (the default
	// for a nil handle) hides its panics, which is exactly what a
	// "panic recovered" reply needs us to read.
	desc := os.Process_Desc {
		command     = []string{cfg.helper, cfg.grpc_addr, cfg.grpcweb_addr},
		env         = env,
		working_dir = cfg.root,
		stdout      = os.stdout,
		stderr      = os.stderr,
	}
	// A leftover helper on our fixed ports makes the new one exit immediately
	// with "address already in use", which the supervisor loop then retries
	// forever. Clear it first rather than thrashing.
	if !ensure_port_free(cfg.grpc_addr) || !ensure_port_free(cfg.grpcweb_addr) {
		return {}, false
	}

	proc_handle, err := os.process_start(desc)
	if err != nil {
		fmt.eprintfln("graiced: failed to start helper: %v", err)
		return {}, false
	}
	fmt.printfln("graiced: helper started (pid %d)", proc_handle.pid)

	if !wait_for_port(cfg.grpcweb_addr, 30 * time.Second) {
		fmt.eprintfln("graiced: helper did not open %s within 30s", cfg.grpcweb_addr)
		_ = os.process_kill(proc_handle)
		return {}, false
	}
	fmt.printfln("graiced: grpc-web ready on %s", cfg.grpcweb_addr)
	return proc_handle, true
}

main :: proc() {
	cfg := config_load()
	fmt.printfln("graiced: root=%s", cfg.root)
	fmt.printfln("graiced: grpc=%s grpc-web=%s gateway=%s",
		cfg.grpc_addr, cfg.grpcweb_addr, cfg.gateway_addr)

	if len(os.args) > 1 && os.args[1] == "bootstrap" {
		os.exit(cmd_bootstrap(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "selftest" {
		os.exit(cmd_selftest(cfg))
	}

	// Post a message as the bot. Exists to verify formatting end to end:
	// markdown in, marks out, checked against what Anytype stored.
	if len(os.args) > 3 && os.args[1] == "send" {
		if send_message(cfg, os.args[2], os.args[3]) {
			fmt.println("sent")
			os.exit(0)
		}
		fmt.eprintln("send failed")
		os.exit(1)
	}

	if len(os.args) > 1 && os.args[1] == "preview" {
		os.exit(cmd_preview(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "bot" {
		os.exit(cmd_bot(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "surfaces" {
		os.exit(cmd_surfaces(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "ask" {
		os.exit(cmd_ask(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "transcript" {
		os.exit(cmd_transcript(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "chat" {
		os.exit(cmd_chat(cfg))
	}

	if len(os.args) > 1 && os.args[1] == "version" {
		// Validates the whole stack (HTTP/1.1 -> grpc-web framing -> protobuf)
		// against any middleware, using the one RPC that needs no session.
		msg := make([dynamic]u8, context.temp_allocator)
		res := rpc_call(cfg, "AppGetVersion", msg[:], "")
		if len(res.err) > 0 {
			fmt.eprintfln("graiced: AppGetVersion failed: %s", res.err)
			os.exit(1)
		}
		fields := pb_parse(res.payload, context.temp_allocator)
		fmt.printfln("grpc-status : %s", res.status)
		fmt.printfln("rpc error   : %q", rpc_error(res.payload))
		fmt.printfln("version     : %q", pb_get_string(fields, 2))
		fmt.printfln("details     : %q", pb_get_string(fields, 3))
		return
	}

	if len(os.args) > 1 && os.args[1] == "check" {
		// Config/preflight only — used by tests and by the install script.
		fmt.printfln("helper exists: %v", os.exists(cfg.helper))
		fmt.printfln("grpc-web port already in use: %v", port_open(cfg.grpcweb_addr))
		fmt.printfln("shim port already in use: %v", port_open(cfg.listen_addr))
		return
	}

	// Claim the ports before supervising anything; two supervisors kill each
	// other's helpers in a tight loop.
	if !supervisor_claim(cfg) {
		os.exit(1)
	}

	// Supervise: a middleware that dies takes the bot's voice with it, and the
	// bot has no way to notice. Restart it and keep the address stable.
	for {
		handle, ok := helper_start(cfg)
		if !ok {
			fmt.eprintfln("graiced: start failed; retrying in 10s")
			time.sleep(10 * time.Second)
			continue
		}
		// Sign in, expose REST on our own port, ensure a key. All runtime state:
		// the middleware forgets between runs.
		if !serve_ready(cfg) {
			fmt.eprintln("graiced: not ready — run `graiced bootstrap` first")
		}
		state, werr := os.process_wait(handle)
		fmt.eprintfln("graiced: helper exited (state=%v err=%v) — restarting", state, werr)
		time.sleep(2 * time.Second)
	}
}

env_int :: proc(key: string, fallback: int) -> int {
	if v, ok := strconv.parse_int(env_or(key, "")); ok {
		return v
	}
	return fallback
}

// The bot's working directory holds SYSTEM_PROMPT.md, sessions/ and state/.
bot_session_dir :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/sessions/main", cfg.bot_dir)
}

bot_system_prompt :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/SYSTEM_PROMPT.md", cfg.bot_dir)
}

cmd_surfaces :: proc(cfg: Config) -> int {
	s := new(Surfaces)
	discussions_load(cfg, s)
	for c in discover_all(cfg, s) {
		name, kind := host_label(cfg, c)
		fmt.printfln("  %-10s %q", kind, name)
	}
	return 0
}

// Show exactly what the agent receives for a surface. Verifies the object body
// is inlined, without waiting for a live message.
cmd_preview :: proc(cfg: Config) -> int {
	s := new(Surfaces)
	discussions_load(cfg, s)
	b := new(Bot)
	b.cfg = cfg
	b.surfaces = s
	b.bodies = body_cache_load(cfg)
	for c in discover_all(cfg, s) {
		fake := Message{author = "@Geep", text = "<your message here>"}
		fmt.println("════════════════════════════════════════")
		fmt.println(build_user_message(b, c, fake))
	}
	return 0
}
