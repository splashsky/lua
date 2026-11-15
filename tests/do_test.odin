package tests

// do_test.odin -- Phase 2 tests for index-safe stack growth (do.odin).
//
// Persistent stack slots are addressed by index, so growth cannot invalidate
// them. The VM's temporary register base is separately refreshed on a move.
// These tests check preserved values, forced moves, and the frame traps.

import "core:testing"
import "base:runtime"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

// Growing the stack must preserve every existing slot's value at its index and
// nil-fill the new region. Shrinking must preserve the low slots it keeps.
@(test)
stack_growth_preserves_indices :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// Plant a sentinel inside the initial stack and remember where top is.
	kernel.set_int(kernel.stack_value(L, 10), 999)
	old_top := L.top

	// Grow well past the initial size.
	testing.expect_value(t, kernel.realloc_stack(L, 200, false), kernel.Thread_Status.Ok)
	testing.expect_value(t, L.stack_size, 200)

	// The sentinel survived the move at the very same index.
	testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 999)
	// top is an index, so it is unchanged by the reallocation.
	testing.expect_value(t, L.top, old_top)
	// A slot in the newly grown region reads back as nil.
	testing.expect(t, kernel.is_nil(kernel.stack_value(L, 100)), "grown region must be nil-filled")

	// Shrinking back keeps the low slots that remain in range.
	testing.expect_value(t, kernel.realloc_stack(L, kernel.BASIC_STACK_SIZE, false), kernel.Thread_Status.Ok)
	testing.expect_value(t, L.stack_size, kernel.BASIC_STACK_SIZE)
	testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 999)
}

// grow_stack must honor the "at least what was asked for" rule: when the 1.5x
// growth is not enough, it grows exactly to top + n.
@(test)
grow_stack_respects_request :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// From BASIC_STACK_SIZE (40), 1.5x is 60, but top(1)+1000 = 1001 wins.
	testing.expect_value(t, kernel.grow_stack(L, 1000, false), kernel.Thread_Status.Ok)
	testing.expect_value(t, L.stack_size, L.top + 1000)
}

// stack_in_use reports the furthest live top (here the base frame's top),
// floored at LUA_MINSTACK.
@(test)
stack_in_use_reports_frame_extent :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// Base frame top is 1 + LUA_MINSTACK; in-use is that plus one slot.
	testing.expect_value(t, kernel.stack_in_use(L), 1 + kernel.MINSTACK + 1)
}

@(test)
stack_in_use_without_frame_array :: proc(t: ^testing.T) {
	// The allocation-free thread baseline has no base frame yet.
	L: kernel.State
	testing.expect_value(t, kernel.stack_in_use(&L), kernel.MINSTACK)
}

// Forced moves must really change the backing address, preserve values, and
// keep the allocator's live-byte accounting balanced.
@(test)
stack_hard_checks_move :: proc(t: ^testing.T) {
	when kernel.HARDSTACKTESTS {
		L := kernel.new_state(kernel.default_allocator())
		testing.expect(t, L != nil)
		defer kernel.close_state(L)
		kernel.set_int(kernel.stack_value(L, 10), 12345)
		old := uintptr(L.stack)
		bytes := kernel.gettotalbytes(L.g)
		testing.expect_value(t, kernel.check_stack(L, 1), kernel.Thread_Status.Ok)
		testing.expect(t, uintptr(L.stack) != old, "check must move the stack")
		testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 12345)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
		old = uintptr(L.stack)
		kernel.check_stack_p(L, 1)
		testing.expect(t, uintptr(L.stack) != old, "inline check must move the stack")
		testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 12345)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
		old = uintptr(L.stack)
		testing.expect(t, kernel.api_checkstack(L, 1))
		testing.expect(t, uintptr(L.stack) != old, "API check must move the stack")
		testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 12345)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
		old = uintptr(L.stack)
		kernel.shrink_stack(L)
		testing.expect(t, uintptr(L.stack) != old, "shrink path must move the stack")
		testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 12345)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
	}
}

