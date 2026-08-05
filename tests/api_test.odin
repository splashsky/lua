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
import lua "luao:lua"

// A fresh, fully-built state with the reference-faithful default allocator.
api_new :: proc() -> ^lua.State {
	return lua.new_state(lua.default_allocator())
}

// Load `src` as a chunk, leaving the compiled closure on the stack (or an error
// message on failure). `rd` must outlive the call.
api_load :: proc(L: ^lua.State, src: string, rd: ^Src_Reader) -> lua.Thread_Status {
	rd^ = Src_Reader {
		data = ([^]u8)(raw_data(src)),
		len  = uint(len(src)),
		done = false,
	}
	return lua.api_load(L, src_read, rd, "=t", "")
}

// ---------------------------------------------------------------------------
// Push / convert round-trips and type queries
// ---------------------------------------------------------------------------

@(test)
test_api_push_and_type :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_pushnil(L)
	lua.api_pushboolean(L, true)
	lua.api_pushinteger(L, 42)
	lua.api_pushnumber(L, 2.5)
	lua.api_pushstring(L, "hello")

	testing.expect_value(t, lua.api_gettop(L), 5)
	testing.expect_value(t, lua.api_type(L, 1), lua.TNIL)
	testing.expect_value(t, lua.api_type(L, 2), lua.TBOOLEAN)
	testing.expect_value(t, lua.api_type(L, 3), lua.TNUMBER)
	testing.expect_value(t, lua.api_type(L, 5), lua.TSTRING)
	testing.expect_value(t, lua.api_type(L, 10), lua.TNONE) // reserved-but-empty slot

	testing.expect(t, lua.api_toboolean(L, 2))
	testing.expect_value(t, lua.api_tointeger(L, 3), 42)
	testing.expect_value(t, lua.api_tonumber(L, 4), 2.5)
	s, ok := lua.api_tolstring(L, 5)
	testing.expect(t, ok)
	testing.expect_value(t, s, "hello")

	// Negative indices count from the top.
	testing.expect_value(t, lua.api_tointeger(L, -3), 42)
	// A number is coercible to a string in place.
	ns, nok := lua.api_tolstring(L, 3)
	testing.expect(t, nok)
	testing.expect_value(t, ns, "42")
	testing.expect_value(t, lua.api_type(L, 3), lua.TSTRING) // converted in place
}

@(test)
test_api_settop_and_pop :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_pushinteger(L, 1)
	lua.api_pushinteger(L, 2)
	lua.api_pushinteger(L, 3)
	testing.expect_value(t, lua.api_gettop(L), 3)
	lua.api_pop(L, 2)
	testing.expect_value(t, lua.api_gettop(L), 1)
	testing.expect_value(t, lua.api_tointeger(L, -1), 1)
	lua.api_settop(L, 0)
	testing.expect_value(t, lua.api_gettop(L), 0)
}

// ---------------------------------------------------------------------------
// Tables through the API: fields, integer keys, raw access, traversal
// ---------------------------------------------------------------------------

@(test)
test_api_table_field_roundtrip :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_newtable(L) // t at index 1
	lua.api_pushinteger(L, 7)
	lua.api_setfield(L, 1, "answer") // t.answer = 7

	typ := lua.api_getfield(L, 1, "answer")
	testing.expect_value(t, typ, lua.TNUMBER)
	testing.expect_value(t, lua.api_tointeger(L, -1), 7)
	lua.api_pop(L, 1)

	// Absent key reads as nil.
	testing.expect_value(t, lua.api_getfield(L, 1, "missing"), lua.TNIL)
}

@(test)
test_api_table_integer_keys :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_newtable(L)
	for i in 1 ..= 5 {
		lua.api_pushinteger(L, lua.Integer(i * 10))
		lua.api_seti(L, 1, lua.Integer(i)) // t[i] = i*10
	}
	sum: lua.Integer = 0
	for i in 1 ..= 5 {
		lua.api_geti(L, 1, lua.Integer(i))
		sum += lua.api_tointeger(L, -1)
		lua.api_pop(L, 1)
	}
	testing.expect_value(t, sum, 150)
	testing.expect_value(t, lua.api_rawlen(L, 1), 5) // border length
}

@(test)
test_api_rawset_rawget :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_newtable(L)
	lua.api_pushstring(L, "k")
	lua.api_pushstring(L, "v")
	lua.api_rawset(L, 1) // raw t.k = v

	lua.api_pushstring(L, "k")
	typ := lua.api_rawget(L, 1)
	testing.expect_value(t, typ, lua.TSTRING)
	s, _ := lua.api_tolstring(L, -1)
	testing.expect_value(t, s, "v")
}

@(test)
test_api_next_traversal :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_newtable(L)
	for i in 1 ..= 4 {
		lua.api_pushinteger(L, lua.Integer(i))
		lua.api_seti(L, 1, lua.Integer(i))
	}
	// Sum every value visited by lua_next -- proves a full, honest traversal.
	sum: lua.Integer = 0
	count := 0
	lua.api_pushnil(L) // first key
	for lua.api_next(L, 1) {
		sum += lua.api_tointeger(L, -1) // value at -1
		count += 1
		lua.api_pop(L, 1) // pop value, keep key for the next step
	}
	testing.expect_value(t, count, 4)
	testing.expect_value(t, sum, 10)
	testing.expect_value(t, lua.api_gettop(L), 1) // traversal left the stack balanced
}

// ---------------------------------------------------------------------------
// Concatenation, length, arithmetic, comparison
// ---------------------------------------------------------------------------

