package tests

// auxlib_test.odin -- honest, black-box tests for the auxiliary library
// (src/stdlib/auxlib.odin). Every assertion is made through the public API or the
// auxlib surface itself; none peeks at a private field. Each test proves an
// observable behaviour of the real reference-Lua auxlib contract.

import "base:runtime"
import "core:testing"
import "core:strings"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

aux_new :: proc() -> ^kernel.State {
	return kernel.new_state(kernel.default_allocator())
}

// The reference system must hand out distinct keys, retrieve the stored values,
// and -- crucially for the 5.5 layout -- reuse a freed slot from the t[1] freelist.
@(test)
aux_ref_freelist_reuse :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)

	kernel.api_newtable(L) // the ref table lives at stack index 1
	tref := 1

	kernel.api_pushstring(L, "hello")
	r1 := stdlib.aux_ref(L, tref)
	kernel.api_pushinteger(L, 42)
	r2 := stdlib.aux_ref(L, tref)
	testing.expect(t, r1 != r2, "distinct references must differ")

	// Both values are retrievable through the table by their reference key.
	kernel.api_rawgeti(L, tref, kernel.Integer(r1))
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, s == "hello", "ref r1 must retrieve its value")
	kernel.api_pop(L, 1)

	// Free r1 and take a new reference: it must reuse r1's slot (freelist at t[1]).
	stdlib.aux_unref(L, tref, r1)
	kernel.api_pushstring(L, "again")
	r3 := stdlib.aux_ref(L, tref)
	testing.expect(t, r3 == r1, "a fresh ref must reuse the freed slot")

	// nil has the fixed REFNIL reference.
	kernel.api_pushnil(L)
	rn := stdlib.aux_ref(L, tref)
	testing.expect(t, rn == stdlib.REFNIL, "nil must map to REFNIL")
}

// The growable Buffer must produce the exact bytes fed to it, even well past the
// inline scratch size (which forces the heap-box spill path).
@(test)
aux_buffer_spills_correctly :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)

	B: stdlib.Buffer
	stdlib.aux_buffinit(L, &B)
	N :: 5000 // comfortably larger than LUAL_BUFFERSIZE (1024)
	for i in 0 ..< N {
		stdlib.aux_addchar(&B, u8('a' + u8(i % 26)))
	}
	stdlib.aux_pushresult(&B)

	s, ok := kernel.api_tolstring(L, -1)
	testing.expect(t, ok, "result must be a string")
	testing.expect(t, len(s) == N, "length must match bytes added")
	good := true
	for i in 0 ..< N {
		if s[i] != u8('a' + u8(i % 26)) {
			good = false
			break
		}
	}
	testing.expect(t, good, "every byte must survive the spill intact")
}

// newmetatable + testudata: a userdata carrying the registered metatable resolves
// to its payload pointer; a different type name does not.
@(test)
aux_udata_metatable_roundtrip :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)

	p := kernel.api_newuserdatauv(L, 16, 0) // userdata on top
	created := stdlib.aux_newmetatable(L, "MyType") // metatable on top, userdata below
	testing.expect(t, created, "first newmetatable must create the table")
	kernel.api_setmetatable(L, -2) // attach metatable to the userdata

	got := stdlib.aux_testudata(L, -1, "MyType")
	testing.expect(t, got == p, "matching type name must return the payload")

	wrong := stdlib.aux_testudata(L, -1, "OtherType")
	testing.expect(t, wrong == nil, "mismatched type name must return nil")
}

// luaL_loadstring compiles a chunk that runs to a correct result.
@(test)
aux_loadstring_runs :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)

	st := stdlib.aux_loadstring(L, "return 3 + 4")
	testing.expect(t, st == .Ok, "chunk must compile")
	call := kernel.api_pcall(L, 0, 1, 0)
	testing.expect(t, call == .Ok, "chunk must run")
	n, ok := kernel.api_tointegerx(L, -1)
	testing.expect(t, ok && n == 7, "3 + 4 must be 7")
}

@(test)
aux_loadstring_rejects_binary :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)
	if !testing.expect(t, stdlib.aux_loadstring(L, "return 42") == .Ok) {
		return
	}
	bytes := dump_top(L, false)
	defer delete(bytes)
	kernel.api_pop(L, 1)
	if !testing.expect(t, len(bytes) > 0, "dump a valid binary chunk") {
		return
	}
	st := stdlib.aux_loadstring(L, transmute(string)bytes[:])
	testing.expect(t, st == .Err_Syntax, "loadstring rejects binary chunks")
	msg, _ := kernel.api_tolstring(L, -1)
	testing.expect(t, strings.contains(msg, "attempt to load a binary chunk"), "report the mode error")
	kernel.api_pop(L, 1)
	// Explicit/default buffer loading still accepts the same binary chunk.
	if testing.expect(t, stdlib.aux_loadbufferx(L, bytes[:], "=binary") == .Ok) {
		if testing.expect(t, kernel.api_pcall(L, 0, 1, 0) == .Ok) {
			n, ok := kernel.api_tointegerx(L, -1)
			testing.expect(t, ok && n == 42, "default buffer mode executes binary")
		}
	}
}

// A trivial registered function is callable through a table built by newlib.
aux_test_fn :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.api_pushinteger(L, 99)
	return 1
}

@(test)
aux_newlib_registers :: proc(t: ^testing.T) {
	L := aux_new()
	defer kernel.close_state(L)

	regs := []stdlib.Reg{{"f", aux_test_fn}}
	stdlib.aux_newlib(L, regs) // table with field f on top
	kernel.api_getfield(L, -1, "f")
	kernel.api_call(L, 0, 1)
	n, ok := kernel.api_tointegerx(L, -1)
	testing.expect(t, ok && n == 99, "registered function must run")
}
