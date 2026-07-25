package tests

// oslib_test.odin -- honest end-to-end tests for the os library
// (src/stdlib/oslib.odin), driven through real Lua chunks. Time-dependent
// functions are pinned to deterministic anchors: the UTC epoch (0) for date
// formatting, and same-day/same-table differences for os.time/os.difftime so the
// host time zone cancels out. We never assert on the wall clock's actual value.

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

oslib_state :: proc() -> ^lua.Lua_State {
	L := lua.new_state(lua.default_allocator())
	lua.lua_pushcfunction(L, aux.luaopen_base)
	lua.lua_call(L, 0, 0)
	lua.lua_pushcfunction(L, aux.luaopen_os)
	lua.lua_call(L, 0, 1)
	lua.lua_setglobal(L, "os")
	return L
}

oslib_run :: proc(L: ^lua.Lua_State, src: string) -> lua.Thread_Status {
	if st := aux.luaL_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.lua_pcall(L, 0, lua.LUA_MULTRET, 0)
}

@(test)
oslib_date_epoch_utc :: proc(t: ^testing.T) {
	L := oslib_state()
	defer lua.close_state(L)
	// The UTC epoch is 1970-01-01 00:00:00 on every machine, so "!" (UTC) date
	// results are fully deterministic.
	st := oslib_run(
		L,
		"local d = os.date('!*t', 0)\n" +
		"assert(d.year == 1970 and d.month == 1 and d.day == 1, 'epoch date')\n" +
		"assert(d.hour == 0 and d.min == 0 and d.sec == 0, 'epoch time')\n" +
		"assert(d.wday == 5, 'epoch was a Thursday (wday 5)')\n" +
		"assert(os.date('!%Y-%m-%d', 0) == '1970-01-01', 'formatted epoch')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "os.date formats the UTC epoch deterministically")
}

@(test)
oslib_time_roundtrip :: proc(t: ^testing.T) {
	L := oslib_state()
	defer lua.close_state(L)
	// os.time interprets the table in local time and os.date('*t') converts back
	// in local time, so the fields round-trip regardless of the host time zone.
	st := oslib_run(
		L,
		"local t0 = os.time({year=2021, month=3, day=14, hour=9, min=26, sec=53})\n" +
		"assert(type(t0) == 'number', 'os.time returns a number')\n" +
		"local d = os.date('*t', t0)\n" +
		"assert(d.year == 2021 and d.month == 3 and d.day == 14, 'date round-trips')\n" +
		"assert(d.hour == 9 and d.min == 26 and d.sec == 53, 'time round-trips')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "os.time/os.date round-trip a date table")
}

@(test)
oslib_difftime :: proc(t: ^testing.T) {
	L := oslib_state()
	defer lua.close_state(L)
	// Both times share a time zone, so their difference is exact and tz-independent.
	st := oslib_run(
		L,
		"local a = os.time({year=2020, month=6, day=15, hour=12, min=0, sec=30})\n" +
		"local b = os.time({year=2020, month=6, day=15, hour=12, min=0, sec=0})\n" +
		"assert(os.difftime(a, b) == 30, 'difftime is 30 seconds')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "os.difftime measures a 30-second gap exactly")
}

@(test)
oslib_getenv_and_clock :: proc(t: ^testing.T) {
	L := oslib_state()
	defer lua.close_state(L)
	st := oslib_run(
		L,
		"assert(os.getenv('LUA_ODIN_DEFINITELY_NOT_SET_9F3A') == nil, 'unset env is nil')\n" +
		"assert(type(os.clock()) == 'number', 'clock is a number')\n" +
		"assert(os.clock() >= 0, 'clock is non-negative')\n" +
		"assert(type(os.time()) == 'number', 'time is a number')\n" +
		"assert(os.time() > 0, 'current time is positive')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "os.getenv/os.clock/os.time behave sanely")
}

@(test)
oslib_date_bad_specifier :: proc(t: ^testing.T) {
	L := oslib_state()
	defer lua.close_state(L)
	// An unknown conversion specifier must raise, not silently pass through.
	st := oslib_run(L, "return os.date('!%Q', 0)")
	testing.expect(t, st != .Ok, "an invalid strftime specifier is rejected")
}
