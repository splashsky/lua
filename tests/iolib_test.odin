package tests

// iolib_test.odin -- honest end-to-end tests for the io library
// (src/stdlib/iolib.odin). Every test drives real Lua chunks that open real files
// (under the OS temp directory) and assert observable io semantics: write/read
// round-trips, the l/L/a/n/number read formats, seek positioning from set/cur/end,
// the lines iterators, io.type classification, and the documented error paths.
// Files are removed at the end of each chunk so the tests leave no residue.

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

io_state :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	kernel.api_pushcfunction(L, stdlib.open_base)
	kernel.api_call(L, 0, 0)
	kernel.api_pushcfunction(L, stdlib.open_io)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "io")
	kernel.api_pushcfunction(L, stdlib.open_os)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "os")
	return L
}

io_run :: proc(L: ^kernel.State, src: string) -> kernel.Thread_Status {
	if st := stdlib.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return kernel.api_pcall(L, 0, kernel.MULTRET, 0)
}

io_eval :: proc(t: ^testing.T, L: ^kernel.State, src: string) -> string {
	st := io_run(L, src)
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return ""
	}
	s, _ := kernel.api_tolstring(L, -1)
	return s
}

// A shared preamble that computes a per-name temp path with forward slashes (which
// the C runtime accepts on Windows too), so tests never collide or touch the cwd.
IO_PREAMBLE :: "local TMP = os.getenv('TEMP') or os.getenv('TMP') or '.'\n" +
	"local function tmppath(nm) return TMP .. '/luaio_' .. nm end\n"

POPEN_FAIL_COMMAND :: "'exit /b 7'" when ODIN_OS == .Windows else "'exit 7'"
POPEN_MULTI_COMMAND :: "'(echo one& echo two& echo three)'" when ODIN_OS == .Windows else
	"\"printf 'one\\\\ntwo\\\\nthree\\\\n'\""
POPEN_WRITE_COMMAND :: "'sort > ' .. path" when ODIN_OS == .Windows else
	"'cat > \"' .. path .. '\"'"

@(test)
io_write_read_all :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('all.tmp')\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"assert(io.type(f) == 'file')\n" +
		"assert(f:write('hello ', 42, ' ', 3.5, '\\n') == f)\n" + // write returns the file
		"f:close()\n" +
		"assert(io.type(f) == 'closed file')\n" +
		"local g = assert(io.open(path, 'r'))\n" +
		"assert(g:read('a') == 'hello 42 3.5\\n')\n" + // numbers rendered canonically
		"g:close()\n" +
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "write then read entire file")
}

@(test)
io_line_formats :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('lines.tmp')\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"f:write('line1\\nline2\\nno-newline')\n" +
		"f:close()\n" +
		"local g = assert(io.open(path, 'r'))\n" +
		"assert(g:read('l') == 'line1')\n" + // 'l' chops the newline
		"assert(g:read('L') == 'line2\\n')\n" + // 'L' keeps it
		"assert(g:read('a') == 'no-newline')\n" + // 'a' reads the rest
		"assert(g:read('l') == nil)\n" + // EOF -> nil
		"g:close()\n" +
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "l / L / a read formats")
}

