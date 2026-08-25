// Stage 2: sign the private middleware in as the bot's own account.
//
// WalletRecover writes a wallet into our own root directory (never the
// desktop's — two middlewares over one store would corrupt it), then
// AccountSelect launches that account. After this the helper is the bot, and
// every message it sends carries the bot's name and avatar.
//
// The recovery phrase is read from the terminal with echo off and is never
// written to disk, passed as an argument, or logged. It lives in this process
// only for the duration of the WalletRecover call.
package main

import "core:fmt"
import "core:os"
import "core:strings"

// Odin's posix package has no termios binding, so echo is toggled with stty.
// Same mechanism a shell's `read -s` uses.
stty :: proc(arg: string) {
	desc := os.Process_Desc {
		command = []string{"/bin/stty", arg},
		stdin   = os.stdin, // must inherit the tty to affect it
	}
	if p, err := os.process_start(desc); err == nil {
		_, _ = os.process_wait(p)
	}
}

read_secret :: proc(prompt: string) -> string {
	fmt.print(prompt)
	stty("-echo")
	line, err := read_line_stdin()
	stty("echo")
	fmt.println()
	if err {
		return ""
	}
	return strings.trim_space(line)
}

read_line_stdin :: proc() -> (string, bool) {
	buf: [1024]u8
	n, err := os.read(os.stdin, buf[:])
	if err != nil || n <= 0 {
		return "", true
	}
	return strings.clone(string(buf[:n])), false
}

// An account id is the directory the middleware creates under our root once a
// wallet is recovered; there is exactly one for a given phrase.
find_account_id :: proc(root: string) -> string {
	dir, err := os.open(root)
	if err != nil {
		return ""
	}
	defer os.close(dir)
	entries, rerr := os.read_dir(dir, -1, context.temp_allocator)
	if rerr != nil {
		return ""
	}
	for e in entries {
		// Account dirs are base58-ish and long; everything else the middleware
		// puts here (tmp, cache) is short and lowercase.
		if e.type == .Directory && len(e.name) > 40 {
			return strings.clone(e.name)
		}
	}
	return ""
}

