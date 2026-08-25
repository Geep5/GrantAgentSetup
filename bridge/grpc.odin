// grpc-web client for the Anytype middleware.
//
// The middleware speaks grpc-web (binary) over plain HTTP/1.1 on localhost:
// POST /anytype.ClientCommands/<Method>, body = one length-prefixed frame,
// response = data frame(s) followed by a trailer frame carrying grpc-status.
//
// Odin's core has TCP but no HTTP, so both are hand-rolled here. That is
// tolerable precisely because the surface is tiny: no TLS, no redirects, no
// keep-alive, no chunked request bodies. Responses MAY be chunked, so the
// reader handles that one case.
package main

import "core:fmt"
import "core:net"
import "core:strconv"
import "core:strings"
import "core:time"

// ---------------------------------------------------------------- protobuf --

// Wire types we need: 2 (length-delimited) and 0 (varint).
pb_varint :: proc(buf: ^[dynamic]u8, v: u64) {
	v := v
	for {
		b := u8(v & 0x7F)
		v >>= 7
		if v != 0 {
			append(buf, b | 0x80)
		} else {
			append(buf, b)
			return
		}
	}
}

pb_tag :: proc(buf: ^[dynamic]u8, field: u32, wire: u8) {
	pb_varint(buf, u64(field) << 3 | u64(wire))
}

pb_string :: proc(buf: ^[dynamic]u8, field: u32, s: string) {
	pb_tag(buf, field, 2)
	pb_varint(buf, u64(len(s)))
	append(buf, ..transmute([]u8)s)
}

pb_bool :: proc(buf: ^[dynamic]u8, field: u32, b: bool) {
	pb_tag(buf, field, 0)
	pb_varint(buf, b ? 1 : 0)
}

Pb_Field :: struct {
	field: u32,
	wire:  u8,
	bytes: []u8, // wire 2
	value: u64,  // wire 0
}

// Decodes one level. Nested messages are decoded by calling this again on the
// `bytes` of the field you want.
pb_parse :: proc(data: []u8, allocator := context.allocator) -> []Pb_Field {
	out := make([dynamic]Pb_Field, allocator)
	i := 0
	for i < len(data) {
		tag, n := pb_read_varint(data, i)
		if n == 0 {
			break
		}
		i = n
		field := u32(tag >> 3)
		wire := u8(tag & 7)
		switch wire {
		case 2:
			ln, n2 := pb_read_varint(data, i)
			if n2 == 0 || n2 + int(ln) > len(data) {
				return out[:]
			}
			append(&out, Pb_Field{field = field, wire = 2, bytes = data[n2:n2 + int(ln)]})
			i = n2 + int(ln)
		case 0:
			v, n2 := pb_read_varint(data, i)
			if n2 == 0 {
				return out[:]
			}
			append(&out, Pb_Field{field = field, wire = 0, value = v})
			i = n2
		case 5:
			i += 4
		case 1:
			i += 8
		case:
			return out[:]
		}
	}
	return out[:]
}

pb_read_varint :: proc(data: []u8, start: int) -> (value: u64, next: int) {
	v: u64
	shift: uint
	i := start
	for i < len(data) {
		b := data[i]
		i += 1
		v |= u64(b & 0x7F) << shift
		if b & 0x80 == 0 {
			return v, i
		}
		shift += 7
		if shift > 63 {
			return 0, 0
		}
	}
	return 0, 0
}

pb_get :: proc(fields: []Pb_Field, field: u32) -> (Pb_Field, bool) {
	for f in fields {
		if f.field == field {
			return f, true
		}
	}
	return {}, false
}

pb_get_string :: proc(fields: []Pb_Field, field: u32) -> string {
	if f, ok := pb_get(fields, field); ok && f.wire == 2 {
		return string(f.bytes)
	}
	return ""
}

// ------------------------------------------------------------------- HTTP --

Rpc_Result :: struct {
	ok:      bool,
	payload: []u8,   // first data frame
	status:  string, // grpc-status from the trailer, "" if absent
	err:     string, // transport-level problem
}

// Reads until the socket closes or the declared body is complete. The
// middleware answers a unary call and moves on, so this stays simple.
// General HTTP/1.1 request. Odin's core has TCP but no HTTP; this stays small
// because everything it talks to is on localhost: no TLS, no redirects, no
// keep-alive, no chunked request bodies. Chunked RESPONSES do occur.
http_request :: proc(addr, method, path: string, body: []u8, headers: []string,
                     allocator := context.allocator) -> (resp: []u8, err: string) {
	r, _, e := http_request_full(addr, method, path, body, headers, allocator)
	return r, e
}

