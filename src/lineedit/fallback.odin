#+build !windows
#+build !linux
#+build !freestanding

package lineedit

// Darwin and BSD intentionally fall back until their native termios/ioctl ABIs
// are implemented and tested instead of borrowing Linux constants.
platform_available :: proc() -> bool { return false }
platform_begin :: proc(prompt: string) -> bool { return false }
platform_capacity :: proc() -> int { return 1 }
platform_redraw :: proc(bytes: []u8, shown_cells, cursor_cells, capacity: int) {}
platform_read :: proc() -> (Event, bool) { return {}, false }
platform_clear :: proc(prompt: string) {}
platform_bell :: proc() {}
platform_finish :: proc() {}
