package lua

// dump.odin -- our analogue of reference Lua's `ldump.c`.
//
// The bytecode serializer: it turns a compiled `Proto` (with its nested protos,
// constants, upvalues, and optionally-stripped debug info) into the precompiled
// chunk byte stream that `luac` writes and that `undump` reads back.
//
// Byte-exactness is a project goal, so this targets one fixed ABI configuration
// -- little-endian, 32-bit `Instruction`, 32-bit C `int`, 64-bit `lua_Integer`,
// IEEE-754 binary64 `lua_Number` -- and serializes the C-defined layout
// *explicitly*, preserving floating-point bit patterns rather than re-encoding
// numerically (see docs/ARCHITECTURE.md, Decision 6).
//
// A subtle but load-bearing wrinkle: reference C's `int` is 32-bit while our
// Odin `int` is 64-bit. Counts and small integers travel as width-independent
// MSB varints (`dumpInt`), so they are immune. But two places emit a *raw*
// C-`int`-shaped value and MUST be pinned to 32 bits to match reference bytes:
//   1. the header's `int` marker (`LUAC_INT` written as an `i32`), and
//   2. every `AbsLineInfo` entry (reference `struct { int pc; int line; }` is
//      two 32-bit fields; our struct holds two 64-bit fields, so we serialize
//      each field as an `i32` by hand instead of block-copying the struct).
// Both are handled below with explicit `i32` casts.

// The sink a `lua_dump` caller supplies -- reference Lua's `lua_Writer`. It is
// handed each chunk of serialized bytes and returns 0 on success or a non-zero
// status to abort the dump. It is a `"c"` proc so it can be a host callback; the
// callback is responsible for establishing its own Odin `context` if it needs one.
Writer :: #type proc "c" (L: rawptr, p: rawptr, sz: uint, ud: rawptr) -> i32

// Header constants, matching `lundump.h` exactly.
//
// `LUAC_VERSION` packs the major/minor version into one byte, one nibble each:
// 5*16 + 5 == 0x55 == 85 for Lua 5.5.
HEADER_VERSION :: VERSION_MAJOR_N * 16 + VERSION_MINOR_N
HEADER_FORMAT :: 0 // the official format id
// The "data" signature: catches naive text-mode / endianness corruption. Bytes
// are 0x19 0x93 '\r' '\n' 0x1a '\n'.
HEADER_DATA :: "\x19\x93\r\n\x1a\n"
HEADER_INT :: -0x5678 // sentinel integer, catches integer-format mismatch
HEADER_INST :: 0x12345678 // sentinel instruction, catches endianness
HEADER_NUM :: -370.5 // sentinel float, catches float-format mismatch

// The number of bytes a 64-bit unsigned can occupy in the MSB varint encoding:
// each byte carries 7 payload bits, so (64 + 6) / 7 == 10. Reference `DIBS`.
DIBS :: (64 + 6) / 7

// The dumper's running state -- reference Lua's `DumpState`. `offset` tracks the
// number of bytes emitted so far (needed to compute alignment padding); `status`
// latches the first writer error and suppresses all further output; `h` is an
// auxiliary table mapping already-dumped strings to their 1-based reuse index,
// and `nstr` counts how many strings have been saved into it.
DumpState :: struct {
	L:      ^State,
	writer: Writer,
	data:   rawptr, // opaque cookie handed back to the writer
	offset: uint, // current position relative to the start of the dump
	strip:  bool, // drop debug info?
	status: i32, // first non-zero writer status latches here
	h:      ^Table, // table tracking saved strings (for de-duplication)
	nstr:   u64, // counter for saved-string indices
}

// Emit a raw block of `size` bytes from `b`. Once a writer has reported an error
// we stop writing entirely (mirroring reference), but we still keep the byte
// count consistent for callers. `b` may be nil only for the final zero-length
// "end of dump" signal. Reference `dumpBlock`.
dump_block :: proc(D: ^DumpState, b: rawptr, size: uint) {
	if D.status == 0 {
		D.status = D.writer(rawptr(D.L), b, size, D.data)
		D.offset += size
	}
}

// Emit a single value `v` by copying its raw bytes. Because we target
// little-endian with the reference numeric formats, a raw copy *is* the wire
// format. Reference `dumpVar` (via `dumpVector`).
dump_var :: proc(D: ^DumpState, v: $T) {
	x := v
	dump_block(D, &x, size_of(T))
}

// Emit the bytes of a compile-time string literal (the signature / data marker),
// without any length prefix. Reference `dumpLiteral`.
dump_literal :: proc(D: ^DumpState, s: string) {
	dump_block(D, raw_data(s), uint(len(s)))
}

// Pad with zero bytes until `offset` is a multiple of `align`. Reference
// `dumpAlign`. `align` never exceeds 8 (size of `lua_Integer`), so a single
// zeroed integer supplies enough padding.
dump_align :: proc(D: ^DumpState, align: uint) {
	padding := align - (D.offset % align)
	if padding < align { // padding == align means we're already aligned
		pad: Integer = 0
		dump_block(D, &pad, padding)
	}
}

