#+build !freestanding

package main

// main.odin -- the standalone `lua` interpreter, our faithful analogue of the
// reference `lua.c`.
//
// This is the program most people mean when they say "lua": it parses the command
// line, runs scripts or `-e` chunks, pulls libraries in with `-l`, honours the
// LUA_INIT environment hooks, and -- when asked, or when stdin is an interactive
// terminal -- drops into a read-eval-print loop. Everything here is a direct port
// of the reference C driver, kept structurally identical (same helper procedures,
// same control flow, same stack choreography) so that its observable behaviour
// matches PUC-Rio Lua exactly.
//
// One documented structural deviation from the C original:
//
//   * The command-line vector is handed to `pmain` through a package-global
//     (`g_argv`) whose storage lives across the protecting `lua_pcall`, instead of
//     the reference's `argc` + `lightuserdata(argv)` pair. This is exactly as safe
//     for a single, non-reentrant interpreter launch; we still push `argc` and the
//     pointer so the protected-call shape mirrors the original.
//
// Interactive terminals use our libc-free native editor. Redirected input or
// output, TERM=dumb, and platforms without a verified terminal ABI retain the
// byte-for-byte plain-reader path.

import "core:fmt"
import "core:os"
import "core:strings"
import "base:runtime"

import host "luao:host"
import lineedit "luao:lineedit"
import lua "luao:lua"
import aux "luao:stdlib"
import stream "luao:stream"

// --------------------------------------------------------------------------------
// Small configuration constants that reference Lua keeps in luaconf.h.
// --------------------------------------------------------------------------------

// The name the interpreter calls itself in diagnostics before it has learned its
// real argv[0]. Reference LUA_PROGNAME.
PROGNAME :: "lua"

// The environment variables consulted at start-up. LUA_INIT_5_5 is tried first
// (version-suffixed, VERSUFFIX = "_5_5"), then the unversioned LUA_INIT. Reference
// LUA_INIT_VAR / LUA_INITVARVERSION.
INIT_VAR :: "INIT"
INIT_VAR_VERSION :: "INIT_5_5"

// REPL prompts and the input line cap. Reference LUA_PROMPT / LUA_PROMPT2 /
// LUA_MAXINPUT.
PROMPT :: "> "
PROMPT2 :: ">> "
MAXINPUT :: 512

// The suffix Lua appends to an error message for a statement that ends mid-way
// through (so the REPL knows to ask for another line). Reference EOFMARK.
EOFMARK :: "<eof>"

// --------------------------------------------------------------------------------
// Argument-mask bits, mirroring the reference `#define has_* ...` set exactly.
// --------------------------------------------------------------------------------

has_error :: 1 // bad option
has_i :: 2 // -i
has_v :: 4 // -v
has_e :: 8 // -e
has_E :: 16 // -E

// --------------------------------------------------------------------------------
// Package-global state, matching the reference file-static `progname` and the
// argv vector we thread into `pmain`.
// --------------------------------------------------------------------------------

// The program name printed in front of error messages. Reference keeps this in a
// file-static and blanks it out inside the REPL (so REPL errors carry no prefix);
// we use the empty string as that "no prefix" sentinel.
progname: string = PROGNAME

// The command line, captured in `main` and read back in `pmain`. Storage outlives
// the protecting `lua_pcall`, so handing `pmain` a pointer to it is safe.
g_argv: []string

// Reference readline history is in-memory and records one complete logical
// statement after continuation lines have been joined. Keep the same ownership
// here; individual editor invocations never add their physical line.
repl_history: [dynamic]string

// Static storage is important: an OS callback may still be finishing while
// docall disarms it. The callback never dereferences L; it only publishes to
// this mailbox, whose lifetime is the whole process.
interrupt_request: lua.Async_Hook_Request

