package tests

// func_test.odin -- Phase 3 tests for closures, prototypes, and upvalues
// (func.odin).
//
// These exercise the machinery that later phases lean on: allocating Lua and C
// closures with the right inline upvalue vectors, creating and freeing prototypes
// through the accounting allocator (no leak), and -- the subtle part -- the
// open/closed upvalue lifecycle. The upvalue test proves the sharing invariant
// (two captures of the same stack slot observe one object) and that closing an
// upvalue detaches it from the stack while preserving the captured value.

import "core:testing"
import lua "luao:lua"

// A freshly allocated Lua closure records its upvalue count and lands on the
// sweepable object list, and its inline upvalue slots can be populated by
// luaF_initupvals.
@(test)
api_closure_allocation :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	base := count_allgc(L)
	cl := lua.func_newLclosure(L, 3)
	testing.expect(t, cl != nil)
	testing.expect_value(t, cl.nupvalues, u8(3))
	testing.expect(t, cl.tt == lua.VLCL, "Lua closures carry the VLCL tag")
	testing.expect_value(t, count_allgc(L), base + 1)

	// Populate the upvalue objects; each is itself a fresh collectable object.
	st := lua.func_initupvals(L, cl)
	testing.expect(t, st == .Ok)
	for i in 0 ..< 3 {
		testing.expect(t, cl.upvals[i] != nil, "every upvalue slot must be filled")
		testing.expect(t, !cl.upvals[i].open, "initupvals creates closed upvalues")
	}
}

// A C (native) closure captures values inline and reports its count. The captured
// slots start nil so a collection before they're filled never scans garbage.
@(test)
c_closure_allocation :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	cl := lua.func_newCclosure(L, 2)
	testing.expect(t, cl != nil)
	testing.expect_value(t, cl.nupvalues, u8(2))
	testing.expect(t, cl.tt == lua.VCCL, "C closures carry the VCCL tag")
	testing.expect(t, lua.is_nil(&cl.upvalue[0]) && lua.is_nil(&cl.upvalue[1]))
}

// A prototype allocates and frees cleanly through the counting allocator, so the
// live-byte balance returns to zero once the state closes. This is the honest
// no-leak proof for the Proto path (whose satellite arrays are freed by
// luaF_freeproto at teardown).
@(test)
proto_allocation_leaves_no_leak :: proc(t: ^testing.T) {
	c: Counting_Allocator
	alloc := lua.Allocator {
		alloc = counting_alloc,
		ud    = &c,
	}

	L := lua.new_state(alloc)
	testing.expect(t, L != nil)

	p := lua.func_newproto(L)
	testing.expect(t, p != nil)
	testing.expect(t, p.tt == lua.VPROTO, "prototypes carry the VPROTO tag")

	lua.close_state(L)
	testing.expect_value(t, c.outstanding, 0)
}

// The heart of the upvalue system: two closures capturing the *same* stack slot
// must share one upvalue object (so a write through one is visible through the
// other), and closing that upvalue must detach it from the stack while carrying
// the captured value into its own storage.
@(test)
open_upvalues_share_and_close :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	// Put a value on the stack at a known slot and expose it as "in use".
	slot := L.top
	lua.set_int(lua.stack_value(L, slot), 1234)
	L.top += 1

	// Two finds for the same slot must return the identical shared upvalue.
	uv1 := lua.func_findupval(L, slot)
	uv2 := lua.func_findupval(L, slot)
	testing.expect(t, uv1 != nil && uv2 != nil)
	testing.expect(t, uv1 == uv2, "same slot must share one upvalue object")
	testing.expect(t, uv1.open, "a capture of a live slot is open")

	// While open, the upvalue forwards to the live stack slot.
	testing.expect_value(t, lua.int_value(lua.upval_value(uv1)), lua.Integer(1234))

	// A different slot must get a different upvalue object.
	other_slot := L.top
	lua.set_int(lua.stack_value(L, other_slot), 5678)
	L.top += 1
	uv_other := lua.func_findupval(L, other_slot)
	testing.expect(t, uv_other != uv1, "different slots get different upvalues")

	// Now close everything at or above `slot`. The upvalue must go closed, detach
	// from the stack, and still yield the captured value from its own storage.
	lua.func_closeupval(L, slot)
	testing.expect(t, !uv1.open, "closing flips the upvalue to closed")
	testing.expect_value(t, lua.int_value(lua.upval_value(uv1)), lua.Integer(1234))

	// The thread's open-upvalue list is now empty (both were at/above `slot`).
	testing.expect(t, L.openupval == nil, "no open upvalues remain after closing")
}
