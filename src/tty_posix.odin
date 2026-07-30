#+build !windows
#+build !freestanding

package main

// tty_posix.odin -- POSIX implementation of `lua_stdin_is_tty`.
//
// The mirror of `tty_windows.odin` for every non-Windows target. Reference Lua on
// POSIX systems uses `isatty(0)` -- file descriptor 0 is standard input -- to tell
// an interactive terminal apart from a redirected file or pipe. We call the very
// same libc function through Odin's POSIX bindings, so a build on Linux or macOS
// behaves identically to the reference interpreter: an interactive shell gets the
// REPL, a `lua < script.lua` invocation runs stdin as a file.

import posix "core:sys/posix"

lua_stdin_is_tty :: proc() -> bool {
	return bool(posix.isatty(posix.FD(0)))
}
