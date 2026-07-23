package tests

// table_test.odin -- Phase 3 tests for tables (table.odin).
//
// Tables are the workhorse Lua data structure: an array part for dense integer
// keys and a hash part for everything else, with automatic rehashing as they
// fill. These tests prove the observable contract -- set/get round-trips for
// integer and string keys, overwrite semantics, absence of a key reading as nil,
// the length operator's border behavior, full traversal via `next`, and that a
// large batch of inserts (forcing several rehashes) loses nothing.

import "core:testing"
import lua "luao:lua"

// Store an integer value under integer key `k`.
set_int_key :: proc(L: ^lua.Lua_State, tbl: ^lua.Table, k: lua.Integer, v: lua.Integer) {
	val: lua.TValue
	lua.set_int(&val, v)
	st := lua.luaH_setint(L, tbl, k, &val)
	assert(st == .Ok)
}

// Read an integer key, returning (value, found). "Found" means the slot held a
// real (non-empty) value.
get_int_key :: proc(tbl: ^lua.Table, k: lua.Integer) -> (lua.Integer, bool) {
	res: lua.TValue
	lua.luaH_getint(tbl, k, &res)
	if lua.is_nil(&res) {
		return 0, false
	}
	return lua.int_value(&res), true
}

// Basic integer key round-trip: what you put in is what you get out, distinct keys
// keep distinct values, and a key never set reads as nil.
@(test)
table_int_roundtrip :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	testing.expect(t, tbl != nil)

	for i in lua.Integer(1) ..= 5 {
		set_int_key(L, tbl, i, i * 100)
	}
	for i in lua.Integer(1) ..= 5 {
		v, found := get_int_key(tbl, i)
		testing.expect(t, found, "previously set key must be found")
		testing.expect_value(t, v, i * 100)
	}

	// A key we never touched must read as nil/absent.
	_, found := get_int_key(tbl, 999)
	testing.expect(t, !found, "unset key must read as absent")
}

// Overwriting a key replaces its value in place rather than creating a duplicate.
@(test)
table_overwrite_replaces :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	set_int_key(L, tbl, 7, 111)
	set_int_key(L, tbl, 7, 222)

	v, found := get_int_key(tbl, 7)
	testing.expect(t, found)
	testing.expect_value(t, v, lua.Integer(222))
}

// String keys must round-trip too, keyed by the interned string object.
@(test)
table_string_key_roundtrip :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	key := lua.luaS_new(L, "answer")
	val: lua.TValue
	lua.set_int(&val, 42)
	kv: lua.TValue
	lua.set_gc(&kv, &key.header)
	st := lua.luaH_set(L, tbl, &kv, &val)
	testing.expect(t, st == .Ok)

	res: lua.TValue
	lua.luaH_getstr(tbl, key, &res)
	testing.expect(t, lua.is_integer(&res), "string key must retrieve its value")
	testing.expect_value(t, lua.int_value(&res), lua.Integer(42))
}

// The length operator's contract is a "border": an index n where t[n] is non-nil
// and t[n+1] is nil. For a contiguous sequence 1..N the border is exactly N.
@(test)
table_length_border :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	for i in lua.Integer(1) ..= 10 {
		set_int_key(L, tbl, i, i)
	}
	n := lua.luaH_getn(L, tbl)
	testing.expect_value(t, n, lua.Unsigned(10))
}

// `next` must visit every stored entry exactly once. We insert a known set of
// integer keys and confirm the traversal recovers all of them (their sum is the
// tell-tale: any missed or duplicated key changes it).
@(test)
table_next_visits_all :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	expected_sum := lua.Integer(0)
	for i in lua.Integer(1) ..= 10 {
		set_int_key(L, tbl, i, i)
		expected_sum += i
	}

	key: lua.TValue
	lua.set_nil(&key) // nil starts a traversal
	out_key: lua.TValue
	out_val: lua.TValue
	seen := 0
	sum := lua.Integer(0)
	for lua.luaH_next(L, tbl, &key, &out_key, &out_val) {
		seen += 1
		testing.expect(t, lua.is_integer(&out_key), "keys were all integers")
		sum += lua.int_value(&out_key)
		lua.set_obj(&key, &out_key) // advance the cursor
	}
	testing.expect_value(t, seen, 10)
	testing.expect_value(t, sum, expected_sum)
}

// A large batch of inserts forces the table to rehash and grow its parts several
// times. Every key must remain retrievable with its exact value afterwards, and
// the sequence length must be the full count -- proving rehashing preserves all
// entries.
@(test)
table_bulk_insert_rehashes_losslessly :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	for i in lua.Integer(1) ..= 200 {
		set_int_key(L, tbl, i, i * 3)
	}
	for i in lua.Integer(1) ..= 200 {
		v, found := get_int_key(tbl, i)
		testing.expect(t, found, "every bulk key must survive rehashing")
		testing.expect_value(t, v, i * 3)
	}
	testing.expect_value(t, lua.luaH_getn(L, tbl), lua.Unsigned(200))
}