// --------------------------------------------------------------------------------
// Tiny string helpers. Odin strings coming from `os.args` are NOT guaranteed to be
// NUL-terminated, so we never index past the end the way the C code leans on the
// implicit terminator; `byte_at` returns 0 for an out-of-range index, reproducing
// C's "read the '\0'" behaviour precisely.
// --------------------------------------------------------------------------------

byte_at :: proc(s: string, i: int) -> u8 {
	return i < len(s) ? s[i] : 0
}

// First index of byte `ch` in `s`, or -1. Stands in for C's `strchr`.
index_byte :: proc(s: string, ch: u8) -> int {
	for i in 0 ..< len(s) {
		if s[i] == ch {
			return i
		}
	}
	return -1
}

// --------------------------------------------------------------------------------
// Diagnostics. All of these route through `aux.write_stderr`, which is our
// `lua_writestringerror`: raw bytes to the C stderr stream, so ordering with the
// io library stays consistent.
// --------------------------------------------------------------------------------

// Print the usage summary, blaming `badoption`. Reference print_usage.
print_usage :: proc(badoption: string) {
	aux.write_stderr(fmt.tprintf("%s: ", progname))
	if byte_at(badoption, 1) == 'e' || byte_at(badoption, 1) == 'l' {
		aux.write_stderr(fmt.tprintf("'%s' needs argument\n", badoption))
	} else {
		aux.write_stderr(fmt.tprintf("unrecognized option '%s'\n", badoption))
	}
	aux.write_stderr(
		fmt.tprintf(
			"usage: %s [options] [script [args]]\n" +
			"Available options are:\n" +
			"  -e stat   execute string 'stat'\n" +
			"  -i        enter interactive mode after executing 'script'\n" +
			"  -l mod    require library 'mod' into global 'mod'\n" +
			"  -l g=mod  require library 'mod' into global 'g'\n" +
			"  -v        show version information\n" +
			"  -E        ignore environment variables\n" +
			"  -W        turn warnings on\n" +
			"  --        stop handling options\n" +
			"  -         stop handling options and execute stdin\n",
			progname,
		),
	)
}

// Print `msg` prefixed with `pname` (when non-empty). Reference l_message.
l_message :: proc(pname: string, msg: string) {
	if pname != "" {
		aux.write_stderr(fmt.tprintf("%s: ", pname))
	}
	aux.write_stderr(fmt.tprintf("%s\n", msg))
}

// If `status` is not OK, print the error message sitting on top of the stack and
// pop it. Returns `status` unchanged so callers can chain. Reference report.
report :: proc(L: ^lua.State, status: lua.Thread_Status) -> lua.Thread_Status {
	if status != .Ok {
		msg, ok := lua.api_tolstring(L, -1)
		if !ok {
			msg = "(error message not a string)"
		}
		l_message(progname, msg)
		lua.api_pop(L, 1)
	}
	return status
}

// The message handler installed under every chunk we run: it turns the raw error
// object into a human-readable string and appends a traceback. Reference
// msghandler. Note this runs as a Lua C function, so we must establish an Odin
// `context` before touching anything that allocates.
msghandler :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	// `lua_tolstring` also *converts* a numeric error object into a string in
	// place, so we try it first and only fall back to __tostring / a generic
	// description when the object is genuinely not string-convertible.
	msg, ok := lua.api_tolstring(L, 1)
	if !ok {
		if aux.aux_callmeta(L, 1, "__tostring") && lua.api_type(L, -1) == lua.TSTRING {
			return 1 // the metamethod result itself is the message
		}
		msg = lua.api_pushfstring(L, "(error object is a %s value)", aux.aux_typename(L, 1))
	}
	aux.aux_traceback(L, L, msg, true, 1) // append a standard traceback
	return 1
}

// The actual interrupt runs as an ordinary Lua hook on the interpreter thread.
// Reset first, exactly like reference lstop, so error handling cannot re-enter it.
lstop :: proc "c" (Lp, ar: rawptr) {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	lua.api_sethook(L, nil, 0, 0)
	aux.aux_error(L, "interrupted!")
}