@(test)
test_api_concat_and_len :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_pushstring(L, "foo")
	lua.api_pushstring(L, "bar")
	lua.api_pushstring(L, "baz")
	lua.api_concat(L, 3)
	s, ok := lua.api_tolstring(L, -1)
	testing.expect(t, ok)
	testing.expect_value(t, s, "foobarbaz")

	lua.api_len(L, -1) // #"foobarbaz" == 9
	testing.expect_value(t, lua.api_tointeger(L, -1), 9)
}

@(test)
test_api_arith_and_compare :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_pushinteger(L, 5)
	lua.api_pushinteger(L, 3)
	lua.api_arith(L, lua.OPADD) // 5 + 3
	testing.expect_value(t, lua.api_tointeger(L, -1), 8)

	lua.api_pushinteger(L, 10)
	lua.api_pushinteger(L, 20)
	testing.expect(t, lua.api_compare(L, -2, -1, lua.OPLT)) // 10 < 20
	testing.expect(t, !lua.api_compare(L, -1, -2, lua.OPLE)) // !(20 <= 10)
}

// ---------------------------------------------------------------------------
// Full userdata with user values
// ---------------------------------------------------------------------------

@(test)
test_api_userdata_uservalues :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	p := lua.api_newuserdatauv(L, 8, 2) // 8 payload bytes, 2 user values
	testing.expect(t, p != nil)
	testing.expect_value(t, lua.api_type(L, -1), lua.TUSERDATA)
	testing.expect(t, lua.api_touserdata(L, -1) == p)
	testing.expect_value(t, lua.api_rawlen(L, -1), 8)

	// Write the first user value and read it back.
	lua.api_pushinteger(L, 99)
	testing.expect(t, lua.api_setiuservalue(L, -2, 1))
	typ := lua.api_getiuservalue(L, -1, 1)
	testing.expect_value(t, typ, lua.TNUMBER)
	testing.expect_value(t, lua.api_tointeger(L, -1), 99)
	lua.api_pop(L, 1)

	// An out-of-range user value index reports nil / false.
	testing.expect_value(t, lua.api_getiuservalue(L, -1, 5), lua.TNONE)
	lua.api_pop(L, 1)
	lua.api_pushinteger(L, 1)
	testing.expect(t, !lua.api_setiuservalue(L, -2, 5))
}

// ---------------------------------------------------------------------------
// Loading source and calling it (protected and unprotected)
// ---------------------------------------------------------------------------

@(test)
test_api_load_and_pcall :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)
	rd: Src_Reader

	status := api_load(L, "return 3 + 4 * 2", &rd)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	call := lua.api_pcall(L, 0, 1, 0)
	testing.expect_value(t, call, lua.Thread_Status.Ok)
	testing.expect_value(t, lua.api_tointeger(L, -1), 11)
}

@(test)
test_api_pcall_catches_error :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)
	rd: Src_Reader

	// No standard library is loaded in this phase, so we trigger a genuine VM
	// runtime error (arithmetic on a nil value) rather than calling `error`.
	status := api_load(L, "return 1 + nil", &rd)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	call := lua.api_pcall(L, 0, 0, 0)
	testing.expect_value(t, call, lua.Thread_Status.Err_Run)
	// The error object is now on top: a string describing the failure.
	msg, ok := lua.api_tolstring(L, -1)
	testing.expect(t, ok)
	testing.expect(t, contains(msg, "nil"))
}

@(test)
test_api_globals_through_env :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)
	rd: Src_Reader

	// A loaded chunk's _ENV is wired to the globals table, so a global write in
	// Lua must be observable via lua_getglobal, and a value we set via the API
	// must be observable to Lua.
	status := api_load(L, "answer = 40 + 2", &rd)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, lua.api_pcall(L, 0, 0, 0), lua.Thread_Status.Ok)

	testing.expect_value(t, lua.api_getglobal(L, "answer"), lua.TNUMBER)
	testing.expect_value(t, lua.api_tointeger(L, -1), 42)
	lua.api_pop(L, 1)

	// Now set a global from the API and read it back from Lua.
	lua.api_pushinteger(L, 7)
	lua.api_setglobal(L, "seven")
	rd2: Src_Reader
	testing.expect_value(t, api_load(L, "return seven * 3", &rd2), lua.Thread_Status.Ok)
	testing.expect_value(t, lua.api_pcall(L, 0, 1, 0), lua.Thread_Status.Ok)
	testing.expect_value(t, lua.api_tointeger(L, -1), 21)
}

// ---------------------------------------------------------------------------
// C closures and upvalue access
// ---------------------------------------------------------------------------

// A native function that returns its single captured upvalue -- exercises the
// upvalue pseudo-index path in `index2value`.
api_return_upvalue :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	lua.api_pushvalue(L, lua.upvalueindex(1))
	return 1
}

@(test)
test_api_cclosure_upvalue :: proc(t: ^testing.T) {
	L := api_new()
	defer lua.close_state(L)

	lua.api_pushinteger(L, 123) // the value to capture
	lua.api_pushcclosure(L, api_return_upvalue, 1) // closure over it
	testing.expect(t, lua.api_iscfunction(L, -1))

	lua.api_call(L, 0, 1) // call it: should return 123
	testing.expect_value(t, lua.api_tointeger(L, -1), 123)

	// And the upvalue is inspectable via lua_getupvalue.
	lua.api_pushinteger(L, 5)
	lua.api_pushcclosure(L, api_return_upvalue, 1)
	_, ok := lua.api_getupvalue(L, -1, 1)
	testing.expect(t, ok)
	testing.expect_value(t, lua.api_tointeger(L, -1), 5)
}