@(test)
stack_hard_move_failure_preserves_old_block :: proc(t: ^testing.T) {
	when kernel.HARDSTACKTESTS {
		c: Counting_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = counting_alloc, ud = &c})
		testing.expect(t, L != nil)
		kernel.set_int(kernel.stack_value(L, 10), 12345)
		old := uintptr(L.stack)
		old_size, old_top := L.stack_size, L.top
		old_bytes := kernel.gettotalbytes(L.g)
		old_outstanding := c.outstanding
		c.fail_at = c.alloc_index
		c.fail_enabled = true
		testing.expect_value(t, kernel.realloc_stack(L, L.stack_size, false), kernel.Thread_Status.Err_Mem)
		testing.expect_value(t, uintptr(L.stack), old)
		testing.expect_value(t, L.stack_size, old_size)
		testing.expect_value(t, L.top, old_top)
		testing.expect_value(t, kernel.int_value(kernel.stack_value(L, 10)), 12345)
		testing.expect_value(t, kernel.gettotalbytes(L.g), old_bytes)
		testing.expect_value(t, c.outstanding, old_outstanding)
		c.fail_enabled = false
		kernel.close_state(L)
		testing.expect_value(t, c.outstanding, 0)
	}
}

// Every frame push in stress mode must move even when capacity is sufficient.
// Verify the old live frames, accounting, and trap arming before initializing the
// new slot. The temporary Lua frame does not execute or invoke the collector.
@(test)
frame_hard_push_moves_and_arms :: proc(t: ^testing.T) {
	when kernel.HARDSTACKTESTS {
		L := kernel.new_state(kernel.default_allocator())
		testing.expect(t, L != nil)
		defer kernel.close_state(L)
		old := uintptr(L.frames)
		bytes := kernel.gettotalbytes(L.g)
		base_top := L.frames[0].top
		testing.expect_value(t, kernel.next_ci(L), 1)
		testing.expect(t, uintptr(L.frames) != old, "frame push must move the array")
		testing.expect_value(t, L.frames[0].top, base_top)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
		L.frames[1] = kernel.Call_Info{}
		L.frames[1].top = 42
		old = uintptr(L.frames)
		testing.expect_value(t, kernel.next_ci(L), 2)
		testing.expect(t, uintptr(L.frames) != old, "subsequent push must move the array")
		testing.expect_value(t, L.frames[1].top, 42)
		testing.expect_value(t, L.frames[1].u.l.trap, 1)
		testing.expect_value(t, kernel.gettotalbytes(L.g), bytes)
		// Fill the remaining capacity with initialized C frames, then force a
		// capacity-growing move as well as the no-growth moves above.
		L.frames[2] = kernel.Call_Info{}
		L.frames[2].callstatus = kernel.CIST_C
		for i in 3 ..< kernel.INITIAL_FRAMES {
			testing.expect_value(t, kernel.next_ci(L), i)
			L.frames[i] = kernel.Call_Info{}
			L.frames[i].callstatus = kernel.CIST_C
		}
		old = uintptr(L.frames)
		old_capacity := L.frames_capacity
		testing.expect_value(t, kernel.next_ci(L), kernel.INITIAL_FRAMES)
		testing.expect(t, uintptr(L.frames) != old, "growing push must move the array")
		testing.expect(t, L.frames_capacity > old_capacity)
		testing.expect_value(t, L.frames[1].top, 42)
		testing.expect_value(t, L.frames[1].u.l.trap, 1)
		L.ci = 0
	}
}

// A failed forced frame move must leave both the old array and its accounting
// intact and restore the emergency-GC guard before the memory error is thrown.
@(test)
frame_hard_move_failure_preserves_old_block :: proc(t: ^testing.T) {
	when kernel.HARDSTACKTESTS {
		c: Counting_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = counting_alloc, ud = &c})
		testing.expect(t, L != nil)
		old := uintptr(L.frames)
		old_bytes := kernel.gettotalbytes(L.g)
		old_outstanding := c.outstanding
		old_gcstop := L.g.gcstopem
		c.fail_at = c.alloc_index
		c.fail_enabled = true
		status := kernel.run_protected(L, proc(L: ^kernel.State, _: rawptr) -> kernel.Thread_Status {
			kernel.next_ci(L)
			return .Ok
		}, nil)
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect_value(t, uintptr(L.frames), old)
		testing.expect_value(t, L.ci, 0)
		testing.expect_value(t, L.g.gcstopem, old_gcstop)
		testing.expect_value(t, kernel.gettotalbytes(L.g), old_bytes)
		testing.expect_value(t, c.outstanding, old_outstanding)
		c.fail_enabled = false
		kernel.close_state(L)
		testing.expect_value(t, c.outstanding, 0)
	}
}

