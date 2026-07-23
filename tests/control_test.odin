package tests

// control_test.odin -- Phase 2 tests for the control/error protocol (control.odin).
//
// Odin has no setjmp/longjmp, so we unwind errors by returning statuses and
// catching them at protected boundaries. These tests prove that boundary behaves
// like reference Lua's pcall boundary observably: it catches a raised error,
// reports the right status, does NOT leave the thread looking broken afterward,
// nests correctly, and relocates the error object to where the caller wants it.

import "core:testing"
import lua "luao:lua"

// A protected computation that pushes a few scratch values and then raises a
// runtime error with a caller-supplied integer as the error object on top.
raising_proc :: proc(L: ^lua.Lua_State, ud: rawptr) -> lua.Thread_Status {
	errval := (^i64)(ud)^
	lua.set_int(lua.stack_value(L, L.top), 111)
	L.top += 1
	lua.set_int(lua.stack_value(L, L.top), 222)
	L.top += 1
	lua.set_int(lua.stack_value(L, L.top), errval) // the error object
	L.top += 1
	return lua.throw(L, .Err_Run)
}

// A protected computation that simply succeeds.
ok_proc :: proc(L: ^lua.Lua_State, ud: rawptr) -> lua.Thread_Status {
	return .Ok
}

// `is_error_status` must draw the line exactly where reference Lua does: only
// codes above Yield are real errors.
@(test)
error_status_classification :: proc(t: ^testing.T) {
	testing.expect(t, !lua.is_error_status(.Ok))
	testing.expect(t, !lua.is_error_status(.Yield))
	testing.expect(t, lua.is_error_status(.Err_Run))
	testing.expect(t, lua.is_error_status(.Err_Syntax))
	testing.expect(t, lua.is_error_status(.Err_Mem))
	testing.expect(t, lua.is_error_status(.Err_Err))
}

// A protected boundary must catch a raised error, report its status, and restore
// the boundary depth to what it was. Critically, the thread's own status must be
// left untouched -- a recovered error must not leave the thread observably broken.
@(test)
protected_boundary_catches_error :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	old_top := L.top
	errval: i64 = 4242
	status := lua.run_protected(L, raising_proc, &errval)

	testing.expect_value(t, status, lua.Thread_Status.Err_Run)
	testing.expect_value(t, L.status, lua.Thread_Status.Ok) // NOT clobbered
	testing.expect_value(t, L.error_boundary_depth, 0) // depth restored

	// The error object sits at top-1; relocating it to old_top must land the
	// exact value we raised and leave top one slot past it.
	lua.set_error_object(L, .Err_Run, old_top)
	testing.expect_value(t, lua.int_value(lua.stack_value(L, old_top)), 4242)
	testing.expect_value(t, L.top, old_top + 1)
}

// A successful protected call returns Ok and leaves the boundary depth balanced.
@(test)
protected_boundary_success :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	status := lua.run_protected(L, ok_proc, nil)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, L.error_boundary_depth, 0)
}

// Nested boundaries must each catch independently: an inner error swallowed by a
// middle layer must not escape to the outer boundary, and the depth counter must
// unwind cleanly to zero.
@(test)
protected_boundary_nests :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	errval: i64 = 7
	outer := lua.run_protected(L, nested_outer, &errval)
	testing.expect_value(t, outer, lua.Thread_Status.Ok)
	testing.expect_value(t, L.error_boundary_depth, 0)
	testing.expect_value(t, L.status, lua.Thread_Status.Ok)
}

// The outer computation runs an inner protected call that raises, confirms it
// caught Err_Run, and reports success -- modeling a pcall that recovers.
nested_outer :: proc(L: ^lua.Lua_State, ud: rawptr) -> lua.Thread_Status {
	inner := lua.run_protected(L, raising_proc, ud)
	if inner != .Err_Run {
		return .Err_Run // propagate an unexpected result so the test fails loudly
	}
	return .Ok
}