cmd_bootstrap :: proc(cfg: Config) -> int {
	fmt.println("graiced: bootstrapping the bot account")
	fmt.printfln("  root      : %s", cfg.root)
	fmt.printfln("  grpc-web  : %s", cfg.grpcweb_addr)
	fmt.println()
	fmt.println("This writes an account store into the root above. One-time: after")
	fmt.println("this, the daemon signs in with the saved account id and never needs")
	fmt.println("the phrase again.")
	fmt.println()

	// Start the middleware ourselves if it is not already up. Requiring the
	// user to run two commands in two terminals was a needless trap: the
	// prompt has echo off, so a bootstrap waiting on stdin looks like a hang.
	started_here: os.Process
	own_helper := false
	if !port_open(cfg.grpcweb_addr) {
		fmt.println("starting middleware...")
		h, ok := helper_start(cfg)
		if !ok {
			fmt.eprintln("graiced: could not start the middleware")
			return 1
		}
		started_here = h
		own_helper = true
	} else {
		fmt.printfln("using middleware already listening on %s", cfg.grpcweb_addr)
	}
	defer if own_helper {
		fmt.println("stopping the middleware we started (run `graiced` to serve)")
		_ = os.process_kill(started_here)
	}

	phrase := read_secret("Graice recovery phrase (nothing will echo): ")
	if len(phrase) == 0 {
		fmt.eprintln("graiced: no phrase entered; nothing changed")
		return 1
	}
	words := len(strings.split(phrase, " ", context.temp_allocator))
	if words != 12 {
		fmt.eprintfln("graiced: expected 12 words, got %d", words)
		return 1
	}

	// The middleware refuses account operations until the client identifies
	// itself -- AccountSelect panics with "client platform with the version must
	// be set using the InitialSetParameters method". The desktop does this at
	// startup; a headless client must too.
	if !initial_set_parameters(cfg) {
		return 1
	}
	fmt.println("client registered ✓")

	// WalletRecover: rootPath = 1, mnemonic = 2
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, cfg.root)
	pb_string(&msg, 2, phrase)
	res := rpc_call(cfg, "WalletRecover", msg[:], "")
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: WalletRecover transport error: %s", res.err)
		return 1
	}
	if e := rpc_error(res.payload); len(e) > 0 {
		fmt.eprintfln("graiced: WalletRecover rejected: %s", e)
		fmt.eprintln("  (a valid phrase for a DIFFERENT account gives 'incorrect mnemonic')")
		return 1
	}
	fmt.println("wallet recovered ✓")

	// Account RPCs need a session: without a token the middleware answers 200
	// with an empty body rather than an error, which is indistinguishable from
	// success unless you check for it. The desktop client does this same
	// WalletCreateSession step before touching accounts.
	sess, sok := wallet_session(cfg, 1, phrase) // 1 = mnemonic
	if !sok {
		fmt.eprintln("graiced: could not open a session with that phrase")
		return 1
	}
	token := sess.token
	fmt.println("session opened ✓")

	// Persist the appToken so later starts never need the phrase again.
	if len(sess.app_token) > 0 {
		if err := os.write_entire_file(app_token_path(cfg), transmute([]u8)sess.app_token); err == nil {
			_ = os.chmod(app_token_path(cfg), os.Permissions{.Read_User, .Write_User})
			fmt.println("app token saved ✓ (phrase no longer needed)")
		} else {
			fmt.eprintfln("graiced: could not save app token: %v", err)
		}
	}

	account := env_or("GRAICED_ACCOUNT_ID", "")
	if len(account) == 0 {
		account = sess.account_id      // the session tells us who we are
	}
	if len(account) == 0 {
		account = find_account_id(cfg.root)
	}
	if len(account) == 0 {
		// WalletRecover does not materialise the account directory -- that only
		// happens on AccountSelect -- so there is nothing local to scan yet.
		// The id is the bot's identity, visible as a space member.
		fmt.eprintln("graiced: could not determine the account id.")
		fmt.eprintln("  It is the bot's identity key, e.g. from the space member list.")
		fmt.eprintln("  Re-run as:")
		fmt.eprintln("    GRAICED_ACCOUNT_ID=<identity> graiced bootstrap")
		return 1
	}
	fmt.printfln("account   : %s", account)

	// AccountRecover first. AccountSelect's own proto says an account is chosen
	// "from those, that came with an AccountAdd event" -- recover is what emits
	// them. Selecting without it panics inside the middleware on a fresh store.
	rec := make([dynamic]u8, context.temp_allocator)
	rres := rpc_call(cfg, "AccountRecover", rec[:], token)
	if len(rres.err) > 0 {
		fmt.eprintfln("graiced: AccountRecover: %s (continuing)", rres.err)
	} else if e := rpc_error(rres.payload); len(e) > 0 {
		fmt.eprintfln("graiced: AccountRecover: %s (continuing)", e)
	} else {
		fmt.println("accounts recovered ✓")
	}

	// AccountSelect: id = 1, rootPath = 2
	sel := make([dynamic]u8, context.temp_allocator)
	pb_string(&sel, 1, account)
	pb_string(&sel, 2, cfg.root)
	sres := rpc_call(cfg, "AccountSelect", sel[:], token)
	if len(sres.err) > 0 {
		fmt.eprintfln("graiced: AccountSelect transport error: %s", sres.err)
		return 1
	}
	if e := rpc_error(sres.payload); len(e) > 0 {
		fmt.eprintfln("graiced: AccountSelect failed: %s", e)
		return 1
	}
	fmt.println("account selected ✓")

	// Persist the id so the daemon can AccountSelect on every start. That call
	// needs only the id and root path, so the phrase is required exactly once.
	if !save_account_id(cfg, account) {
		fmt.eprintfln("graiced: warning — could not write %s; set GRAICED_ACCOUNT_ID instead",
			account_id_path(cfg))
	}

	fmt.println()
	fmt.println("Bootstrap complete.")
	if len(sess.app_token) == 0 {
		// Be honest: this middleware issues no appToken, so the phrase IS
		// needed again on every start -- exactly as the desktop app needs it.
		fmt.println()
		fmt.println("NOTE: no app token was issued, so the daemon needs the phrase at")
		fmt.println("every start (the desktop app has the same constraint). Store it in")
		fmt.println("the login Keychain once -- it will prompt, nothing appears in ps:")
		fmt.printfln("  security add-generic-password -a %s -s %s -U -w",
			KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE)
	}
	fmt.println()
	fmt.println("Then start the daemon with:  graiced")
	fmt.println("Then add to the bot's .env:")
	fmt.printfln("  ANYTYPE_BOT_IDENTITY=%s", account)
	return 0
}

