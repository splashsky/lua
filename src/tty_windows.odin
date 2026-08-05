#+build windows
#+build !freestanding

package main

// tty_windows.odin -- Windows implementation of `lua_stdin_is_tty`.
//
// Reference `lua.c` decides whether to drop into the interactive REPL (versus
// treating a piped/redirected stdin as a script) by asking whether standard
// input is a terminal. On Windows the reference uses `_isatty(_fileno(stdin))`.
// We answer without reaching into the C runtime by asking the console subsystem
// directly: `GetConsoleMode` succeeds only for a handle that refers to a real
// console input buffer, and fails when stdin has been redirected from a file or
// a pipe.
//
// Note this is deliberately *narrower* than `_isatty`, not identical to it.
// `_isatty` is true for any character device -- a console, but also `NUL`, a
// serial port, or a printer -- whereas `GetConsoleMode` is true only for an
// actual console. The two therefore disagree for an invocation like
// `lua < NUL`, where reference Lua would enter interactive mode and immediately
// see EOF, while we treat it as an empty script. Both do nothing observable, so
// this is a knowingly accepted deviation rather than an oversight; switching to
// `GetFileType(h) == FILE_TYPE_CHAR` would match `_isatty` exactly if that edge
// is ever deemed to matter.
//
// Do not "unify" this with the other terminal tests in the tree -- they answer
// genuinely different questions:
//   * this file        -- should the REPL start? (mirrors reference `lua.c`)
//   * lineedit         -- can the native editor take over raw mode? (needs a real
//                         console on *both* stdin and stdout, so `GetConsoleMode`
//                         is the correct test there)
//   * stream.odin      -- should stdout be line-buffered? (mirrors C stdio)

import win "core:sys/windows"

stdin_is_tty :: proc() -> bool {
	mode: win.DWORD
	handle := win.GetStdHandle(win.STD_INPUT_HANDLE)
	return win.GetConsoleMode(handle, &mode) != win.FALSE
}
