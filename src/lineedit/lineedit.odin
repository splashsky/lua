#+build !freestanding

package lineedit

import host "lang:host"
import kernel "lang:kernel"
import stream "lang:stream"

MAX_LINE :: 511
TAB_WIDTH :: 4
MAX_COMPLETIONS :: 256
MAX_COMPLETION_VISITS :: 4096
MAX_COMPLETION_PARTS :: 64

Completion :: struct {
	names: [MAX_COMPLETIONS]string,
	count: int,
	word_start: int,
	prefix: string,
}

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
	Interrupt,
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

is_ident_start :: proc(b: u8) -> bool {
	return b == '_' || b >= 'A' && b <= 'Z' || b >= 'a' && b <= 'z'
}

is_ident_continue :: proc(b: u8) -> bool {
	return is_ident_start(b) || b >= '0' && b <= '9'
}

is_identifier :: proc(s: string) -> bool {
	if len(s) == 0 || !is_ident_start(s[0]) {
		return false
	}
	for i in 1 ..< len(s) {
		if !is_ident_continue(s[i]) {
			return false
		}
	}
	return true
}

starts_with :: proc(s, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

string_less :: proc(a, b: string) -> bool {
	n := min(len(a), len(b))
	for i in 0 ..< n {
		if a[i] != b[i] {
			return a[i] < b[i]
		}
	}
	return len(a) < len(b)
}

sort_completion :: proc(c: ^Completion) {
	for i in 1 ..< c.count {
		value := c.names[i]
		j := i
		for j > 0 && string_less(value, c.names[j - 1]) {
			c.names[j] = c.names[j - 1]
			j -= 1
		}
		c.names[j] = value
	}
}

completion_common_prefix :: proc(c: ^Completion) -> int {
	if c.count == 0 {
		return 0
	}
	n := len(c.names[0])
	for i in 1 ..< c.count {
		n = min(n, len(c.names[i]))
		j := 0
		for j < n && c.names[0][j] == c.names[i][j] {
			j += 1
		}
		n = j
	}
	return n
}

parse_completion_word :: proc(line: []u8, cursor: int, parts: ^[MAX_COMPLETION_PARTS]string) -> (
	start, count: int,
	ok: bool,
) {
	start = cursor
	for start > 0 {
		b := line[start - 1]
		if !is_ident_continue(b) && b != '.' && b != ':' {
			break
		}
		start -= 1
	}
	if start == cursor {
		return start, 0, false
	}

	part_start := start
	for i in start ..< cursor {
		if line[i] != '.' && line[i] != ':' {
			continue
		}
		if count >= MAX_COMPLETION_PARTS - 1 || i == part_start {
			return start, 0, false
		}
		part := string(line[part_start:i])
		if !is_identifier(part) {
			return start, 0, false
		}
		parts[count] = part
		count += 1
		part_start = i + 1
	}
	if count >= MAX_COMPLETION_PARTS {
		return start, 0, false
	}
	last := string(line[part_start:cursor])
	if len(last) > 0 && !is_identifier(last) {
		return start, 0, false
	}
	parts[count] = last
	count += 1
	return start, count, true
}

// Find a named raw field and replace the table at `table_index` with its value.
// We intentionally scan with lua_next instead of pushing the typed name as a Lua
// string: interning that name could allocate and therefore raise. The key handed
// back by lua_next is carried unchanged into the next call, so it is always a
// valid iteration key and cannot hit luaH_next's "invalid key" error path.
raw_descend :: proc(L: ^kernel.State, table_index: int, name: string) -> bool {
	kernel.api_pushnil(L)
	visited := 0
	for kernel.api_next(L, table_index) {
		visited += 1
		if kernel.api_type(L, -2) == kernel.TSTRING {
			key, _ := kernel.api_tolstring(L, -2)
			if key == name {
				if kernel.api_type(L, -1) != kernel.TTABLE {
					kernel.api_pop(L, 2)
					return false
				}
				kernel.api_copy(L, -1, table_index)
				kernel.api_pop(L, 2)
				return true
			}
		}
		if visited == MAX_COMPLETION_VISITS {
			kernel.api_pop(L, 2)
			return false
		}
		kernel.api_pop(L, 1)
	}
	return false
}

// Generate candidates without invoking user code. The caller must reserve four
// stack slots with lua_checkstack *before* entering raw terminal mode.
//
// Every Lua operation below is non-allocating and throw-free under that
// precondition: lua_pushglobaltable is a raw registry-array read; type queries,
// copying, nil pushes, and pops only touch reserved stack slots; lua_tolstring is
// used only after proving the value already is a string; and lua_next performs
// raw table traversal without consulting __pairs or any other metamethod. We
// never use lua_gettable/lua_getfield, so __index is not merely discouraged -- it
// is unreachable. Each table walk examines at most 4096 entries, and output is
// capped at 256 candidates, bounding both time and redraw volume for deliberately
// enormous globals tables.
completion_candidates :: proc(L: ^kernel.State, line: []u8, cursor: int) -> (c: Completion) {
	if cursor < 0 || cursor > len(line) {
		return
	}
	parts: [MAX_COMPLETION_PARTS]string
	start, part_count, ok := parse_completion_word(line, cursor, &parts)
	if !ok {
		return
	}
	c.word_start = start
	c.prefix = parts[part_count - 1]

	base := kernel.api_gettop(L)
	kernel.api_pushglobaltable(L)
	table_index := kernel.api_absindex(L, -1)
	for i in 0 ..< part_count - 1 {
		if !raw_descend(L, table_index, parts[i]) {
			kernel.api_settop(L, base)
			return
		}
	}

	kernel.api_pushnil(L)
	visited := 0
	for kernel.api_next(L, table_index) {
		visited += 1
		if kernel.api_type(L, -2) == kernel.TSTRING {
			name, _ := kernel.api_tolstring(L, -2)
			if is_identifier(name) && starts_with(name, c.prefix) {
				c.names[c.count] = name
				c.count += 1
				if c.count == MAX_COMPLETIONS {
					kernel.api_pop(L, 2)
					break
				}
			}
		}
		if visited == MAX_COMPLETION_VISITS {
			kernel.api_pop(L, 2)
			break
		}
		kernel.api_pop(L, 1)
	}
	kernel.api_settop(L, base)
	sort_completion(&c)
	return
}

show_completions :: proc(prompt: string, c: ^Completion) {
	platform_finish()
	for i in 0 ..< c.count {
		if i > 0 {
			_ = stream.write(stream.stdout(), []u8{' '})
		}
		_ = stream.write(stream.stdout(), transmute([]u8)c.names[i])
	}
	_ = stream.write(stream.stdout(), []u8{'\r', '\n'})
	_ = stream.write(stream.stdout(), transmute([]u8)prompt)
	stream.flush(stream.stdout())
	_ = platform_begin(prompt)
}

complete_line :: proc(
	L: ^kernel.State,
	prompt: string,
	line: []u8,
	length, cursor, viewport: ^int,
) {
	c := completion_candidates(L, line[:length^], cursor^)
	if c.count == 0 {
		// In whitespace, after punctuation, or on a missing/raw-inaccessible
		// table, Tab is a quiet no-op. Inserting a literal tab into Lua source is
		// surprising here and would make an accidental completion harder to undo.
		return
	}
	common := completion_common_prefix(&c)
	if common > len(c.prefix) {
		add := common - len(c.prefix)
		if length^ + add > MAX_LINE {
			platform_bell()
			return
		}
		copy(line[cursor^ + add:], line[cursor^:length^])
		copy(line[cursor^:cursor^ + add], transmute([]u8)c.names[0][len(c.prefix):common])
		cursor^ += add
		length^ += add
		return
	}
	if c.count > 1 {
		show_completions(prompt, &c)
		viewport^ = 0
	}
}

// read_line owns raw mode for the narrowest possible interval. Prompt handling,
// storage preparation, and the one potentially allocating Lua operation
// (lua_checkstack) happen first. Completion then uses only the carefully bounded,
// raw, throw-free API subset documented above. There are no early returns after
// enter_terminal: every outcome reaches the one explicit cleanup epilogue because
// longjmp makes defer unsuitable for terminal safety. The outer interpreter's
// idempotent restore_terminal call remains the backstop if that invariant is ever
// accidentally broken.
read_line :: proc(
	L: ^kernel.State,
	prompt: string,
	dst: []u8,
	history: []string,
) -> (n: int, eof, handled: bool) {
	if len(dst) < MAX_LINE || !platform_available() ||
	   !stream.prepare_direct_read(stream.stdin()) {
		return 0, false, false
	}
	if !kernel.api_checkstack(L, 4) {
		stream.finish_direct_read(stream.stdin())
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
			case .Interrupt:
				// Readline-style Ctrl-C: discard the draft and stay in the
				// editor with a clean prompt. No Lua error is involved because
				// docall (and therefore the execution interrupt) is not armed.
				length, cursor, viewport = 0, 0, 0
				history_pos = len(history)
				platform_interrupt(prompt)
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
				} else if event.count == 1 && b == '\t' {
					complete_line(L, prompt, line[:], &length, &cursor, &viewport)
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
