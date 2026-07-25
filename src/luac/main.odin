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
		list_function(L, f, listing > 1)
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
// Bytecode listing (`-l`). A faithful port of reference luac.c's PrintFunction and
// its helpers (PrintString / PrintType / PrintConstant / PrintCode / PrintHeader /
// PrintDebug). This is purely human-readable debug output: it has no bearing on the
// language semantics or on the byte-compatibility of dumped chunks. We deliberately
// mirror the reference format character-for-character so `luac -l` output can be
// diffed against the reference tool (pointer addresses aside, which differ per run).
// --------------------------------------------------------------------------------

// Reference COMMENT: the tab-semicolon that introduces a trailing annotation.
@(private = "file")
LIST_COMMENT :: "\t; "

// isprint for the C locale: printable ASCII, space through tilde. Reference relies
// on <ctype.h> isprint; in the "C" locale that is exactly this range.
@(private = "file")
is_print :: proc(c: int) -> bool {
	return c >= 0x20 && c <= 0x7e
}

// "" for a count of one, "s" otherwise -- reference SS(x). Used to pluralize the
// header's noun list ("1 slot", "3 slots").
@(private = "file")
plural :: proc(x: int) -> string {
	return x == 1 ? "" : "s"
}

// The name of upvalue `x`, or "-" when it carries no debug name -- reference
// UPVALNAME.
@(private = "file")
upvalname :: proc(f: ^lua.Proto, x: int) -> string {
	name := f.upvalues[x].name
	return name != nil ? string(lua.str_slice(name)) : "-"
}

// The metamethod event name for index `c` -- reference eventname(c). The interned
// TM_* names live in the global state; the VM stores them there at startup.
@(private = "file")
eventname :: proc(L: ^lua.Lua_State, c: int) -> string {
	return string(lua.str_slice(L.g.tmname[c]))
}

// Print a string constant with the exact C-string escaping reference luac uses.
@(private = "file")
print_string :: proc(ts: ^lua.TString) {
	fmt.print("\"")
	for b in lua.str_slice(ts) {
		c := int(b)
		switch c {
		case 34: // '"'
			fmt.print("\\\"")
		case 92: // '\\'
			fmt.print("\\\\")
		case 7: // '\a'
			fmt.print("\\a")
		case 8: // '\b'
			fmt.print("\\b")
		case 12: // '\f'
			fmt.print("\\f")
		case 10: // '\n'
			fmt.print("\\n")
		case 13: // '\r'
			fmt.print("\\r")
		case 9: // '\t'
			fmt.print("\\t")
		case 11: // '\v'
			fmt.print("\\v")
		case:
			if is_print(c) {
				fmt.printf("%c", rune(c))
			} else {
				fmt.printf("\\%03d", c)
			}
		}
	}
	fmt.print("\"")
}

// Print the one-letter type tag of constant `i` (N/B/F/I/S), then a tab --
// reference PrintType.
@(private = "file")
print_type :: proc(f: ^lua.Proto, i: int) {
	o := &f.k[i]
	switch lua.type_tag(o) {
	case lua.VNIL:
		fmt.print("N")
	case lua.VFALSE, lua.VTRUE:
		fmt.print("B")
	case lua.VNUMFLT:
		fmt.print("F")
	case lua.VNUMINT:
		fmt.print("I")
	case lua.VSHRSTR, lua.VLNGSTR:
		fmt.print("S")
	case:
		fmt.printf("?%d", int(lua.type_tag(o))) // cannot happen
	}
	fmt.print("\t")
}

// Print constant `i` in source form -- reference PrintConstant. Numbers reuse the
// kernel's own formatters, so a float renders byte-identically to how the runtime
// (and reference Lua) would print it, including the trailing ".0" on integral
// floats.
@(private = "file")
print_constant :: proc(f: ^lua.Proto, i: int) {
	o := &f.k[i]
	buf: [128]byte
	switch lua.type_tag(o) {
	case lua.VNIL:
		fmt.print("nil")
	case lua.VFALSE:
		fmt.print("false")
	case lua.VTRUE:
		fmt.print("true")
	case lua.VNUMFLT, lua.VNUMINT:
		n := lua.number_to_str(o, buf[:])
		fmt.print(string(buf[:n]))
	case lua.VSHRSTR, lua.VLNGSTR:
		print_string(lua.str_value(o))
	case:
		fmt.printf("?%d", int(lua.type_tag(o))) // cannot happen
	}
}

