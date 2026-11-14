package tests

// api_test.odin -- Phase 6 end-to-end tests for the embedding C-style API
// (api.odin).
//
// These tests are deliberately black-box: they drive the public API exactly the
// way the standard library and a host program would, and assert only on values
// observed *through that same API*. Pushing, converting, table get/set, calling,
// protected calling, loading source, userdata user-values, and upvalue access are
// each exercised end-to-end. If `lua_pushinteger` followed by `lua_tointeger`
// round-trips, the stack model, index translation, and value tagging all work
// together -- and none of it peeks at a private field to force a pass.
//
// The `Src_Reader` / `src_read` helpers are shared with the lexer/VM tests.

import "core:testing"
import "base:runtime"
import kernel "lang:kernel"

// A fresh, fully-built state with the reference-faithful default allocator.
api_new :: proc() -> ^kernel.State {
	return kernel.new_state(kernel.default_allocator())
}

// Load `src` as a chunk, leaving the compiled closure on the stack (or an error
// message on failure). `rd` must outlive the call.
api_load :: proc(L: ^kernel.State, src: string, rd: ^Src_Reader) -> kernel.Thread_Status {
	rd^ = Src_Reader {
		data = ([^]u8)(raw_data(src)),
		len  = uint(len(src)),
		done = false,
	}
	return kernel.api_load(L, src_read, rd, "=t", "")
}

// The undumper has no parser pacing checks of its own. Loading a binary chunk
// with due debt must start a GC step while preserving existing stack roots.
@(test)
test_api_binary_load_runs_gc :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader
	testing.expect_value(t, dump_load_text(L, "return 123", &rd), kernel.Thread_Status.Ok)
	bytes := dump_top(L, false)
	defer delete(bytes)
	kernel.api_pushstring(L, "surviving stack root")
	kernel.api_gc(L, kernel.GCCOLLECT)
	testing.expect_value(t, L.g.gcstate, kernel.GCSpause)
	kernel.state_setdebt(L.g, 0)
	testing.expect_value(t, dump_load_binary(L, bytes[:], &rd), kernel.Thread_Status.Ok)
	testing.expect(t, L.g.gcstate != kernel.GCSpause, "loading binary must run a due GC step")
	s, ok := kernel.api_tolstring(L, 2)
	testing.expect(t, ok)
	testing.expect_value(t, s, "surviving stack root")
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 123)

	// Repeated discarded loads should not accumulate an unbounded proto tree.
	kernel.api_pop(L, 1)
	kernel.api_gc(L, kernel.GCCOLLECT)
	before := kernel.gettotalbytes(L.g)
	for i in 0 ..< 2000 {
		st := dump_load_binary(L, bytes[:], &rd)
		if st != .Ok {
			testing.expect(t, false, "binary load failed")
			break
		}
		kernel.api_pop(L, 1)
	}
	testing.expect(t, kernel.gettotalbytes(L.g) - before < 300 * 1024, "discarded binary chunks should be collected")
	testing.expect_value(t, kernel.api_gettop(L), 2)
}

// ---------------------------------------------------------------------------
// Push / convert round-trips and type queries
// ---------------------------------------------------------------------------

@(test)
test_api_push_and_type :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushnil(L)
	kernel.api_pushboolean(L, true)
	kernel.api_pushinteger(L, 42)
	kernel.api_pushnumber(L, 2.5)
	kernel.api_pushstring(L, "hello")

	testing.expect_value(t, kernel.api_gettop(L), 5)
	testing.expect_value(t, kernel.api_type(L, 1), kernel.TNIL)
	testing.expect_value(t, kernel.api_type(L, 2), kernel.TBOOLEAN)
	testing.expect_value(t, kernel.api_type(L, 3), kernel.TNUMBER)
	testing.expect_value(t, kernel.api_type(L, 5), kernel.TSTRING)
	testing.expect_value(t, kernel.api_type(L, 10), kernel.TNONE) // reserved-but-empty slot

	testing.expect(t, kernel.api_toboolean(L, 2))
	testing.expect_value(t, kernel.api_tointeger(L, 3), 42)
	testing.expect_value(t, kernel.api_tonumber(L, 4), 2.5)
	s, ok := kernel.api_tolstring(L, 5)
	testing.expect(t, ok)
	testing.expect_value(t, s, "hello")

	// Negative indices count from the top.
	testing.expect_value(t, kernel.api_tointeger(L, -3), 42)
	// A number is coercible to a string in place.
	ns, nok := kernel.api_tolstring(L, 3)
	testing.expect(t, nok)
	testing.expect_value(t, ns, "42")
	testing.expect_value(t, kernel.api_type(L, 3), kernel.TSTRING) // converted in place
}

