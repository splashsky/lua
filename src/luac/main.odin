package main

// luac/main.odin -- the standalone `luac` bytecode compiler, our faithful
// analogue of the reference `luac.c`.
//
// `luac` compiles Lua source into a precompiled chunk. It parses each input file
// to a prototype (reusing the very same kernel compiler the runtime uses), can
// combine several inputs into one chunk that runs them in sequence, optionally
// strips debug information, and dumps the result to a file (or, when told to,
// lists the bytecode). Because it shares the kernel's `dump`, byte-for-byte
// compatibility with reference `luac` output is a property of the kernel, not of
// this driver.
//
// Structurally this mirrors reference luac.c one-for-one: `doargs` for option
// parsing, `pmain` run under a protected call, `combine` (which lives in the
// kernel as `luac_combine`, since it performs prototype surgery), a `writer`
// callback for `dump`, and the `fatal`/`cannot`/`usage` diagnostics.
//
// One documented, staged limitation: bytecode *listing* (`-l`) -- the human
// readable disassembly -- is implemented separately (see the disassembler port).
// It is luac-specific debug output with no bearing on language semantics or on
// the byte-compatibility of dumped chunks.

import "core:fmt"
import "core:os"
import "core:strings"
import libc "core:c/libc"
import "base:runtime"

import lua "luao:lua"
import aux "luao:stdlib"

// Default program name and default output file. Reference PROGNAME / OUTPUT.
LUAC_PROGNAME :: "luac"
LUAC_OUTPUT :: "luac.out"

// --------------------------------------------------------------------------------
// Option state, mirroring the reference file-static flags.
// --------------------------------------------------------------------------------

listing := 0 // list bytecodes? (-l once = brief, twice = full)
dumping := true // dump bytecodes? (cleared by -p)
stripping := false // strip debug information? (-s)
output := LUAC_OUTPUT // output file name (-o)
output_to_stdout := false // true when the output is '-' (stdout)
progname := LUAC_PROGNAME // actual program name (argv[0])
use_default_input := false // list the default output file when given no inputs

// The input file list, captured in `main` and read back in `pmain`. Its storage
// must outlive the protecting `lua_pcall`, so we keep it in a package global and
// hand `pmain` a pointer to it.
g_inputs: []string

// --------------------------------------------------------------------------------
// Diagnostics. Reference fatal / cannot / usage. All exit the process.
// --------------------------------------------------------------------------------

fatal :: proc(message: string) -> ! {
	aux.write_stderr(fmt.tprintf("%s: %s\n", progname, message))
	os.exit(1)
}

// Report an I/O failure on the output file. Reference `cannot` also appends
// strerror(errno); Odin's standard library does not expose a portable strerror,
// so we report the operation and file name, which is the actionable part.
cannot :: proc(what: string) -> ! {
	aux.write_stderr(fmt.tprintf("%s: cannot %s %s\n", progname, what, output))
	os.exit(1)
}

usage :: proc(message: string) -> ! {
	if len(message) > 0 && message[0] == '-' {
		aux.write_stderr(fmt.tprintf("%s: unrecognized option '%s'\n", progname, message))
	} else {
		aux.write_stderr(fmt.tprintf("%s: %s\n", progname, message))
	}
	aux.write_stderr(
		fmt.tprintf(
			"usage: %s [options] [filenames]\n" +
			"Available options are:\n" +
			"  -l       list (use -l -l for full listing)\n" +
			"  -o name  output to file 'name' (default is \"%s\")\n" +
			"  -p       parse only\n" +
			"  -s       strip debug information\n" +
			"  -v       show version information\n" +
			"  --       stop handling options\n" +
			"  -        stop handling options and process stdin\n",
			progname,
			LUAC_OUTPUT,
		),
	)
	os.exit(1)
}

// --------------------------------------------------------------------------------
// Argument parsing. Returns the index of the first input file in `argv`. Reference
// doargs (the mutating `argv[--i]=Output` trick is replaced by the
// `use_default_input` flag, which `main` honours).
// --------------------------------------------------------------------------------

