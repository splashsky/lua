package tests

// gc_test.odin -- Phase 3 tests for the garbage-collection foundation (gc.odin).
//
// Phase 3 ships a deterministic, stop-the-world mark-and-sweep (`gc_full`). These
// tests prove its core observable promises without reaching into collector
// internals: an object nothing points at is reclaimed, an object reachable from a
// root (a value on the main thread's stack, which the collector traverses) is
// kept, a value stored inside a *kept* table is itself kept, and the "fixed"
// strings (metamethod names, the memory-error message) are never collected.
//
// We measure by counting the live `allgc` list -- an honest, observable proxy for
// "what the collector decided to keep" -- and, for the survival cases, by reading
// the value straight back out after a collection.

import "core:testing"
import kernel "lang:kernel"

// Count the objects currently on the sweepable `allgc` list. This is the
// population the collector reclaims from; fixed objects live on a separate list
// and are intentionally not counted here.
count_allgc :: proc(L: ^kernel.State) -> int {
	n := 0
	for o := L.g.allgc; o != nil; o = o.next {
		n += 1
	}
	return n
}

// Push a collectable object onto the main thread's stack so the collector will
// treat it as reachable. Returns the stack index used, so the caller can later
// drop the root by popping.
push_root :: proc(L: ^kernel.State, o: ^kernel.GCObject) -> int {
	idx := L.top
	kernel.set_gc(kernel.stack_value(L, idx), o)
	L.top += 1
	return idx
}

// Drop the topmost root pushed by `push_root`, clearing the slot so a later
// collection can't still see it.
pop_root :: proc(L: ^kernel.State) {
	L.top -= 1
	kernel.set_nil(kernel.stack_value(L, L.top))
}

// An object that nothing references must be reclaimed by a full collection: after
// creating one unreferenced table, the live count rises by one; after `gc_full`
// it falls back to the baseline.
@(test)
gc_collects_unreferenced :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	base := count_allgc(L)
	_ = kernel.table_new(L) // created, never rooted
	testing.expect_value(t, count_allgc(L), base + 1)

	kernel.gc_full(L, false)
	testing.expect_value(t, count_allgc(L), base)
}

// An object reachable from a root must survive collection. We root a table on the
// stack, collect, and confirm the population still includes it (baseline + 1). We
// then drop the root and collect again to confirm it is now reclaimed -- the
// mirror image that proves the survival wasn't just the collector failing to run.
@(test)
gc_keeps_rooted :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	base := count_allgc(L)
	tbl := kernel.table_new(L)
	push_root(L, kernel.obj2gco(tbl))

	kernel.gc_full(L, false)
	testing.expect_value(t, count_allgc(L), base + 1)

	pop_root(L)
	kernel.gc_full(L, false)
	testing.expect_value(t, count_allgc(L), base)
}

// A value stored inside a surviving table must itself survive: the collector has
// to traverse the table and mark what it holds. We root a table, store a fresh
// short string as a value in it, collect, then read the value back and confirm it
// is intact -- an observable check that the reachable-through-a-table edge keeps
// the string alive.
@(test)
gc_keeps_value_reachable_through_table :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	tbl := kernel.table_new(L)
	push_root(L, kernel.obj2gco(tbl))

	s := kernel.string_new(L, "reachable-through-a-table-value")
	sv: kernel.TValue
	kernel.set_gc(&sv, kernel.obj2gco(s))
	st := kernel.table_setint(L, tbl, 1, &sv)
	testing.expect(t, st == .Ok)

	kernel.gc_full(L, false)

	// The string must still be retrievable and intact after collection.
	res: kernel.TValue
	kernel.table_getint(tbl, 1, &res)
	testing.expect(t, kernel.is_collectable(&res), "value survived as a GC object")
	got := kernel.str_value(&res)
	testing.expect_value(t, str_contents(got), "reachable-through-a-table-value")

	pop_root(L)
}

// Fixed strings (the metamethod names installed by luaT_init) must never be
// collected: they live for the whole life of the state. After a full collection,
// the "__index" metamethod name is still present and correct -- and re-interning
// that literal returns the very same fixed object.
@(test)
gc_never_collects_fixed_strings :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	fixed := L.g.tmname[kernel.TM_INDEX]
	testing.expect(t, fixed != nil)
	testing.expect_value(t, str_contents(fixed), "__index")

	kernel.gc_full(L, false)

	// Still the same live object with the same content after collecting.
	testing.expect_value(t, str_contents(fixed), "__index")
	again := kernel.string_new(L, "__index")
	testing.expect(t, again == fixed, "fixed metamethod name stays interned")
}
