// Anytype conversation transport — the Odin port of anytype_transport.py.
//
// Two surfaces, one interface:
//   * a space chat      (a chat object; several may exist per space)
//   * an object's Discussion (attached to a Task/Page; its id is NOT the
//     object id -- only ObjectShow exposes the discussionId)
//
// Reads and writes both go over REST against graiced's own JSON API, so the
// bot speaks as the bot identity rather than as the human who owns the desktop
// app. grpc-web is still needed for ONE thing: discovering Discussions, since
// ObjectShow is the only call that reveals a discussionId and the REST app key
// (scope JsonAPI) is refused for direct grpc calls.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

REST_VERSION :: "2025-11-08"

Message :: struct {
	id:         string, // order_id: lexicographically sortable, the watermark key
	message_id: string, // anytype message id, for reply threading
	author:     string, // display name
	is_bot:     bool,   // ours, by identity key
	text:       string,
	host:       string, // chat id it arrived on
	reply_to:   string, // parent message, when this one is itself a reply
	created:    i64,    // unix seconds, for transcripts
	attachments: []string, // object ids; fetched lazily when the message is used
}

Chat :: struct {
	id:        string,
	name:      string,
	kind:      string, // "chat" or the host object's type name
	host_id:   string, // object hosting a Discussion; == id for a chat object
	last_order: string,
}

// ---------------------------------------------------------------- REST ------

rest_url :: proc(cfg: Config, path: string) -> string {
	return fmt.tprintf("http://%s/v1/spaces/%s%s", cfg.listen_addr, cfg.space_id, path)
}

// GET returning parsed JSON. Caller frees via json.destroy_value.
rest_get :: proc(cfg: Config, path: string) -> (json.Value, bool) {
	body, err := http_request(cfg.listen_addr, "GET", fmt.tprintf("/v1/spaces/%s%s", cfg.space_id, path),
	                          nil, rest_headers(cfg), context.temp_allocator)
	if len(err) > 0 {
		fmt.eprintfln("graiced: GET %s failed: %s", path, err)
		return nil, false
	}
	v, jerr := json.parse(body, allocator = context.temp_allocator)
	if jerr != nil {
		return nil, false
	}
	return v, true
}

rest_post :: proc(cfg: Config, path: string, payload: []u8) -> (json.Value, bool) {
	body, err := http_request(cfg.listen_addr, "POST", fmt.tprintf("/v1/spaces/%s%s", cfg.space_id, path),
	                          payload, rest_headers(cfg), context.temp_allocator)
	if len(err) > 0 {
		fmt.eprintfln("graiced: POST %s failed: %s", path, err)
		return nil, false
	}
	v, jerr := json.parse(body, allocator = context.temp_allocator)
	if jerr != nil {
		return nil, false
	}
	return v, true
}

// Built into the temp allocator: a compound literal would return a slice into
// this frame's stack, which Odin rejects outright.
rest_headers :: proc(cfg: Config) -> []string {
	h := make([dynamic]string, context.temp_allocator)
	append(&h, fmt.tprintf("Authorization: Bearer %s", cfg.api_key))
	append(&h, fmt.tprintf("Anytype-Version: %s", REST_VERSION))
	append(&h, "Content-Type: application/json")
	return h[:]
}

// ------------------------------------------------------------- messages -----

jget :: proc(v: json.Value, key: string) -> (json.Value, bool) {
	obj, ok := v.(json.Object)
	if !ok {
		return nil, false
	}
	inner, found := obj[key]
	return inner, found
}

jint :: proc(v: json.Value, key: string) -> i64 {
	if inner, ok := jget(v, key); ok {
		#partial switch n in inner {
		case json.Integer: return i64(n)
		case json.Float:   return i64(n)
		}
	}
	return 0
}

jstr :: proc(v: json.Value, key: string) -> string {
	if inner, ok := jget(v, key); ok {
		if s, is := inner.(json.String); is {
			return string(s)
		}
	}
	return ""
}

