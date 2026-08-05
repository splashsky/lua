#+build !freestanding

package stdlib

// iolib.odin -- our analogue of reference Lua's `liolib.c`.
//
// The I/O library: the file-handle userdata type and its methods (read/write/
// lines/seek/flush/setvbuf/close), the default input/output handles, and the
// convenience free functions (io.open/io.read/io.write/io.lines/...). Just like
// reference Lua, we are a thin skin over the shared Odin buffered-stream layer.
// That layer supplies the stdio semantics Lua relies on (including Windows text
// translation) while talking only to core:os file handles.
//
// One deliberate, documented deviation from a full POSIX reference build:
//
//   * Text-mode positions are represented by raw byte offsets. Like the opaque
//     cookies returned by the Windows CRT, they are intended to be passed back to
//     seek rather than arithmetically interpreted. This covers every operation
//     Lua exposes while retaining full 64-bit core:os offsets.
//
// `io.popen` is implemented without libc on Windows and Linux. Other hosted
// targets retain reference Lua's ISO-C "'popen' not supported" fallback until
// their process and wait-status ABIs are implemented deliberately.

import "base:runtime"
import "core:os"
import kernel "lang:kernel"
import shellproc "lang:shellproc"
import stream "lang:stream"

// The registry keys under which the default input/output handles live, and the
// length of the shared "_IO_" prefix (used to name the file in error messages) --
// reference IO_PREFIX / IO_INPUT / IO_OUTPUT / IOPREF_LEN.
@(private = "file")
IO_PREFIX :: "_IO_"
@(private = "file")
IO_INPUT :: "_IO_input"
@(private = "file")
IO_OUTPUT :: "_IO_output"
@(private = "file")
IOPREF_LEN :: len(IO_PREFIX)

// The name of the file-handle metatable in the registry -- reference LUA_FILEHANDLE
// (defined as "FILE*" in lua.h). `luaL_newmetatable` also stashes this under the
// metatable's `__name`, which is what powers the default `__tostring`/type errors.
@(private = "file")
FILEHANDLE :: "FILE*"

// The payload behind a file-handle userdata -- reference `luaL_Stream`. `closef`
// is the function that knows how to close this particular stream (a regular file,
// a popen pipe, or a standard stream that must never be closed). A NULL `closef`
// is the canonical "this handle is closed" marker, which is why handles are always
// created closed first and only then wired up to a real file.
@(private = "file")
LStream :: struct {
	f:      ^stream.Stream,
	closef: kernel.C_Function,
	popen:  ^shellproc.Handle,
}

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
}

// --------------------------------------------------------------------------------
// Handle plumbing: fetch/validate the userdata, open/closed bookkeeping.
// --------------------------------------------------------------------------------

// A handle is "closed" exactly when it has no close function -- reference isclosed.
@(private = "file")
isclosed :: #force_inline proc "contextless" (p: ^LStream) -> bool {
	return p.closef == nil
}

// Fetch the LStream at stack slot 1, raising a type error if it isn't a file
// handle -- reference `tolstream`.
@(private = "file")
tolstream :: proc(L: ^kernel.State) -> ^LStream {
	return (^LStream)(aux_checkudata(L, 1, FILEHANDLE))
}

// Fetch the underlying FILE* at slot 1, raising if the handle is closed --
// reference `tofile`.
@(private = "file")
tofile :: proc(L: ^kernel.State) -> ^stream.Stream {
	p := tolstream(L)
	if isclosed(p) {
		aux_error(L, "attempt to use a closed file")
	}
	return p.f
}

// Create a fresh handle already marked closed and wearing the FILE* metatable.
// Building it closed first means a later allocation failure can never leave a
// half-open handle behind -- reference `newprefile`.
@(private = "file")
newprefile :: proc(L: ^kernel.State) -> ^LStream {
	p := (^LStream)(kernel.api_newuserdatauv(L, size_of(LStream), 0))
	p.f = nil
	p.closef = nil // mark as closed until a real file is installed
	p.popen = nil
	aux_setmetatable(L, FILEHANDLE)
	return p
}

// A prefile destined to hold a regular fopen'd file: closed via io_fclose --
// reference `newfile`.
@(private = "file")
newfile :: proc(L: ^kernel.State) -> ^LStream {
	p := newprefile(L)
	p.f = nil
	p.closef = io_fclose
	return p
}

