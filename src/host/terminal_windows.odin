#+build windows
#+build !freestanding

package host

import win "core:sys/windows"

// The saved console mode is process-global deliberately. Lua errors unwind with
// longjmp, which skips every Odin defer between the throw and the protected
// boundary. Keeping the small restoration record outside the editor means the
// outer driver and every hosted exit path can repair the console even after such
// a jump. `terminal_active` is set only after the original mode is known, so
// restore_terminal is also safe after partial initialisation.
terminal_handle: win.HANDLE
terminal_saved_mode: win.DWORD
terminal_active: bool

enter_terminal :: proc() -> bool {
	if terminal_active {
		return true
	}
	h := win.GetStdHandle(win.STD_INPUT_HANDLE)
	mode: win.DWORD
	if win.GetConsoleMode(h, &mode) == win.FALSE {
		return false
	}
	terminal_handle = h
	terminal_saved_mode = mode
	terminal_active = true

	// ENABLE_EXTENDED_FLAGS is required when changing Quick Edit. Quick Edit is
	// disabled while editing because a mouse selection can otherwise freeze
	// ReadConsoleInputW indefinitely.
	ENABLE_EXTENDED_FLAGS :: win.DWORD(0x0080)
	raw := (mode &~ (
		win.ENABLE_ECHO_INPUT |
		win.ENABLE_LINE_INPUT |
		win.ENABLE_PROCESSED_INPUT |
		win.ENABLE_QUICK_EDIT_MODE
	)) | win.ENABLE_WINDOW_INPUT | ENABLE_EXTENDED_FLAGS
	if win.SetConsoleMode(h, raw) == win.FALSE {
		restore_terminal()
		return false
	}
	return true
}

restore_terminal :: proc() {
	if !terminal_active {
		return
	}
	// Clear first: if restoring itself fails, repeated emergency calls must not
	// race or repeatedly mutate a handle whose lifetime is already ending.
	h := terminal_handle
	mode := terminal_saved_mode
	terminal_active = false
	_ = win.SetConsoleMode(h, mode)
}
