#+build !freestanding

package stdlib

// auxlib_hosted.odin -- the parts of the auxiliary library that need an OS.
//
// Everything here is still a faithful port of `lauxlib.c`; it lives in its own
// file purely because bare metal has no filesystem, clock, stderr, or default
// heap. The target-independent bulk of the auxiliary library -- argument
// checking, the Buffer, the reference system, tracebacks -- stays in
// `auxlib.odin`, which carries no build tag and is compiled for every target.
//
// The freestanding counterpart is `auxlib_freestanding.odin`, which supplies only
// the one routine (`aux_makeseed`) that has a genuinely different implementation
// rather than simply being absent.

import "base:runtime"
import "core:io"
import "core:os"
import "core:time"
import kernel "lang:kernel"
import stream "lang:stream"

// Odin's arena_temp_end leaves allocations intact if the arena had no block at
// begin (possible on a new thread). There were no older allocations to preserve,
// so reset it explicitly. Retain the normal first block for reuse, but don't pin
// an exceptionally large first allocation for the lifetime of the thread.
aux_host_temp_end :: proc(temp: runtime.Arena_Temp) {
	runtime.default_temp_allocator_temp_end(temp)
	if temp.arena != nil && temp.block == nil {
		runtime.arena_free_all(temp.arena)
		if temp.arena.curr_block != nil &&
		   temp.arena.curr_block.capacity > temp.arena.minimum_block_size {
			runtime.arena_destroy(temp.arena)
		}
	}
}

// Copy a temporary host string into Lua. The protected boundary catches OOM;
// no finalizer may run here, since closing the current coroutine would jump past
// even this boundary. The caller runs the GC check after releasing its resources.
@(private)
push_host_string_protected :: proc(L: ^kernel.State, value: ^string) -> kernel.Thread_Status {
	return kernel.run_protected(L, push_host_string_body, value)
}

@(private = "file")
push_host_string_body :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	kernel.api_pushstring_nogc(L, (^string)(ud)^)
	return .Ok
}

// runtime.Arena normally starts with zeroed backing storage. Our first block
// is an uninitialized stack buffer, so honor zero-initializing allocation modes
// explicitly while retaining the ordinary arena behavior for all other modes.
@(private = "file")
host_env_arena_allocator :: proc(
	data: rawptr, mode: runtime.Allocator_Mode, size, alignment: int,
	old_memory: rawptr, old_size: int, loc := #caller_location,
) -> (result: []byte, err: runtime.Allocator_Error) {
	result, err = runtime.arena_allocator_proc(data, mode, size, alignment, old_memory, old_size, loc)
	if err == nil {
		if mode == .Alloc {
			runtime.mem_zero(raw_data(result), len(result))
		} else if mode == .Resize && old_size >= 0 && old_size < len(result) {
			runtime.mem_zero(raw_data(result[old_size:]), len(result) - old_size)
		}
	}
	return
}

// Push an environment value, if present. Give core:os a stack-backed arena so
// lookup happens only once and can distinguish empty from absent on all hosts.
// An oversized value gets an explicitly owned overflow block; Lua cannot run a
// finalizer until that block has been released.
aux_getenv_push :: #force_inline proc(L: ^kernel.State, name: string) -> bool {
	buf: [2048]u8 = ---
	block := runtime.Memory_Block{base = raw_data(buf[:]), capacity = len(buf)}
	arena := runtime.Arena{
		backing_allocator = os.heap_allocator(),
		curr_block = &block,
		total_capacity = len(buf),
		minimum_block_size = 4096,
	}
	allocator := runtime.Allocator{procedure = host_env_arena_allocator, data = &arena}
	value, found := os.lookup_env(name, allocator)
	if arena.curr_block == &block {
		if found do kernel.api_pushstring(L, value)
		return found
	}
	status := kernel.Thread_Status.Ok
	if found {
		status = push_host_string_protected(L, &value)
	}
	for arena.curr_block != &block {
		runtime.arena_free_last_memory_block(&arena)
	}
	if status != .Ok {
		kernel.throw(L, status)
	}
	if found do kernel.gc_checkGC(L)
	return found
}

// Reader state for loading from a file -- reference `LoadF`.
Load_F :: struct {
	n:    int, // number of pre-read (pushed-back) bytes still in `buff`
	f:    ^stream.Stream,
	buff: [8192]u8,
}

// The buffered file reader handed to `lua_load` -- reference `getF`.
getF :: proc "c" (L: ^kernel.State, ud: rawptr, size: ^uint) -> [^]u8 {
	context = runtime.default_context()
	lf := (^Load_F)(ud)
	if lf.n > 0 {
		// Deliver the bytes pre-read while sniffing the header (`#!`/BOM).
		size^ = uint(lf.n)
		lf.n = 0
	} else {
		if stream.feof(lf.f) {
			return nil
		}
		nr := stream.read(lf.f, lf.buff[:])
		size^ = uint(nr)
		if nr == 0 {
			return nil
		}
	}
	return &lf.buff[0]
}