// Invoke a handle's close function, first clearing the pointer so the handle is
// marked closed even if the close itself fails -- reference `aux_close`.
@(private = "file")
aux_close :: proc(L: ^kernel.State) -> i32 {
	p := tolstream(L)
	cf := p.closef
	p.closef = nil // mark stream as closed before calling
	return cf(rawptr(L))
}

// Close function for regular files -- reference `io_fclose`.
@(private = "file")
io_fclose :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := tolstream(L)
	stream.clear_error()
	ok := stream.close(p.f)
	return aux_fileresult(L, ok, "", false, stream.last_error())
}

// A popen stream must close its pipe endpoint before waiting. In write mode that
// close is what delivers EOF to the child's stdin; waiting first would deadlock
// with a child that is correctly waiting for more input.
@(private = "file")
io_pclose :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := tolstream(L)
	stream.clear_error()
	ok := stream.close(p.f)
	close_err := stream.last_error()
	result := shellproc.wait(p.popen)
	p.popen = nil
	if !ok {
		return aux_execresult(L, -1, close_err)
	}
	return aux_execresult(L, result.code, result.err, result.signaled)
}

// Close function for the standard streams: it refuses to close them and, because
// aux_close has already cleared the pointer, restores itself so the handle stays
// usable -- reference `io_noclose`.
@(private = "file")
io_noclose :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := tolstream(L)
	p.closef = io_noclose // keep the file open
	aux_pushfail(L)
	kernel.api_pushstring(L, "cannot close standard file")
	return 2
}

// --------------------------------------------------------------------------------
// io.type / __tostring / __gc / __close
// --------------------------------------------------------------------------------

// io.type(obj) -> "file", "closed file", or nil (when obj isn't a handle at all).
@(private = "file")
io_type :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_checkany(L, 1)
	p := (^LStream)(aux_testudata(L, 1, FILEHANDLE))
	if p == nil {
		aux_pushfail(L) // not a file handle at all
	} else if isclosed(p) {
		kernel.api_pushstring(L, "closed file")
	} else {
		kernel.api_pushstring(L, "file")
	}
	return 1
}

@(private = "file")
f_tostring :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := tolstream(L)
	if isclosed(p) {
		kernel.api_pushstring(L, "file (closed)")
	} else {
		kernel.api_pushfstring(L, "file (%p)", rawptr(p.f))
	}
	return 1
}

// __gc / __close: close the handle if it is still open and actually holds a file,
// silently ignoring the result (finalizers must not raise) -- reference `f_gc`.
@(private = "file")
f_gc :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := tolstream(L)
	if !isclosed(p) && p.f != nil {
		aux_close(L)
	}
	return 0
}

// --------------------------------------------------------------------------------
// close / open / tmpfile / popen
// --------------------------------------------------------------------------------

@(private = "file")
f_close :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tofile(L) // make sure the argument is an open stream
	return aux_close(L)
}

@(private = "file")
io_close :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if kernel.api_isnone(L, 1) { // no argument: close the default output
		kernel.api_getfield(L, kernel.REGISTRYINDEX, IO_OUTPUT)
	}
	return f_close(Lp)
}

// Check whether `mode` matches `[rwa]%+?b*` -- reference `l_checkmode`.
@(private = "file")
l_checkmode :: proc(mode: string) -> bool {
	m := transmute([]u8)mode
	i := 0
	if i >= len(m) || (m[i] != 'r' && m[i] != 'w' && m[i] != 'a') {
		return false
	}
	i += 1
	if i < len(m) && m[i] == '+' { // optional '+'
		i += 1
	}
	// Any remaining characters must all be the accepted extension 'b'.
	for ; i < len(m); i += 1 {
		if m[i] != 'b' {
			return false
		}
	}
	return true
}

@(private = "file")
io_open :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	filename := aux_checkstring(L, 1)
	mode := aux_optstring(L, 2, "r")
	p := newfile(L)
	aux_argcheck(L, l_checkmode(mode), 2, "invalid mode")
	stream.clear_error()
	p.f = stream.open(filename, mode)
	if p.f == nil {
		return aux_fileresult(L, false, filename, true, stream.last_error())
	}
	return 1
}