// Newest first, matching what the session loop expects.
messages :: proc(cfg: Config, chat_id: string, limit: int, after: string,
                 allocator := context.allocator) -> []Message {
	path := fmt.tprintf("/chats/%s/messages?limit=%d", chat_id, limit)
	if len(after) > 0 {
		path = fmt.tprintf("%s&after_order_id=%s", path, url_escape(after))
	}
	v, ok := rest_get(cfg, path)
	if !ok {
		return nil
	}
	arr, has := jget(v, "messages")
	if !has {
		return nil
	}
	list, is_arr := arr.(json.Array)
	if !is_arr {
		return nil
	}

	out := make([dynamic]Message, allocator)
	for item in list {
		creator := jstr(item, "creator")
		text := ""
		if content, found := jget(item, "content"); found {
			text = jstr(content, "text")
		}
		append(&out, Message {
			id         = strings.clone(jstr(item, "order_id"), allocator),
			message_id = strings.clone(jstr(item, "id"), allocator),
			author     = strings.clone(jstr(item, "creator_name"), allocator),
			// Identity, not inference: the bot's key either is the creator or
			// is not. (The Python version had to fall back to remembering its
			// own POSTs, because bot and human shared one account.)
			is_bot     = len(cfg.bot_identity) > 0 &&
			             strings.contains(creator, cfg.bot_identity),
			text       = strings.clone(text, allocator),
			host       = strings.clone(chat_id, allocator),
			reply_to   = strings.clone(jstr(item, "reply_to_message_id"), allocator),
			created    = jint(item, "created_at"),
			attachments = attachment_targets(item, allocator),
		})
	}
	slice.reverse_sort_by(out[:], proc(a, b: Message) -> bool { return a.id < b.id })
	return out[:]
}

