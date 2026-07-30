#+build !freestanding

package lineedit

import host "luao:host"
import stream "luao:stream"

MAX_LINE :: 511
TAB_WIDTH :: 4

Key :: enum {
	None,
	Character,
	Enter,
	Left,
	Right,
	Up,
	Down,
	Home,
	End,
	Delete,
	Backspace,
	Eof,
	Redraw,
}

Event :: struct {
	key: Key,
	bytes: [4]u8,
	count: int,
	repeat: int,
}

utf8_next :: proc(s: []u8, at: int) -> int {
	if at >= len(s) {
		return len(s)
	}
	b := s[at]
	need := 1
	if b >= 0xc2 && b <= 0xdf {
		need = 2
	} else if b >= 0xe0 && b <= 0xef {
		need = 3
	} else if b >= 0xf0 && b <= 0xf4 {
		need = 4
	}
	if need == 1 || at + need > len(s) {
		return at + 1
	}
	for i in 1 ..< need {
		if s[at + i] < 0x80 || s[at + i] > 0xbf {
			return at + 1
		}
	}
	if need == 3 &&
	   ((b == 0xe0 && s[at + 1] < 0xa0) ||
	    (b == 0xed && s[at + 1] > 0x9f)) {
		return at + 1
	}
	if need == 4 &&
	   ((b == 0xf0 && s[at + 1] < 0x90) ||
	    (b == 0xf4 && s[at + 1] > 0x8f)) {
		return at + 1
	}
	return at + need
}

utf8_prev :: proc(s: []u8, at: int) -> int {
	if at <= 0 {
		return 0
	}
	p := at - 1
	for p > 0 && at - p < 4 && s[p] >= 0x80 && s[p] <= 0xbf {
		p -= 1
	}
	return utf8_next(s, p) == at ? p : at - 1
}

display_piece :: proc(src: []u8, at: int, out: []u8) -> (next, n, cells: int) {
	next = utf8_next(src, at)
	b := src[at]
	if b == '\t' {
		copy(out, []u8{' ', ' ', ' ', ' '})
		return next, 4, TAB_WIDTH
	}
	if b < 0x20 || b == 0x7f {
		out[0] = '^'
		out[1] = b == 0x7f ? '?' : b + '@'
		return next, 2, 2
	}
	if next == at + 1 && b >= 0x80 {
		hex := "0123456789ABCDEF"
		out[0] = '\\'
		out[1] = 'x'
		out[2] = hex[b >> 4]
		out[3] = hex[b & 15]
		return next, 4, 4
	}
	copy(out, src[at:next])
	// This deliberately treats every valid non-ASCII code point as one cell.
	// Without a wcwidth-style Unicode table, combining marks and East Asian wide
	// characters cannot be positioned generally correctly. ASCII editing is
	// exact; arbitrary bytes remain safe and editable rather than being executed.
	return next, next - at, 1
}

redraw :: proc(line: []u8, cursor: int, viewport: ^int) {
	capacity := platform_capacity()
	if capacity < 1 {
		capacity = 1
	}
	if viewport^ > cursor {
		viewport^ = cursor
	}

	for {
		cells := 0
		p := viewport^
		for p < cursor {
			part: [4]u8
			next, _, w := display_piece(line, p, part[:])
			cells += w
			p = next
		}
		if cells < capacity || viewport^ >= cursor {
			break
		}
		viewport^ = utf8_next(line, viewport^)
	}

	shown: [MAX_LINE * 4]u8
	out_n, shown_cells := 0, 0
	p := viewport^
	for p < len(line) {
		part: [4]u8
		next, n, cells := display_piece(line, p, part[:])
		if out_n + n > len(shown) || shown_cells + cells > capacity {
			break
		}
		copy(shown[out_n:out_n + n], part[:n])
		out_n += n
		shown_cells += cells
		p = next
	}
	cursor_cells := 0
	p = viewport^
	for p < cursor {
		part: [4]u8
		next, _, cells := display_piece(line, p, part[:])
		cursor_cells += cells
		p = next
	}
	platform_redraw(shown[:out_n], shown_cells, cursor_cells, capacity)
}

delete_range :: proc(line: []u8, length: ^int, first, last: int) {
	copy(line[first:], line[last:length^])
	length^ -= last - first
}