@(private = "file")
io_popen :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	when ODIN_OS != .Windows && ODIN_OS != .Linux {
		// Do not guess at Darwin/BSD process and wait-status ABIs. This is the
		// same explicit fallback used by reference Lua on unsupported hosts.
		aux_error(L, "'popen' not supported")
	}

	command := aux_checkstring(L, 1)
	mode := aux_optstring(L, 2, "r")
	p := newprefile(L)
	valid_mode := false
	when ODIN_OS == .Windows {
		// Match _popen exactly: r/w, optionally followed by b or t.
		valid_mode = (len(mode) == 1 && (mode[0] == 'r' || mode[0] == 'w')) ||
			(len(mode) == 2 &&
				(mode[0] == 'r' || mode[0] == 'w') &&
				(mode[1] == 'b' || mode[1] == 't'))
	} else {
		// POSIX popen accepts only the two one-character directions in Lua.
		valid_mode = len(mode) == 1 && (mode[0] == 'r' || mode[0] == 'w')
	}
	aux_argcheck(L, valid_mode, 2, "invalid mode")

	result := shellproc.open(command, mode)
	p.f = result.stream
	p.popen = result.handle
	p.closef = io_pclose
	if result.err != nil {
		return aux_fileresult(L, false, command, true, result.err)
	}
	return 1
}

@(private = "file")
io_tmpfile :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := newfile(L)
	stream.clear_error()
	p.f = stream.tmpfile()
	if p.f == nil {
		return aux_fileresult(L, false, "", false, stream.last_error())
	}
	return 1
}

// --------------------------------------------------------------------------------
// Default input/output: io.input / io.output and their registry-backed handles.
// --------------------------------------------------------------------------------

// Fetch the FILE* of the default handle stored under `findex`, raising if it has
// been closed -- reference `getiofile`. The handle is left on the stack (as the
// implicit "self" that g_read/g_write count), exactly as reference does.
@(private = "file")
getiofile :: proc(L: ^kernel.State, findex: string) -> ^stream.Stream {
	kernel.api_getfield(L, kernel.REGISTRYINDEX, findex)
	p := (^LStream)(kernel.api_touserdata(L, -1))
	if isclosed(p) {
		aux_error(L, "default %s file is closed", findex[IOPREF_LEN:])
	}
	return p.f
}

// Open (or set) the default file stored under registry key `f` -- reference
// `g_iofile`. With no usable argument it just returns the current handle.
@(private = "file")
g_iofile :: proc(L: ^kernel.State, f: string, mode: string) -> i32 {
	if !kernel.api_isnoneornil(L, 1) {
		filename, is_str := kernel.api_tostring(L, 1)
		if is_str {
			// Open the named file, raising a descriptive error on failure.
			p := newfile(L)
			p.f = stream.open(filename, mode)
			if p.f == nil {
				aux_error(
					L,
					"cannot open file '%s' (%s)",
					filename,
					os.error_string(stream.last_error()),
				)
			}
		} else {
			tofile(L) // check that argument 1 is a valid file handle
			kernel.api_pushvalue(L, 1)
		}
		kernel.api_setfield(L, kernel.REGISTRYINDEX, f)
	}
	// Return the current value.
	kernel.api_getfield(L, kernel.REGISTRYINDEX, f)
	return 1
}

@(private = "file")
io_input :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return g_iofile(L, IO_INPUT, "r")
}

@(private = "file")
io_output :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return g_iofile(L, IO_OUTPUT, "w")
}

// --------------------------------------------------------------------------------
// Lines iterators: io.lines / file:lines and the io_readline closure.
// --------------------------------------------------------------------------------

// Maximum number of format arguments to a lines iterator; it plus the three fixed
// upvalues must fit in the closure upvalue limit -- reference MAXARGLINE.
@(private = "file")
MAXARGLINE :: 250