// Call a function already sitting on the stack (with `narg` arguments above it),
// wrapping it with the message handler so errors arrive pre-tracebacked.
// Reference docall. platform_interrupt_arm is deliberately scoped to the pcall:
// Ctrl-C while ordinary driver/editor code is not mistaken for a running chunk.
docall :: proc(L: ^lua.State, narg: int, nres: int) -> lua.Thread_Status {
	base := lua.api_gettop(L) - narg // function index
	lua.api_pushcfunction(L, msghandler) // push message handler
	lua.api_insert(L, base) // put it under function and args
	flag := lua.MASKCALL | lua.MASKRET | lua.MASKLINE | lua.MASKCOUNT
	lua.api_prepare_async_hook(L, &interrupt_request, lstop, flag, 1)
	platform_interrupt_arm()
	status := lua.api_pcall(L, narg, nres, base)
	platform_interrupt_disarm()
	lua.api_disarm_async_hook(L, &interrupt_request)
	lua.api_remove(L, base) // remove message handler from the stack
	return status
}

// Print the copyright banner. Reference print_version.
print_version :: proc() {
	aux.write_string(lua.COPYRIGHT)
	aux.write_line()
}

// --------------------------------------------------------------------------------
// The `arg` table and script arguments.
// --------------------------------------------------------------------------------

// Build the global `arg` table so that `arg[0]` is the script name, arguments
// after it get positive indices, and options before it get negative indices.
// Reference createargtable.
createargtable :: proc(L: ^lua.State, argv: []string, argc: int, script: int) {
	narg := argc - (script + 1) // number of positive indices
	lua.api_createtable(L, narg, script + 1)
	for i in 0 ..< argc {
		lua.api_pushstring(L, argv[i])
		lua.api_rawseti(L, -2, lua.Integer(i - script))
	}
	lua.api_setglobal(L, "arg")
}

// Push the contents of `arg` from 1..#arg on the stack and return the count.
// Reference pushargs.
pushargs :: proc(L: ^lua.State) -> int {
	if lua.api_getglobal(L, "arg") != lua.TTABLE {
		aux.aux_error(L, "'arg' is not a table")
	}
	n := int(aux.aux_len(L, -1))
	aux.aux_checkstack(L, n + 3, "too many arguments to script")
	for i in 1 ..= n {
		lua.api_rawgeti(L, -i, lua.Integer(i))
	}
	lua.api_remove(L, -(n + 1)) // remove table from the stack
	return n
}

// --------------------------------------------------------------------------------
// Chunk loaders: load-then-call, reporting any error. Reference dochunk / dofile /
// dostring. An empty `name` means "read stdin as a file", exactly as passing NULL
// to the reference `luaL_loadfile` does.
// --------------------------------------------------------------------------------

dochunk :: proc(L: ^lua.State, status: lua.Thread_Status) -> lua.Thread_Status {
	status := status
	if status == .Ok {
		status = docall(L, 0, 0)
	}
	return report(L, status)
}

dofile :: proc(L: ^lua.State, name: string) -> lua.Thread_Status {
	return dochunk(L, aux.aux_loadfilex(L, name))
}

dostring :: proc(L: ^lua.State, s: string, name: string) -> lua.Thread_Status {
	return dochunk(L, aux.aux_loadbufferx(L, transmute([]u8)s, name))
}

// Run `globname[=modname]` as `globname = require(modname)`. With no explicit
// `=modname`, a '-' in the name marks a "version" suffix that is trimmed off the
// *global* name (the module name keeps it). Reference dolibrary (LUA_IGMARK = "-").
dolibrary :: proc(L: ^lua.State, arg: string) -> lua.Thread_Status {
	globname := arg
	modname := arg
	suffix := -1 // index of the '-' version mark in the global name, if any
	if eq := index_byte(arg, '='); eq >= 0 {
		globname = arg[:eq] // global name ends at '='
		modname = arg[eq + 1:] // module name starts after '='
	} else {
		suffix = index_byte(modname, '-') // look for a suffix mark
	}
	lua.api_getglobal(L, "require")
	lua.api_pushstring(L, modname)
	status := docall(L, 1, 1) // call 'require(modname)'
	if status == .Ok {
		if suffix >= 0 {
			globname = globname[:suffix] // drop the version suffix
		}
		lua.api_setglobal(L, globname) // globname = require(modname)
	}
	return report(L, status)
}