// Emit one byte. Reference `dumpByte`.
dump_byte :: proc(D: ^DumpState, y: int) {
	x := Byte(y)
	dump_block(D, &x, 1)
}

// Emit an unsigned integer in the MSB varint encoding: 7 payload bits per byte,
// most-significant group first, with the high bit of every byte except the last
// set as a "more bytes follow" flag. Reference `dumpVarint`.
dump_varint :: proc(D: ^DumpState, x0: u64) {
	buff: [DIBS]Byte
	x := x0
	n: uint = 1
	buff[DIBS - 1] = Byte(x & 0x7f) // least-significant group last
	for {
		x >>= 7
		if x == 0 {
			break
		}
		n += 1
		buff[DIBS - n] = Byte((x & 0x7f) | 0x80) // earlier groups, flagged
	}
	dump_block(D, &buff[DIBS - n], n)
}

// Emit a `size_t`-shaped count. Reference `dumpSize`.
dump_size :: proc(D: ^DumpState, sz: uint) {
	dump_varint(D, u64(sz))
}

// Emit a non-negative C-`int`-shaped count. Reference `dumpInt`. The value is
// width-independent on the wire (a varint), so our 64-bit `int` is fine here as
// long as it is non-negative -- which every prototype count is.
dump_int :: proc(D: ^DumpState, x: int) {
	assert(x >= 0)
	dump_varint(D, u64(x))
}

// Emit a `lua_Number` by its raw IEEE-754 bits. Reference `dumpNumber`.
dump_number :: proc(D: ^DumpState, x: Number) {
	dump_var(D, x)
}

// Emit a signed integer with a zig-zag varint so that small-magnitude values
// (very common, e.g. -1) stay short: a non-negative x becomes 2x, a negative x
// becomes -2x - 1. Reference `dumpInteger`.
dump_integer :: proc(D: ^DumpState, x: Integer) {
	cx: u64
	if x >= 0 {
		cx = 2 * transmute(u64)x
	} else {
		cx = 2 * (~transmute(u64)x) + 1
	}
	dump_varint(D, cx)
}

// Emit a (nullable) string, with de-duplication. The encoding:
//   * size == 0 followed by an index means "reuse the previously-saved string
//     with that 1-based index"; index 0 specifically means NULL.
//   * size >= 1 means an inline string whose real length is size-1; its bytes
//     follow, including the trailing '\0' (so `size` is length+1). The string is
//     then recorded under the next reuse index.
// Reference `dumpString`.
dump_string :: proc(D: ^DumpState, ts: ^TString) {
	if ts == nil {
		dump_varint(D, 0) // "reuse" ...
		dump_varint(D, 0) // ... the special NULL index
		return
	}
	// Have we dumped this exact string object already?
	idx: TValue
	table_getstr(D.h, ts, &idx)
	if !is_nil(&idx) {
		dump_varint(D, 0) // reuse a saved string ...
		dump_varint(D, u64(int_value(&idx))) // ... at this index
		return
	}
	// First time: write the contents (with the terminating NUL) and remember it.
	size := ts.len
	dump_size(D, size + 1)
	dump_block(D, str_bytes(ts), size + 1) // str_bytes[len] is the NUL
	D.nstr += 1
	key: TValue
	value: TValue
	set_string(&key, ts)
	set_int(&value, Integer(D.nstr))
	table_set(D.L, D.h, &key, &value) // h[ts] = nstr; integer value needs no barrier
}

// Emit the bytecode: a count, alignment padding, then the raw instruction words.
// Reference `dumpCode`.
dump_code :: proc(D: ^DumpState, f: ^Proto) {
	dump_int(D, f.sizecode)
	dump_align(D, size_of(Instruction))
	dump_block(D, f.code, uint(f.sizecode) * size_of(Instruction))
}

// Emit the constant pool. Each constant is a type tag byte followed by its
// payload (nothing for nil/false/true). Reference `dumpConstants`.
dump_constants :: proc(D: ^DumpState, f: ^Proto) {
	n := f.sizek
	dump_int(D, n)
	for i in 0 ..< n {
		o := &f.k[i]
		tt := type_tag(o)
		dump_byte(D, int(tt))
		switch tt {
		case VNUMFLT:
			dump_number(D, flt_value(o))
		case VNUMINT:
			dump_integer(D, int_value(o))
		case VSHRSTR, VLNGSTR:
			dump_string(D, str_value(o))
		case:
			// nil / false / true carry no payload; nothing more to write.
			assert(tt == VNIL || tt == VFALSE || tt == VTRUE)
		}
	}
}

// Emit the nested prototypes, recursively. Reference `dumpProtos`.
dump_protos :: proc(D: ^DumpState, f: ^Proto) {
	n := f.sizep
	dump_int(D, n)
	for i in 0 ..< n {
		dump_function(D, f.p[i])
	}
}

// Emit the upvalue descriptors (their capture wiring, not their names -- names
// are debug info handled in `dump_debug`). Reference `dumpUpvalues`.
dump_upvalues :: proc(D: ^DumpState, f: ^Proto) {
	n := f.sizeupvalues
	dump_int(D, n)
	for i in 0 ..< n {
		dump_byte(D, int(f.upvalues[i].instack))
		dump_byte(D, int(f.upvalues[i].idx))
		dump_byte(D, int(f.upvalues[i].kind))
	}
}

