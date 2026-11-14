package tests

// oslib_test.odin -- honest end-to-end tests for the os library
// (src/stdlib/oslib.odin), driven through real Lua chunks. Time-dependent
// functions are pinned to deterministic anchors: the UTC epoch (0) for date
// formatting, and same-day/same-table differences for os.time/os.difftime so the
// host time zone cancels out. We never assert on the wall clock's actual value.

import "base:runtime"
import "core:os"
import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

oslib_state :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	kernel.api_pushcfunction(L, stdlib.open_base)
	kernel.api_call(L, 0, 0)
	kernel.api_pushcfunction(L, stdlib.open_os)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "os")
	return L
}

oslib_run :: proc(L: ^kernel.State, src: string) -> kernel.Thread_Status {
	if st := stdlib.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return kernel.api_pcall(L, 0, kernel.MULTRET, 0)
}

@(test)
oslib_date_epoch_utc :: proc(t: ^testing.T) {
	L := oslib_state()
	defer kernel.close_state(L)
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
	defer kernel.close_state(L)
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
oslib_time_minus_one :: proc(t: ^testing.T) {
	when ODIN_OS != .Windows { // MSVC mktime cannot represent negative timestamps.
		L := oslib_state()
		defer kernel.close_state(L)
		st := oslib_run(L, `
			local t = os.date('*t', -1)
			t.wday, t.yday = nil, nil
			assert(os.time(t) == -1)
			assert(t.wday and t.yday) -- the table was normalized too
			assert(not pcall(os.time, {year=0x7fffffffffffffff, month=1, day=1}))
		`)
		if st != .Ok {
			msg, _ := kernel.api_tolstring(L, -1)
			testing.expectf(t, false, "os.time(-1) round-trip: %s", msg)
		}
	} else {
		L := oslib_state()
		defer kernel.close_state(L)
		st := oslib_run(L, `assert(not pcall(os.time, {year=1960, month=1, day=1}))`)
		testing.expect(t, st == .Ok, "Windows mktime rejects negative timestamps")
	}
}

@(test)
oslib_difftime :: proc(t: ^testing.T) {
	L := oslib_state()
	defer kernel.close_state(L)
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
	defer kernel.close_state(L)
	st := oslib_run(
		L,
		"assert(os.getenv('ODIN_DEFINITELY_NOT_SET_9F3A') == nil, 'unset env is nil')\n" +
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
	defer kernel.close_state(L)
	// An unknown conversion specifier must raise, not silently pass through.
	st := oslib_run(L, "return os.date('!%Q', 0)")
	testing.expect(t, st != .Ok, "an invalid strftime specifier is rejected")
}

// Every native callback starts with runtime.default_context(), so inspecting
// this thread's actual default arena detects allocations that a Lua heap or RSS
// test alone can miss. Warm it first, then demand no per-call accumulation.
@(test)
oslib_temporary_arena_is_bounded :: proc(t: ^testing.T) {
	long_value: [4096]u8
	for &ch in long_value do ch = 'x'
	name :: "LUA_ODIN_TEMP_ARENA_TEST_LONG"
	if !testing.expect(t, os.set_env(name, string(long_value[:])) == nil) do return
	defer os.unset_env(name)
	L := oslib_state()
	defer kernel.close_state(L)
	src := `
		for i = 1, 2000 do
			assert(#os.getenv('LUA_ODIN_TEMP_ARENA_TEST_LONG') == 4096)
			os.getenv('LUA_ODIN_TEMP_ARENA_TEST_MISSING')
			os.date('!%c %D %T %F %R', 1700000000)
			os.date('%c %Z %z', 1700000000)
			os.date('*t', 1700000000)
			assert(not pcall(os.date, '%Q', 1700000000))
			os.time({year=2023, month=11, day=14})
		end
	`
	temp := (^runtime.Default_Temp_Allocator)(runtime.default_context().temp_allocator.data)
	// Warm the implementation and make the comparison on the same thread.
	testing.expect_value(t, oslib_run(L, src), kernel.Thread_Status.Ok)
	before := temp.arena.total_used
	testing.expect_value(t, oslib_run(L, src), kernel.Thread_Status.Ok)
	testing.expect_value(t, temp.arena.total_used, before)
}

Host_String_Fail_Allocator :: struct {
	count: Counting_Allocator,
	fail: bool,
}

host_string_fail_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	a := (^Host_String_Fail_Allocator)(ud)
	if a.fail && nsize != 0 do return nil
	return counting_alloc(&a.count, ptr, osize, nsize)
}

getenv_oom_body :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	stdlib.aux_getenv_push(L, (^string)(ud)^)
	return .Ok
}