// --------------------------------------------------------------------------------
// Argument sweep and option execution.
// --------------------------------------------------------------------------------

// Walk `argv`, returning the option mask and the "first" index: -1 when there is
// no program name, 0 when there is no script, otherwise the script index (or the
// bad-argument index when the mask is has_error). Also records `progname` from
// argv[0]. Reference collectargs.
collectargs :: proc(argv: []string) -> (args: int, first: int) {
	if len(argv) == 0 { // no program name at all
		return 0, -1
	}
	if len(argv[0]) > 0 { // program name present and not empty?
		progname = argv[0] // save it
	}
	i := 1
	for i < len(argv) {
		first = i
		if byte_at(argv[i], 0) != '-' { // not an option?
			return args, first // stop handling options
		}
		switch byte_at(argv[i], 1) { // check the option letter
		case '-': // "--"
			if byte_at(argv[i], 2) != 0 { // extra characters after "--"?
				return has_error, i
			}
			// a script name, if any, comes after "--"
			first = (i + 1 < len(argv)) ? i + 1 : 0
			return args, first
		case 0: // "-"
			return args, first // script "name" is '-'
		case 'E':
			if byte_at(argv[i], 2) != 0 {
				return has_error, i
			}
			args |= has_E
		case 'W':
			if byte_at(argv[i], 2) != 0 {
				return has_error, i
			}
		case 'i':
			args |= has_i // (-i implies -v)
			fallthrough
		case 'v':
			if byte_at(argv[i], 2) != 0 {
				return has_error, i
			}
			args |= has_v
		case 'e':
			args |= has_e
			fallthrough
		case 'l': // both -e and -l need an argument
			if byte_at(argv[i], 2) == 0 { // no concatenated argument?
				i += 1 // try the next argv entry
				if i >= len(argv) || byte_at(argv[i], 0) == '-' {
					return has_error, i - 1 // missing argument
				}
			}
		case: // invalid option
			return has_error, i
		}
		i += 1
	}
	return args, 0 // no script name
}

// Execute the `-e`, `-l`, and `-W` options in command-line order, stopping at the
// first error. Reference runargs.
runargs :: proc(L: ^lua.State, argv: []string, n: int) -> bool {
	lua.api_warning(L, cstring("@off"), false) // stand-alone Lua starts with warnings off
	i := 1
	for i < n {
		option := byte_at(argv[i], 1)
		switch option {
		case 'e', 'l':
			extra: string
			if byte_at(argv[i], 2) == 0 { // argument is the next entry
				i += 1
				extra = argv[i]
			} else { // argument is glued on: -eCODE
				extra = argv[i][2:]
			}
			status := option == 'e' \
				? dostring(L, extra, "=(command line)") \
				: dolibrary(L, extra)
			if status != .Ok {
				return false // stop if error
			}
		case 'W':
			lua.api_warning(L, cstring("@on"), false) // warnings on
		}
		i += 1
	}
	return true
}

// Run the LUA_INIT / LUA_INIT_5_5 environment hook, if set. A leading '@' means
// "the rest is a filename"; otherwise the value is a chunk of Lua source.
// Reference handle_luainit.
handle_luainit :: proc(L: ^lua.State) -> lua.Thread_Status {
	name := INIT_VAR_VERSION
	init, ok := os.lookup_env(name, context.temp_allocator)
	if !ok {
		name = INIT_VAR
		init, ok = os.lookup_env(name, context.temp_allocator)
	}
	if !ok {
		return .Ok
	}
	if len(init) > 0 && init[0] == '@' {
		return dofile(L, init[1:])
	}
	return dostring(L, init, fmt.tprintf("=%s", name))
}

