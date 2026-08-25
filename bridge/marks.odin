// Markdown -> Anytype marks.
//
// Anytype chat renders bold/italic/code/links, but NOT markdown: it carries
// formatting as a list of {from, to, type} ranges alongside plain text. Sending
// "**bold**" literally shows the asterisks. So the syntax is stripped and
// converted to ranges.
//
// Two things that silently produce wrong output:
//
//   * Offsets are CODE POINTS, not bytes -- the proto calls them "a range of
//     symbols". Odin strings are UTF-8 bytes, so an em-dash or emoji before a
//     mark shifts every later range if you count bytes.
//   * Mark type names must be LOWERCASE. "Bold" does not error; it renders as
//     strikethrough, which looks like a formatting bug rather than a bad value.
package main

import "core:strings"
import "core:unicode/utf8"

TextMark :: struct {
	from:  int,    // inclusive, in code points
	to:    int,    // exclusive
	type:  string, // lowercase: bold | italic | strikethrough | keyboard | link
	param: string, // link target, empty otherwise
}

// A rune that would make a surrounding * or _ part of a word rather than a
// delimiter, so snake_case and 2*3*4 are left alone.
is_word_rune :: proc(r: rune) -> bool {
	return (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z') ||
	       (r >= '0' && r <= '9') || r == '_'
}

rune_at :: proc(s: string, byte_idx: int) -> rune {
	if byte_idx < 0 || byte_idx >= len(s) {
		return 0
	}
	r, _ := utf8.decode_rune_in_string(s[byte_idx:])
	return r
}

rune_before :: proc(s: string, byte_idx: int) -> rune {
	if byte_idx <= 0 {
		return 0
	}
	r, _ := utf8.decode_last_rune_in_string(s[:byte_idx])
	return r
}

// Find `close` starting at `from`, refusing to cross a newline: an unmatched
// delimiter should stay literal rather than swallowing the rest of the message.
find_close :: proc(s: string, from: int, close: string) -> int {
	i := from
	for i < len(s) {
		if s[i] == '\n' {
			return -1
		}
		if i + len(close) <= len(s) && s[i:i + len(close)] == close {
			return i
		}
		i += 1
	}
	return -1
}

markdown_to_marks :: proc(text: string, allocator := context.temp_allocator) ->
	(plain: string, marks: []TextMark) {

	b := strings.builder_make(allocator)
	out := make([dynamic]TextMark, allocator)
	idx := 0        // code-point offset into the plain output
	i := 0          // byte offset into the input

	emit :: proc(b: ^strings.Builder, idx: ^int, s: string) {
		strings.write_string(b, s)
		idx^ += utf8.rune_count_in_string(s)
	}

	for i < len(text) {
		matched := false

		// Fenced block: ```lang\n ... \n```
		// Must come first -- the inline scanner below refuses to cross a
		// newline (correct for `code`), so a fence would never match and the
		// backticks would render literally in the chat.
		if i + 3 <= len(text) && text[i:i + 3] == "```" {
			body := i + 3
			// Skip an optional language tag on the opening line.
			if nl := strings.index(text[body:], "\n"); nl >= 0 {
				lang := strings.trim_space(text[body:body + nl])
				if !strings.contains(lang, "`") {
					body = body + nl + 1
				}
			}
			if close_at := strings.index(text[body:], "```"); close_at >= 0 {
				inner := strings.trim_right(text[body:body + close_at], "\n")
				if len(inner) > 0 {
					from := idx
					emit(&b, &idx, inner)
					// Anytype has no fenced-block style for a chat message, so
					// the content is marked as code and the fences dropped.
					append(&out, TextMark{from = from, to = idx, type = "keyboard"})
					i = body + close_at + 3
					// Keep the newline that FOLLOWS the fence: it separates the
					// block from the next line. (Swallowing it ran the next
					// sentence onto the end of the code.) The newline before the
					// closing fence is already trimmed off `inner` above.
					continue
				}
			}
		}

		// Longest delimiters first, so ** is never read as two italics.
		type_for :: proc(open: string) -> string {
			switch open {
			case "**": return "bold"
			case "~~": return "strikethrough"
			case "`":  return "keyboard"
			}
			return ""
		}

		for open in ([]string{"**", "~~", "`"}) {
			if i + len(open) > len(text) || text[i:i + len(open)] != open {
				continue
			}
			start := i + len(open)
			end := find_close(text, start, open)
			if end < 0 || end == start {
				continue                     // unmatched: leave it literal
			}
			inner := text[start:end]
			from := idx
			emit(&b, &idx, inner)
			append(&out, TextMark{from = from, to = idx, type = type_for(open)})
			i = end + len(open)
			matched = true
			break
		}
		if matched {
			continue
		}

		// [text](url)
		if text[i] == '[' {
			close_br := find_close(text, i + 1, "]")
			if close_br > 0 && close_br + 1 < len(text) && text[close_br + 1] == '(' {
				close_paren := find_close(text, close_br + 2, ")")
				if close_paren > 0 {
					label := text[i + 1:close_br]
					url := text[close_br + 2:close_paren]
					from := idx
					emit(&b, &idx, label)
					append(&out, TextMark{from = from, to = idx, type = "link", param = url})
					i = close_paren + 1
					continue
				}
			}
		}

		// *italic* / _italic_ -- only when the delimiter is not inside a word.
		if text[i] == '*' || text[i] == '_' {
			d := text[i:i + 1]
			before := rune_before(text, i)
			opens := !is_word_rune(before) && before != rune(d[0])
			if opens {
				start := i + 1
				end := find_close(text, start, d)
				if end > start {
					after := rune_at(text, end + 1)
					if !is_word_rune(after) && after != rune(d[0]) {
						inner := text[start:end]
						from := idx
						emit(&b, &idx, inner)
						append(&out, TextMark{from = from, to = idx, type = "italic"})
						i = end + 1
						continue
					}
				}
			}
		}

		// Ordinary character: copy one whole rune, never a partial byte.
		_, size := utf8.decode_rune_in_string(text[i:])
		if size <= 0 {
			size = 1
		}
		emit(&b, &idx, text[i:i + size])
		i += size
	}

	return strings.to_string(b), out[:]
}

// Serialise marks for the REST payload.
write_marks_json :: proc(b: ^strings.Builder, marks: []TextMark) {
	strings.write_string(b, "[")
	for m, i in marks {
		if i > 0 {
			strings.write_string(b, ",")
		}
		strings.write_string(b, "{\"from\":")
		write_int(b, m.from)
		strings.write_string(b, ",\"to\":")
		write_int(b, m.to)
		strings.write_string(b, ",\"type\":")
		json_write_string(b, m.type)
		if len(m.param) > 0 {
			strings.write_string(b, ",\"param\":")
			json_write_string(b, m.param)
		}
		strings.write_string(b, "}")
	}
	strings.write_string(b, "]")
}
