package tests

// control_test.odin -- Phase 2 tests for the control/error protocol (control.odin).
//
// Errors unwind via a faithful setjmp/longjmp: `throw` jumps back to the nearest
// `run_protected`, which catches the status. These tests prove that boundary
// behaves like reference Lua's pcall boundary observably: it catches a raised
// error, reports the right status, does NOT leave the thread looking broken
// afterward, nests correctly, unlinks its boundary from the `errorJmp` chain,
// and relocates the error object to where the caller wants it.

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

// A protected computation that pushes a few scratch values and then raises a
// runtime error with a caller-supplied integer as the error object on top.
raising_proc :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	errval := (^i64)(ud)^
	kernel.set_int(kernel.stack_value(L, L.top), 111)
	L.top += 1
	kernel.set_int(kernel.stack_value(L, L.top), 222)
	L.top += 1
	kernel.set_int(kernel.stack_value(L, L.top), errval) // the error object
	L.top += 1
	return kernel.throw(L, .Err_Run)
}

// A protected computation that simply succeeds.
ok_proc :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	return .Ok
}

// `is_error_status` must draw the line exactly where reference Lua does: only
// codes above Yield are real errors.
@(test)
error_status_classification :: proc(t: ^testing.T) {
	testing.expect(t, !kernel.is_error_status(.Ok))
	testing.expect(t, !kernel.is_error_status(.Yield))
	testing.expect(t, kernel.is_error_status(.Err_Run))
	testing.expect(t, kernel.is_error_status(.Err_Syntax))
	testing.expect(t, kernel.is_error_status(.Err_Mem))
	testing.expect(t, kernel.is_error_status(.Err_Err))
}

// A protected boundary must catch a raised error, report its status, and unlink
// its boundary from the thread's `errorJmp` chain. Critically, the thread's own
// status must be left untouched -- a recovered error must not leave the thread
// observably broken.
@(test)
protected_boundary_catches_error :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	old_top := L.top
	errval: i64 = 4242
	status := kernel.run_protected(L, raising_proc, &errval)

	testing.expect_value(t, status, kernel.Thread_Status.Err_Run)
	testing.expect_value(t, L.status, kernel.Thread_Status.Ok) // NOT clobbered
	testing.expect(t, L.errorJmp == nil) // boundary unlinked

	// The error object sits at top-1; relocating it to old_top must land the
	// exact value we raised and leave top one slot past it.
	kernel.set_error_object(L, .Err_Run, old_top)
	testing.expect_value(t, kernel.int_value(kernel.stack_value(L, old_top)), 4242)
	testing.expect_value(t, L.top, old_top + 1)
}

// A successful protected call returns Ok and leaves the boundary chain balanced.
@(test)
protected_boundary_success :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	status := kernel.run_protected(L, ok_proc, nil)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, L.errorJmp == nil)
}

// Nested boundaries must each catch independently: an inner error swallowed by a
// middle layer must not escape to the outer boundary, and the boundary chain must
// unwind cleanly back to empty.
@(test)
protected_boundary_nests :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	errval: i64 = 7
	outer := kernel.run_protected(L, nested_outer, &errval)
	testing.expect_value(t, outer, kernel.Thread_Status.Ok)
	testing.expect(t, L.errorJmp == nil)
	testing.expect_value(t, L.status, kernel.Thread_Status.Ok)
}

// The outer computation runs an inner protected call that raises, confirms it
// caught Err_Run, and reports success -- modeling a pcall that recovers.
nested_outer :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	inner := kernel.run_protected(L, raising_proc, ud)
	if inner != .Err_Run {
		return .Err_Run // propagate an unexpected result so the test fails loudly
	}
	return .Ok
}

Jump_Stress_Shared :: struct {
	ok:          bool,
	catches:     int,
	next_status: kernel.Thread_Status,
}

Jump_Stress_Level :: struct {
	depth:           int,
	shared:          ^Jump_Stress_Shared,
	parent_sentinel: ^i64,
}

// Keep real native frames between the throw site and its landing pad. The local
// is observed after the recursive call so an optimized build cannot turn this
// into tail recursion; its address also escapes, forcing the value to memory
// rather than relying on LLVM understanding setjmp's missing "returns_twice"
// attribute.
deep_jump_stress :: #force_no_inline proc(L: ^kernel.State, depth: int, shared: ^Jump_Stress_Shared) -> kernel.Thread_Status {
	sentinel := i64(0x120000 + depth)
	sentinel_ptr := &sentinel
	if depth == 0 {
		shared.next_status = .Err_Syntax
		L.n_ccalls = 900
		return kernel.throw(L, .Err_Syntax)
	}
	status := deep_jump_stress(L, depth - 1, shared)
	if sentinel_ptr^ != i64(0x120000 + depth) {
		shared.ok = false
	}
	return status
}