// Print the instruction stream, one opcode per line, with the same columns and
// trailing comments as reference PrintCode.
@(private = "file")
print_code :: proc(L: ^lua.Lua_State, f: ^lua.Proto) {
	code := f.code
	n := f.sizecode
	for pc in 0 ..< n {
		i := code[pc]
		o := lua.get_opcode(i)
		// Our kernel's argument extractors deliberately assert that the instruction
		// is in the matching format (they exist to catch VM misuse). A disassembler,
		// though, must read whatever fields a given opcode actually uses -- so we
		// gate each extractor on the opcode's format mode and leave the rest at 0.
		// Every case below reads only the fields its own opcode defines, so the
		// zeroed placeholders are never printed. (Reference luac gets away with
		// computing them all eagerly only because C's GETARG_* macros don't assert.)
		mode := lua.get_op_mode(o)
		abc := mode == .iABC
		vabc := mode == .ivABC
		a := lua.getarg_A(i)
		b := abc ? lua.getarg_B(i) : 0
		c := abc ? lua.getarg_C(i) : 0
		ax := mode == .iAx ? lua.getarg_Ax(i) : 0
		bx := mode == .iABx ? lua.getarg_Bx(i) : 0
		sb := abc ? lua.getarg_sB(i) : 0
		sc := abc ? lua.getarg_sC(i) : 0
		vb := vabc ? lua.getarg_vB(i) : 0
		vc := vabc ? lua.getarg_vC(i) : 0
		sbx := mode == .iAsBx ? lua.getarg_sBx(i) : 0
		isk := lua.getarg_k(i)
		line := lua.luaG_getfuncline(f, pc)
		isk_s := isk != 0 ? "k" : ""

		fmt.printf("\t%d\t", pc + 1)
		if line > 0 {
			fmt.printf("[%d]\t", line)
		} else {
			fmt.print("[-]\t")
		}
		fmt.printf("%-9s\t", lua.opnames[int(o)])

		switch o {
		case .MOVE:
			fmt.printf("%d %d", a, b)
		case .LOADI:
			fmt.printf("%d %d", a, sbx)
		case .LOADF:
			fmt.printf("%d %d", a, sbx)
		case .LOADK:
			fmt.printf("%d %d", a, bx)
			fmt.print(LIST_COMMENT)
			print_constant(f, bx)
		case .LOADKX:
			fmt.printf("%d", a)
			fmt.print(LIST_COMMENT)
			print_constant(f, lua.getarg_Ax(code[pc + 1]))
		case .LOADFALSE:
			fmt.printf("%d", a)
		case .LFALSESKIP:
			fmt.printf("%d", a)
		case .LOADTRUE:
			fmt.printf("%d", a)
		case .LOADNIL:
			fmt.printf("%d %d", a, b)
			fmt.printf(LIST_COMMENT + "%d out", b + 1)
		case .GETUPVAL:
			fmt.printf("%d %d", a, b)
			fmt.printf(LIST_COMMENT + "%s", upvalname(f, b))
		case .SETUPVAL:
			fmt.printf("%d %d", a, b)
			fmt.printf(LIST_COMMENT + "%s", upvalname(f, b))
		case .GETTABUP:
			fmt.printf("%d %d %d", a, b, c)
			fmt.printf(LIST_COMMENT + "%s", upvalname(f, b))
			fmt.print(" ")
			print_constant(f, c)
		case .GETTABLE:
			fmt.printf("%d %d %d", a, b, c)
		case .GETI:
			fmt.printf("%d %d %d", a, b, c)
		case .GETFIELD:
			fmt.printf("%d %d %d", a, b, c)
			fmt.print(LIST_COMMENT)
			print_constant(f, c)
		case .SETTABUP:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			fmt.printf(LIST_COMMENT + "%s", upvalname(f, a))
			fmt.print(" ")
			print_constant(f, b)
			if isk != 0 {
				fmt.print(" ")
				print_constant(f, c)
			}
		case .SETTABLE:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			if isk != 0 {
				fmt.print(LIST_COMMENT)
				print_constant(f, c)
			}
		case .SETI:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			if isk != 0 {
				fmt.print(LIST_COMMENT)
				print_constant(f, c)
			}
		case .SETFIELD:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			fmt.print(LIST_COMMENT)
			print_constant(f, b)
			if isk != 0 {
				fmt.print(" ")
				print_constant(f, c)
			}
		case .NEWTABLE:
			fmt.printf("%d %d %d%s", a, vb, vc, isk_s)
			extraargc := lua.getarg_Ax(code[pc + 1]) * (lua.MAXARG_C + 1)
			fmt.printf(LIST_COMMENT + "%d", vc + extraargc)
		case .SELF:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			if isk != 0 {
				fmt.print(LIST_COMMENT)
				print_constant(f, c)
			}
		case .ADDI:
			fmt.printf("%d %d %d", a, b, sc)
		case .ADDK, .SUBK, .MULK, .MODK, .POWK, .DIVK, .IDIVK, .BANDK, .BORK, .BXORK:
			fmt.printf("%d %d %d", a, b, c)
			fmt.print(LIST_COMMENT)
			print_constant(f, c)
		case .SHLI:
			fmt.printf("%d %d %d", a, b, sc)
		case .SHRI:
			fmt.printf("%d %d %d", a, b, sc)
		case .ADD, .SUB, .MUL, .MOD, .POW, .DIV, .IDIV, .BAND, .BOR, .BXOR, .SHL, .SHR:
			fmt.printf("%d %d %d", a, b, c)
		case .MMBIN:
			fmt.printf("%d %d %d", a, b, c)
			fmt.printf(LIST_COMMENT + "%s", eventname(L, c))
		case .MMBINI:
			fmt.printf("%d %d %d %d", a, sb, c, isk)
			fmt.printf(LIST_COMMENT + "%s", eventname(L, c))
			if isk != 0 {
				fmt.print(" flip")
			}
		case .MMBINK:
			fmt.printf("%d %d %d %d", a, b, c, isk)
			fmt.printf(LIST_COMMENT + "%s ", eventname(L, c))
			print_constant(f, b)
			if isk != 0 {
				fmt.print(" flip")
			}
		case .UNM:
			fmt.printf("%d %d", a, b)
		case .BNOT:
			fmt.printf("%d %d", a, b)
		case .NOT:
			fmt.printf("%d %d", a, b)
		case .LEN:
			fmt.printf("%d %d", a, b)
		case .CONCAT:
			fmt.printf("%d %d", a, b)
		case .CLOSE:
			fmt.printf("%d", a)
		case .TBC:
			fmt.printf("%d", a)
		case .JMP:
			sj := lua.getarg_sJ(i)
			fmt.printf("%d", sj)
			fmt.printf(LIST_COMMENT + "to %d", sj + pc + 2)
		case .EQ:
			fmt.printf("%d %d %d", a, b, isk)
		case .LT:
			fmt.printf("%d %d %d", a, b, isk)
		case .LE:
			fmt.printf("%d %d %d", a, b, isk)
		case .EQK:
			fmt.printf("%d %d %d", a, b, isk)
			fmt.print(LIST_COMMENT)
			print_constant(f, b)
		case .EQI:
			fmt.printf("%d %d %d", a, sb, isk)
		case .LTI:
			fmt.printf("%d %d %d", a, sb, isk)
		case .LEI:
			fmt.printf("%d %d %d", a, sb, isk)
		case .GTI:
			fmt.printf("%d %d %d", a, sb, isk)
		case .GEI:
			fmt.printf("%d %d %d", a, sb, isk)
		case .TEST:
			fmt.printf("%d %d", a, isk)
		case .TESTSET:
			fmt.printf("%d %d %d", a, b, isk)
		case .CALL:
			fmt.printf("%d %d %d", a, b, c)
			fmt.print(LIST_COMMENT)
			if b == 0 {
				fmt.print("all in ")
			} else {
				fmt.printf("%d in ", b - 1)
			}
			if c == 0 {
				fmt.print("all out")
			} else {
				fmt.printf("%d out", c - 1)
			}
		case .TAILCALL:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			fmt.printf(LIST_COMMENT + "%d in", b - 1)
		case .RETURN:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			fmt.print(LIST_COMMENT)
			if b == 0 {
				fmt.print("all out")
			} else {
				fmt.printf("%d out", b - 1)
			}
		case .RETURN0:
			// no operands
		case .RETURN1:
			fmt.printf("%d", a)
		case .FORLOOP:
			fmt.printf("%d %d", a, bx)
			fmt.printf(LIST_COMMENT + "to %d", pc - bx + 2)
		case .FORPREP:
			fmt.printf("%d %d", a, bx)
			fmt.printf(LIST_COMMENT + "exit to %d", pc + bx + 3)
		case .TFORPREP:
			fmt.printf("%d %d", a, bx)
			fmt.printf(LIST_COMMENT + "to %d", pc + bx + 2)
		case .TFORCALL:
			fmt.printf("%d %d", a, c)
		case .TFORLOOP:
			fmt.printf("%d %d", a, bx)
			fmt.printf(LIST_COMMENT + "to %d", pc - bx + 2)
		case .SETLIST:
			fmt.printf("%d %d %d%s", a, vb, vc, isk_s)
			if isk != 0 {
				extraargc := lua.getarg_Ax(code[pc + 1]) * (lua.MAXARG_C + 1)
				fmt.printf(LIST_COMMENT + "%d", c + extraargc)
			}
		case .CLOSURE:
			fmt.printf("%d %d", a, bx)
			fmt.printf(LIST_COMMENT + "%p", rawptr(f.p[bx]))
		case .VARARG:
			fmt.printf("%d %d %d%s", a, b, c, isk_s)
			fmt.print(LIST_COMMENT)
			if c == 0 {
				fmt.print("all out")
			} else {
				fmt.printf("%d out", c - 1)
			}
		case .GETVARG:
			fmt.printf("%d %d %d", a, b, c)
		case .ERRNNIL:
			fmt.printf("%d %d", a, bx)
			fmt.print(LIST_COMMENT)
			if bx == 0 {
				fmt.print("?")
			} else {
				print_constant(f, bx - 1)
			}
		case .VARARGPREP:
			fmt.printf("%d", a)
		case .EXTRAARG:
			fmt.printf("%d", ax)
		}
		fmt.print("\n")
	}
}

