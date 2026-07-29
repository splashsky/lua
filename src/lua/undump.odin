package lua

// undump.odin -- our analogue of reference Lua's `lundump.h` / `lundump.c`.
//
// The bytecode loader: the exact inverse of `dump`. It reads a precompiled chunk
// (via ZIO), validates the header against our fixed ABI configuration --
// rejecting incompatible chunks precisely as reference Lua does -- and
// reconstructs the `Proto` tree, returning the top-level closure. Because loading
// untrusted bytecode is a real hazard, the strict validation here is a
// correctness *and* safety matter.
//
// Two faithful-porting notes:
//   1. Reference C's `int` is 32-bit; our Odin `int` is 64-bit. Counts arrive as
//      width-independent varints (fine), but the header `int` marker and every
//      `AbsLineInfo` entry are read as explicit 32-bit values to mirror the
//      dumper (see dump.odin's header comment).
//   2. Reference has a zero-copy "fixed buffer" fast path (`luaZ_getaddr`,
//      `S->fixed`) that points prototype arrays directly into a read-only image.
//      We have no such zero-copy ZIO path, so we implement copy-only semantics:
//      the `fixed` argument is accepted (the call site passes it) but the loader
//      always copies and never sets `PF_FIXED`. This is a documented, behavior-
//      preserving deviation -- `fixed` is only ever an optimization, never a
//      correctness requirement, and copying is always safe.

// The loader's running state -- reference Lua's `LoadState`. `offset` tracks the
// byte position (for alignment), `h` is the saved-string reuse table, and `nstr`
// counts strings recorded in it. `fixed` is retained for fidelity but, per the
// note above, never changes memory decisions.
LoadState :: struct {
	L:      ^Lua_State,
	Z:      ^Zio,
	name:   string, // chunk name, for error messages
	h:      ^Table, // list (int-keyed table) for string reuse
	offset: uint, // current position relative to the start of the dump
	nstr:   u64, // number of strings recorded in `h`
	fixed:  bool, // dump is a fixed (read-only) image -- accepted but unused
}

// Raise a "bad binary format" syntax error naming the chunk and the reason. Like
// reference `error`, this never returns: `throw` longjmps back to the innermost
// protected boundary (here, the protected parser that invoked us).
undump_error :: proc(S: ^LoadState, why: string) {
	luaO_pushfstring(S.L, "%s: bad binary format (%s)", S.name, why)
	throw(S.L, .Err_Syntax)
}

// Read exactly `size` bytes into `b`, or raise "truncated chunk". Reference
// `loadBlock`. `zio_read` returns the number of bytes it could NOT supply, so a
// non-zero result means the stream ran short.
load_block :: proc(S: ^LoadState, b: rawptr, size: uint) {
	if zio_read(S.Z, b, size) != 0 {
		undump_error(S, "truncated chunk")
	}
	S.offset += size
}

// Consume alignment padding so the next read starts on an `align` boundary,
// mirroring the padding the dumper inserted. Reference `loadAlign`.
load_align :: proc(S: ^LoadState, align: uint) {
	padding := align - (S.offset % align)
	if padding < align {
		pad: Integer
		load_block(S, &pad, padding)
	}
}

// Read one byte, or raise "truncated chunk". Reference `loadByte`.
load_byte :: proc(S: ^LoadState) -> Byte {
	b := zio_getc(S.Z)
	if b == EOZ {
		undump_error(S, "truncated chunk")
	}
	S.offset += 1
	return Byte(b)
}

// Read an MSB-varint unsigned integer, rejecting a value that would exceed
// `limit` (overflow protection against a hostile chunk). Reference `loadVarint`.
load_varint :: proc(S: ^LoadState, limit: u64) -> u64 {
	x: u64 = 0
	lim := limit >> 7
	for {
		b := load_byte(S)
		if x > lim {
			undump_error(S, "integer overflow")
		}
		x = (x << 7) | u64(b & 0x7f)
		if (b & 0x80) == 0 {
			break
		}
	}
	return x
}

// Read a `size_t`-shaped count. Reference `loadSize`.
load_size :: proc(S: ^LoadState) -> uint {
	return uint(load_varint(S, u64(MAX_SIZE)))
}