// read_line owns raw mode for the narrowest possible interval. Its caller has
// already obtained and printed the Lua prompt and supplied fixed storage, so no
// Lua API call or allocation happens while the terminal is raw. There are no
// early returns after enter_terminal: every outcome reaches the one explicit
// cleanup epilogue because longjmp makes defer unsuitable for terminal safety.
read_line :: proc(prompt: string, dst: []u8, history: []string) -> (n: int, eof, handled: bool) {
	if len(dst) < MAX_LINE || !platform_available() ||
	   !stream.prepare_direct_read(stream.stdin()) {
		return 0, false, false
	}
	if !platform_begin(prompt) || !host.enter_terminal() {
		host.restore_terminal()
		stream.finish_direct_read(stream.stdin())
		return 0, false, false
	}

	line: [MAX_LINE]u8
	draft: [MAX_LINE]u8
	length, cursor, viewport := 0, 0, 0
	draft_length := 0
	history_pos := len(history)
	done, got_eof, failed := false, false, false
	redraw(line[:length], cursor, &viewport)

	for !done && !failed {
		event, ok := platform_read()
		if !ok {
			failed = true
			break
		}
		repeat := max(event.repeat, 1)
		for _ in 0 ..< repeat {
			#partial switch event.key {
			case .Enter:
				done = true
			case .Eof:
				if length == 0 {
					got_eof = true
					done = true
				}
			case .Left:
				cursor = utf8_prev(line[:length], cursor)
			case .Right:
				cursor = utf8_next(line[:length], cursor)
			case .Home:
				cursor = 0
			case .End:
				cursor = length
			case .Backspace:
				if cursor > 0 {
					p := utf8_prev(line[:length], cursor)
					delete_range(line[:], &length, p, cursor)
					cursor = p
				}
			case .Delete:
				if cursor < length {
					delete_range(line[:], &length, cursor, utf8_next(line[:length], cursor))
				} else if length == 0 {
					got_eof = true
					done = true
				}
			case .Up:
				if history_pos > 0 {
					if history_pos == len(history) {
						copy(draft[:], line[:length])
						draft_length = length
					}
					history_pos -= 1
					length = min(len(history[history_pos]), MAX_LINE)
					copy(line[:length], transmute([]u8)history[history_pos][:length])
					cursor = length
					viewport = 0
				}
			case .Down:
				if history_pos < len(history) {
					history_pos += 1
					if history_pos == len(history) {
						length = draft_length
						copy(line[:length], draft[:length])
					} else {
						length = min(len(history[history_pos]), MAX_LINE)
						copy(line[:length], transmute([]u8)history[history_pos][:length])
					}
					cursor = length
					viewport = 0
				}
			case .Character:
				b := event.bytes[0]
				if event.count == 1 && b == 1 { // Ctrl-A
					cursor = 0
				} else if event.count == 1 && b == 5 { // Ctrl-E
					cursor = length
				} else if event.count == 1 && b == 11 { // Ctrl-K
					length = cursor
				} else if event.count == 1 && b == 21 { // Ctrl-U
					delete_range(line[:], &length, 0, cursor)
					cursor = 0
				} else if event.count == 1 && b == 23 { // Ctrl-W
					p := cursor
					for p > 0 && (line[p - 1] == ' ' || line[p - 1] == '\t') {
						p -= 1
					}
					for p > 0 && line[p - 1] != ' ' && line[p - 1] != '\t' {
						p = utf8_prev(line[:length], p)
					}
					delete_range(line[:], &length, p, cursor)
					cursor = p
				} else if event.count == 1 && b == 12 { // Ctrl-L
					platform_clear(prompt)
					platform_begin(prompt)
				} else if event.count == 1 && b == 4 { // Ctrl-D
					if length == 0 {
						got_eof = true
						done = true
					} else if cursor < length {
						delete_range(line[:], &length, cursor, utf8_next(line[:length], cursor))
					}
				} else if event.count == 1 && b == 26 { // Windows Ctrl-Z
					if length == 0 {
						got_eof = true
						done = true
					}
				} else if length + event.count <= MAX_LINE {
					copy(line[cursor + event.count:], line[cursor:length])
					copy(line[cursor:cursor + event.count], event.bytes[:event.count])
					cursor += event.count
					length += event.count
				} else {
					platform_bell()
				}
			case:
			}
			if done {
				break
			}
		}
		if !done {
			redraw(line[:length], cursor, &viewport)
		}
	}

	// One cleanup epilogue for Enter, EOF, read failure, and every editor command.
	host.restore_terminal()
	stream.finish_direct_read(stream.stdin())
	platform_finish()
	if failed {
		return 0, true, true
	}
	if !got_eof {
		copy(dst[:length], line[:length])
	}
	return length, got_eof, true
}