// Print the one-line function header (source span, instruction count, and the
// param/slot/upvalue/local/constant/function tallies) -- reference PrintHeader.
@(private = "file")
print_header :: proc(f: ^lua.Proto) {
	s := f.source != nil ? string(lua.str_slice(f.source)) : "=?"
	if len(s) > 0 && (s[0] == '@' || s[0] == '=') {
		s = s[1:] // skip the @file / =chunk marker
	} else if len(s) > 0 && s[0] == u8(lua.LUA_SIGNATURE[0]) {
		s = "(bstring)" // a binary chunk used as a source
	} else {
		s = "(string)" // an anonymous string chunk
	}
	fmt.printf(
		"\n%s <%s:%d,%d> (%d instruction%s at %p)\n",
		f.linedefined == 0 ? "main" : "function",
		s,
		f.linedefined,
		f.lastlinedefined,
		f.sizecode,
		plural(f.sizecode),
		rawptr(f),
	)
	fmt.printf(
		"%d%s param%s, %d slot%s, %d upvalue%s, ",
		int(f.numparams),
		(f.flag & (lua.PF_VAHID | lua.PF_VATAB)) != 0 ? "+" : "",
		plural(int(f.numparams)),
		int(f.maxstacksize),
		plural(int(f.maxstacksize)),
		f.sizeupvalues,
		plural(f.sizeupvalues),
	)
	fmt.printf(
		"%d local%s, %d constant%s, %d function%s\n",
		f.sizelocvars,
		plural(f.sizelocvars),
		f.sizek,
		plural(f.sizek),
		f.sizep,
		plural(f.sizep),
	)
}