// Read a C-`int`-shaped count, bounded by 32-bit INT_MAX exactly as reference
// does -- so a chunk claiming an implausible count is rejected up front rather
// than driving a gigantic allocation. Reference `loadInt`.
load_int :: proc(S: ^LoadState) -> int {
	return int(load_varint(S, u64(0x7fffffff)))
}

// Read a raw `lua_Number` by its IEEE-754 bits. Reference `loadNumber`.
load_number :: proc(S: ^LoadState) -> Number {
	x: Number
	load_block(S, &x, size_of(Number))
	return x
}

// Read a zig-zag-encoded signed integer (inverse of `dump_integer`). Reference
// `loadInteger`.
load_integer :: proc(S: ^LoadState) -> Integer {
	cx := load_varint(S, max(u64))
	if (cx & 1) != 0 {
		return transmute(i64)(~(cx >> 1))
	}
	return transmute(i64)(cx >> 1)
}

// Allocate a fresh `[^]T` of `n` elements through the fallible kernel allocator,
// raising `Err_Mem` if the allocation fails. An `n` of 0 yields a nil pointer
// (an empty array needs no storage). This is our counterpart to reference
// `luaM_newvectorchecked` for the copy-only loader.
load_new_vector :: proc(L: ^Lua_State, $T: typeid, n: int) -> [^]T {
	if n == 0 {
		return nil
	}
	block := state_realloc(L, nil, 0, uint(n) * size_of(T))
	if block == nil {
		throw(L, .Err_Mem)
	}
	return cast([^]T)block
}

// Load a (nullable) string into slot `sl` of prototype `p`. The assignment and
// GC barrier must happen before any operation that could allocate (and thus
// trigger an emergency collection), so the freshly created string is anchored
// through the prototype the whole time. Reference `loadString`.
//
// Encoding (inverse of `dump_string`):
//   * size == 0 then index: reuse a previously-saved string (index 0 => NULL,
//     leaving the pre-filled slot alone).
//   * size >= 1: an inline string of real length size-1, followed by its bytes
//     including the trailing NUL; record it under the next reuse index.
load_string :: proc(S: ^LoadState, p: ^Proto, sl: ^^TString) {
	L := S.L
	ts: ^TString
	size := load_size(S)
	if size == 0 { // previously-saved string (or NULL)?
		idx := load_varint(S, max(u64))
		if idx == 0 { // NULL: the slot is already nil
			return
		}
		stv: TValue
		luaH_getint(S.h, Integer(idx), &stv)
		if base_type(&stv) != TSTRING {
			undump_error(S, "invalid string index")
		}
		ts = str_value(&stv)
		sl^ = ts
		luaC_barrier(L, obj2gco(p), obj2gco(ts))
		return // do not save it again
	} else if size - 1 <= MAXSHORTLEN { // short string?
		real := size - 1
		buff: [MAXSHORTLEN + 1]Byte // extra byte for the trailing NUL
		load_block(S, &buff[0], real + 1)
		ts = luaS_newlstr(L, &buff[0], real)
		sl^ = ts
		luaC_barrier(L, obj2gco(p), obj2gco(ts))
	} else { // long string: allocate then read directly into its buffer
		real := size - 1
		ts = luaS_createlngstrobj(L, real)
		sl^ = ts // anchor before the read (which can GC)
		luaC_barrier(L, obj2gco(p), obj2gco(ts))
		load_block(S, str_bytes(ts), real + 1) // content plus NUL, in place
	}
	// Record the newly-loaded string for future reuse references.
	S.nstr += 1
	sv: TValue
	set_string(&sv, ts)
	luaH_setint(L, S.h, Integer(S.nstr), &sv)
	luaC_barrierback(L, obj2gco(S.h))
}

// Read the bytecode. Reference `loadCode`.
load_code :: proc(S: ^LoadState, f: ^Proto) {
	n := load_int(S)
	load_align(S, size_of(Instruction))
	f.code = load_new_vector(S.L, Instruction, n)
	f.sizecode = n
	load_block(S, f.code, uint(n) * size_of(Instruction))
}

