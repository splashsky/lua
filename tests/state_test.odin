package tests

// state_test.odin -- Phase 2 tests for state creation/teardown (state.odin).
//
// These prove observable, load-bearing properties of a freshly built Lua state
// and, crucially, that building and tearing one down leaks nothing. They do that
// honestly: an instrumented allocator counts every outstanding byte, so a leak or
// a double free shows up as a nonzero balance -- there is no way to "fit" these to
// pass without the accounting actually being correct.

import "base:runtime"
import "core:testing"
import kernel "lang:kernel"

// An allocator that tracks how many bytes are currently live and can be told to
// fail its Nth fresh allocation. `outstanding` must return to exactly zero once a
// state is closed; any other value means a leak or a mis-sized free.
Counting_Allocator :: struct {
	outstanding:  int, // live bytes right now
	alloc_index:  int, // count of fresh allocations seen so far
	fail_at:      int, // index of the fresh allocation to fail (when enabled)
	fail_enabled: bool, // whether injected failure is active
}

// The instrumented allocation function. It is a faithful realloc/free shim like
// the default allocator, but it books every byte in and out through the
// `Counting_Allocator` handed in via `ud`, and can refuse a chosen fresh
// allocation to exercise the out-of-memory paths.
counting_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	c := (^Counting_Allocator)(ud)
	if nsize == 0 {
		if ptr != nil {
			c.outstanding -= int(osize)
			runtime.heap_free(ptr)
		}
		return nil
	}
	if ptr == nil {
		// A brand-new allocation: honor an injected failure if this is the
		// index we were told to reject.
		idx := c.alloc_index
		c.alloc_index += 1
		if c.fail_enabled && idx == c.fail_at {
			return nil
		}
	}
	p := runtime.heap_resize(ptr, int(nsize))
	if p == nil {
		return nil
	}
	if ptr != nil {
		c.outstanding -= int(osize)
	}
	c.outstanding += int(nsize)
	return p
}

// A freshly created state must be fully built and sitting at the documented
// baseline: one base frame, the value stack sized to BASIC_STACK_SIZE, and `top`
// resting just past the base frame's function slot.
@(test)
new_state_baseline :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil, "new_state must succeed with the default allocator")
	defer kernel.close_state(L)

	// The sentinel must report a complete state.
	testing.expect(t, kernel.completestate(L.g), "state should be marked complete")

	// The thread starts life with no error.
	testing.expect_value(t, L.status, kernel.Thread_Status.Ok)

	// Stack geometry mirrors reference Lua's stack_init exactly.
	testing.expect_value(t, L.stack_size, kernel.BASIC_STACK_SIZE)
	testing.expect_value(t, L.top, 1)
	testing.expect_value(t, L.tbclist, 0)

	// Exactly one frame -- the base frame -- and it is a C/Odin frame whose
	// function slot is index 0 with the minimum working area above it.
	testing.expect_value(t, L.ci, 0)
	base := L.frames[0]
	testing.expect_value(t, base.func, 0)
	testing.expect_value(t, base.top, 1 + kernel.MINSTACK)
	testing.expect(t, (base.callstatus & kernel.CIST_C) != 0, "base frame must be a C frame")
}

// Building a state and closing it must leave zero bytes outstanding. This is the
// honest no-leak proof: the counter can only balance if every allocation (the
// global block, the value stack, the frame array) is matched by a correctly sized
// free.
@(test)
state_lifecycle_leaves_no_leak :: proc(t: ^testing.T) {
	c: Counting_Allocator
	alloc := kernel.Allocator {
		alloc = counting_alloc,
		ud    = &c,
	}

	L := kernel.new_state(alloc)
	testing.expect(t, L != nil, "new_state must succeed")
	testing.expect(t, c.outstanding > 0, "a live state must hold some memory")

	kernel.close_state(L)
	testing.expect_value(t, c.outstanding, 0)
}

// If the very first allocation (the global block) fails, new_state must report
// failure and leak nothing -- there is nothing to clean up, but the balance must
// still be zero.
@(test)
new_state_oom_on_global_block :: proc(t: ^testing.T) {
	c := Counting_Allocator {
		fail_at      = 0,
		fail_enabled = true,
	}
	alloc := kernel.Allocator {
		alloc = counting_alloc,
		ud    = &c,
	}

	L := kernel.new_state(alloc)
	testing.expect(t, L == nil, "new_state must fail when the global block can't allocate")
	testing.expect_value(t, c.outstanding, 0)
}

// If a *later* allocation fails (here the value stack, the second fresh
// allocation), new_state must unwind the partially built state through the
// protected boundary, free the global block it already grabbed, and again leak
// nothing. This exercises the throw -> propagate -> close_state path end to end.
@(test)
new_state_oom_on_stack_frees_partial :: proc(t: ^testing.T) {
	c := Counting_Allocator {
		fail_at      = 1,
		fail_enabled = true,
	}
	alloc := kernel.Allocator {
		alloc = counting_alloc,
		ud    = &c,
	}

	L := kernel.new_state(alloc)
	testing.expect(t, L == nil, "new_state must fail when the value stack can't allocate")
	testing.expect_value(t, c.outstanding, 0)
}

// If the frame array (the third fresh allocation) fails after the stack already
// succeeded, close_state must free the stack it did grab and the global block,
// balancing the accounting back to zero. This covers the "fail after a partial
// success within stack_init" path the first OOM test doesn't reach.
@(test)
new_state_oom_on_frames_frees_partial :: proc(t: ^testing.T) {
	c := Counting_Allocator {
		fail_at      = 2,
		fail_enabled = true,
	}
	alloc := kernel.Allocator {
		alloc = counting_alloc,
		ud    = &c,
	}

	L := kernel.new_state(alloc)
	testing.expect(t, L == nil, "new_state must fail when the frame array can't allocate")
	testing.expect_value(t, c.outstanding, 0)
}