// Print the debug tables (constants, locals, upvalues) -- reference PrintDebug.
// Only emitted for `-l -l` (the "full" listing).
@(private = "file")
print_debug :: proc(f: ^lua.Proto) {
	n := f.sizek
	fmt.printf("constants (%d) for %p:\n", n, rawptr(f))
	for i in 0 ..< n {
		fmt.printf("\t%d\t", i)
		print_type(f, i)
		print_constant(f, i)
		fmt.print("\n")
	}
	n = f.sizelocvars
	fmt.printf("locals (%d) for %p:\n", n, rawptr(f))
	for i in 0 ..< n {
		lv := &f.locvars[i]
		fmt.printf(
			"\t%d\t%s\t%d\t%d\n",
			i,
			string(lua.str_slice(lv.varname)),
			lv.startpc + 1,
			lv.endpc + 1,
		)
	}
	n = f.sizeupvalues
	fmt.printf("upvalues (%d) for %p:\n", n, rawptr(f))
	for i in 0 ..< n {
		uv := &f.upvalues[i]
		fmt.printf("\t%d\t%s\t%d\t%d\n", i, upvalname(f, i), int(uv.instack), int(uv.idx))
	}
}

// The top-level lister -- reference PrintFunction. Prints this prototype, then (for
// full listings) its debug tables, then recurses into every nested prototype.
list_function :: proc(L: ^lua.Lua_State, f: ^lua.Proto, full: bool) {
	print_header(f)
	print_code(L, f)
	if full {
		print_debug(f)
	}
	for i in 0 ..< f.sizep {
		list_function(L, f.p[i], full)
	}
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
