#+build linux
#+build !freestanding

package host

import linux "core:sys/linux"

// Linux's ioctl termios ABI is not the Darwin/BSD ABI. Keep this definition in
// the Linux-only file: sharing it with another "POSIX" target would be memory
// corruption, not portability.
linux_termios :: struct {
	iflag, oflag, cflag, lflag: u32,
	line: u8,
	cc: [19]u8,
}

TCGETS :: u32(0x5401)
TCSETS :: u32(0x5402)
ICANON :: u32(0x00000002)
ECHO :: u32(0x00000008)
ISIG :: u32(0x00000001)
VMIN :: 6
VTIME :: 5

terminal_saved_mode: linux_termios
terminal_active: bool

enter_terminal :: proc() -> bool {
	if terminal_active {
		return true
	}
	mode: linux_termios
	if i64(linux.ioctl(0, TCGETS, uintptr(&mode))) < 0 {
		return false
	}
	terminal_saved_mode = mode
	terminal_active = true
	raw := mode
	raw.lflag &~= ICANON | ECHO | ISIG
	raw.cc[VMIN] = 1
	raw.cc[VTIME] = 0
	if i64(linux.ioctl(0, TCSETS, uintptr(&raw))) < 0 {
		restore_terminal()
		return false
	}
	return true
}

restore_terminal :: proc() {
	if !terminal_active {
		return
	}
	terminal_active = false
	_ = linux.ioctl(0, TCSETS, uintptr(&terminal_saved_mode))
}