// Load and run the main script named on the command line. A bare "-" (unless it
// followed a literal "--") means stdin. Reference handle_script.
handle_script :: proc(L: ^lua.State, argv: []string, script: int) -> lua.Thread_Status {
	fname := argv[script]
	if fname == "-" && argv[script - 1] != "--" {
		fname = "" // stdin
	}
	status := aux.aux_loadfilex(L, fname)
	if status == .Ok {
		n := pushargs(L) // push arguments to script
		status = docall(L, n, lua.MULTRET)
	}
	return report(L, status)
}

// --------------------------------------------------------------------------------
// Read-Eval-Print Loop.
// --------------------------------------------------------------------------------

// Return the prompt string, leaving its Lua value anchored on the stack (the
// caller pops it). Honours the `_PROMPT` / `_PROMPT2` globals. Reference get_prompt.
get_prompt :: proc(L: ^lua.State, firstline: bool) -> string {
	name := firstline ? "_PROMPT" : "_PROMPT2"
	if lua.api_getglobal(L, name) == lua.TNIL {
		return firstline ? PROMPT : PROMPT2 // default
	}
	// apply tostring over the custom prompt value
	p := aux.aux_tolstring(L, -1)
	lua.api_remove(L, -2) // remove original value, keep the string
	return p
}

// Does `status` mean "syntax error because the statement isn't finished"? True
// when it's a syntax error whose message ends with the EOFMARK. Reference
// incomplete.
incomplete :: proc(L: ^lua.State, status: lua.Thread_Status) -> bool {
	if status == .Err_Syntax {
		msg, ok := lua.api_tolstring(L, -1)
		if ok && len(msg) >= len(EOFMARK) && msg[len(msg) - len(EOFMARK):] == EOFMARK {
			return true
		}
	}
	return false
}

// Show the prompt and read one physical line. All Lua interaction and storage
// preparation happens before native raw mode begins, and the editor restores the
// terminal before this procedure touches the Lua stack again.
pushline :: proc(L: ^lua.State, firstline: bool) -> bool {
	buffer: [MAXINPUT]u8
	prmt := get_prompt(L, firstline)
	aux.write_string(prmt)
	stream.flush(stream.stdout())

	n, editor_eof, edited := lineedit.read_line(L, prmt, buffer[:], repl_history[:])
	if edited {
		lua.api_pop(L, 1)
		if editor_eof {
			return false
		}
		lua.api_pushlstring(L, buffer[:n])
		return true
	}

	// Non-terminal stdin/stdout, TERM=dumb, and unsupported terminal platforms
	// deliberately use the old stream reader. This is the path exercised by
	// pipes and redirected CLI tests, so editing can never consume their bytes.
	n = 0
	for n < len(buffer) - 1 {
		c := stream.getc(stream.stdin())
		if c == stream.EOF {
			break
		}
		buffer[n] = u8(c)
		n += 1
		if c == '\n' {
			break
		}
	}
	lua.api_pop(L, 1) // remove prompt (get_prompt left it on the stack)
	if n == 0 {
		return false // no input
	}
	l := n
	if l > 0 && buffer[l - 1] == '\n' {
		l -= 1
	}
	lua.api_pushlstring(L, transmute([]u8)buffer[:l])
	return true
}

// Try to compile the line on top of the stack as `return <line>;` -- the trick
// that lets the REPL echo bare expressions. On success the compiled chunk
// replaces the line; on failure the stack is left holding the original line.
// Reference addreturn.
addreturn :: proc(L: ^lua.State) -> lua.Thread_Status {
	line, _ := lua.api_tolstring(L, -1) // original line
	retline := lua.api_pushfstring(L, "return %s;", line)
	status := aux.aux_loadbufferx(L, transmute([]u8)retline, "=stdin")
	if status == .Ok {
		lua.api_remove(L, -2) // remove modified line, keep the chunk
	} else {
		lua.api_pop(L, 2) // pop the failed load result and the modified line
	}
	return status
}

