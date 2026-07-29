package tests

// table_test.odin -- Phase 3 tests for tables (table.odin).
//
// Tables are the workhorse Lua data structure: an array part for dense integer
// keys and a hash part for everything else, with automatic rehashing as they
// fill. These tests prove the observable contract -- set/get round-trips for
// integer and string keys, overwrite semantics, absence of a key reading as nil,
// the length operator's border behavior, full traversal via `next`, and that a
// large batch of inserts (forcing several rehashes) loses nothing.
//
// The last two tests target the hash part specifically. Integer keys mostly land
// in the array part, so they never exercise the free-slot search (`getfreepos`)
// that placing a colliding key depends on -- string keys do.

import "core:fmt"
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

// --- hash-part specific -----------------------------------------------------

// Store integer value `v` under the string key `name`.
set_str_key :: proc(L: ^lua.Lua_State, tbl: ^lua.Table, name: string, v: lua.Integer) {
	key := lua.luaS_new(L, name)
	kv: lua.TValue
	lua.set_gc(&kv, &key.header)
	val: lua.TValue
	lua.set_int(&val, v)
	st := lua.luaH_set(L, tbl, &kv, &val)
	assert(st == .Ok)
}

// Clear the string key `name` (Lua's `t[name] = nil`).
clear_str_key :: proc(L: ^lua.Lua_State, tbl: ^lua.Table, name: string) {
	key := lua.luaS_new(L, name)
	kv: lua.TValue
	lua.set_gc(&kv, &key.header)
	val: lua.TValue
	lua.set_nil(&val)
	st := lua.luaH_set(L, tbl, &kv, &val)
	assert(st == .Ok)
}

// Read the string key `name`, returning (value, found).
get_str_key :: proc(L: ^lua.Lua_State, tbl: ^lua.Table, name: string) -> (lua.Integer, bool) {
	key := lua.luaS_new(L, name)
	res: lua.TValue
	lua.luaH_getstr(tbl, key, &res)
	if lua.is_nil(&res) {
		return 0, false
	}
	return lua.int_value(&res), true
}

// Filling the hash part drives it through every growth stage -- sizes below the
// cursor threshold (1, 2, 4 slots) and above it (8 and up) -- so both branches of
// the free-slot search run, across many rehashes. Whatever strategy that search
// uses, no key may be lost, duplicated, or left pointing at the wrong value: we
// check every key reads back exactly, and that a full `next` traversal sees each
// entry once and only once.
@(test)
table_hash_bulk_insert_lossless :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	testing.expect(t, tbl != nil)

	N :: 500
	for i in 0 ..< N {
		set_str_key(L, tbl, fmt.tprintf("key%d", i), lua.Integer(i * 7))
	}

	// Every key must read back with its exact value.
	for i in 0 ..< N {
		v, found := get_str_key(L, tbl, fmt.tprintf("key%d", i))
		testing.expect(t, found, "every hash key must survive rehashing")
		testing.expect_value(t, v, lua.Integer(i * 7))
	}

	// A key never inserted must still be absent (nothing stray got left behind).
	_, missing := get_str_key(L, tbl, "key-never-set")
	testing.expect(t, !missing, "unset key must read as absent")

	// Traversal must see exactly N entries. Summing the values is the tell-tale:
	// a lost, duplicated, or mis-mapped entry changes the total.
	key: lua.TValue
	lua.set_nil(&key)
	out_key, out_val: lua.TValue
	seen := 0
	sum := lua.Integer(0)
	for lua.luaH_next(L, tbl, &key, &out_key, &out_val) {
		seen += 1
		sum += lua.int_value(&out_val)
		lua.set_obj(&key, &out_key)
	}
	testing.expect_value(t, seen, N)

	want := lua.Integer(0)
	for i in 0 ..< N {
		want += lua.Integer(i * 7)
	}
	testing.expect_value(t, sum, want)
}

// Deleting keys and inserting fresh ones is the case where free-slot bookkeeping
// can go wrong: a cleared entry keeps a "dead" key rather than becoming free
// again, so later insertions must still find room (rehashing when they cannot).
// This churns the table through delete/insert cycles and then proves the exact
// surviving set: cleared keys absent, untouched keys unchanged, new keys correct.
@(test)
table_hash_delete_reinsert_stays_consistent :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	tbl := lua.luaH_new(L)
	N :: 300
	for i in 0 ..< N {
		set_str_key(L, tbl, fmt.tprintf("k%d", i), lua.Integer(i))
	}

	// Clear every other key.
	for i := 0; i < N; i += 2 {
		clear_str_key(L, tbl, fmt.tprintf("k%d", i))
	}
	for i in 0 ..< N {
		v, found := get_str_key(L, tbl, fmt.tprintf("k%d", i))
		if i % 2 == 0 {
			testing.expect(t, !found, "cleared key must read as absent")
		} else {
			testing.expect(t, found, "untouched key must survive its neighbours' deletion")
			testing.expect_value(t, v, lua.Integer(i))
		}
	}

	// Now insert a fresh batch, which must find room among (or beyond) the dead
	// entries left behind above.
	for i in 0 ..< N {
		set_str_key(L, tbl, fmt.tprintf("n%d", i), lua.Integer(i * 2))
	}

	// Final state: survivors intact, cleared keys still gone, new keys correct.
	live := 0
	for i in 0 ..< N {
		v, found := get_str_key(L, tbl, fmt.tprintf("k%d", i))
		if i % 2 == 0 {
			testing.expect(t, !found, "cleared key must stay absent after refilling")
		} else {
			testing.expect(t, found, "survivor must outlast the second batch")
			testing.expect_value(t, v, lua.Integer(i))
			live += 1
		}
		nv, nfound := get_str_key(L, tbl, fmt.tprintf("n%d", i))
		testing.expect(t, nfound, "newly inserted key must be retrievable")
		testing.expect_value(t, nv, lua.Integer(i * 2))
	}

	// Traversal must agree with that accounting: survivors plus the new batch.
	key: lua.TValue
	lua.set_nil(&key)
	out_key, out_val: lua.TValue
	seen := 0
	for lua.luaH_next(L, tbl, &key, &out_key, &out_val) {
		seen += 1
		lua.set_obj(&key, &out_key)
	}
	testing.expect_value(t, seen, live + N)
}