// InitialSetParameters: platform=1, version=2, workdir=3, logLevel=4.
// Must be the first call on a fresh middleware.
initial_set_parameters :: proc(cfg: Config) -> bool {
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, "darwin")
	pb_string(&msg, 2, GRAICED_VERSION)
	pb_string(&msg, 3, cfg.root)
	pb_string(&msg, 4, "error")
	res := rpc_call(cfg, "InitialSetParameters", msg[:], "")
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: InitialSetParameters failed: %s", res.err)
		return false
	}
	if e := rpc_error(res.payload); len(e) > 0 {
		fmt.eprintfln("graiced: InitialSetParameters rejected: %s", e)
		return false
	}
	return true
}

KEYCHAIN_ACCOUNT :: "graiced"
KEYCHAIN_SERVICE :: "graiced-mnemonic"

// Anytype's own desktop app calls WalletRecover with the mnemonic on EVERY
// launch and keeps it in the login keychain between runs -- there is no
// on-disk wallet the middleware can load unaided, and WalletCreateSession
// returned no appToken to stand in for it. So graiced does the same thing:
// the phrase lives in the Keychain (written once by the user, never by us or
// by argv) and is read back at each start.
keychain_phrase :: proc() -> string {
	desc := os.Process_Desc {
		command = []string{
			"/usr/bin/security", "find-generic-password",
			"-a", KEYCHAIN_ACCOUNT, "-s", KEYCHAIN_SERVICE, "-w",
		},
	}
	state, out, errout, err := os.process_exec(desc, context.allocator)
	defer delete(errout)
	if err != nil || state.exit_code != 0 {
		delete(out)
		return ""
	}
	return strings.trim_space(string(out))
}

Session :: struct {
	token:      string, // ephemeral, for this middleware run
	app_token:  string, // persistent; replaces the phrase on later runs
	account_id: string,
}

// WalletCreateSession's request is a oneof: mnemonic=1, appKey=2, token=3.
// Authenticating with the phrase also returns an appToken the client is meant
// to persist -- that is what lets the daemon start without the phrase.
wallet_session :: proc(cfg: Config, field: u32, secret: string) -> (Session, bool) {
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, field, secret)
	res := rpc_call(cfg, "WalletCreateSession", msg[:], "")
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: WalletCreateSession failed: %s", res.err)
		return {}, false
	}
	if e := rpc_error(res.payload); len(e) > 0 {
		fmt.eprintfln("graiced: WalletCreateSession rejected: %s", e)
		return {}, false
	}
	f := pb_parse(res.payload, context.temp_allocator)
	s := Session {
		token      = strings.clone(pb_get_string(f, 2)),
		app_token  = strings.clone(pb_get_string(f, 3)),
		account_id = strings.clone(pb_get_string(f, 4)),
	}
	return s, len(s.token) > 0
}

app_token_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/app_token", cfg.root)
}

app_token_load :: proc(cfg: Config) -> string {
	data, err := os.read_entire_file(app_token_path(cfg), context.allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

account_id_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/account_id", cfg.root)
}

save_account_id :: proc(cfg: Config, id: string) -> bool {
	err := os.write_entire_file(account_id_path(cfg), transmute([]u8)id)
	return err == nil
}

load_account_id :: proc(cfg: Config) -> string {
	if v := env_or("GRAICED_ACCOUNT_ID", ""); len(v) > 0 {
		return v
	}
	data, rerr := os.read_entire_file(account_id_path(cfg), context.allocator)
	if rerr != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

// Sign the freshly started middleware in as the bot. No phrase involved: the
// wallet is already on disk from bootstrap.
account_select :: proc(cfg: Config, token: string) -> bool {
	id := load_account_id(cfg)
	if len(id) == 0 {
		fmt.eprintln("graiced: no account id — run `graiced bootstrap` first")
		return false
	}
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, id)
	pb_string(&msg, 2, cfg.root)
	res := rpc_call(cfg, "AccountSelect", msg[:], token)
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: AccountSelect transport error: %s", res.err)
		return false
	}
	if e := rpc_error(res.payload); len(e) > 0 {
		fmt.eprintfln("graiced: AccountSelect failed: %s", e)
		return false
	}
	fmt.printfln("graiced: signed in as %s", id)
	return true
}
