// Expose the bot's middleware as a normal Anytype JSON API.
//
// The original plan was to hand-write chat RPCs and an HTTP shim here, because
// a second helper cannot serve REST on :31009 (that port is hardcoded). It
// turns out AccountChangeJsonApiAddr moves the JSON API to any address, and
// AccountLocalLinkCreateApp mints an app key without the desktop's 4-digit
// pairing prompt. So the bot's middleware can simply serve a real REST API on
// its own port, and the Python transport keeps working unchanged apart from a
// different base URL and key.
package main

import "core:fmt"
import "core:os"
import "core:strings"

API_KEY_FILE :: "api_key"

api_key_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/%s", cfg.root, API_KEY_FILE)
}

// Move this middleware's JSON API onto our own port. Must be re-issued on every
// start: the address is runtime state, not stored in the account.
json_api_enable :: proc(cfg: Config, token: string) -> bool {
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, cfg.listen_addr) // listenAddr
	res := rpc_call(cfg, "AccountChangeJsonApiAddr", msg[:], token)
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: AccountChangeJsonApiAddr transport error: %s", res.err)
		return false
	}
	// NOTE: this response carries Error in field 2, not the usual field 1.
	if e := rpc_error_at(res.payload, 2); len(e) > 0 {
		fmt.eprintfln("graiced: AccountChangeJsonApiAddr failed: %s", e)
		return false
	}
	fmt.printfln("graiced: JSON API listening on %s", cfg.listen_addr)
	return true
}

// Mint a JsonAPI-scoped app key for the bot. Persistent, so this only needs to
// happen once; the key is reused on later starts.
api_key_create :: proc(cfg: Config, token: string) -> string {
	info := make([dynamic]u8, context.temp_allocator)
	pb_string(&info, 2, "graiced") // AppInfo.appName
	pb_tag(&info, 7, 0)            // AppInfo.scope
	pb_varint(&info, 1)            // LocalApiScope.JsonAPI

	msg := make([dynamic]u8, context.temp_allocator)
	pb_tag(&msg, 1, 2)             // CreateApp.Request.app
	pb_varint(&msg, u64(len(info)))
	append(&msg, ..info[:])

	res := rpc_call(cfg, "AccountLocalLinkCreateApp", msg[:], token)
	if len(res.err) > 0 {
		fmt.eprintfln("graiced: CreateApp transport error: %s", res.err)
		return ""
	}
	if e := rpc_error(res.payload); len(e) > 0 {
		fmt.eprintfln("graiced: CreateApp failed: %s", e)
		return ""
	}
	fields := pb_parse(res.payload, context.temp_allocator)
	return strings.clone(pb_get_string(fields, 2)) // appKey
}

api_key_load :: proc(cfg: Config) -> string {
	data, err := os.read_entire_file(api_key_path(cfg), context.allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}

api_key_ensure :: proc(cfg: Config, token: string) -> string {
	if k := api_key_load(cfg); len(k) > 0 {
		return k
	}
	k := api_key_create(cfg, token)
	if len(k) == 0 {
		return ""
	}
	if err := os.write_entire_file(api_key_path(cfg), transmute([]u8)k); err != nil {
		fmt.eprintfln("graiced: could not save api key: %v", err)
	} else {
		// The key is a credential; keep it off other users' radar.
		_ = os.chmod(api_key_path(cfg), os.Permissions{.Read_User, .Write_User})
		fmt.printfln("graiced: api key saved to %s", api_key_path(cfg))
	}
	return k
}

// Everything the bot needs, after the helper is up: be the bot, serve REST,
// have a key. Returns false if the bot would not actually be reachable.
serve_ready :: proc(cfg: Config) -> bool {
	// Re-authenticate with the persisted appToken (field 3 = token), not the
	// phrase. Account RPCs are refused without a session -- silently, with an
	// empty 200 -- so this must come first.
	// Same handshake the bootstrap does; the middleware is fresh on every start.
	if !initial_set_parameters(cfg) {
		return false
	}
	// Prefer an appToken if the middleware ever issues one; today it does not,
	// so fall back to the Keychain phrase the way the desktop client does.
	sess: Session
	ok: bool
	if app_token := app_token_load(cfg); len(app_token) > 0 {
		sess, ok = wallet_session(cfg, 3, app_token)
	} else {
		phrase := keychain_phrase()
		if len(phrase) == 0 {
			fmt.eprintln("graiced: no phrase in the Keychain. Store it once with:")
			fmt.eprintfln("  security add-generic-password -a %s -s %s -U -w",
				KEYCHAIN_ACCOUNT, KEYCHAIN_SERVICE)
			return false
		}
		// The wallet must be re-opened on every middleware start.
		rec := make([dynamic]u8, context.temp_allocator)
		pb_string(&rec, 1, cfg.root)
		pb_string(&rec, 2, phrase)
		if r := rpc_call(cfg, "WalletRecover", rec[:], ""); len(r.err) > 0 {
			fmt.eprintfln("graiced: WalletRecover failed: %s", r.err)
			return false
		}
		sess, ok = wallet_session(cfg, 1, phrase)
	}
	if !ok {
		fmt.eprintln("graiced: could not open a session")
		return false
	}
	if !account_select(cfg, sess.token) {
		return false
	}
	if !json_api_enable(cfg, sess.token) {
		return false
	}
	key := api_key_ensure(cfg, sess.token)
	if len(key) == 0 {
		fmt.eprintln("graiced: no api key — the bot cannot authenticate")
		return false
	}
	fmt.println("graiced: ready")
	fmt.println()
	fmt.println("Point the bot at this middleware:")
	fmt.printfln("  ANYTYPE_API_BASE=http://%s", cfg.listen_addr)
	fmt.printfln("  ANYTYPE_API_KEY=%s", key)
	fmt.printfln("  ANYTYPE_BOT_IDENTITY=%s", load_account_id(cfg))
	return true
}

// The key graiced minted at bootstrap, for when the bot runs in this process
// and no ANYTYPE_API_KEY is exported.
api_key_load_quiet :: proc() -> string {
	root := env_or("GRAICED_ROOT", fmt.tprintf("%s/.graiced/account", env_or("HOME", "")))
	data, err := os.read_entire_file(fmt.tprintf("%s/api_key", root), context.allocator)
	if err != nil {
		return ""
	}
	return strings.trim_space(string(data))
}