// Build the closure that a generic-for will call. Upvalues, in order: the file,
// the number of formats, a boolean "close when done", then the formats themselves
// -- reference `aux_lines`.
@(private = "file")
aux_lines :: proc(L: ^kernel.State, toclose: bool) {
	n := kernel.api_gettop(L) - 1 // number of format arguments
	aux_argcheck(L, n <= MAXARGLINE, MAXARGLINE + 2, "too many arguments")
	kernel.api_pushvalue(L, 1) // the file
	kernel.api_pushinteger(L, kernel.Integer(n)) // number of formats
	kernel.api_pushboolean(L, toclose) // close/keep the file when finished
	kernel.api_rotate(L, 2, 3) // move the three fixed values ahead of the formats
	kernel.api_pushcclosure(L, io_readline, 3 + n)
}

@(private = "file")
f_lines :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	tofile(L) // check that it's a valid file handle
	aux_lines(L, false) // file:lines never closes its own file
	return 1
}

@(private = "file")
io_lines :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	toclose: bool
	if kernel.api_isnone(L, 1) {
		kernel.api_pushnil(L) // ensure there is at least one argument
	}
	if kernel.api_isnil(L, 1) { // no filename: iterate the default input
		kernel.api_getfield(L, kernel.REGISTRYINDEX, IO_INPUT)
		kernel.api_replace(L, 1) // move it to slot 1
		tofile(L) // check that it's a valid file handle
		toclose = false // do not close the shared default input
	} else { // open a named file just for this iteration
		filename := aux_checkstring(L, 1)
		p := newfile(L)
		p.f = stream.open(filename, "r")
		if p.f == nil {
			aux_error(
				L,
				"cannot open file '%s' (%s)",
				filename,
				os.error_string(stream.last_error()),
			)
		}
		kernel.api_replace(L, 1) // move the new file to slot 1
		toclose = true // close it once iteration finishes
	}
	aux_lines(L, toclose) // push the iterator function
	if toclose {
		kernel.api_pushnil(L) // state
		kernel.api_pushnil(L) // control
		kernel.api_pushvalue(L, 1) // the file is the to-be-closed 4th result
		return 4
	}
	return 1
}

// --------------------------------------------------------------------------------
// READ
// --------------------------------------------------------------------------------

// Maximum length of a numeral read by the 'n' format -- reference L_MAXLENNUM.
@(private = "file")
L_MAXLENNUM :: 200

// Auxiliary state for read_number -- reference `RN`.
@(private = "file")
RN :: struct {
	f:    ^stream.Stream, // file being read
	c:    i32, // current look-ahead character
	n:    int, // number of bytes buffered
	buff: [L_MAXLENNUM + 1]u8, // +1 for the terminating NUL
}

// Save the current char and read the next, failing on buffer overflow --
// reference `nextc`.
@(private = "file")
nextc :: proc(rn: ^RN) -> bool {
	if rn.n >= L_MAXLENNUM {
		rn.buff[0] = 0 // invalidate the result
		return false
	}
	rn.buff[rn.n] = u8(rn.c)
	rn.n += 1
	rn.c = stream.getc(rn.f)
	return true
}

// Accept the current char if it is one of two -- reference `test2`.
@(private = "file")
test2 :: proc(rn: ^RN, a: u8, b: u8) -> bool {
	if rn.c == i32(a) || rn.c == i32(b) {
		return nextc(rn)
	}
	return false
}

// Read a run of (hex)digits, returning how many were consumed -- reference
// `readdigits`.
@(private = "file")
readdigits :: proc(rn: ^RN, hex: bool) -> int {
	count := 0
	for {
		is_digit := hex ? kernel.is_xdigit(int(rn.c)) : kernel.is_digit(int(rn.c))
		if !is_digit || !nextc(rn) {
			break
		}
		count += 1
	}
	return count
}