// Force frame growth without moving the value stack. This checks that callers
// return to the right Lua frames and that frame relocation arms their traps.
frame_move_probe :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	old_ci := L.ci
	old_stack := uintptr(L.stack)
	old_capacity := L.frames_capacity
	ok := true
	for L.frames_capacity == old_capacity {
		when kernel.HARDSTACKTESTS {old_frames := uintptr(L.frames)}
		idx := kernel.next_ci(L)
		when kernel.HARDSTACKTESTS {ok = ok && uintptr(L.frames) != old_frames}
		L.frames[idx] = kernel.Call_Info{}
		L.frames[idx].func = L.frames[old_ci].func
		L.frames[idx].top = L.frames[old_ci].top
		L.frames[idx].callstatus = kernel.CIST_C
	}
	L.ci = old_ci
	ok = ok && uintptr(L.stack) == old_stack
	lua_frames := 0
	for i in 0 ..= L.ci {
		if kernel.is_lua_frame(&L.frames[i]) {
			lua_frames += 1
			ok = ok && L.frames[i].u.l.trap != 0
		}
	}
	kernel.api_pushboolean(L, ok && lua_frames >= 2)
	return 1
}

@(test)
frame_move_arms_suspended_lua_frames :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, frame_move_probe)
	kernel.api_setglobal(L, "probe")
	rd: Src_Reader
	src := "local function inner(x) if not probe() then return -99 end; return x+22 end; " +
	       "local function outer(x) local n=inner(x); return n+1 end; local n=outer(100); return n+1"
	testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 124)
}

// Reallocation from a native callback must arm every suspended Lua frame.
// The return to Lua then exercises the VM's local-base refresh without hooks.
stack_move_probe :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	old := uintptr(L.stack)
	st := kernel.realloc_stack(L, L.stack_size, false)
	ok := st == .Ok
	when kernel.HARDSTACKTESTS {ok = ok && uintptr(L.stack) != old}
	lua_frames := 0
	for i in 0 ..= L.ci {
		if kernel.is_lua_frame(&L.frames[i]) {
			lua_frames += 1
			ok = ok && L.frames[i].u.l.trap != 0
		}
	}
	kernel.api_pushboolean(L, ok && lua_frames >= 2)
	return 1
}

// The VM resolves closure upvalues from its current register base. Exercise
// both open and closed upvalues before and after a forced stack relocation.
@(test)
upvalue_access_survives_vm_stack_move :: proc(t: ^testing.T) {
	sources := [2]string {
		"local function outer(x) local function inner() x=x+1; " +
		"if not probe() then return -1 end; x=x+1; return x end; " +
		"local r=inner(); return r end; return outer(40)",
		"local function make() local x=40; return function() x=x+1; " +
		"if not probe() then return -1 end; x=x+1; return x end end; " +
		"local f=make(); local r=f(); return r",
	}
	for src in sources {
		L := api_new()
		kernel.api_pushcfunction(L, stack_move_probe)
		kernel.api_setglobal(L, "probe")
		rd: Src_Reader
		testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_tointeger(L, -1), 42)
		kernel.close_state(L)
	}
}

@(test)
stack_move_arms_suspended_lua_frames :: proc(t: ^testing.T) {
	L := api_new()
	testing.expect(t, L != nil)
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stack_move_probe)
	kernel.api_setglobal(L, "probe")
	rd: Src_Reader
	src := "local function inner(x) if not probe() then return -99 end; return x+22 end; " +
	       "local function outer(x) local n=inner(x); return n+1 end; local n=outer(100); return n+1"
	testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 124)
}

// Every metamethod returns to an instruction that must discard any stale base.
// Keep live registers after each call, and cover a to-be-closed value and an
// iterator as well as varargs. In HARDSTACKTESTS every probe changes address.
@(test)
stack_move_through_vm_operations :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stack_move_probe)
	kernel.api_setglobal(L, "probe")
	src := `
local function moved() assert(probe()) end
local mt = {
  __index = function(t, k) moved(); return 17 end,
  __newindex = function(t, k, v) moved(); rawset(t, k, v) end,
  __add = function(a, b) moved(); return 23 end,
  __len = function(a) moved(); return 29 end,
  __eq = function(a, b) moved(); return true end,
  __lt = function(a, b) moved(); return true end,
  __concat = function(a, b) moved(); return 'joined' end,
  __call = function(a, ...) moved(); return ... end,
  __close = function(a) moved() end,
}
local a, b = setmetatable({}, mt), setmetatable({}, mt)
local keep = 100
assert(a.missing + keep == 117)
a.x = 7; assert(a.x + keep == 107)
assert((a + b) + keep == 123 and #a + keep == 129)
assert(a == b and a < b and (a .. b) == 'joined')
assert(a(keep, 2) == 100)
local function iter(_, n) moved(); if n < 3 then return n+1 end end
local sum = 0
for i in iter, nil, 0 do sum = sum + i end
do local c <close> = a end
local function var(a, ...) moved(); return a + ... end
assert(var(keep, sum) == 106)
return keep + sum
`
	testing.expect_value(t, corolib_run(L, src), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 106)
}

