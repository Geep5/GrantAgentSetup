// Finding every surface the bot should watch.
//
// Two kinds, discovered two different ways -- this asymmetry is not a design
// choice, it is what the API forces:
//
//   chats        ChatSubscribeToMessagePreviews returns every chat in the
//                space in one call, so new chats appear on their own.
//   discussions  Previews do NOT include them (verified: a discussion with 29
//                messages went unlisted while previews returned 3 chats). The
//                discussionId lives only in the object's detail record, which
//                only ObjectShow exposes -- REST has no property, no search
//                hit, nothing. So objects are listed over REST and probed.
//
// Probing is cheap because hits are cached permanently: a discussionId never
// changes. Steady state is one REST list plus a probe per genuinely new object.
package main

import "core:encoding/json"
import "core:fmt"
import "core:os"
import "core:strings"

Surfaces :: struct {
	chats:       [dynamic]Chat,
	// object_id -> discussion_id, persisted so objects are probed only once.
	discussions: map[string]string,
	token:       string,          // Full-scope grpc session, for ObjectShow
}

discussions_path :: proc(cfg: Config) -> string {
	return fmt.tprintf("%s/state/anytype_discussions.json", cfg.bot_dir)
}

discussions_load :: proc(cfg: Config, s: ^Surfaces) {
	s.discussions = make(map[string]string)
	data, err := os.read_entire_file(discussions_path(cfg), context.temp_allocator)
	if err != nil {
		return
	}
	v, jerr := json.parse(data, allocator = context.temp_allocator)
	if jerr != nil {
		return
	}
	obj, ok := v.(json.Object)
	if !ok {
		return
	}
	for k, val in obj {
		if str, is := val.(json.String); is {
			s.discussions[strings.clone(k)] = strings.clone(string(str))
		}
	}
}

discussions_save :: proc(cfg: Config, s: ^Surfaces) {
	b := strings.builder_make(context.temp_allocator)
	strings.write_string(&b, "{")
	first := true
	for k, v in s.discussions {
		if !first {
			strings.write_string(&b, ",")
		}
		first = false
		json_write_string(&b, k)
		strings.write_string(&b, ":")
		json_write_string(&b, v)
	}
	strings.write_string(&b, "}")
	os.make_directory_all(fmt.tprintf("%s/state", cfg.bot_dir))
	_ = os.write_entire_file(discussions_path(cfg), transmute([]u8)strings.to_string(b))
}

// A Full-scope session, needed only for ObjectShow. The REST app key is scope
// JsonAPI ("no direct grpc api calls allowed"), so the phrase is unavoidable
// here -- it comes from the Keychain, never from a file or the environment.
surfaces_session :: proc(cfg: Config, s: ^Surfaces) -> bool {
	if len(s.token) > 0 {
		return true
	}
	if !initial_set_parameters(cfg) {
		return false
	}
	phrase := keychain_phrase()
	if len(phrase) == 0 {
		return false
	}
	sess, ok := wallet_session(cfg, 1, phrase)
	if !ok {
		return false
	}
	s.token = sess.token
	return true
}

// Every chat in our space, via one preview call.
discover_chats :: proc(cfg: Config, s: ^Surfaces) {
	if !surfaces_session(cfg, s) {
		return
	}
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, "graiced-bot")
	// Temp: the payload is parsed here and never escapes (see fill_blank_text).
	res := rpc_call(cfg, "ChatSubscribeToMessagePreviews", msg[:], s.token, context.temp_allocator)
	if len(res.err) > 0 || len(rpc_error(res.payload)) > 0 {
		return
	}
	fields := pb_parse(res.payload, context.temp_allocator)
	for raw in pb_get_all(fields, 2) {          // ChatPreview
		p := pb_parse(raw, context.temp_allocator)
		space := pb_get_string(p, 1)
		chat := pb_get_string(p, 2)
		if len(chat) == 0 || (len(cfg.space_id) > 0 && space != cfg.space_id) {
			continue
		}
		append(&s.chats, Chat{id = strings.clone(chat), kind = "chat", host_id = strings.clone(chat)})
	}
}

// Objects in the space, excluding chat objects (they are chats already).
space_objects :: proc(cfg: Config) -> []string {
	v, ok := rest_get(cfg, "/objects?limit=200")
	if !ok {
		return nil
	}
	arr, has := jget(v, "data")
	if !has {
		return nil
	}
	list, is := arr.(json.Array)
	if !is {
		return nil
	}
	out := make([dynamic]string, context.temp_allocator)
	for o in list {
		id := jstr(o, "id")
		if len(id) == 0 {
			continue
		}
		if t, found := jget(o, "type"); found && jstr(t, "key") == "chat_derived" {
			continue
		}
		append(&out, strings.clone(id, context.temp_allocator))
	}
	return out[:]
}