send_message :: proc(cfg: Config, chat_id, text: string, reply_to: string = "") -> bool {
	if len(strings.trim_space(text)) == 0 {
		return false
	}
	// Anytype chat does not render markdown; it carries formatting as ranges.
	// Sending raw markdown shows literal asterisks and backticks.
	plain, marks := markdown_to_marks(text, context.temp_allocator)

	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"text":`)
	json_write_string(&b, plain)
	strings.write_string(&b, `,"style":"paragraph"`)
	if len(marks) > 0 {
		strings.write_string(&b, `,"marks":`)
		write_marks_json(&b, marks)
	}
	// Only the first chunk of a split answer threads; otherwise a long reply
	// renders as a pile of separate quoted replies.
	if len(reply_to) > 0 {
		strings.write_string(&b, `,"reply_to_message_id":`)
		json_write_string(&b, reply_to)
	}
	strings.write_string(&b, "}")

	payload := transmute([]u8)strings.to_string(b)
	v, ok := rest_post(cfg, fmt.tprintf("/chats/%s/messages", chat_id), payload)
	if !ok {
		return false
	}
	return len(jstr(v, "message_id")) > 0
}

write_int :: proc(b: ^strings.Builder, n: int) {
	strings.write_string(b, fmt.tprintf("%d", n))
}

// Minimal JSON string escaping -- enough for chat text.
json_write_string :: proc(b: ^strings.Builder, s: string) {
	strings.write_byte(b, '"')
	for r in s {
		switch r {
		case '"':  strings.write_string(b, "\\\"")
		case '\\': strings.write_string(b, "\\\\")
		case '\n': strings.write_string(b, "\\n")
		case '\r': strings.write_string(b, "\\r")
		case '\t': strings.write_string(b, "\\t")
		case:
			if r < 0x20 {
				strings.write_string(b, fmt.tprintf("\\u%04x", int(r)))
			} else {
				strings.write_rune(b, r)
			}
		}
	}
	strings.write_byte(b, '"')
}

url_escape :: proc(s: string) -> string {
	b := strings.builder_make(context.temp_allocator)
	for i in 0 ..< len(s) {
		c := s[i]
		is_safe := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
		           (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~'
		if is_safe {
			strings.write_byte(&b, c)
		} else {
			strings.write_string(&b, fmt.tprintf("%%%02X", c))
		}
	}
	return strings.to_string(b)
}

// ------------------------------------------------------------- selftest -----

// Verifies the Odin transport against the live middleware, so it can be
// compared against what the Python one reports before anything depends on it.
cmd_chat :: proc(cfg: Config) -> int {
	fmt.printfln("space   : %s", cfg.space_id)
	fmt.printfln("api key : %s", len(cfg.api_key) > 0 ? "set" : "MISSING")
	fmt.printfln("identity: %s", len(cfg.bot_identity) > 0 ? cfg.bot_identity : "(unset)")

	chat := env_or("ANYTYPE_CHAT_ID", "")
	if len(chat) == 0 {
		fmt.eprintln("set ANYTYPE_CHAT_ID to a chat or discussion id")
		return 1
	}
	ms := messages(cfg, chat, 6, "", context.temp_allocator)
	fmt.printfln("\n%d message(s), newest first:", len(ms))
	for m in ms {
		who := m.is_bot ? "bot  " : "human"
		text := m.text
		if len(text) > 58 {
			text = text[:58]
		}
		fmt.printfln("  [%s] %s %q", m.id, who, text)
	}
	return 0
}

// ------------------------------------------------ blocks fallback (grpc) ----
//
// Some UI-written messages store their text in ChatMessage.blocks (field 17),
// which the REST DTO does not map -- they come back with text == "". Skipping
// them makes the bot silently deaf to real questions, so any blank message is
// re-read over grpc-web, where the blocks are visible.
//
// Measured: a discussion whose messages were all blank over REST read back
// completely over grpc. This is not a rare edge case; it is how the desktop
// app writes.

// ChatMessage.blocks(17) -> MessageBlock.text(1) -> MessageBlockText.text(1)
message_block_text :: proc(fields: []Pb_Field) -> string {
	parts := make([dynamic]string, context.temp_allocator)
	for blk in pb_get_all(fields, 17) {
		inner := pb_parse(blk, context.temp_allocator)
		tf, ok := pb_get(inner, 1)
		if !ok || tf.wire != 2 {
			continue
		}
		txt := pb_parse(tf.bytes, context.temp_allocator)
		if s := pb_get_string(txt, 1); len(s) > 0 {
			append(&parts, s)
		}
	}
	return strings.join(parts[:], "\n", context.temp_allocator)
}

// Fill in text for messages REST returned blank. Needs a Full-scope session,
// which only the phrase provides; without one the messages stay blank and the
// caller logs it rather than pretending they were empty.
fill_blank_text :: proc(cfg: Config, s: ^Surfaces, chat_id: string, ms: []Message,
                        allocator := context.allocator) -> int {
	blanks := 0
	for m in ms {
		if len(strings.trim_space(m.text)) == 0 {
			blanks += 1
		}
	}
	if blanks == 0 {
		return 0
	}
	if !surfaces_session(cfg, s) {
		fmt.eprintfln("graiced: %d message(s) unreadable over REST and no grpc session", blanks)
		return 0
	}
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, chat_id)
	pb_tag(&msg, 3, 0)
	pb_varint(&msg, 50)
	// Temp, not the heap: the payload is consumed in this proc, and the HTTP
	// accumulator inside http_request cannot be freed by the caller anyway
	// (the body it returns is a subslice of it, not the allocation base).
	res := rpc_call(cfg, "ChatGetMessages", msg[:], s.token, context.temp_allocator)
	if len(res.err) > 0 || len(rpc_error(res.payload)) > 0 {
		return 0
	}
	fields := pb_parse(res.payload, context.temp_allocator)
	filled := 0
	for raw in pb_get_all(fields, 2) {
		mf := pb_parse(raw, context.temp_allocator)
		id := pb_get_string(mf, 1)
		text := message_block_text(mf)
		if len(text) == 0 {
			continue
		}
		for &m in ms {
			if m.message_id == id && len(strings.trim_space(m.text)) == 0 {
				m.text = strings.clone(text, allocator)
				filled += 1
			}
		}
	}
	return filled
}

// ----------------------------------------------------------- attachments ---
//
// A chat attachment is an object id, not a file path: the bytes come from
// /v1/spaces/{space}/files/{id}. Anytype serves them with no filename header,
// so the extension is derived from Content-Type and the stem from the id.
//
// Images are injected inline with omp's @file syntax so the agent SEES them;
// everything else is handed over as a path for its read tool.

ext_for :: proc(ctype: string) -> string {
	switch ctype {
	case "image/png":     return ".png"
	case "image/jpeg":    return ".jpg"
	case "image/gif":     return ".gif"
	case "image/webp":    return ".webp"
	case "image/heic":    return ".heic"
	case "image/svg+xml": return ".svg"
	case "application/pdf":  return ".pdf"
	case "text/plain":       return ".txt"
	case "text/markdown":    return ".md"
	case "text/csv":         return ".csv"
	case "application/json": return ".json"
	case "application/zip":  return ".zip"
	}
	return ".bin"
}

Attachment :: struct {
	path:     string,
	is_image: bool,
	ok:       bool,
}

// Download one attachment into the bot's attachments/ directory. Cached: the
// same id is fetched once, since a discussion re-reads the same messages.
fetch_attachment :: proc(cfg: Config, target: string) -> Attachment {
	dir := fmt.tprintf("%s/attachments", cfg.bot_dir)
	os.make_directory_all(dir)

	body, ctype, err := http_request_full(cfg.listen_addr, "GET",
		fmt.tprintf("/v1/spaces/%s/files/%s", cfg.space_id, target),
		nil, rest_headers(cfg), context.temp_allocator)
	if len(err) > 0 || len(body) == 0 {
		fmt.eprintfln("graiced: attachment %s failed: %s", target[:min(len(target), 12)],
			len(err) > 0 ? err : "empty body")
		return Attachment{ok = false}
	}
	path := fmt.tprintf("%s/%s%s", dir, target, ext_for(ctype))
	if werr := os.write_entire_file(path, body); werr != nil {
		return Attachment{ok = false}
	}
	return Attachment{
		path     = strings.clone(path),
		is_image = strings.has_prefix(ctype, "image/"),
		ok       = true,
	}
}

// The attachment target ids on a REST message. The API documents {target,
// type}; older payloads have been seen with object_id/id, so all three are
// accepted rather than silently returning nothing.
attachment_targets :: proc(m: json.Value, allocator := context.temp_allocator) -> []string {
	out := make([dynamic]string, allocator)
	arr, has := jget(m, "attachments")
	if !has {
		return out[:]
	}
	list, is := arr.(json.Array)
	if !is {
		return out[:]
	}
	for a in list {
		id := jstr(a, "target")
		if len(id) == 0 { id = jstr(a, "object_id") }
		if len(id) == 0 { id = jstr(a, "id") }
		if len(id) > 0 {
			append(&out, strings.clone(id, allocator))
		}
	}
	return out[:]
}

// ------------------------------------------------------ working indicator ---
//
// Anytype has no typing or presence API -- nothing in that family exists in the
// middleware. A reaction is the closest native equivalent: it renders on the
// message itself, needs no extra chat noise, and toggles off cleanly.
//
// The emoji and the logic driving it live in working.odin; this is just the
// transport call.

// The endpoint toggles, so the same call adds and removes.
toggle_reaction :: proc(cfg: Config, chat_id, message_id, emoji: string) -> bool {
	if len(message_id) == 0 {
		return false
	}
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, `{"emoji":`)
	json_write_string(&b, emoji)
	strings.write_string(&b, "}")
	_, ok := rest_post(cfg,
		fmt.tprintf("/chats/%s/messages/%s/reactions", chat_id, message_id),
		transmute([]u8)strings.to_string(b))
	return ok
}