// Read a valid numeral prefix into a buffer, then validate/convert it with
// lua_stringtonumber -- reference `read_number`. On success the conversion itself
// pushes the number; on failure we push a placeholder nil that g_read discards.
@(private = "file")
read_number :: proc(L: ^kernel.State, f: ^stream.Stream) -> bool {
	rn: RN
	count := 0
	hex := false
	rn.f = f
	rn.n = 0
	// C locale: the decimal separator is '.', which we always accept anyway.
	for {
		rn.c = stream.getc(f)
		if !kernel.is_space(int(rn.c)) {
			break
		}
	}
	test2(&rn, '-', '+') // optional sign
	if test2(&rn, '0', '0') {
		if test2(&rn, 'x', 'X') {
			hex = true
		} else {
			count = 1 // count the leading '0' as a digit
		}
	}
	count += readdigits(&rn, hex) // integral part
	if test2(&rn, '.', '.') { // decimal point
		count += readdigits(&rn, hex) // fractional part
	}
	if count > 0 && test2(&rn, hex ? 'p' : 'e', hex ? 'P' : 'E') { // exponent mark
		test2(&rn, '-', '+') // exponent sign
		readdigits(&rn, false) // exponent digits (always decimal)
	}
	stream.ungetc(rn.c, f) // unread the look-ahead char (a no-op for EOF)
	rn.buff[rn.n] = 0 // terminate the string
	if kernel.api_stringtonumber(L, string(cstring(&rn.buff[0]))) != 0 {
		return true // a valid number was pushed
	}
	kernel.api_pushnil(L) // provisional result to be removed by g_read
	return false
}

// Peek one byte to detect EOF without consuming input, always pushing "" --
// reference `test_eof`.
@(private = "file")
test_eof :: proc(L: ^kernel.State, f: ^stream.Stream) -> bool {
	c := stream.getc(f)
	stream.ungetc(c, f) // no-op when c == EOF
	kernel.api_pushstring(L, "")
	return c != stream.EOF
}

// Read one line, with `chop` controlling whether the trailing newline is kept --
// reference `read_line`. Always pushes a string; returns whether anything was read.
@(private = "file")
read_line :: proc(L: ^kernel.State, f: ^stream.Stream, chop: bool) -> bool {
	b: Buffer
	aux_buffinit(L, &b)
	found_newline := false
	for {
		buff := aux_prepbuffsize(&b, AUX_BUFFERSIZE)
		n, found := stream.read_until(f, buff[:AUX_BUFFERSIZE], '\n')
		added := n
		if found {
			found_newline = true
			if chop {
				added -= 1
			}
		}
		aux_addsize(&b, uint(added))
		if found || n < AUX_BUFFERSIZE {
			break
		}
	}
	aux_pushresult(&b)
	// Success if we read a newline or produced any bytes at all.
	return found_newline || kernel.api_rawlen(L, -1) > 0
}

// Read the entire remaining file in buffer-sized chunks -- reference `read_all`.
@(private = "file")
read_all :: proc(L: ^kernel.State, f: ^stream.Stream) {
	b: Buffer
	aux_buffinit(L, &b)
	for {
		p := aux_prepbuffsize(&b, AUX_BUFFERSIZE)
		nr := stream.read(f, p[:AUX_BUFFERSIZE])
		aux_addsize(&b, uint(nr))
		if nr != AUX_BUFFERSIZE {
			break
		}
	}
	aux_pushresult(&b)
}

// Read exactly `n` bytes (a single fread), pushing whatever was read -- reference
// `read_chars`. Success is "read at least one byte", so a partial read at EOF
// still succeeds.
@(private = "file")
read_chars :: proc(L: ^kernel.State, f: ^stream.Stream, n: uint) -> bool {
	b: Buffer
	aux_buffinit(L, &b)
	p := aux_prepbuffsize(&b, n)
	nr := stream.read(f, p[:n])
	aux_addsize(&b, uint(nr))
	aux_pushresult(&b)
	return nr > 0
}

// The shared implementation of io.read / file:read -- reference `g_read`. `first`
// is the stack index of the first format (2 for file:read's self, 1 for io.read's
// default handle).
@(private = "file")
g_read :: proc(L: ^kernel.State, f: ^stream.Stream, first: i32) -> i32 {
	nargs := kernel.api_gettop(L) - 1
	n: i32
	success: bool
	stream.clearerr(f)
	stream.clear_error()
	if nargs == 0 { // no formats: read one chopped line
		success = read_line(L, f, true)
		n = first + 1 // one result
	} else {
		// Reserve stack for every result plus auxlib's buffer.
		aux_checkstack(L, nargs + kernel.MINSTACK, "too many arguments")
		success = true
		n = first
		for nargs > 0 && success {
			nargs -= 1
			if kernel.api_type(L, int(n)) == kernel.TNUMBER {
				l := uint(aux_checkinteger(L, int(n)))
				success = l == 0 ? test_eof(L, f) : read_chars(L, f, l)
			} else {
				p := transmute([]u8)aux_checkstring(L, int(n))
				idx := 0
				if len(p) > 0 && p[0] == '*' { // skip optional '*' (compatibility)
					idx = 1
				}
				fc: u8 = idx < len(p) ? p[idx] : 0
				switch fc {
				case 'n':
					success = read_number(L, f)
				case 'l':
					success = read_line(L, f, true)
				case 'L':
					success = read_line(L, f, false)
				case 'a':
					read_all(L, f)
					success = true // reading the whole file always "succeeds"
				case:
					aux_argerror(L, int(n), "invalid format")
				}
			}
			n += 1
		}
	}
	if stream.ferror(f) {
		return aux_fileresult(L, false, "", false, stream.last_error())
	}
	if !success {
		kernel.api_pop(L, 1) // drop the failed provisional result
		aux_pushfail(L) // and report nil in its place
	}
	return n - first
}