// As http_request, but also reports Content-Type -- needed to give a
// downloaded attachment the right extension, since Anytype serves files with
// no filename header.
http_request_full :: proc(addr, method, path: string, body: []u8, headers: []string,
                          allocator := context.allocator) -> (resp: []u8, ctype: string, err: string) {
	sock, derr := net.dial_tcp_from_hostname_and_port_string(addr)
	if derr != nil {
		return nil, "", fmt.tprintf("dial %s failed: %v", addr, derr)
	}
	defer net.close(sock)

	head := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&head, "%s %s HTTP/1.1\r\n", method, path)
	fmt.sbprintf(&head, "Host: %s\r\n", addr)
	for h in headers {
		fmt.sbprintf(&head, "%s\r\n", h)
	}
	fmt.sbprintf(&head, "Content-Length: %d\r\n\r\n", len(body))

	if _, serr := net.send_tcp(sock, transmute([]u8)strings.to_string(head)); serr != nil {
		return nil, "", fmt.tprintf("send header failed: %v", serr)
	}
	if len(body) > 0 {
		if _, serr := net.send_tcp(sock, body); serr != nil {
			return nil, "", fmt.tprintf("send body failed: %v", serr)
		}
	}

	// Without a deadline a header-only reply (no Content-Length, no chunks)
	// parks us on recv forever — exactly what a refused AccountSelect does.
	_ = net.set_option(sock, .Receive_Timeout, 20 * time.Second)

	acc := make([dynamic]u8, allocator)
	chunk: [4096]u8
	for {
		n, rerr := net.recv_tcp(sock, chunk[:])
		if rerr != nil || n <= 0 {
			break
		}
		append(&acc, ..chunk[:n])
		// Stop once we have headers plus the declared body; otherwise we would
		// block until the peer closes, which it may not do promptly.
		if done, span, chunked := http_body_complete(acc[:]); done {
			return http_take_body(acc[:], span, chunked, allocator),
			       header_value(acc[:], "content-type:"), ""
		}
	}
	if done, span, chunked := http_body_complete(acc[:]); done {
		return http_take_body(acc[:], span, chunked, allocator),
		       header_value(acc[:], "content-type:"), ""
	}
	return nil, "", "incomplete HTTP response"
}

// The middleware answers unary calls with Transfer-Encoding: chunked, so the
// body must be de-chunked before it can be read as grpc-web frames -- chunk
// size lines sitting inside the payload otherwise parse as frame headers.
http_take_body :: proc(buf: []u8, span: Span, chunked: bool,
                       allocator := context.allocator) -> []u8 {
	if !chunked {
		return buf[span.start:span.end]
	}
	out := make([dynamic]u8, allocator)
	i := span.start
	for i < len(buf) {
		eol := index_of(buf[i:], "\r\n")
		if eol < 0 {
			break
		}
		size_str := strings.trim_space(string(buf[i:i + eol]))
		// Chunk extensions (";" suffix) are legal; ignore anything after it.
		if semi := strings.index(size_str, ";"); semi >= 0 {
			size_str = size_str[:semi]
		}
		size, ok := strconv.parse_int(size_str, 16)
		if !ok || size == 0 {
			break                        // 0-length chunk terminates the body
		}
		start := i + eol + 2
		if start + size > len(buf) {
			break
		}
		append(&out, ..buf[start:start + size])
		i = start + size + 2             // skip the CRLF after the chunk
	}
	return out[:]
}

Span :: struct {
	start, end: int,
}

// Returns the body span once the full response is present. Handles both
// Content-Length and chunked transfer encoding (the middleware uses both
// depending on the call).
http_body_complete :: proc(buf: []u8) -> (done: bool, span: Span, chunked: bool) {
	sep := index_of(buf, "\r\n\r\n")
	if sep < 0 {
		return false, {}, false
	}
	head := string(buf[:sep])
	body_start := sep + 4

	if strings.contains(head, "Transfer-Encoding: chunked") ||
	   strings.contains(head, "transfer-encoding: chunked") {
		// Complete once the terminating zero-length chunk has arrived.
		if index_of(buf[body_start:], "\r\n0\r\n\r\n") >= 0 {
			return true, Span{body_start, len(buf)}, true
		}
		return false, {}, true
	}

	cl := header_int(head, "Content-Length:")
	if cl < 0 {
		cl = header_int(head, "content-length:")
	}
	if cl < 0 {
		return false, {}, false
	}
	if len(buf) >= body_start + cl {
		return true, Span{body_start, body_start + cl}, false
	}
	return false, {}, false
}

header_int :: proc(head, name: string) -> int {
	idx := strings.index(head, name)
	if idx < 0 {
		return -1
	}
	rest := head[idx + len(name):]
	if e := strings.index(rest, "\r\n"); e >= 0 {
		rest = rest[:e]
	}
	v, ok := strconv.parse_int(strings.trim_space(rest))
	return ok ? v : -1
}

index_of :: proc(buf: []u8, needle: string) -> int {
	return strings.index(string(buf), needle)
}

// ---------------------------------------------------------------- grpc-web --