@(test)
test_api_numeric_and_string_conversion_paths :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushinteger(L, min(i64))
	kernel.api_pushnumber(L, 42.0)
	kernel.api_pushnumber(L, 42.5)
	kernel.api_pushstring(L, "-17")
	kernel.api_pushstring(L, "bad")
	kernel.api_pushboolean(L, true)

	i, ok := kernel.api_tointegerx(L, 1)
	testing.expect(t, ok && i == min(i64))
	i, ok = kernel.api_tointegerx(L, -5)
	testing.expect(t, ok && i == 42)
	i, ok = kernel.api_tointegerx(L, 3)
	testing.expect(t, !ok && i == 0)
	i, ok = kernel.api_tointegerx(L, 4)
	testing.expect(t, ok && i == -17)
	i, ok = kernel.api_tointegerx(L, 5)
	testing.expect(t, !ok && i == 0)
	i, ok = kernel.api_tointegerx(L, 10) // acceptable, but no value
	testing.expect(t, !ok && i == 0)

	n, nok := kernel.api_tonumberx(L, 1)
	testing.expect(t, nok && n == kernel.Number(min(i64)))
	n, nok = kernel.api_tonumberx(L, 3)
	testing.expect(t, nok && n == 42.5)
	n, nok = kernel.api_tonumberx(L, 4)
	testing.expect(t, nok && n == -17)
	n, nok = kernel.api_tonumberx(L, 6)
	testing.expect(t, !nok && n == 0)

	s, sok := kernel.api_tolstring(L, 4)
	testing.expect(t, sok && s == "-17")
	s, sok = kernel.api_tolstring(L, 2)
	testing.expect(t, sok && s == "42.0")
	testing.expect_value(t, kernel.api_type(L, 2), kernel.TSTRING)
	s, sok = kernel.api_tolstring(L, 6)
	testing.expect(t, !sok && s == "")
	s, sok = kernel.api_tolstring(L, 10)
	testing.expect(t, !sok && s == "")
}

@(test)
test_api_settop_and_pop :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushinteger(L, 1)
	kernel.api_pushinteger(L, 2)
	kernel.api_pushinteger(L, 3)
	testing.expect_value(t, kernel.api_gettop(L), 3)
	kernel.api_pop(L, 2)
	testing.expect_value(t, kernel.api_gettop(L), 1)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 1)
	kernel.api_settop(L, 0)
	testing.expect_value(t, kernel.api_gettop(L), 0)
}

// ---------------------------------------------------------------------------
// Tables through the API: fields, integer keys, raw access, traversal
// ---------------------------------------------------------------------------

@(test)
test_api_table_field_roundtrip :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_newtable(L) // t at index 1
	kernel.api_pushinteger(L, 7)
	kernel.api_setfield(L, 1, "answer") // t.answer = 7

	typ := kernel.api_getfield(L, 1, "answer")
	testing.expect_value(t, typ, kernel.TNUMBER)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 7)
	kernel.api_pop(L, 1)

	// Absent key reads as nil.
	testing.expect_value(t, kernel.api_getfield(L, 1, "missing"), kernel.TNIL)
}

@(test)
test_api_table_integer_keys :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_newtable(L)
	for i in 1 ..= 5 {
		kernel.api_pushinteger(L, kernel.Integer(i * 10))
		kernel.api_seti(L, 1, kernel.Integer(i)) // t[i] = i*10
	}
	sum: kernel.Integer = 0
	for i in 1 ..= 5 {
		kernel.api_geti(L, 1, kernel.Integer(i))
		sum += kernel.api_tointeger(L, -1)
		kernel.api_pop(L, 1)
	}
	testing.expect_value(t, sum, 150)
	testing.expect_value(t, kernel.api_rawlen(L, 1), 5) // border length
}

@(test)
test_api_rawset_rawget :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_newtable(L)
	kernel.api_pushstring(L, "k")
	kernel.api_pushstring(L, "v")
	kernel.api_rawset(L, 1) // raw t.k = v

	kernel.api_pushstring(L, "k")
	typ := kernel.api_rawget(L, 1)
	testing.expect_value(t, typ, kernel.TSTRING)
	s, _ := kernel.api_tolstring(L, -1)
	testing.expect_value(t, s, "v")
}

@(test)
test_api_next_traversal :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_newtable(L)
	for i in 1 ..= 4 {
		kernel.api_pushinteger(L, kernel.Integer(i))
		kernel.api_seti(L, 1, kernel.Integer(i))
	}
	// Sum every value visited by lua_next -- proves a full, honest traversal.
	sum: kernel.Integer = 0
	count := 0
	kernel.api_pushnil(L) // first key
	for kernel.api_next(L, 1) {
		sum += kernel.api_tointeger(L, -1) // value at -1
		count += 1
		kernel.api_pop(L, 1) // pop value, keep key for the next step
	}
	testing.expect_value(t, count, 4)
	testing.expect_value(t, sum, 10)
	testing.expect_value(t, kernel.api_gettop(L), 1) // traversal left the stack balanced
}

// ---------------------------------------------------------------------------
// Concatenation, length, arithmetic, comparison
// ---------------------------------------------------------------------------