@(test)
io_bulk_read_edge_cases :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('bulk.tmp')\n" +
		"local function put(data)\n" +
		"  local f = assert(io.open(path, 'wb')); assert(f:write(data)); f:close()\n" +
		"end\n" +
		"local function lines(data, mode)\n" +
		"  put(data); local out = {}\n" +
		"  for line in io.lines(path, mode or 'l') do out[#out+1] = line end\n" +
		"  return out\n" +
		"end\n" +
		// Empty input, empty lines, only newlines, and a final unterminated line.
		"put(''); local f = assert(io.open(path, 'r'))\n" +
		"assert(f:read('l') == nil and f:read('L') == nil); f:close()\n" +
		"local a = lines('\\n'); assert(#a == 1 and a[1] == '')\n" +
		"a = lines('\\n\\n\\n', 'L')\n" +
		"assert(#a == 3 and a[1] == '\\n' and a[2] == '\\n' and a[3] == '\\n')\n" +
		"a = lines('one\\n\\ntail'); assert(#a == 3 and a[1] == 'one' and a[2] == '' and a[3] == 'tail')\n" +
		// Cross several stream/Lua-buffer boundaries before finding the newline.
		"local long = ''; for i = 1, 20000 do long = long .. 'x' end\n" +
		"put(long .. '\\nlast'); f = assert(io.open(path, 'r'))\n" +
		"assert(f:read('l') == long and f:read('L') == 'last' and f:read('l') == nil); f:close()\n" +
		// read_number leaves one byte in ungetc pushback; the bulk line reader
		// must return that byte before touching the stream's buffered raw bytes.
		"put('12x\\n'); f = assert(io.open(path, 'r'))\n" +
		"assert(f:read('n') == 12 and f:read('l') == 'x'); f:close()\n" +
		// A binary fixture lets the same bytes exercise Windows text translation
		// and the translation-free binary path.
		"local raw = '\\r\\nA\\rB\\r\\nC\\x1aD\\n'; put(raw)\n" +
		"f = assert(io.open(path, 'rb')); assert(f:read('a') == raw); f:close()\n" +
		"f = assert(io.open(path, 'r'))\n" +
		"local first = f:read('L')\n" +
		"if first == '\\n' then\n" + // Windows text mode
		"  assert(f:seek() == 2)\n" +
		"  assert(f:read('l') == 'A\\rB' and f:seek() == 7)\n" +
		"  assert(f:read('a') == 'C' and f:seek() == 8 and f:read(1) == nil)\n" +
		"else\n" + // Other hosts do not translate text streams
		"  assert(first == '\\r\\n' and f:read('l') == 'A\\rB\\r' and f:read('a') == 'C\\x1aD\\n')\n" +
		"end\n" +
		"f:close(); os.remove(path); return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "bulk lines preserve edge, pushback, text, and binary semantics")
}

@(test)
io_number_and_chars :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('num.tmp')\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"f:write('3.14 0x1F 100\\nABCDEFG')\n" +
		"f:close()\n" +
		"local g = assert(io.open(path, 'r'))\n" +
		"assert(g:read('n') == 3.14)\n" + // float numeral
		"assert(g:read('n') == 31)\n" + // hexadecimal integer 0x1F
		"assert(g:read('n') == 100)\n" +
		"assert(g:read('l') == '')\n" + // remainder of the number line is empty
		"assert(g:read(3) == 'ABC')\n" + // read an exact byte count
		"assert(g:read(2) == 'DE')\n" +
		"assert(g:read(0) == '')\n" + // zero request: empty string, not EOF here
		"assert(g:read('a') == 'FG')\n" +
		"assert(g:read(1) == nil)\n" + // now at EOF
		"g:close()\n" +
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "n format and byte-count reads")
}

@(test)
io_seek_positions :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('seek.tmp')\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"f:write('0123456789')\n" +
		"f:close()\n" +
		"local g = assert(io.open(path, 'r'))\n" +
		"assert(g:seek('end') == 10)\n" + // size of the file
		"assert(g:seek('set') == 0)\n" + // rewind, default offset 0
		"assert(g:read(2) == '01')\n" +
		"assert(g:seek() == 2)\n" + // current position
		"assert(g:seek('set', 3) == 3)\n" +
		"assert(g:read(2) == '34')\n" +
		"assert(g:seek('cur', 2) == 7)\n" + // relative seek
		"assert(g:read('a') == '789')\n" +
		"g:close()\n" +
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "seek set/cur/end positioning")
}

@(test)
io_lines_iterators :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		"local path = tmppath('iter.tmp')\n" +
		"local f = assert(io.open(path, 'w'))\n" +
		"f:write('a\\nb\\nc\\n')\n" +
		"f:close()\n" +
		// io.lines(filename) opens, iterates, and closes the file automatically
		"local t = {}\n" +
		"for line in io.lines(path) do t[#t+1] = line end\n" +
		"assert(#t == 3 and t[1] == 'a' and t[3] == 'c')\n" +
		// file:lines iterates an already-open handle (which we then close ourselves)
		"local g = assert(io.open(path, 'r'))\n" +
		"local n = 0\n" +
		"for line in g:lines() do n = n + 1 end\n" +
		"assert(n == 3)\n" +
		"assert(io.type(g) == 'file')\n" + // file:lines does not close the file
		"g:close()\n" +
		"os.remove(path)\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "io.lines and file:lines")
}