// Warn that `local` declarations don't persist between REPL lines. Reference
// checklocal (including its quirk of also warning on a bare "local" at end of
// line, because C's strchr matches the terminating NUL).
checklocal :: proc(line: string) {
	i := 0
	for i < len(line) && (line[i] == ' ' || line[i] == '\t') {
		i += 1
	}
	rest := line[i:]
	if len(rest) >= 5 && rest[:5] == "local" {
		if len(rest) == 5 || rest[5] == ' ' || rest[5] == '\t' {
			aux.write_stderr(
				"warning: locals do not survive across lines in interactive mode\n",
			)
		}
	}
}

// Keep reading and concatenating lines until we have a complete statement (or hit
// an error that isn't "incomplete"). The first line is already on the stack.
// Reference multiline.
multiline :: proc(L: ^lua.State) -> lua.Thread_Status {
	line, _ := lua.api_tolstring(L, 1) // get first line
	checklocal(line)
	for {
		status := aux.aux_loadbufferx(L, transmute([]u8)line, "=stdin") // try it
		if !incomplete(L, status) || !pushline(L, false) {
			return status // shouldn't or can't add a continuation line
		}
		lua.api_remove(L, -2) // remove the "incomplete" error message
		lua.api_pushstring(L, "\n") // add a newline...
		lua.api_insert(L, -2) // ...between the two lines
		lua.api_concat(L, 3) // join them
		line, _ = lua.api_tolstring(L, 1) // get what we have so far
	}
}

// Read one logical line of input and load it: first as an expression (`return
// ...`), then, failing that, as a statement possibly spanning continuation lines.
// Returns `eof = true` at end-of-input. Reference loadline (with a boolean eof in
// place of the C sentinel return of -1).
loadline :: proc(L: ^lua.State) -> (status: lua.Thread_Status, eof: bool) {
	lua.api_settop(L, 0)
	if !pushline(L, true) {
		return .Ok, true // no input
	}
	status = addreturn(L)
	if status != .Ok { // "return ..." didn't compile?
		status = multiline(L) // try as a statement, maybe multi-line
	}
	line, _ := lua.api_tolstring(L, 1)
	if len(line) > 0 {
		// Bounded session history prevents an indefinitely long REPL from growing
		// without limit. Allocation happens after raw mode has ended; if the Odin
		// allocator cannot clone the statement, its normal fatal allocation path
		// is allowed to run with the terminal already restored.
		if len(repl_history) == 100 {
			delete(repl_history[0])
			copy(repl_history[:99], repl_history[1:])
			resize(&repl_history, 99)
		}
		append(&repl_history, strings.clone(line))
	}
	lua.api_remove(L, 1) // remove the line, leaving the chunk (if any)
	return status, false
}

// Print, via the global `print`, whatever values a REPL chunk left on the stack.
// Reference l_print.
l_print :: proc(L: ^lua.State) {
	n := lua.api_gettop(L)
	if n > 0 { // any result to print?
		aux.aux_checkstack(L, lua.MINSTACK, "too many results to print")
		lua.api_getglobal(L, "print")
		lua.api_insert(L, 1)
		if lua.api_pcall(L, n, 0, 0) != .Ok {
			msg, _ := lua.api_tolstring(L, -1)
			l_message(progname, lua.api_pushfstring(L, "error calling 'print' (%s)", msg))
		}
	}
}

// The loop itself: read a line, evaluate it, print results, repeat. Errors are
// reported but don't end the session. Reference doREPL.
doREPL :: proc(L: ^lua.State) {
	oldprogname := progname
	progname = "" // no 'progname' prefix on errors in interactive mode
	for {
		status, eof := loadline(L)
		if eof {
			break
		}
		if status == .Ok {
			status = docall(L, 0, lua.MULTRET)
		}
		if status == .Ok {
			l_print(L)
		} else {
			report(L, status)
		}
	}
	lua.api_settop(L, 0) // clear the stack
	aux.write_line()
	progname = oldprogname
}