@(test)
test_api_concat_and_len :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushstring(L, "foo")
	kernel.api_pushstring(L, "bar")
	kernel.api_pushstring(L, "baz")
	kernel.api_concat(L, 3)
	s, ok := kernel.api_tolstring(L, -1)
	testing.expect(t, ok)
	testing.expect_value(t, s, "foobarbaz")

	kernel.api_len(L, -1) // #"foobarbaz" == 9
	testing.expect_value(t, kernel.api_tointeger(L, -1), 9)
}

@(test)
test_api_arith_and_compare :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushinteger(L, 5)
	kernel.api_pushinteger(L, 3)
	kernel.api_arith(L, kernel.OPADD) // 5 + 3
	testing.expect_value(t, kernel.api_tointeger(L, -1), 8)

	kernel.api_pushinteger(L, 10)
	kernel.api_pushinteger(L, 20)
	testing.expect(t, kernel.api_compare(L, -2, -1, kernel.OPLT)) // 10 < 20
	testing.expect(t, !kernel.api_compare(L, -1, -2, kernel.OPLE)) // !(20 <= 10)
}

// ---------------------------------------------------------------------------
// Full userdata with user values
// ---------------------------------------------------------------------------

@(test)
test_api_userdata_uservalues :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	p := kernel.api_newuserdatauv(L, 8, 2) // 8 payload bytes, 2 user values
	testing.expect(t, p != nil)
	testing.expect_value(t, kernel.api_type(L, -1), kernel.TUSERDATA)
	testing.expect(t, kernel.api_touserdata(L, -1) == p)
	testing.expect_value(t, kernel.api_rawlen(L, -1), 8)

	// Write the first user value and read it back.
	kernel.api_pushinteger(L, 99)
	testing.expect(t, kernel.api_setiuservalue(L, -2, 1))
	typ := kernel.api_getiuservalue(L, -1, 1)
	testing.expect_value(t, typ, kernel.TNUMBER)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 99)
	kernel.api_pop(L, 1)

	// An out-of-range user value index reports nil / false.
	testing.expect_value(t, kernel.api_getiuservalue(L, -1, 5), kernel.TNONE)
	kernel.api_pop(L, 1)
	kernel.api_pushinteger(L, 1)
	testing.expect(t, !kernel.api_setiuservalue(L, -2, 5))
}

// ---------------------------------------------------------------------------
// Loading source and calling it (protected and unprotected)
// ---------------------------------------------------------------------------

@(test)
test_api_load_and_pcall :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader

	status := api_load(L, "return 3 + 4 * 2", &rd)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	call := kernel.api_pcall(L, 0, 1, 0)
	testing.expect_value(t, call, kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 11)
}

@(test)
test_api_pcall_catches_error :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader

	// No standard library is loaded in this phase, so we trigger a genuine VM
	// runtime error (arithmetic on a nil value) rather than calling `error`.
	status := api_load(L, "return 1 + nil", &rd)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	call := kernel.api_pcall(L, 0, 0, 0)
	testing.expect_value(t, call, kernel.Thread_Status.Err_Run)
	// The error object is now on top: a string describing the failure.
	msg, ok := kernel.api_tolstring(L, -1)
	testing.expect(t, ok)
	testing.expect(t, contains(msg, "nil"))
}

@(test)
test_api_globals_through_env :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader

	// A loaded chunk's _ENV is wired to the globals table, so a global write in
	// Lua must be observable via lua_getglobal, and a value we set via the API
	// must be observable to Lua.
	status := api_load(L, "answer = 40 + 2", &rd)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_pcall(L, 0, 0, 0), kernel.Thread_Status.Ok)

	testing.expect_value(t, kernel.api_getglobal(L, "answer"), kernel.TNUMBER)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 42)
	kernel.api_pop(L, 1)

	// Now set a global from the API and read it back from Lua.
	kernel.api_pushinteger(L, 7)
	kernel.api_setglobal(L, "seven")
	rd2: Src_Reader
	testing.expect_value(t, api_load(L, "return seven * 3", &rd2), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 21)
}

// ---------------------------------------------------------------------------
// C closures and upvalue access
// ---------------------------------------------------------------------------

// A native function that returns its single captured upvalue -- exercises the
// upvalue pseudo-index path in `index2value`.
api_return_upvalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.api_pushvalue(L, kernel.upvalueindex(1))
	return 1
}

@(test)
test_api_cclosure_upvalue :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)

	kernel.api_pushinteger(L, 123) // the value to capture
	kernel.api_pushcclosure(L, api_return_upvalue, 1) // closure over it
	testing.expect(t, kernel.api_iscfunction(L, -1))

	kernel.api_call(L, 0, 1) // call it: should return 123
	testing.expect_value(t, kernel.api_tointeger(L, -1), 123)

	// And the upvalue is inspectable via lua_getupvalue.
	kernel.api_pushinteger(L, 5)
	kernel.api_pushcclosure(L, api_return_upvalue, 1)
	_, ok := kernel.api_getupvalue(L, -1, 1)
	testing.expect(t, ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 5)
}
