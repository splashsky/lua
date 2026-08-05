#+build windows
#+build !freestanding

package main

// tty_windows.odin -- Windows implementation of `lua_stdin_is_tty`.
//
// Reference `lua.c` decides whether to drop into the interactive REPL (versus
// treating a piped/redirected stdin as a script) by asking whether standard
// input is a terminal. On Windows the reference uses `_isatty(_fileno(stdin))`.
// We answer the same question without reaching into the C runtime by asking the
// console subsystem directly: `GetConsoleMode` succeeds only for a handle that
// refers to a real console input buffer, and fails (returns zero) when stdin has
// been redirected from a file or a pipe. That is exactly the distinction the
// reference draws, so the observable behaviour matches.

import win "core:sys/windows"

stdin_is_tty :: proc() -> bool {
	mode: win.DWORD
	handle := win.GetStdHandle(win.STD_INPUT_HANDLE)
	return win.GetConsoleMode(handle, &mode) != win.FALSE
}