// --------------------------------------------------------------------------------
// pmain -- the whole driver, run inside a protected call so any start-up error is
// caught and reported rather than crashing. Reference pmain.
// --------------------------------------------------------------------------------

pmain :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	argc := int(lua.api_tointeger(L, 1))
	argv := (^[]string)(lua.api_touserdata(L, 2))^
	args, script := collectargs(argv)
	// index of the first argument that is not an option (or argc when there is none)
	optlim := script > 0 ? script : argc
	aux.aux_checkversion(L) // check the core is the version we expect
	if args == has_error { // bad argument?
		print_usage(argv[script]) // 'script' holds the bad-arg index
		return 0
	}
	if (args & has_v) != 0 { // -v?
		print_version()
	}
	if (args & has_E) != 0 { // -E? tell the libraries to ignore env vars
		lua.api_pushboolean(L, true)
		lua.api_setfield(L, lua.REGISTRYINDEX, "NOENV")
	}
	aux.aux_openlibs(L) // open the standard libraries
	createargtable(L, argv, argc, script) // build the 'arg' table
	lua.api_gc(L, lua.GCRESTART) // start the collector...
	lua.api_gc(L, lua.GCGEN) // ...in generational mode
	if (args & has_E) == 0 { // no -E? run LUA_INIT
		if handle_luainit(L) != .Ok {
			return 0 // error running LUA_INIT
		}
	}
	if !runargs(L, argv, optlim) { // execute -e / -l / -W
		return 0 // something failed
	}
	if script > 0 { // run the main script, if any
		if handle_script(L, argv, script) != .Ok {
			return 0 // stop on error
		}
	}
	if (args & has_i) != 0 { // -i? enter the REPL
		doREPL(L)
	} else if script < 1 && (args & (has_e | has_v)) == 0 { // nothing else to do?
		if stdin_is_tty() { // interactive terminal?
			print_version()
			doREPL(L)
		} else {
			dofile(L, "") // execute stdin as a file (status deliberately ignored)
		}
	}
	lua.api_pushboolean(L, true) // signal "no errors"
	return 1
}

// --------------------------------------------------------------------------------
// The process entry point: create a state, call `pmain` under protection, report,
// and translate success/failure into an exit code. Reference main.
// --------------------------------------------------------------------------------

main :: proc() {
	g_argv = os.args // capture the command line; storage outlives the pcall below
	platform_interrupt_init()

	L := lua.new_state(lua.default_allocator()) // create the interpreter state
	if L == nil {
		l_message(len(g_argv) > 0 ? g_argv[0] : PROGNAME, "cannot create state: not enough memory")
		host.process_exit(1)
	}
	lua.api_gc(L, lua.GCSTOP) // stop the GC while we build the state
	lua.api_pushcfunction(L, pmain) // the function to protect-call
	lua.api_pushinteger(L, lua.Integer(len(g_argv))) // 1st arg: argc
	lua.api_pushlightuserdata(L, &g_argv) // 2nd arg: pointer to argv
	status := lua.api_pcall(L, 2, 1, 0) // run pmain in protected mode
	// A Lua error can longjmp over the editor's ordinary stack frames and every
	// defer in them. Repair raw mode immediately at the outermost protected
	// boundary, before even inspecting or reporting the error.
	host.restore_terminal()
	result := lua.api_toboolean(L, -1) // pmain's boolean result
	report(L, status)
	lua.close_state(L)
	// Reference Lua exits by returning from `main`, so the C runtime flushes every
	// buffered stream on the way out. os.exit skips language-runtime cleanup on
	// some platforms, so explicitly flush every Odin stream first.
	host.process_exit((result && status == .Ok) ? 0 : 1)
}
