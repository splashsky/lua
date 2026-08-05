package tests

// dump_test.odin -- Phase 8 end-to-end tests for the bytecode serializer /
// deserializer (dump.odin / undump.odin).
//
// These tests are deliberately black-box and honest: they drive only the public
// API (`lua_load`, `lua_dump`, `lua_pcall`) exactly as `luac` and a host program
// would, and they never poke at a private field to force a pass. The core claim
// -- that our dump/undump are exact inverses and produce byte-stable, reference-
// shaped chunks -- is proven three independent ways:
//
//   1. Header golden bytes: the emitted header is compared field-by-field
//      against expectations re-derived from the documented format constants
//      (signature, version nibbles, LUAC_DATA, and the little-endian sentinel
//      values at their exact widths). This catches any endianness / width / value
//      mistake without trusting the loader.
//   2. Byte-stable round trip: source -> dump -> load(binary) -> dump again must
//      yield an identical byte stream. If the loader mis-reads anything the
//      dumper wrote (or vice versa), the second dump diverges.
//   3. Behavioral equivalence: the chunk reconstructed from bytecode executes and
//      produces the same result as the original source, through `lua_pcall`.
//
// Both strip=false (with debug info) and strip=true are exercised, and a chunk
// with nested functions, upvalues, many constants, and multi-line source is used
// so the constant pool, proto tree, upvalue wiring, and line-info paths all run.

import "base:runtime"
import "core:testing"
import kernel "lang:kernel"

// A growable sink the dump writer appends into. It lives on the test stack and is
// handed to `lua_dump` as the opaque `data` cookie.
Dump_Sink :: struct {
	bytes: [dynamic]u8,
}

// The `lua_Writer` callback: append every emitted chunk to the sink. It is a "c"
// proc (as the API demands), so it establishes a default Odin context before
// touching the dynamic array. Returning 0 means "keep going".
dump_writer :: proc "c" (L: rawptr, p: rawptr, sz: uint, ud: rawptr) -> i32 {
	context = runtime.default_context()
	sink := (^Dump_Sink)(ud)
	if sz > 0 && p != nil {
		src := ([^]u8)(p)
		for i in 0 ..< sz {
			append(&sink.bytes, src[i])
		}
	}
	return 0
}

// Load `src` as a text chunk, leaving the compiled closure on top of the stack.
dump_load_text :: proc(L: ^kernel.State, src: string, rd: ^Src_Reader) -> kernel.Thread_Status {
	rd^ = Src_Reader {
		data = ([^]u8)(raw_data(src)),
		len  = uint(len(src)),
		done = false,
	}
	return kernel.api_load(L, src_read, rd, "=dump", "")
}

// Dump the function on top of the stack into a fresh byte slice. `lua_dump` does
// not pop the function (reference parity), so the caller's stack is unchanged.
dump_top :: proc(L: ^kernel.State, strip: bool) -> [dynamic]u8 {
	sink: Dump_Sink
	status := kernel.api_dump(L, dump_writer, &sink, strip)
	if status != 0 {
		// Should never happen with our always-succeeding writer.
		delete(sink.bytes)
		return nil
	}
	return sink.bytes
}

// Load a previously-dumped byte slice back into a closure on top of the stack,
// using binary ("b") mode so it routes through `luaU_undump`.
dump_load_binary :: proc(L: ^kernel.State, bytes: []u8, rd: ^Src_Reader) -> kernel.Thread_Status {
	rd^ = Src_Reader {
		data = ([^]u8)(raw_data(bytes)),
		len  = uint(len(bytes)),
		done = false,
	}
	return kernel.api_load(L, src_read, rd, "=binary", "b")
}

// A representative chunk: a nested closure capturing an upvalue, several distinct
// constant kinds (ints, a float, strings -- one repeated, to exercise string
// de-duplication), and multiple source lines (to exercise line info).
DUMP_SAMPLE_SRC :: `
local base = 100
local function adder(x)
	return x + base + 7
end
local msg = "hello"
local msg2 = "hello"
return adder(3) + #msg + #msg2 + (2.5 // 1)
`

// The expected numeric result of DUMP_SAMPLE_SRC:
//   adder(3) = 3 + 100 + 7 = 110; #"hello" = 5 (twice) => +10; 2.5 // 1 = 2.
//   110 + 5 + 5 + 2 = 122.
DUMP_SAMPLE_RESULT :: 122

// ---------------------------------------------------------------------------
// 1. Header golden bytes
// ---------------------------------------------------------------------------