// Read the constant pool. Every pointer slot is nil-initialized first so the GC
// always sees a consistent prototype even if a later read raises. Reference
// `loadConstants`.
load_constants :: proc(S: ^LoadState, f: ^Proto) {
	n := load_int(S)
	f.k = load_new_vector(S.L, TValue, n)
	f.sizek = n
	for i in 0 ..< n {
		set_nil(&f.k[i])
	}
	for i in 0 ..< n {
		o := &f.k[i]
		t := int(load_byte(S))
		switch t {
		case VNIL:
			set_nil(o)
		case VFALSE:
			set_false(o)
		case VTRUE:
			set_true(o)
		case VNUMFLT:
			set_float(o, load_number(S))
		case VNUMINT:
			set_int(o, load_integer(S))
		case VSHRSTR, VLNGSTR:
			// Reference borrows `f.source` to anchor the string while creating
			// it, then moves it into the constant slot and clears `source`.
			assert(f.source == nil)
			load_string(S, f, &f.source)
			if f.source == nil {
				undump_error(S, "bad format for constant string")
			}
			set_string(o, f.source)
			f.source = nil
		case:
			undump_error(S, "invalid constant")
		}
	}
}

// Read the nested prototypes. Slots are nil-initialized before filling so the GC
// can scan a half-built array safely. Reference `loadProtos`.
load_protos :: proc(S: ^LoadState, f: ^Proto) {
	n := load_int(S)
	f.p = load_new_vector(S.L, ^Proto, n)
	f.sizep = n
	for i in 0 ..< n {
		f.p[i] = nil
	}
	for i in 0 ..< n {
		f.p[i] = luaF_newproto(S.L)
		luaC_barrier(S.L, obj2gco(f), obj2gco(f.p[i]))
		load_function(S, f.p[i])
	}
}

// Read the upvalue descriptors. Names are cleared first (they are filled later,
// in `load_debug`) so an emergency GC mid-load sees valid pointers. Reference
// `loadUpvalues`.
load_upvalues :: proc(S: ^LoadState, f: ^Proto) {
	n := load_int(S)
	f.upvalues = load_new_vector(S.L, Upvaldesc, n)
	f.sizeupvalues = n
	for i in 0 ..< n {
		f.upvalues[i].name = nil
	}
	for i in 0 ..< n {
		f.upvalues[i].instack = load_byte(S)
		f.upvalues[i].idx = load_byte(S)
		f.upvalues[i].kind = load_byte(S)
	}
}

// Read the debug information: line deltas, absolute-line checkpoints, local-var
// descriptors, and upvalue names. Reference `loadDebug`.
load_debug :: proc(S: ^LoadState, f: ^Proto) {
	// Per-instruction line deltas.
	n := load_int(S)
	f.lineinfo = load_new_vector(S.L, i8, n)
	f.sizelineinfo = n
	load_block(S, f.lineinfo, uint(n) * size_of(i8))
	// Absolute-line checkpoints: read each `(pc, line)` pair as two 32-bit
	// fields (the on-wire width) into our 64-bit struct fields.
	n = load_int(S)
	if n > 0 {
		load_align(S, size_of(i32))
		f.abslineinfo = load_new_vector(S.L, AbsLineInfo, n)
		f.sizeabslineinfo = n
		for i in 0 ..< n {
			pc: i32
			line: i32
			load_block(S, &pc, size_of(i32))
			load_block(S, &line, size_of(i32))
			f.abslineinfo[i].pc = int(pc)
			f.abslineinfo[i].line = int(line)
		}
	}
	// Local-variable descriptors.
	n = load_int(S)
	f.locvars = load_new_vector(S.L, LocVar, n)
	f.sizelocvars = n
	for i in 0 ..< n {
		f.locvars[i].varname = nil
	}
	for i in 0 ..< n {
		load_string(S, f, &f.locvars[i].varname)
		f.locvars[i].startpc = load_int(S)
		f.locvars[i].endpc = load_int(S)
	}
	// Upvalue names. A stripped chunk writes 0 here; a present-but-nonzero count
	// is treated purely as a "has debug info" marker, and there must be exactly
	// `sizeupvalues` names. Reference `loadDebug`.
	n = load_int(S)
	if n != 0 {
		n = f.sizeupvalues
	}
	for i in 0 ..< n {
		load_string(S, f, &f.upvalues[i].name)
	}
}