// An error longjmps past Lua frames; their old tops must not keep the enlarged
// stack alive or make a later overflow look like an error in error handling.
@(test)
pcall_unwind_discards_frame_extents :: proc(t: ^testing.T) {
	L := api_new()
	testing.expect(t, L != nil)
	defer kernel.close_state(L)
	rd: Src_Reader
	src := "local function f(n) if n==0 then return nil+1 end; return 1+f(n-1) end; return f(80)"
	testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Err_Run)
	testing.expect_value(t, L.ci, 0)
	inuse := kernel.stack_in_use(L)
	testing.expect(t, L.stack_size <= inuse * 2, "unwound frames must not prevent stack shrinking")
}

// Reuse frames with different argument/result counts, including from hooks and
// resumable closes. In stress mode every stack and frame check relocates.
@(test)
call_frame_missing_arguments_and_continuations :: proc(t: ^testing.T) {
	L := dbg_state()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stdlib.open_coroutine)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "coroutine")
	src := `
local function fixed(a, b, c, d, e, f)
  collectgarbage('collect')
  return a, b, c, d, e, f
end
for i = 1, 25 do
  local a,b,c,d,e,f = fixed('alive')
  assert(a == 'alive' and b == nil and c == nil and d == nil and e == nil and f == nil)
  a,b,c,d,e,f = fixed(1,2,3,4,5,6,7,8)
  assert(a == 1 and b == 2 and c == 3 and d == 4 and e == 5 and f == 6)
end
local function var(a,b,...)
  collectgarbage('collect')
  return a,b,select('#',...),...
end
local a,b,c,n,x,y,z
a,b,n,x,y,z = var('ok')
assert(a == 'ok' and b == nil and n == 0 and x == nil)
a,b,n,x,y,z = var('ok',nil,2,nil,4)
assert(a == 'ok' and b == nil and n == 3 and x == 2 and y == nil and z == 4)
local obj = setmetatable({}, {__call = function(self, a, b, c)
  assert(self ~= nil and a == 8 and b == nil and c == nil)
  return a,b,c
end})
a,b,c = obj(8)
assert(a == 8 and b == nil and c == nil)

local function target(a,b,c) return a,b,c end
local calls, returns, lines, counts = 0,0,0,0
local function deep(n) if n > 0 then return 1 + deep(n-1) end return 0 end
debug.sethook(function(event)
  if event == 'line' then lines = lines + 1 end
  if event == 'count' then counts = counts + 1 end
  local info = debug.getinfo(2, 'fl')
  if info.func == target then
    assert(info.currentline > 0)
    if event == 'call' then
      assert(calls == 0 and returns == 0)
      calls = calls + 1
      local _, x = debug.getlocal(2, 1)
      local _, y = debug.getlocal(2, 2)
      local _, z = debug.getlocal(2, 3)
      assert(x == 17 and y == nil and z == nil)
      assert(deep(30) == 30)
    elseif event == 'return' then
      assert(calls == 1 and returns == 0)
      returns = returns + 1
    end
  end
end, 'crl', 2)
a,b,c = target(17)
debug.sethook()
assert(a == 17 and b == nil and c == nil)
assert(calls == 1 and returns == 1 and lines > 0 and counts > 0)

local co = coroutine.create(function()
  return pcall(function()
    local v <close> = setmetatable({}, {__close = function() coroutine.yield('close') end})
    coroutine.yield('body')
    return 'done', 9
  end)
end)
local ok, v, w = coroutine.resume(co)
assert(ok and v == 'body')
collectgarbage('collect')
ok, v, w = coroutine.resume(co)
assert(ok and v == 'close')
collectgarbage('collect')
local s
ok, s, v, w = coroutine.resume(co)
assert(ok and s and v == 'done' and w == 9)
assert(coroutine.status(co) == 'dead')
`
	status := dbg_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "call protocol failed: %s", msg)
	}
}