// One unary call. `msg` is the encoded request message.
rpc_call :: proc(cfg: Config, method: string, msg: []u8, token: string,
                 allocator := context.allocator) -> Rpc_Result {
	frame := make([dynamic]u8, allocator)
	append(&frame, 0) // uncompressed data frame
	n := u32(len(msg))
	append(&frame, u8(n >> 24), u8(n >> 16), u8(n >> 8), u8(n))
	append(&frame, ..msg)

	path := fmt.tprintf("/anytype.ClientCommands/%s", method)
	hdrs := make([dynamic]string, context.temp_allocator)
	append(&hdrs, "Content-Type: application/grpc-web+proto", "X-Grpc-Web: 1")
	if len(token) > 0 {
		append(&hdrs, fmt.tprintf("token: %s", token))
	}
	body, err := http_request(cfg.grpcweb_addr, "POST", path, frame[:], hdrs[:], allocator)
	if len(err) > 0 {
		return Rpc_Result{err = err}
	}

	res := Rpc_Result {
		ok = true,
	}
	i := 0
	for i + 5 <= len(body) {
		flag := body[i]
		ln := int(u32(body[i + 1]) << 24 | u32(body[i + 2]) << 16 |
		          u32(body[i + 3]) << 8 | u32(body[i + 4]))
		i += 5
		if i + ln > len(body) {
			break
		}
		if flag == 0 && res.payload == nil {
			res.payload = body[i:i + ln]
		} else if flag == 0x80 {
			res.status = grpc_status(string(body[i:i + ln]))
		}
		i += ln
	}
	if len(res.status) > 0 && res.status != "0" {
		res.ok = false
		res.err = fmt.tprintf("grpc-status %s", res.status)
		return res
	}
	// An empty body is NOT success. Several account RPCs answer 200 with no
	// frames at all when they refuse the call (e.g. no session token), and
	// rpc_error on an empty payload finds no Error field and reports "fine" --
	// which silently turned a refusal into "wallet recovered ✓".
	if res.payload == nil {
		res.ok = false
		res.err = "empty response (call refused — is a session token required?)"
	}
	return res
}

grpc_status :: proc(trailer: string) -> string {
	idx := strings.index(trailer, "grpc-status:")
	if idx < 0 {
		return ""
	}
	rest := trailer[idx + len("grpc-status:"):]
	if e := strings.index(rest, "\r\n"); e >= 0 {
		rest = rest[:e]
	}
	return strings.trim_space(rest)
}

// Anytype wraps a per-call Error{code=1, description=2} in field 1 of every
// response; code 0 means success, so only a non-zero code is a real error.
// Most responses put Error in field 1, but not all — AccountChangeJsonApiAddr
// uses field 2. Reading the wrong field silently reports success on failure.
rpc_error_at :: proc(payload: []u8, field: u32) -> string {
	fields := pb_parse(payload, context.temp_allocator)
	ef, ok := pb_get(fields, field)
	if !ok || ef.wire != 2 {
		return ""
	}
	inner := pb_parse(ef.bytes, context.temp_allocator)
	code: u64 = 0
	if cf, ok2 := pb_get(inner, 1); ok2 && cf.wire == 0 {
		code = cf.value
	}
	if code == 0 {
		return ""
	}
	return fmt.tprintf("code %d: %s", code, pb_get_string(inner, 2))
}

rpc_error :: proc(payload: []u8) -> string {
	fields := pb_parse(payload, context.temp_allocator)
	ef, ok := pb_get(fields, 1)
	if !ok || ef.wire != 2 {
		return ""
	}
	inner := pb_parse(ef.bytes, context.temp_allocator)
	code: u64 = 0
	if cf, ok2 := pb_get(inner, 1); ok2 && cf.wire == 0 {
		code = cf.value
	}
	desc := pb_get_string(inner, 2)
	if code == 0 && len(desc) == 0 {
		return ""
	}
	if code == 0 {
		return ""
	}
	return fmt.tprintf("code %d: %s", code, desc)
}

pb_get_all :: proc(fields: []Pb_Field, field: u32, allocator := context.temp_allocator) -> [][]u8 {
	out := make([dynamic][]u8, allocator)
	for f in fields {
		if f.field == field && f.wire == 2 {
			append(&out, f.bytes)
		}
	}
	return out[:]
}

// Case-insensitive header lookup over the raw response.
header_value :: proc(buf: []u8, name: string) -> string {
	sep := index_of(buf, "\r\n\r\n")
	if sep < 0 {
		return ""
	}
	head := strings.to_lower(string(buf[:sep]), context.temp_allocator)
	idx := strings.index(head, name)
	if idx < 0 {
		return ""
	}
	rest := head[idx + len(name):]
	if e := strings.index(rest, "\r\n"); e >= 0 {
		rest = rest[:e]
	}
	if semi := strings.index(rest, ";"); semi >= 0 {
		rest = rest[:semi]
	}
	return strings.trim_space(rest)
}