// Skip a leading UTF-8 BOM if present and return the first byte after it --
// reference `skipBOM`. The BOM is discarded (never handed to the loader). Note we
// faithfully mirror the reference quirk: a *partial* BOM (a stray 0xEF not followed
// by the full sequence) already consumed its trailing bytes via `getc`, which can't
// be pushed back -- but a real Lua source never starts that way, so this matches
// reference behavior exactly.
skipBOM :: proc(lf: ^Load_F) -> i32 {
	c := stream.getc(lf.f)
	if c == 0xEF && stream.getc(lf.f) == 0xBB && stream.getc(lf.f) == 0xBF {
		return stream.getc(lf.f) // valid BOM: ignore it and return the next char
	}
	return c // no (valid) BOM: return the first character read
}

// Skip a leading `#!` line (a Unix executable shebang) before compiling --
// reference `skipcomment`. Reports the first significant byte via `c` and returns
// `true` when a comment line was skipped (so the caller can inject a newline to keep
// line numbers honest, exactly as reference Lua does).
skipcomment :: proc(lf: ^Load_F, c: ^i32) -> bool {
	ci := skipBOM(lf)
	c^ = ci
	if ci == '#' {
		// A `#!` line: skip until end of line, then report the next byte.
		for ci != stream.EOF && ci != '\n' {
			ci = stream.getc(lf.f)
		}
		c^ = stream.getc(lf.f) // the character after the comment (if any)
		return true
	}
	return false
}

// Load a chunk from a named file (or stdin when `filename == ""`) -- reference
// `luaL_loadfilex`.
aux_loadfilex :: proc(
	L: ^kernel.State,
	filename: string,
	mode: string = "",
) -> kernel.Thread_Status {
	lf: Load_F
	if filename == "" {
		kernel.api_pushstring(L, "=stdin")
		lf.f = stream.stdin()
	} else {
		kernel.api_pushfstring(L, "@%s", filename)
		lf.f = stream.open(filename, "r")
		if lf.f == nil {
			kernel.api_pushfstring(L, "cannot open %s", filename)
			kernel.api_remove(L, -2)
			return .Err_Err
		}
	}
	c: i32
	lf.n = 0
	if skipcomment(&lf, &c) {
		// A shebang line was skipped; inject a newline so reported line numbers
		// stay aligned with the source file (reference Lua does the same).
		lf.buff[lf.n] = '\n'
		lf.n += 1
	}
	if c == i32(kernel.SIGNATURE[0]) && filename != "" {
		// Binary chunk. We sniffed it in text mode, which on Windows mangles bytes
		// (CRLF translation, 0x1A-as-EOF). Discard everything read so far and reopen
		// the file in binary mode, then re-sniff -- reference `freopen(..,"rb",..)`.
		lf.n = 0
		lf.f = stream.reopen(filename, "rb", lf.f)
		if lf.f == nil {
			kernel.api_pushfstring(L, "cannot reopen %s", filename)
			kernel.api_remove(L, -2)
			return .Err_Err
		}
		skipcomment(&lf, &c) // re-read the initial portion in binary mode
	}
	if c != stream.EOF {
		lf.buff[lf.n] = u8(c) // `c` is the first real character of the stream
		lf.n += 1
	}
	chunkname, _ := kernel.api_tostring(L, -1)
	status := kernel.api_load(L, getF, &lf, chunkname, mode)
	readerr := stream.ferror(lf.f)
	if filename != "" {
		stream.close(lf.f)
	}
	if readerr {
		kernel.api_settop(L, -2) // remove any partial result
		kernel.api_pushfstring(L, "cannot read %s", filename)
		kernel.api_remove(L, -2)
		return .Err_Err
	}
	kernel.api_remove(L, -2) // remove the chunk name, leaving the result
	return status
}

// --------------------------------------------------------------------------------
// C-string helpers retained for the few C-ABI boundaries still in the VM.
// --------------------------------------------------------------------------------

// Allocate a NUL-terminated copy of `s` for handing to a C ABI. Freed with
// `delete_cstring`.
cstring_from :: proc(s: string) -> cstring {
	buf := make([]u8, len(s) + 1, os.heap_allocator())
	if len(s) > 0 {
		runtime.mem_copy(raw_data(buf), raw_data(s), len(s))
	}
	buf[len(s)] = 0
	return cstring(raw_data(buf))
}

delete_cstring :: proc(c: cstring) {
	free(rawptr(c), os.heap_allocator())
}

// --------------------------------------------------------------------------------
// State creation, allocator, and the default warning system
// --------------------------------------------------------------------------------

// Create a new Lua state wired to the default allocator and warning handler --
// reference `luaL_newstate`. (Reference also installs a panic function via
// `lua_atpanic`; our top-level driver runs everything under `lua_pcall`, so an
// unhandled panic hook is not needed here.)
aux_newstate :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	if L != nil {
		kernel.api_setwarnf(L, warnfon, L)
	}
	return L
}

