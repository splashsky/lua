#+build linux
#+build !freestanding

package lineedit

import "core:os"
import linux "core:sys/linux"
import stream "luao:stream"

linux_winsize :: struct {
	rows, cols, xpixel, ypixel: u16,
}

TIOCGWINSZ :: u32(0x5413)
origin_column: int

platform_available :: proc() -> bool {
	if !os.is_tty(os.stdin) || !os.is_tty(os.stdout) {
		return false
	}
	env: [512]u8
	return os.get_env(env[:], "TERM") != "dumb"
}

platform_begin :: proc(prompt: string) -> bool {
	// Save the exact cursor position after the prompt. Redraw returns here rather
	// than carriage-returning over the prompt.
	write_out([]u8{0x1b, '[', 's'})
	origin_column = len(prompt)
	return true
}

platform_capacity :: proc() -> int {
	ws: linux_winsize
	if i64(linux.ioctl(1, TIOCGWINSZ, uintptr(&ws))) < 0 || ws.cols < 2 {
		return 79
	}
	return int(ws.cols) - origin_column - 1
}

write_out :: proc(s: []u8) {
	_ = stream.write(stream.stdout(), s)
	stream.flush(stream.stdout())
}

platform_redraw :: proc(bytes: []u8, shown_cells, cursor_cells, capacity: int) {
	write_out([]u8{0x1b, '[', 'u'})
	write_out(bytes)
	if shown_cells < capacity {
		spaces: [MAX_LINE * 4]u8
		for i in 0 ..< capacity - shown_cells { spaces[i] = ' ' }
		write_out(spaces[:capacity - shown_cells])
	}
	write_out([]u8{0x1b, '[', 'u'})
	if cursor_cells > 0 {
		seq: [32]u8
		n := 0
		seq[n] = 0x1b; n += 1
		seq[n] = '['; n += 1
		digits: [10]u8
		dn, v := 0, cursor_cells
		for v > 0 { digits[dn] = u8(v % 10) + '0'; dn += 1; v /= 10 }
		for i := dn - 1; i >= 0; i -= 1 { seq[n] = digits[i]; n += 1 }
		seq[n] = 'C'; n += 1
		write_out(seq[:n])
	}
}

read_byte :: proc(timeout_ms: i32 = -1) -> (u8, bool) {
	if timeout_ms >= 0 {
		pfd := linux.Poll_Fd{fd = 0, events = {.IN}}
		n, err := linux.poll([]linux.Poll_Fd{pfd}, timeout_ms)
		if err != .NONE || n <= 0 {
			return 0, false
		}
	}
	b: [1]u8
	n, err := linux.read(0, b[:])
	return b[0], err == .NONE && n == 1
}

platform_read :: proc() -> (Event, bool) {
	b, ok := read_byte()
	if !ok {
		return {}, false
	}
	if b == '\r' || b == '\n' { return Event{key = .Enter, repeat = 1}, true }
	if b == 0x7f || b == 8 { return Event{key = .Backspace, repeat = 1}, true }
	if b != 0x1b {
		return Event{key = .Character, bytes = {b, 0, 0, 0}, count = 1, repeat = 1}, true
	}

	// Escape starts terminal key sequences, but it is also ordinary pasted data.
	// Wait only 35 ms for a suffix: a standalone Escape can never wedge the REPL,
	// and an unknown/pasted sequence is returned byte-by-byte safely.
	second, has_second := read_byte(35)
	if !has_second {
		return Event{key = .Character, bytes = {0x1b, 0, 0, 0}, count = 1, repeat = 1}, true
	}
	if second != '[' && second != 'O' {
		// Preserve the Escape byte. The following byte remains unavailable with a
		// raw syscall interface, so encode both as one insertion when space allows.
		return Event{key = .Character, bytes = {0x1b, second, 0, 0}, count = 2, repeat = 1}, true
	}
	third, has_third := read_byte(35)
	if !has_third {
		return Event{key = .Character, bytes = {0x1b, second, 0, 0}, count = 2, repeat = 1}, true
	}
	switch third {
	case 'A': return Event{key = .Up, repeat = 1}, true
	case 'B': return Event{key = .Down, repeat = 1}, true
	case 'C': return Event{key = .Right, repeat = 1}, true
	case 'D': return Event{key = .Left, repeat = 1}, true
	case 'H': return Event{key = .Home, repeat = 1}, true
	case 'F': return Event{key = .End, repeat = 1}, true
	case '1', '7':
		_, _ = read_byte(35)
		return Event{key = .Home, repeat = 1}, true
	case '4', '8':
		_, _ = read_byte(35)
		return Event{key = .End, repeat = 1}, true
	case '3':
		_, _ = read_byte(35)
		return Event{key = .Delete, repeat = 1}, true
	}
	return Event{key = .Character, bytes = {0x1b, second, third, 0}, count = 3, repeat = 1}, true
}

platform_clear :: proc(prompt: string) {
	write_out([]u8{0x1b, '[', '2', 'J', 0x1b, '[', 'H'})
	write_out(transmute([]u8)prompt)
}

platform_bell :: proc() { write_out([]u8{7}) }
platform_finish :: proc() { write_out([]u8{'\r', '\n'}) }