@(thread_local)
host_finalizer_saw_scope: bool
@(thread_local)
host_finalizer_ran: bool

// Set up an immediately pending finalizer without running it. The next
// api_pushstring GC check must happen only after the host arena scope is closed.
host_prepare_finalizer :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.gc_runtilstate(L, kernel.GCScallfin, true)
	queued := L.g.tobefnz != nil
	L.g.gcstp = 0
	kernel.state_setdebt(L.g, 0)
	kernel.api_pushboolean(L, queued)
	return 1
}

host_record_finalizer :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	temp := (^runtime.Default_Temp_Allocator)(context.temp_allocator.data)
	host_finalizer_saw_scope = temp.arena.temp_count != 0
	host_finalizer_ran = true
	return 0
}

@(test)
oslib_getenv_releases_scope_before_finalizer :: proc(t: ^testing.T) {
	long_value: [4096]u8
	for &ch in long_value do ch = 'f'
	name :: "LUA_ODIN_TEMP_ARENA_TEST_FINALIZER"
	if !testing.expect(t, os.set_env(name, string(long_value[:])) == nil) do return
	defer os.unset_env(name)
	L := kernel.new_state(kernel.default_allocator())
	defer kernel.close_state(L)
	stdlib.aux_openlibs(L)
	kernel.api_pushcfunction(L, host_prepare_finalizer)
	kernel.api_setglobal(L, "prepare_host_finalizer")
	kernel.api_pushcfunction(L, host_record_finalizer)
	kernel.api_setglobal(L, "record_host_finalizer")
	host_finalizer_ran = false
	host_finalizer_saw_scope = false
	status := oslib_run(L, `
		collectgarbage('incremental')
		local co = coroutine.create(function()
			collectgarbage('collect')
			collectgarbage('stop')
			local obj = setmetatable({}, {__gc = function()
				record_host_finalizer()
				coroutine.close()
			end})
			obj = nil
			assert(prepare_host_finalizer())
			os.getenv('LUA_ODIN_TEMP_ARENA_TEST_FINALIZER')
			error('the finalizer must close this coroutine')
		end)
		assert(coroutine.resume(co))
		assert(coroutine.status(co) == 'dead')
	`)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, host_finalizer_ran, "the queued finalizer must run")
	testing.expect(t, !host_finalizer_saw_scope, "finalizers cannot escape a host arena scope")
}

// The allocating getenv fallback has a host arena scope around a Lua string
// allocation. Exercise the actual longjmp, including the emergency-GC retry,
// rather than only testing the ordinary success and argument-error paths.
@(test)
oslib_getenv_oom_ends_temporary_scope :: proc(t: ^testing.T) {
	long_value: [4096]u8
	for &ch in long_value do ch = 'q'
	name := "LUA_ODIN_TEMP_ARENA_TEST_OOM"
	if !testing.expect(t, os.set_env(name, string(long_value[:])) == nil) do return
	defer os.unset_env(name)
	a: Host_String_Fail_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = host_string_fail_alloc, ud = &a})
	if !testing.expect(t, L != nil) do return
	temp := (^runtime.Default_Temp_Allocator)(runtime.default_context().temp_allocator.data)
	before := temp.arena.total_used
	for _ in 0 ..< 20 {
		a.fail = true
		status := kernel.run_protected(L, getenv_oom_body, &name)
		a.fail = false
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect_value(t, temp.arena.total_used, before)
	}
	kernel.close_state(L)
	testing.expect_value(t, a.count.outstanding, 0)
}