doargs :: proc(argv: []string) -> int {
	version := 0
	if len(argv) > 0 && len(argv[0]) > 0 {
		progname = argv[0]
	}
	i := 1
	for i < len(argv) {
		a := argv[i]
		if len(a) == 0 || a[0] != '-' { // end of options; keep this argument
			break
		} else if a == "--" { // end of options; skip it
			i += 1
			if version != 0 {
				version += 1
			}
			break
		} else if a == "-" { // end of options; use stdin
			break
		} else if a == "-l" { // list
			listing += 1
		} else if a == "-o" { // output file
			i += 1
			if i >= len(argv) {
				usage("'-o' needs argument")
			}
			output = argv[i]
			if len(output) == 0 || (output[0] == '-' && len(output) > 1) {
				usage("'-o' needs argument")
			}
			if output == "-" {
				output_to_stdout = true
			}
		} else if a == "-p" { // parse only
			dumping = false
		} else if a == "-s" { // strip debug information
			stripping = true
		} else if a == "-v" { // show version
			version += 1
		} else { // unknown option
			usage(a)
		}
		i += 1
	}
	// No input files, but we were asked to list or merely parse? Reference then
	// re-processes the default output file (so `luac -l` disassembles luac.out).
	if i == len(argv) && (listing != 0 || !dumping) {
		dumping = false
		use_default_input = true
	}
	if version != 0 {
		fmt.println(lua.COPYRIGHT)
		if version == len(argv) - 1 { // every argument was a version request
			os.exit(0)
		}
	}
	return i
}

// --------------------------------------------------------------------------------
// The dump writer callback handed to `lua_dump`: write the block to the FILE in
// `ud`. Reference writer -- returns non-zero (error) when a non-empty block fails
// to write.
// --------------------------------------------------------------------------------

luac_writer :: proc "c" (L: rawptr, p: rawptr, sz: uint, ud: rawptr) -> i32 {
	if sz == 0 {
		return 0
	}
	D := (^libc.FILE)(ud)
	return libc.fwrite(p, sz, 1, D) != 1 ? 1 : 0
}

// --------------------------------------------------------------------------------
// pmain -- load every input, combine them, optionally list, optionally dump.
// Run under a protected call. Reference pmain.
// --------------------------------------------------------------------------------

pmain :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.Lua_State)(Lp)
	argc := int(lua.lua_tointeger(L, 1))
	argv := (^[]string)(lua.lua_touserdata(L, 2))^
	if !lua.lua_checkstack(L, argc) {
		fatal("too many input files")
	}
	for i in 0 ..< argc {
		filename := argv[i] == "-" ? "" : argv[i] // '-' means stdin
		if aux.luaL_loadfilex(L, filename) != .Ok {
			msg, _ := lua.lua_tolstring(L, -1)
			fatal(msg)
		}
	}
	// Fold the loaded chunks into a single function (see kernel luac_combine).
	// The result is left on top of the stack, ready for `lua_dump`.
	f := lua.luac_combine(L, argc)
	if f == nil {
		msg, _ := lua.lua_tolstring(L, -1)
		fatal(msg)
	}
	if listing != 0 {
		list_function(f, listing > 1)
	}
	if dumping {
		if output_to_stdout {
			// `lua_dump` walks the top-of-stack function and streams bytes to our
			// writer; a stdout target needs no open/close.
			lua.lua_dump(L, luac_writer, libc.stdout, stripping)
		} else {
			cpath := strings.clone_to_cstring(output, context.temp_allocator)
			D := libc.fopen(cpath, "wb")
			if D == nil {
				cannot("open")
			}
			lua.lua_dump(L, luac_writer, D, stripping)
			if libc.ferror(D) != 0 {
				cannot("write")
			}
			if libc.fclose(D) != 0 {
				cannot("close")
			}
		}
	}
	return 0
}

// --------------------------------------------------------------------------------
// Bytecode listing (`-l`). Implemented by the disassembler port; until then this
// fails explicitly rather than silently ignoring the request. Reference luaU_print
// / PrintFunction.
// --------------------------------------------------------------------------------

list_function :: proc(f: ^lua.Proto, full: bool) {
	fatal("listing (-l) is not yet implemented")
}

// --------------------------------------------------------------------------------
// Process entry point. Reference main.
// --------------------------------------------------------------------------------

main :: proc() {
	argv := os.args
	first := doargs(argv)
	inputs := use_default_input ? []string{LUAC_OUTPUT} : argv[first:]
	if len(inputs) == 0 {
		usage("no input files given")
	}
	g_inputs = inputs // keep alive across the pcall below

	L := lua.new_state(lua.default_allocator())
	if L == nil {
		fatal("cannot create state: not enough memory")
	}
	lua.lua_pushcfunction(L, pmain)
	lua.lua_pushinteger(L, lua.Integer(len(g_inputs)))
	lua.lua_pushlightuserdata(L, &g_inputs)
	if lua.lua_pcall(L, 2, 0, 0) != .Ok {
		msg, _ := lua.lua_tolstring(L, -1)
		fatal(msg)
	}
	lua.close_state(L)
	os.exit(0)
}
