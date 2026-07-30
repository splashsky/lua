#+build windows
#+build !freestanding

package host

import "base:intrinsics"
import win "core:sys/windows"

// The saved console mode is process-global deliberately. Lua errors unwind with
// longjmp, which skips every Odin defer between the throw and the protected
// boundary. Keeping the small restoration record outside the editor means the
// outer driver and every hosted exit path can repair the console even after such
// a jump. `terminal_active` is set only after the original mode is known, so
// restore_terminal is also safe after partial initialisation.
terminal_handle: win.HANDLE
terminal_saved_mode: win.DWORD
terminal_active: i32

enter_terminal :: proc() -> bool {
	if intrinsics.atomic_load(&terminal_active) != 0 {
		return true
	}
	h := win.GetStdHandle(win.STD_INPUT_HANDLE)
	mode: win.DWORD
	if win.GetConsoleMode(h, &mode) == win.FALSE {
		return false
	}
	terminal_handle = h
	terminal_saved_mode = mode
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
		return false
	}
	// Publish only after the handle, saved mode, and raw-mode transition are
	// complete. A console-control thread can now safely acquire this record.
	intrinsics.atomic_store(&terminal_active, i32(1))
	return true
}

restore_terminal :: proc "contextless" () {
	if intrinsics.atomic_exchange(&terminal_active, i32(0)) == 0 {
		return
	}
	// Clear first: if restoring itself fails, repeated emergency calls must not
	// race or repeatedly mutate a handle whose lifetime is already ending.
	h := terminal_handle
	mode := terminal_saved_mode
	_ = win.SetConsoleMode(h, mode)
}

// A control callback cannot safely enter Odin's allocator, stream layer, or
// os.exit machinery. This is the emergency half of process_exit: restore the
// only hosted resource we can own at that point, then use KERNEL32 directly.
// The ordinary path remains process_exit (restore + flush + os.exit).
emergency_process_exit :: proc "contextless" (status: int) -> ! {
	restore_terminal()
	win.ExitProcess(win.UINT(status))
}