// Every level catches the child at a different native depth, verifies a local
// which was live across that jump, then throws again to its own parent. This
// proves that the errorJmp chain routes each jump to the innermost live buffer.
jump_stress_level :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	level := (^Jump_Stress_Level)(ud)
	if level.parent_sentinel != nil &&
	   level.parent_sentinel^ != i64(0x340000 + level.depth + 1) {
		level.shared.ok = false
	}
	if level.depth == 0 {
		return deep_jump_stress(L, 200, level.shared)
	}

	sentinel := i64(0x340000 + level.depth)
	child := Jump_Stress_Level{
		depth = level.depth - 1,
		shared = level.shared,
		parent_sentinel = &sentinel,
	}
	before_ccalls := L.n_ccalls + 3
	L.n_ccalls = before_ccalls
	float_sentinel := f64(before_ccalls)*1.25 + 0.5
	status := kernel.run_protected(L, jump_stress_level, &child)
	if status != level.shared.next_status ||
	   sentinel != i64(0x340000 + level.depth) ||
	   float_sentinel != f64(before_ccalls)*1.25 + 0.5 ||
	   L.n_ccalls != before_ccalls {
		level.shared.ok = false
	}
	level.shared.catches += 1
	level.shared.next_status = .Err_Run if status == .Err_Syntax else .Err_Syntax
	return kernel.throw(L, level.shared.next_status)
}

// This is intentionally harsher than a normal pcall: 200 native recursive
// frames, five successive jumps through nested boundaries, escaping locals,
// and deliberate n_ccalls damage at the throw site. Removing #force_no_inline,
// saving the wrong stack pointer/register set, or unlinking the wrong boundary
// makes this crash or fail its exact restoration checks under -o:speed.
@(test)
protected_boundary_machine_state_stress :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	L.n_ccalls = 37
	shared := Jump_Stress_Shared{ok = true}
	root := Jump_Stress_Level{depth = 4, shared = &shared}
	status := kernel.run_protected(L, jump_stress_level, &root)

	testing.expect_value(t, status, kernel.Thread_Status.Err_Syntax)
	testing.expect(t, shared.ok, "live locals and nested landing pads survived every jump")
	testing.expect_value(t, shared.catches, 4)
	testing.expect_value(t, L.n_ccalls, 37)
	testing.expect(t, L.errorJmp == nil, "all protected-boundary nodes were unlinked")
	testing.expect_value(t, L.status, kernel.Thread_Status.Ok)
}

// Drive the same mechanism through the public Lua surface. The chunk combines
// several nested pcalls, deep errors from a metamethod, errors crossing a
// coroutine boundary, and locals/tables whose exact values must remain intact
// after each catch. The final host-side checks also prove that the outer API
// boundary restored its chain and C-call accounting.
@(test)
protected_boundary_lua_surface_stress :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)
	stdlib.aux_openlibs(L)

	before_ccalls := L.n_ccalls
	source :=
		"local survivor = {tag='alive', value=0x12345}\n" +
		"local function deep(n, message)\n" +
		"  local keep = n * 17 + 3\n" +
		"  if n == 0 then error(message) end\n" +
		"  deep(n - 1, message)\n" +
		"  return keep\n" +
		"end\n" +
		"local ok_outer, err_outer = pcall(function()\n" +
		"  local outer_local = 'outer survives'\n" +
		"  local ok1, err1 = pcall(function() deep(90, 'inner-one') end)\n" +
		"  assert(not ok1 and err1:find('inner-one', 1, true))\n" +
		"  local ok2, err2 = pcall(function()\n" +
		"    local middle = 0x55aa\n" +
		"    local ok3, err3 = pcall(function() deep(130, 'inner-three') end)\n" +
		"    assert(not ok3 and err3:find('inner-three', 1, true))\n" +
		"    assert(middle == 0x55aa)\n" +
		"    error('middle-two')\n" +
		"  end)\n" +
		"  assert(not ok2 and err2:find('middle-two', 1, true))\n" +
		"  assert(outer_local == 'outer survives')\n" +
		"  error('outer-four')\n" +
		"end)\n" +
		"assert(not ok_outer and err_outer:find('outer-four', 1, true))\n" +
		"local mt = {__add=function() deep(110, 'metamethod-jump') end}\n" +
		"local operand = setmetatable({}, mt)\n" +
		"local ok_meta, err_meta = pcall(function() return operand + 1 end)\n" +
		"assert(not ok_meta and err_meta:find('metamethod-jump', 1, true))\n" +
		"local co = coroutine.create(function()\n" +
		"  local co_keep = {17, 29}\n" +
		"  local ok_inner, err_inner = pcall(function() deep(75, 'co-inner') end)\n" +
		"  assert(not ok_inner and err_inner:find('co-inner', 1, true))\n" +
		"  assert(co_keep[1] == 17 and co_keep[2] == 29)\n" +
		"  coroutine.yield('caught-inner')\n" +
		"  return operand + 2\n" +
		"end)\n" +
		"local r1, yielded = coroutine.resume(co)\n" +
		"assert(r1 and yielded == 'caught-inner')\n" +
		"local r2, co_err = coroutine.resume(co)\n" +
		"assert(not r2 and co_err:find('metamethod-jump', 1, true))\n" +
		"assert(coroutine.status(co) == 'dead')\n" +
		"assert(survivor.tag == 'alive' and survivor.value == 0x12345)\n" +
		"return 0x5eed"

	testing.expect_value(t, stdlib.aux_loadstring(L, source), kernel.Thread_Status.Ok)
	status := kernel.api_pcall(L, 0, 1, 0)
	if status != .Ok {
		message, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "jump stress chunk failed: %s", message)
		return
	}
	testing.expect_value(t, kernel.api_tointeger(L, -1), i64(0x5eed))
	testing.expect_value(t, L.n_ccalls, before_ccalls)
	testing.expect(t, L.errorJmp == nil, "public pcall left no protected boundary linked")
	testing.expect_value(t, L.status, kernel.Thread_Status.Ok)
}
