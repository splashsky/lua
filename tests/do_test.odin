package tests

// do_test.odin -- Phase 2 tests for index-safe stack growth (do.odin).
//
// The whole reason the kernel addresses stack slots by index instead of pointer
// is so a reallocation never invalidates anything. These tests prove exactly
// that observable property: values written before a grow/shrink are still there,
// at the same indices, afterward -- and freshly exposed slots read back as nil.

import "core:testing"
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