// Read one function prototype. The field order must exactly match
// `dump_function`. Reference `loadFunction`. Per the copy-only design we mask off
// `PF_FIXED` from the loaded flag and never set it.
load_function :: proc(S: ^LoadState, f: ^Proto) {
	f.linedefined = load_int(S)
	f.lastlinedefined = load_int(S)
	f.numparams = load_byte(S)
	f.flag = load_byte(S) & ~Byte(PF_FIXED) // keep only the meaningful flags
	f.maxstacksize = load_byte(S)
	load_code(S, f)
	load_constants(S, f)
	load_upvalues(S, f)
	load_protos(S, f)
	load_string(S, f, &f.source)
	load_debug(S, f)
}

// Read `len(s)` bytes and confirm they equal `s`, else raise `msg`. Used for the
// signature and data-marker literals. Reference `checkliteral`.
check_literal :: proc(S: ^LoadState, s: string, msg: string) {
	buff: [16]Byte // larger than both LUA_SIGNATURE and LUAC_DATA
	load_block(S, &buff[0], uint(len(s)))
	for i in 0 ..< len(s) {
		if buff[i] != s[i] {
			undump_error(S, msg)
			return
		}
	}
}

// Raise a "<type> <what> mismatch" error for a numeric-format check. Reference
// `numerror`.
num_error :: proc(S: ^LoadState, what: string, tname: string) {
	ts := luaO_pushfstring(S.L, "%s %s mismatch", tname, what)
	undump_error(S, string(str_slice(ts)))
}

// Confirm the size byte and sentinel value of one number marker match this
// build's `T` and `expected`. Reference `checknum` (with `checknumsize` /
// `checknumformat`).
check_num :: proc(S: ^LoadState, expected: $T, tname: string) {
	if int(load_byte(S)) != size_of(T) {
		num_error(S, "size", tname)
	}
	v: T
	load_block(S, &v, size_of(T))
	if v != expected {
		num_error(S, "format", tname)
	}
}

// Validate the chunk header against our ABI configuration. Reference
// `checkHeader`. The first signature byte was already consumed by the parser
// (that is what routed us here), so we check `LUA_SIGNATURE[1:]`.
check_header :: proc(S: ^LoadState) {
	check_literal(S, LUA_SIGNATURE[1:], "not a binary chunk")
	if load_byte(S) != LUAC_VERSION {
		undump_error(S, "version mismatch")
	}
	if load_byte(S) != LUAC_FORMAT {
		undump_error(S, "format mismatch")
	}
	check_literal(S, LUAC_DATA, "corrupted chunk")
	check_num(S, i32(LUAC_INT), "int") // C int marker: 4 bytes
	check_num(S, Instruction(LUAC_INST), "instruction")
	check_num(S, Integer(LUAC_INT), "Lua integer")
	check_num(S, Number(LUAC_NUM), "Lua number")
}

// luaU_undump reconstructs a `Proto` tree from a precompiled chunk read through
// `z`, returning the top-level closure -- reference Lua's `luaU_undump`. `fixed`
// is accepted for interface fidelity but, per this file's header note, does not
// change the copy-only loading behavior.
//
// The closure and the saved-string table are both anchored on the stack during
// the load (so an emergency GC can never reclaim work in progress); the table is
// popped before returning, leaving the closure on top exactly as reference does.
luaU_undump :: proc(L: ^Lua_State, z: ^Zio, name: string, fixed: bool) -> ^LClosure {
	S: LoadState
	// Normalize the chunk name for error messages, mirroring reference.
	nm := name
	if len(nm) > 0 {
		if nm[0] == '@' || nm[0] == '=' {
			nm = nm[1:]
		} else if nm[0] == LUA_SIGNATURE[0] {
			nm = "binary string"
		}
	}
	S.name = nm
	S.L = L
	S.Z = z
	S.fixed = fixed
	S.offset = 1 // the first byte was already read by the parser
	check_header(&S)
	cl := luaF_newLclosure(L, int(load_byte(&S)))
	set_gc(stack_value(L, L.top), obj2gco(cl)) // anchor the closure
	inc_top(L)
	S.h = luaH_new(L) // create the saved-string list
	S.nstr = 0
	set_gc(stack_value(L, L.top), obj2gco(S.h)) // anchor it too
	inc_top(L)
	cl.p = luaF_newproto(L)
	luaC_barrier(L, obj2gco(cl), obj2gco(cl.p))
	load_function(&S, cl.p)
	if int(cl.nupvalues) != cl.p.sizeupvalues {
		undump_error(&S, "corrupted chunk")
	}
	L.top -= 1 // pop the saved-string table; leave the closure on top
	return cl
}