// An object's discussionId, or "" -- the only route is ObjectShow's details.
object_discussion :: proc(cfg: Config, s: ^Surfaces, object_id: string) -> string {
	msg := make([dynamic]u8, context.temp_allocator)
	pb_string(&msg, 1, object_id)
	pb_string(&msg, 2, object_id)
	pb_string(&msg, 5, cfg.space_id)
	res := rpc_call(cfg, "ObjectShow", msg[:], s.token, context.temp_allocator)
	if len(res.err) > 0 {
		return ""
	}
	// The id sits near the "discussionId" key in the detail blob; scanning for
	// it beats decoding the entire nested Struct.
	blob := make([dynamic]u8, context.temp_allocator)
	for f in pb_parse(res.payload, context.temp_allocator) {
		if f.wire == 2 {
			append(&blob, ..f.bytes)
		}
	}
	text := string(blob[:])
	key := strings.index(text, "discussionId")
	if key < 0 {
		return ""
	}
	window := text[key:]
	if len(window) > 140 {
		window = window[:140]
	}
	idx := strings.index(window, "bafyrei")
	if idx < 0 {
		return ""
	}
	rest := window[idx:]
	end := 0
	for end < len(rest) {
		c := rest[end]
		is_id := (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9')
		if !is_id {
			break
		}
		end += 1
	}
	if end < 45 {
		return ""
	}
	return strings.clone(rest[:end])
}

discover_discussions :: proc(cfg: Config, s: ^Surfaces) {
	if !surfaces_session(cfg, s) {
		return
	}
	dirty := false
	probed := 0
	for oid in space_objects(cfg) {
		if did, cached := s.discussions[oid]; cached {
			// Cloned: `oid` comes out of space_objects, which allocates into
			// the temp arena — and s.chats outlives the poll iteration that
			// resets it. Aliasing it here would dangle every host_id.
			append(&s.chats, Chat{id = did, kind = "discussion", host_id = strings.clone(oid)})
			continue
		}
		did := object_discussion(cfg, s, oid)
		probed += 1
		if len(did) > 0 {
			s.discussions[strings.clone(oid)] = did
			append(&s.chats, Chat{id = did, kind = "discussion", host_id = strings.clone(oid)})
			dirty = true
		}
	}
	if dirty {
		discussions_save(cfg, s)
	}
	if probed > 0 {
		fmt.printfln("graiced: probed %d object(s); %d discussion(s) known", probed, len(s.discussions))
	}
}

// Everything the bot watches.
//
// Builds into a scratch list and only commits it if something was found: a
// transient middleware outage made discovery return nothing, which used to
// wipe the live list and leave the bot watching zero surfaces until the next
// cycle. Keeping the previous set is always better than going blind.
discover_all :: proc(cfg: Config, s: ^Surfaces) -> []Chat {
	previous := s.chats
	s.chats = make([dynamic]Chat)
	discover_chats(cfg, s)
	discover_discussions(cfg, s)
	if len(s.chats) == 0 && len(previous) > 0 {
		fmt.eprintfln("graiced: discovery found nothing (middleware down?) — keeping %d known surface(s)",
			len(previous))
		delete(s.chats)
		s.chats = previous
		return s.chats[:]
	}
	// `host_id` is uniquely owned by the discarded list; `id` aliases the
	// s.discussions value, so it must NOT be freed here.
	for c in previous do delete(c.host_id)
	delete(previous)
	fmt.printfln("graiced: %d surface(s)", len(s.chats))
	return s.chats[:]
}

// How much of an object body to inline. Long enough for a task (outline, Q&A,
// next action), short enough not to crowd out the conversation itself.
HOST_BODY_LIMIT :: 2000

Host :: struct {
	name: string,
	kind: string,
	body: string,   // markdown; empty for a chat, or for an empty object
	truncated: bool,
}

// Everything about the surface a message arrived on, in one fetch.
//
// The body is included because the agent otherwise has to remember to go and
// read it -- which depends on a skill being loaded and on it choosing to.
// Handing it over means "this" always refers to something concrete.
host_info :: proc(cfg: Config, c: Chat) -> Host {
	id := c.kind == "chat" ? c.id : c.host_id
	v, ok := rest_get(cfg, fmt.tprintf("/objects/%s?format=md", id))
	if !ok {
		return Host{name = "(unreadable)", kind = c.kind == "chat" ? "chat" : "object"}
	}
	o, has := jget(v, "object")
	if !has {
		return Host{name = "(unreadable)", kind = c.kind == "chat" ? "chat" : "object"}
	}
	h := Host{name = jstr(o, "name")}
	if len(h.name) == 0 {
		h.name = c.kind == "chat" ? "a chat" : "(untitled)"
	}
	if c.kind == "chat" {
		h.kind = "chat"           // a chat has no body to speak of
		return h
	}
	h.kind = "object"
	if t, found := jget(o, "type"); found {
		if k := jstr(t, "name"); len(k) > 0 {
			h.kind = k
		}
	}
	body := strings.trim_space(jstr(o, "markdown"))
	if len(body) > HOST_BODY_LIMIT {
		// Cut on a line boundary so the agent never sees half a sentence.
		cut := strings.last_index(body[:HOST_BODY_LIMIT], "\n")
		if cut < HOST_BODY_LIMIT / 2 {
			cut = HOST_BODY_LIMIT
		}
		body = body[:cut]
		h.truncated = true
	}
	h.body = body
	return h
}

// Name a surface so the agent knows what it is answering about. An object's
// Discussion means that object IS the subject; a chat has no single subject.
host_label :: proc(cfg: Config, c: Chat) -> (string, string) {
	if c.kind == "chat" {
		v, ok := rest_get(cfg, fmt.tprintf("/objects/%s", c.id))
		if ok {
			if o, has := jget(v, "object"); has {
				if n := jstr(o, "name"); len(n) > 0 {
					return n, "chat"
				}
			}
		}
		return "a chat", "chat"
	}
	v, ok := rest_get(cfg, fmt.tprintf("/objects/%s", c.host_id))
	if !ok {
		return "(unreadable)", "object"
	}
	o, has := jget(v, "object")
	if !has {
		return "(unreadable)", "object"
	}
	name := jstr(o, "name")
	if len(name) == 0 {
		name = "(untitled)"
	}
	kind_name := "object"
	if t, found := jget(o, "type"); found {
		if k := jstr(t, "name"); len(k) > 0 {
			kind_name = k
		}
	}
	return name, kind_name
}