// Tail calls reuse the current frame and slide overlapping function/argument
// slots after a stack check. Cover fewer and extra arguments, hidden varargs,
// and a __call retry while forced relocation is enabled by the stress build.
@(test)
tail_call_argument_slide_survives_relocation :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	src := `
local function sink(a,b,c,d,e)
  collectgarbage('collect')
  return a,b,c,d,e
end
local function pass(a,...) return sink(a,...) end
local a,b,c,d,e = pass('keep')
assert(a == 'keep' and b == nil and c == nil and d == nil and e == nil)
a,b,c,d,e = pass('keep',nil,3,4,5,6)
assert(a == 'keep' and b == nil and c == 3 and d == 4 and e == 5)
local callable = setmetatable({}, {__call = function(self,a,b,c)
  assert(self ~= nil and a == 7 and b == nil and c == nil)
  return a,b,c
end})
local function via(...) return callable(...) end
a,b,c = via(7)
assert(a == 7 and b == nil and c == nil)
local function again(n,a,...)
  if n == 0 then return a,... end
  return again(n-1,a,...)
end
a,b,c,d = again(40,1,nil,3,4)
assert(a == 1 and b == nil and c == 3 and d == 4)
`
	status := corolib_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "tail-call argument slide failed: %s", msg)
	}
}

// These callbacks are entered through the VM's native CALL path, not through
// an embedding API call. The close callback leaves a marked slot for poscall.
precall_vm_results :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	n := kernel.api_tointeger(L, 1)
	kernel.api_pushinteger(L, n + 1)
	kernel.api_pushinteger(L, n + 2)
	kernel.api_pushinteger(L, n + 3)
	return 3
}

precall_vm_close :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.api_toclose(L, 1)
	kernel.api_pushinteger(L, 123)
	return 1
}

@(test)
vm_precall_fast_and_fallback_paths :: proc(t: ^testing.T) {
	L := dbg_state()
	defer kernel.close_state(L)
	kernel.api_pushcfunction(L, stdlib.open_coroutine)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "coroutine")
	kernel.api_pushcfunction(L, precall_vm_results)
	kernel.api_setglobal(L, "native_results")
	kernel.api_pushinteger(L, 99)
	kernel.api_pushcclosure(L, precall_vm_results, 1)
	kernel.api_setglobal(L, "native_closure")
	kernel.api_pushcfunction(L, precall_vm_close)
	kernel.api_setglobal(L, "native_close")
	kernel.api_pushcfunction(L, frame_move_probe)
	kernel.api_setglobal(L, "framemove")
	kernel.api_pushcfunction(L, stack_move_probe)
	kernel.api_setglobal(L, "stackmove")
	src := `
local function exercise(n)
  native_results(n)
  local x = native_results(n)
  local a,b,c = native_results(n)
  assert(x == n+1 and a == n+1 and b == n+2 and c == n+3)
  return select('#', native_results(n))
end
assert(exercise(10) == 3)
local a,b,c = native_closure(11)
assert(a == 12 and b == 13 and c == 14)
local function moved()
  assert(stackmove())
  assert(framemove())
  return exercise(20)
end
assert(moved() == 3)
local events = ''
debug.sethook(function(event)
  local f = debug.getinfo(2, 'f').func
  if f == native_results or f == native_closure then
    if event == 'call' then events = events .. 'c'
    elseif event == 'return' then events = events .. 'r' end
  end
end, 'cr')
a,b,c = native_results(30)
local d,e,f = native_closure(35)
debug.sethook()
assert(a == 31 and b == 32 and c == 33 and d == 36 and e == 37 and f == 38)
assert(events == 'crcr')
local called = setmetatable({}, {__call = function(_, x) return native_results(x) end})
a,b,c = called(40)
assert(a == 41 and b == 42 and c == 43)
local closed = 0
local resource = setmetatable({}, {__close = function() closed = closed + 1 end})
local sawreturn = false
debug.sethook(function(event)
  if event == 'return' and debug.getinfo(2, 'f').func == native_close then
    assert(closed == 1)
    sawreturn = true
  end
end, 'r')
local result = native_close(resource)
debug.sethook()
assert(result == 123 and closed == 1 and sawreturn)
local co = coroutine.create(function()
  local value = coroutine.yield('body')
  local x,y,z = native_results(value)
  local r = setmetatable({}, {__close = function() coroutine.yield('close') end})
  local last = native_close(r)
  return x,y,z,last
end)
local ok, x = coroutine.resume(co)
assert(ok and x == 'body')
ok, x = coroutine.resume(co, 50)
assert(ok and x == 'close')
local y,z,last
ok,x,y,z,last = coroutine.resume(co)
assert(ok and x == 51 and y == 52 and z == 53 and last == 123)
assert(coroutine.status(co) == 'dead')
`
	status := dbg_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "VM precall: %s", msg)
	}
}