@(private = "file")
io_read :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return g_read(L, getiofile(L, IO_INPUT), 1)
}

@(private = "file")
f_read :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return g_read(L, tofile(L), 2)
}

// The lines-iterator body: reads according to its captured formats, closing the
// file at EOF only if it opened the file itself -- reference `io_readline`.
@(private = "file")
io_readline :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	p := (^LStream)(kernel.api_touserdata(L, kernel.upvalueindex(1)))
	n := int(kernel.api_tointeger(L, kernel.upvalueindex(2)))
	if isclosed(p) {
		aux_error(L, "file is already closed")
	}
	kernel.api_settop(L, 1)
	aux_checkstack(L, n, "too many arguments")
	for i := 1; i <= n; i += 1 { // re-push the captured formats for g_read
		kernel.api_pushvalue(L, kernel.upvalueindex(3 + i))
	}
	nres := g_read(L, p.f, 2) // number of results g_read produced
	if kernel.api_toboolean(L, -int(nres)) { // read at least one value?
		return nres
	}
	// First result is falsy: EOF or error.
	if nres > 1 { // there is error information (2nd result)
		msg, _ := kernel.api_tostring(L, -int(nres) + 1)
		aux_error(L, "%s", msg)
	}
	if kernel.api_toboolean(L, kernel.upvalueindex(3)) { // did we open the file?
		kernel.api_settop(L, 0)
		kernel.api_pushvalue(L, kernel.upvalueindex(1)) // put the file at slot 1
		aux_close(L) // close it
	}
	return 0
}

// --------------------------------------------------------------------------------
// WRITE
// --------------------------------------------------------------------------------

// The shared implementation of io.write / file:write -- reference `g_write`.
// `luaL_checklstring` renders numbers through the kernel's canonical formatting
// (exactly what reference's lua_numbertocstring produces) and rejects non-string,
// non-number arguments with the standard "string expected" error.
@(private = "file")
g_write :: proc(L: ^kernel.State, f: ^stream.Stream, arg_start: i32) -> i32 {
	arg := int(arg_start)
	nargs := kernel.api_gettop(L) - arg
	totalbytes: uint = 0
	stream.clear_error()
	for nargs > 0 {
		nargs -= 1
		s := transmute([]u8)aux_checklstring(L, arg)
		l := uint(len(s))
		numbytes: uint = 0
		if l > 0 {
			numbytes = uint(stream.write(f, s))
		}
		totalbytes += numbytes
		if numbytes < l { // short write: report the error and bytes-so-far
			nr := aux_fileresult(L, false, "", false, stream.last_error())
			kernel.api_pushinteger(L, kernel.Integer(totalbytes))
			return nr + 1
		}
		arg += 1
	}
	return 1 // success: the file handle is already on top of the stack
}

@(private = "file")
io_write :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return g_write(L, getiofile(L, IO_OUTPUT), 1)
}

@(private = "file")
f_write :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	f := tofile(L)
	kernel.api_pushvalue(L, 1) // push the file to be returned on success
	return g_write(L, f, 2)
}

// --------------------------------------------------------------------------------
// seek / setvbuf / flush
// --------------------------------------------------------------------------------

@(private = "file")
seek_whence := [3]stream.Seek_From{.Start, .Current, .End}

@(private = "file")
seek_names := []string{"set", "cur", "end"}