@(test)
io_type_and_defaults :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		"assert(io.type('not a file') == nil)\n" + // non-userdata
		"assert(io.type(42) == nil)\n" +
		"assert(io.type(io.stdout) == 'file')\n" +
		// The default input/output accessors return live file handles.
		"assert(io.type(io.output()) == 'file')\n" +
		"assert(io.type(io.input()) == 'file')\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "io.type and default handles")
}

@(test)
io_error_paths :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	src :=
		IO_PREAMBLE +
		// invalid open mode is rejected before touching the filesystem
		"assert(not pcall(io.open, 'whatever', 'zz'))\n" +
		// opening a missing file for reading returns fail + message (does not raise)
		"local ok, msg = io.open(tmppath('does_not_exist_xyz.tmp'), 'r')\n" +
		"assert(ok == nil and type(msg) == 'string')\n" +
		// invalid read format raises
		"local g = assert(io.open(tmppath('err.tmp'), 'w'))\n" +
		"g:write('data'); g:close()\n" +
		"local h = assert(io.open(tmppath('err.tmp'), 'r'))\n" +
		"assert(not pcall(function() return h:read('q') end))\n" +
		"h:close()\n" +
		// using a closed handle raises
		"assert(not pcall(function() return h:read('a') end))\n" +
		"os.remove(tmppath('err.tmp'))\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "documented io error paths")
}

@(test)
io_tmpfile_roundtrip :: proc(t: ^testing.T) {
	L := io_state()
	defer kernel.close_state(L)
	// io.tmpfile may be unavailable in restricted environments; when it succeeds it
	// must honestly round-trip through a rewind. When it fails it must report the
	// (nil, message) failure contract. Either outcome is asserted truthfully.
	src :=
		"local f, msg = io.tmpfile()\n" +
		"if f then\n" +
		"  assert(io.type(f) == 'file')\n" +
		"  f:write('round', 'trip')\n" +
		"  f:seek('set')\n" +
		"  assert(f:read('a') == 'roundtrip')\n" +
		"  f:close()\n" +
		"else\n" +
		"  assert(type(msg) == 'string')\n" + // failure must carry a message
		"end\n" +
		"return 'ok'"
	testing.expect(t, io_eval(t, L, src) == "ok", "io.tmpfile round-trip or failure contract")
}

@(test)
io_popen_read_and_status :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		L := io_state()
		defer kernel.close_state(L)
		src :=
			"local f = assert(io.popen('echo hello'))\n" +
			"assert(f:read('a') == 'hello\\n')\n" +
			"local ok, why, code = f:close()\n" +
			"assert(ok == true and why == 'exit' and code == 0)\n" +
			"local command = " + POPEN_FAIL_COMMAND + "\n" +
			"local g = assert(io.popen(command))\n" +
			"assert(g:read('a') == '')\n" +
			"ok, why, code = g:close()\n" +
			"assert(ok == nil and why == 'exit' and code == 7)\n" +
			"local h = assert(io.popen(" + POPEN_MULTI_COMMAND + "))\n" +
			"assert(h:read('a') == 'one\\ntwo\\nthree\\n')\n" +
			"assert(h:read(1) == nil)\n" +
			"assert(h:close())\n" +
			"return 'ok'"
		testing.expect(t, io_eval(t, L, src) == "ok", "io.popen reads through EOF and reports child status")
	}
}

@(test)
io_popen_write_and_mode_validation :: proc(t: ^testing.T) {
	when ODIN_OS == .Windows || ODIN_OS == .Linux {
		L := io_state()
		defer kernel.close_state(L)
		src :=
			IO_PREAMBLE +
			"local path = tmppath('popen_write.tmp')\n" +
			"local command = " + POPEN_WRITE_COMMAND + "\n" +
			"local f = assert(io.popen(command, 'w'))\n" +
			"assert(f:write('alpha\\nbeta\\n') == f)\n" +
			"local ok, why, code = f:close()\n" +
			"assert(ok == true and why == 'exit' and code == 0)\n" +
			"local g = assert(io.open(path, 'r'))\n" +
			"assert(g:read('a') == 'alpha\\nbeta\\n')\n" +
			"g:close(); os.remove(path)\n" +
			"local good, msg = pcall(io.popen, 'echo no', 'r+')\n" +
			"assert(not good)\n" +
			"return msg"
		actual := io_eval(t, L, src)
		testing.expectf(
			t,
			actual == "bad argument #2 to '?' (invalid mode)",
			"io.popen writes stdin and validates modes; got %q",
			actual,
		)
	}
}
