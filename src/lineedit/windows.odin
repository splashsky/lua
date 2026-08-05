#+build windows
#+build !freestanding

package lineedit

import win "core:sys/windows"
import stream "lang:stream"

input_handle: win.HANDLE
output_handle: win.HANDLE
input_origin: win.COORD

platform_available :: proc() -> bool {
	imode, omode: win.DWORD
	input_handle = win.GetStdHandle(win.STD_INPUT_HANDLE)
	output_handle = win.GetStdHandle(win.STD_OUTPUT_HANDLE)
	return win.GetConsoleMode(input_handle, &imode) != win.FALSE &&
		win.GetConsoleMode(output_handle, &omode) != win.FALSE
}

platform_begin :: proc(prompt: string) -> bool {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if win.GetConsoleScreenBufferInfo(output_handle, &info) == win.FALSE {
		return false
	}
	input_origin = info.dwCursorPosition
	return true
}

platform_capacity :: proc() -> int {
	info: win.CONSOLE_SCREEN_BUFFER_INFO
	if win.GetConsoleScreenBufferInfo(output_handle, &info) == win.FALSE {
		return 1
	}
	width := int(info.srWindow.Right - info.srWindow.Left + 1)
	// Reserve the final physical column. Writing it can trigger an automatic wrap
	// whose cursor semantics differ between conhost versions.
	return max(width - int(input_origin.X) - 1, 1)
}

platform_redraw :: proc(bytes: []u8, shown_cells, cursor_cells, capacity: int) {
	_ = win.SetConsoleCursorPosition(output_handle, input_origin)
	_ = stream.write(stream.stdout(), bytes)
	if shown_cells < capacity {
		spaces: [MAX_LINE * 4]u8
		for i in 0 ..< capacity - shown_cells {
			spaces[i] = ' '
		}
		_ = stream.write(stream.stdout(), spaces[:capacity - shown_cells])
	}
	stream.flush(stream.stdout())
	at := input_origin
	at.X += win.SHORT(cursor_cells)
	_ = win.SetConsoleCursorPosition(output_handle, at)
}

platform_read :: proc() -> (Event, bool) {
	for {
		record: win.INPUT_RECORD
		n: win.DWORD
		if win.ReadConsoleInputW(input_handle, &record, 1, &n) == win.FALSE || n == 0 {
			return {}, false
		}
		if record.EventType != .KEY_EVENT || record.Event.KeyEvent.bKeyDown == win.FALSE {
			continue
		}
		k := record.Event.KeyEvent
		e := Event{repeat = int(k.wRepeatCount)}
		switch k.wVirtualKeyCode {
		case 0x0d: e.key = .Enter
		case 0x25: e.key = .Left
		case 0x27: e.key = .Right
		case 0x26: e.key = .Up
		case 0x28: e.key = .Down
		case 0x24: e.key = .Home
		case 0x23: e.key = .End
		case 0x2e: e.key = .Delete
		case 0x08: e.key = .Backspace
		case:
			w := u16(k.uChar.UnicodeChar)
			if w == 0 {
				continue
			}
			if w == 3 {
				return Event{key = .Interrupt, repeat = 1}, true
			}
			e.key = .Character
			cp := u32(w)
			if w >= 0xd800 && w <= 0xdbff {
				// A UTF-16 high surrogate is completed from the following key
				// event before UTF-8 encoding. Non-key records may occur between
				// halves (for example a resize), so keep reading until a usable
				// low surrogate arrives.
				for {
					next: win.INPUT_RECORD
					if win.ReadConsoleInputW(input_handle, &next, 1, &n) == win.FALSE || n == 0 {
						return {}, false
					}
					if next.EventType == .KEY_EVENT && next.Event.KeyEvent.bKeyDown != win.FALSE {
						low := u16(next.Event.KeyEvent.uChar.UnicodeChar)
						if low >= 0xdc00 && low <= 0xdfff {
							cp = 0x10000 + (u32(w - 0xd800) << 10) + u32(low - 0xdc00)
						}
						break
					}
				}
			}
			if cp <= 0x7f {
				e.bytes[0] = u8(cp); e.count = 1
			} else if cp <= 0x7ff {
				e.bytes[0] = 0xc0 | u8(cp >> 6)
				e.bytes[1] = 0x80 | u8(cp & 63); e.count = 2
			} else if cp <= 0xffff {
				e.bytes[0] = 0xe0 | u8(cp >> 12)
				e.bytes[1] = 0x80 | u8((cp >> 6) & 63)
				e.bytes[2] = 0x80 | u8(cp & 63); e.count = 3
			} else {
				e.bytes[0] = 0xf0 | u8(cp >> 18)
				e.bytes[1] = 0x80 | u8((cp >> 12) & 63)
				e.bytes[2] = 0x80 | u8((cp >> 6) & 63)
				e.bytes[3] = 0x80 | u8(cp & 63); e.count = 4
			}
		}
		return e, true
	}
}

platform_clear :: proc(prompt: string) {
	// Ctrl-L starts a fresh physical row. Avoiding a whole-screen fill keeps this
	// implementation compatible with older consoles without VT output enabled.
	_ = stream.write(stream.stdout(), []u8{'\r', '\n'})
	_ = stream.write(stream.stdout(), transmute([]u8)prompt)
	stream.flush(stream.stdout())
}

platform_bell :: proc() {
	_ = stream.write(stream.stdout(), []u8{7})
	stream.flush(stream.stdout())
}

platform_interrupt :: proc(prompt: string) {
	_ = stream.write(stream.stdout(), []u8{'^', 'C', '\r', '\n'})
	_ = stream.write(stream.stdout(), transmute([]u8)prompt)
	stream.flush(stream.stdout())
	_ = platform_begin(prompt)
}

platform_finish :: proc() {
	_ = stream.write(stream.stdout(), []u8{'\r', '\n'})
	stream.flush(stream.stdout())
}