// Emit the debug information (all of which is suppressed when `strip` is set):
// line deltas, absolute-line checkpoints, local-variable descriptors, and
// upvalue names. Reference `dumpDebug`.
dump_debug :: proc(D: ^DumpState, f: ^Proto) {
	// Per-instruction line deltas (`ls_byte`).
	n := f.sizelineinfo if !D.strip else 0
	dump_int(D, n)
	if f.lineinfo != nil {
		dump_block(D, f.lineinfo, uint(n) * size_of(i8))
	}
	// Absolute-line checkpoints. Reference stores `struct { int pc; int line; }`
	// (two 32-bit fields). Our `AbsLineInfo` holds two 64-bit fields, so we must
	// NOT block-copy it; we serialize each field explicitly as an `i32`.
	n = f.sizeabslineinfo if !D.strip else 0
	dump_int(D, n)
	if n > 0 {
		dump_align(D, size_of(i32)) // reference aligns to sizeof(int) == 4
		for i in 0 ..< n {
			dump_var(D, i32(f.abslineinfo[i].pc))
			dump_var(D, i32(f.abslineinfo[i].line))
		}
	}
	// Local-variable descriptors.
	n = f.sizelocvars if !D.strip else 0
	dump_int(D, n)
	for i in 0 ..< n {
		dump_string(D, f.locvars[i].varname)
		dump_int(D, f.locvars[i].startpc)
		dump_int(D, f.locvars[i].endpc)
	}
	// Upvalue names.
	n = f.sizeupvalues if !D.strip else 0
	dump_int(D, n)
	for i in 0 ..< n {
		dump_string(D, f.upvalues[i].name)
	}
}

// Emit one function prototype: its fixed header fields, then code, constants,
// upvalue wiring, nested protos, source name (dropped when stripping), and debug
// info. The field order is load-bearing -- it must exactly match `loadFunction`.
// Reference `dumpFunction`.
dump_function :: proc(D: ^DumpState, f: ^Proto) {
	dump_int(D, f.linedefined)
	dump_int(D, f.lastlinedefined)
	dump_byte(D, int(f.numparams))
	dump_byte(D, int(f.flag))
	dump_byte(D, int(f.maxstacksize))
	dump_code(D, f)
	dump_constants(D, f)
	dump_upvalues(D, f)
	dump_protos(D, f)
	dump_string(D, nil if D.strip else f.source)
	dump_debug(D, f)
}

// Emit one number "marker": a size byte followed by a sentinel value of that
// exact width. The loader re-reads these to confirm the chunk's numeric formats
// match this build's. Reference `dumpNumInfo`. We take the value pre-cast to the
// right width so the raw copy emits exactly `size_of(T)` bytes.
dump_num_info :: proc(D: ^DumpState, v: $T) {
	dump_byte(D, size_of(T))
	dump_var(D, v)
}

// Emit the chunk header. Reference `dumpHeader`.
//
// The `int` marker deliberately uses `i32` (not our 64-bit `int`): reference C's
// `int` is 32-bit, so a byte-faithful header must write size 4 and a 4-byte
// value. The `lua_Integer` marker below uses the same sentinel value at 8 bytes.
dump_header :: proc(D: ^DumpState) {
	dump_literal(D, SIGNATURE)
	dump_byte(D, HEADER_VERSION)
	dump_byte(D, HEADER_FORMAT)
	dump_literal(D, HEADER_DATA)
	dump_num_info(D, i32(HEADER_INT)) // C int marker: 4 bytes
	dump_num_info(D, Instruction(HEADER_INST)) // Instruction marker: 4 bytes
	dump_num_info(D, Integer(HEADER_INT)) // lua_Integer marker: 8 bytes
	dump_num_info(D, Number(HEADER_NUM)) // lua_Number marker: 8 bytes
}

// luaU_dump serializes prototype `f` (and everything it references) through the
// `writer` sink -- reference Lua's `luaU_dump`. `strip` drops debug info. Returns
// the writer's last status (0 == success).
//
// It anchors an auxiliary de-duplication table on the stack and, exactly like
// reference, leaves that slot in place on return: the caller (reference's
// `lua_dump`) is responsible for restoring `L.top`. We keep that contract so the
// emitted bytes -- and the stack discipline -- match reference precisely.
dump_chunk :: proc(L: ^State, f: ^Proto, writer: Writer, data: rawptr, strip: bool) -> i32 {
	D: DumpState
	D.h = table_new(L) // aux. table tracking strings already dumped
	set_gc(stack_value(L, L.top), obj2gco(D.h)) // anchor it against GC
	inc_top(L)
	D.L = L
	D.writer = writer
	D.data = data
	D.offset = 0
	D.strip = strip
	D.status = 0
	D.nstr = 0
	dump_header(&D)
	dump_byte(&D, f.sizeupvalues) // top-level closure's upvalue count
	dump_function(&D, f)
	dump_block(&D, nil, 0) // signal end of dump
	return D.status
}