// `luaL_fileresult` -- reference Lua's OS-result reporter. On success it pushes
// `true`; on failure it pushes `fail`, an error string (prefixed with the file
// name if one was given), and the numeric errno. Callers pass `stat = true` for a
// successful C call. The errno is read once up front because subsequent Lua API
// calls may clobber it.
aux_fileresult :: proc(
	L: ^kernel.State,
	stat: bool,
	fname: string,
	has_fname: bool,
	err: os.Error = nil,
) -> i32 {
	if stat {
		kernel.api_pushboolean(L, true)
		return 1
	}
	aux_pushfail(L)
	msg := err != nil ? os.error_string(err) : "(no extra info)"
	if has_fname {
		kernel.api_pushfstring(L, "%s: %s", fname, msg)
	} else {
		kernel.api_pushstring(L, msg)
	}
	en, ok := os.is_platform_error(err)
	if !ok {
		switch err {
		case os.General_Error.Not_Exist: en = 2
		case os.General_Error.Exist: en = 17
		case io.Error.Permission_Denied: en = 13
		case runtime.Allocator_Error.Out_Of_Memory: en = 12
		case os.General_Error.Invalid_File, io.Error.Closed: en = 9
		case os.General_Error.Broken_Pipe: en = 32
		case: en = 5
		}
	}
	kernel.api_pushinteger(L, kernel.Integer(en))
	return 3
}

// `luaL_execresult` -- reference Lua's process-result reporter for os.execute /
// io's pclose. Platform process code decodes the native wait result first, then
// this routine produces the common (true|fail, "exit"|"signal", code) tuple.
aux_execresult :: proc(
	L: ^kernel.State,
	stat: i32,
	err: os.Error = nil,
	signaled: bool = false,
) -> i32 {
	if err != nil {
		return aux_fileresult(L, false, "", false, err)
	}
	if !signaled && stat == 0 {
		kernel.api_pushboolean(L, true)
	} else {
		aux_pushfail(L)
	}
	kernel.api_pushstring(L, "signal" if signaled else "exit")
	kernel.api_pushinteger(L, kernel.Integer(stat))
	return 3
}

// `luaL_makeseed` -- reference Lua's seed generator. It mixes a stack address
// (Address Space Layout Randomization, when present) with the current wall-clock
// time and folds the bytes down to an unsigned 32-bit value. The result is
// *deliberately* nondeterministic: it seeds the PRNG and the sort's pivot
// randomization, so faithfulness here means "some unpredictable unsigned int",
// not "these exact bytes". We reproduce the reference's shape (address XOR time,
// folded) without promising bit-for-bit identical output across runs.
aux_makeseed :: proc(L: ^kernel.State) -> u32 {
	// A local's address supplies ASLR-derived entropy; the clock supplies the rest.
	local: int
	addr := uintptr(&local)
	t := u64(time.to_unix_seconds(time.now()))
	mixed := u64(addr) ~ (t * 0x9E3779B97F4A7C15) // golden-ratio odd multiplier
	// Fold the 64 bits into 32 by XORing the halves, matching the reference's
	// "xor the buffer words together" reduction.
	return u32(mixed) ~ u32(mixed >> 32)
}

// The warning subsystem's three states -- reference `warnfoff`/`warnfon`/
// `warnfcont`. Control messages ("@on"/"@off") toggle emission; ordinary messages
// are written to stderr, accumulating fragments until a non-continued piece flushes
// a trailing newline.

// Handle a possible "@..." control message; returns true if it was one.
checkcontrol :: proc(L: ^kernel.State, message: string, tocont: bool) -> bool {
	if tocont || len(message) == 0 || message[0] != '@' {
		return false
	}
	body := message[1:]
	if body == "off" {
		kernel.api_setwarnf(L, warnfoff, L)
	} else if body == "on" {
		kernel.api_setwarnf(L, warnfon, L)
	}
	return true
}

warnfoff :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	checkcontrol((^kernel.State)(ud), string(msg), tocont != 0)
}

warnfcont :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	L := (^kernel.State)(ud)
	write_stderr(string(msg))
	if tocont != 0 {
		kernel.api_setwarnf(L, warnfcont, L) // more to come
	} else {
		write_stderr("\n")
		kernel.api_setwarnf(L, warnfon, L) // next call starts a new warning
	}
}

warnfon :: proc "c" (ud: rawptr, msg: cstring, tocont: i32) {
	context = runtime.default_context()
	if checkcontrol((^kernel.State)(ud), string(msg), tocont != 0) {
		return
	}
	write_stderr(kernel.BRAND + " warning: ")
	warnfcont(ud, msg, tocont)
}

// Write raw bytes to the shared stderr stream so diagnostics and io.stderr retain
// one coherent buffering order.
write_stderr :: proc(s: string) {
	if len(s) > 0 {
		stream.write(stream.stderr(), transmute([]u8)s)
	}
	stream.flush(stream.stderr())
}

// Write bytes through the same stdout object used by io.stdout and print.
write_string :: proc(s: string) {
	if len(s) > 0 {
		stream.write(stream.stdout(), transmute([]u8)s)
	}
}

// End a line on stdout and flush it -- reference `lua_writeline`.
write_line :: proc() {
	write_string("\n")
	stream.flush(stream.stdout())
}