@(private = "file")
f_seek :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	f := tofile(L)
	op := aux_checkoption(L, 2, "cur", seek_names)
	p3 := aux_optinteger(L, 3, 0)
	offset := i64(p3)
	stream.clear_error()
	pos, ok := stream.seek(f, offset, seek_whence[op])
	if !ok {
		return aux_fileresult(L, false, "", false, stream.last_error())
	}
	kernel.api_pushinteger(L, kernel.Integer(pos))
	return 1
}

@(private = "file")
setvbuf_mode := [3]stream.Buffer_Mode{.Unbuffered, .Full, .Line}

@(private = "file")
setvbuf_names := []string{"no", "full", "line"}

@(private = "file")
f_setvbuf :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	f := tofile(L)
	op := aux_checkoption(L, 2, "", setvbuf_names) // mode is required (no default)
	sz := aux_optinteger(L, 3, AUX_BUFFERSIZE)
	stream.clear_error()
	res := stream.setvbuf(f, setvbuf_mode[op], int(sz))
	return aux_fileresult(L, res, "", false, stream.last_error())
}

@(private = "file")
aux_flush :: proc(L: ^kernel.State, f: ^stream.Stream) -> i32 {
	stream.clear_error()
	res := stream.flush(f)
	return aux_fileresult(L, res, "", false, stream.last_error())
}

@(private = "file")
f_flush :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return aux_flush(L, tofile(L))
}

@(private = "file")
io_flush :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	return aux_flush(L, getiofile(L, IO_OUTPUT))
}

// --------------------------------------------------------------------------------
// Registration.
// --------------------------------------------------------------------------------

// Functions exported on the `io` table -- reference `iolib`.
@(private = "file")
iolib := []Reg {
	{"close", io_close},
	{"flush", io_flush},
	{"input", io_input},
	{"lines", io_lines},
	{"open", io_open},
	{"output", io_output},
	{"popen", io_popen},
	{"read", io_read},
	{"tmpfile", io_tmpfile},
	{"type", io_type},
	{"write", io_write},
}

// Methods on a file handle (metatable.__index) -- reference `meth`.
@(private = "file")
methlib := []Reg {
	{"read", f_read},
	{"write", f_write},
	{"lines", f_lines},
	{"flush", f_flush},
	{"seek", f_seek},
	{"close", f_close},
	{"setvbuf", f_setvbuf},
}

// Metamethods installed directly on the FILE* metatable. `__index` is a nil
// placeholder that createmeta overwrites with the method table -- reference
// `metameth`.
@(private = "file")
metameth := []Reg {
	{"__index", nil},
	{"__gc", f_gc},
	{"__close", f_gc},
	{"__tostring", f_tostring},
}

// Build the FILE* metatable and wire its __index to the method table -- reference
// `createmeta`.
@(private = "file")
createmeta :: proc(L: ^kernel.State) {
	aux_newmetatable(L, FILEHANDLE) // metatable for file handles
	aux_setfuncs(L, metameth, 0) // add metamethods (leaves __index = false)
	aux_newlib(L, methlib) // create the method table
	kernel.api_setfield(L, -2, "__index") // metatable.__index = method table
	kernel.api_pop(L, 1) // pop the metatable
}

// Create a standard stream, register it in the module (and, for stdin/stdout,
// under its registry default key) -- reference `createstdfile`.
@(private = "file")
createstdfile :: proc(L: ^kernel.State, f: ^stream.Stream, k: string, has_key: bool, fname: string) {
	p := newprefile(L)
	p.f = f
	p.closef = io_noclose // standard streams are never closed
	if has_key {
		kernel.api_pushvalue(L, -1)
		kernel.api_setfield(L, kernel.REGISTRYINDEX, k) // add to registry
	}
	kernel.api_setfield(L, -2, fname) // add to the module table
}

// `luaopen_io` -- build and return the io table.
open_io :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, iolib) // the io module
	createmeta(L)
	// Create and register the three standard streams.
	createstdfile(L, stream.stdin(), IO_INPUT, true, "stdin")
	createstdfile(L, stream.stdout(), IO_OUTPUT, true, "stdout")
	createstdfile(L, stream.stderr(), "", false, "stderr")
	return 1
}