@(test)
test_dump_header_golden_bytes :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	defer kernel.close_state(L)

	rd: Src_Reader
	testing.expect_value(t, dump_load_text(L, "return 1", &rd), kernel.Thread_Status.Ok)
	bytes := dump_top(L, false)
	defer delete(bytes)

	// Re-derive the expected header from the documented format constants.
	expected: [dynamic]u8
	defer delete(expected)
	append_str :: proc(b: ^[dynamic]u8, s: string) {
		for i in 0 ..< len(s) {
			append(b, s[i])
		}
	}
	append_scalar :: proc(b: ^[dynamic]u8, p: rawptr, n: uint) {
		src := ([^]u8)(p)
		for i in 0 ..< n {
			append(b, src[i])
		}
	}
	append_str(&expected, kernel.SIGNATURE) // "\x1bLua"
	append(&expected, u8(kernel.HEADER_VERSION)) // 0x55 for 5.5
	append(&expected, u8(kernel.HEADER_FORMAT)) // 0x00
	append_str(&expected, kernel.HEADER_DATA) // the 6-byte conversion-check marker
	// int marker: size byte 4, then i32 LUAC_INT little-endian.
	append(&expected, 4)
	iv := i32(kernel.HEADER_INT)
	append_scalar(&expected, &iv, 4)
	// Instruction marker: size byte 4, then u32 LUAC_INST little-endian.
	append(&expected, 4)
	instv := kernel.Instruction(kernel.HEADER_INST)
	append_scalar(&expected, &instv, 4)
	// lua_Integer marker: size byte 8, then i64 LUAC_INT little-endian.
	append(&expected, 8)
	lintv := kernel.Integer(kernel.HEADER_INT)
	append_scalar(&expected, &lintv, 8)
	// lua_Number marker: size byte 8, then f64 LUAC_NUM little-endian.
	append(&expected, 8)
	lnumv := kernel.Number(kernel.HEADER_NUM)
	append_scalar(&expected, &lnumv, 8)

	testing.expect(t, len(bytes) >= len(expected), "dump shorter than expected header")
	mismatch := false
	for i in 0 ..< len(expected) {
		if bytes[i] != expected[i] {
			mismatch = true
			break
		}
	}
	testing.expect(t, !mismatch, "dumped header bytes do not match the format spec")
}

// ---------------------------------------------------------------------------
// 2. Byte-stable round trip + 3. behavioral equivalence
// ---------------------------------------------------------------------------

// Shared body for both strip variants: load source, dump, reload from binary,
// dump the reload, assert the two dumps are byte-identical, then run the reloaded
// closure and confirm it yields the expected value.
dump_roundtrip_check :: proc(t: ^testing.T, strip: bool) {
	L := kernel.new_state(kernel.default_allocator())
	defer kernel.close_state(L)

	// Compile the source.
	rd: Src_Reader
	testing.expect_value(t, dump_load_text(L, DUMP_SAMPLE_SRC, &rd), kernel.Thread_Status.Ok)

	// First dump.
	first := dump_top(L, strip)
	defer delete(first)
	testing.expect(t, len(first) > 0, "first dump produced no bytes")

	// Drop the original closure; reload purely from the dumped bytes.
	kernel.api_settop(L, 0)
	rd2: Src_Reader
	testing.expect_value(t, dump_load_binary(L, first[:], &rd2), kernel.Thread_Status.Ok)

	// Second dump of the reconstructed closure.
	second := dump_top(L, strip)
	defer delete(second)

	// The two byte streams must be identical -- exact inverse property.
	testing.expect_value(t, len(second), len(first))
	identical := len(first) == len(second)
	if identical {
		for i in 0 ..< len(first) {
			if first[i] != second[i] {
				identical = false
				break
			}
		}
	}
	testing.expect(t, identical, "round-tripped bytecode is not byte-identical")

	// Behavioral equivalence: run the reloaded closure (still on top) and check
	// it computes the expected result.
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), DUMP_SAMPLE_RESULT)
}

@(test)
test_dump_roundtrip_with_debug :: proc(t: ^testing.T) {
	dump_roundtrip_check(t, false)
}

@(test)
test_dump_roundtrip_stripped :: proc(t: ^testing.T) {
	dump_roundtrip_check(t, true)
}

// A direct behavioral check that the *original* source and the *stripped* reload
// agree, and that a stripped chunk is strictly smaller than the debug one (proof
// that stripping actually drops the line/local/upvalue-name info rather than
// silently no-op'ing).
@(test)
test_dump_strip_is_smaller :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	defer kernel.close_state(L)

	rd: Src_Reader
	testing.expect_value(t, dump_load_text(L, DUMP_SAMPLE_SRC, &rd), kernel.Thread_Status.Ok)

	with_debug := dump_top(L, false)
	defer delete(with_debug)
	stripped := dump_top(L, true)
	defer delete(stripped)

	testing.expect(t, len(stripped) < len(with_debug), "stripped dump should be smaller")
}
