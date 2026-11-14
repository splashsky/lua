package tests

// do_test.odin -- Phase 2 tests for index-safe stack growth (do.odin).
//
// Persistent stack slots are addressed by index, so growth cannot invalidate
// them. The VM's temporary register base is separately refreshed on a move.
// These tests check preserved values, forced moves, and the frame traps.

import "core:testing"
import "base:runtime"
import kernel "lang:kernel"

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
	testing.expect_value(t, L.nci, L.ci + 1)
	inuse := kernel.stack_in_use(L)
	testing.expect(t, L.stack_size <= inuse * 2, "unwound frames must not prevent stack shrinking")
}
