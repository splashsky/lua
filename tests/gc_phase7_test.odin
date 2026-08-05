package tests

// gc_phase7_test.odin -- Phase 7 tests for the full incremental + generational
// collector (gc.odin + gc_run.odin) and the `lua_gc` control surface (api.odin).
//
// Phase 3 proved the stop-the-world foundation; Phase 7 replaced it with the real
// pacing-driven state machine plus weak tables, ephemerons, finalizers, and the
// generational/incremental mode switch. These tests exercise the *new* observable
// promises the reference collector makes, always through honest, black-box checks:
// we drive collection, then read back what the collector decided (a cleared weak
// entry, a survived strong entry, a finalizer that ran, a mode value handed back,
// a parameter that round-trips). No test asserts on incidental collector internals.

import "core:testing"
import kernel "lang:kernel"

// A full collection must reclaim a batch of unreferenced objects: after creating
// several tables that nothing roots, driving `lua_gc` COLLECT brings the live
// population back to where it started. This proves the incremental state machine,
// run to completion, sweeps everything the foundation used to sweep.
@(test)
gc_phase7_collect_reclaims_batch :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	base := count_allgc(L)
	for _ in 0 ..< 8 {
		_ = kernel.table_new(L) // created, never rooted
	}
	testing.expect(t, count_allgc(L) >= base + 8, "the batch is live before collecting")

	kernel.api_gc(L, kernel.GCCOLLECT)
	testing.expect_value(t, count_allgc(L), base)
}

// `lua_gc` COUNT reports the live heap size in Kbytes, and STOP/RESTART toggle
// whether the collector is running. We check the observable state transitions:
// a fresh state reports "running", COUNT is a sane positive size, STOP turns
// ISRUNNING off, and RESTART turns it back on.
@(test)
gc_phase7_api_count_and_running :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// A living state holds some bytes; COUNT is #bytes >> 10, so it is >= 0 and
	// COUNTB (the low 10 bits) is always in range.
	testing.expect(t, kernel.api_gc(L, kernel.GCCOUNT) >= 0, "COUNT is non-negative")
	countb := kernel.api_gc(L, kernel.GCCOUNTB)
	testing.expect(t, 0 <= countb && countb < 1024, "COUNTB is the low 10 bits")

	testing.expect_value(t, kernel.api_gc(L, kernel.GCISRUNNING), 1)
	kernel.api_gc(L, kernel.GCSTOP)
	testing.expect_value(t, kernel.api_gc(L, kernel.GCISRUNNING), 0)
	kernel.api_gc(L, kernel.GCRESTART)
	testing.expect_value(t, kernel.api_gc(L, kernel.GCISRUNNING), 1)
}

// Switching collection mode returns the *previous* mode and installs the new one,
// exactly as reference `lua_gc(LUA_GCGEN/LUA_GCINC)` does. A fresh state is
// incremental, so GEN returns INC (and switches to generational); INC then
// returns GEN (and switches back).
@(test)
gc_phase7_api_mode_switch :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// Fresh states run the incremental collector.
	prev := kernel.api_gc(L, kernel.GCGEN)
	testing.expect_value(t, prev, kernel.GCINC)

	prev2 := kernel.api_gc(L, kernel.GCINC)
	testing.expect_value(t, prev2, kernel.GCGEN)
}

// A GC parameter must round-trip through `lua_gc` PARAM: reading returns the
// current (percentage-applied) value, and writing a new value is visible on the
// next read. We use the pause parameter and confirm the write took.
@(test)
gc_phase7_api_param_roundtrip :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// Set the pause parameter to 300 and read it straight back. The read applies
	// the coded value at 100%, recovering (approximately) what we stored; the
	// float-coding is lossy at the low bits, so we assert it is in the right
	// neighborhood rather than bit-exact.
	_ = kernel.api_gc(L, kernel.GCPARAM, kernel.GCPPAUSE, 300)
	got := kernel.api_gc(L, kernel.GCPARAM, kernel.GCPPAUSE, -1)
	testing.expect(t, 290 <= got && got <= 310, "the pause parameter round-trips")
}

// A weak-*valued* table drops entries whose value is otherwise unreachable, but
// keeps entries whose value is still rooted elsewhere. We build a table with
// `__mode = "v"`, put an unrooted table under key 1 and a rooted string under
// key 2, collect, and confirm key 1 was cleared while key 2 survived.
@(test)
gc_phase7_weak_value_cleared :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	weak := kernel.table_new(L)
	push_root(L, kernel.obj2gco(weak))
	mt := kernel.table_new(L)
	push_root(L, kernel.obj2gco(mt))

	// Install __mode = "v" on the weak table's metatable.
	modekey := kernel.string_new(L, "__mode")
	mk: kernel.TValue
	kernel.set_string(&mk, modekey)
	mv: kernel.TValue
	kernel.set_string(&mv, kernel.string_new(L, "v"))
	testing.expect(t, kernel.table_set(L, mt, &mk, &mv) == .Ok)
	weak.metatable = mt

	// key 1 -> a table nothing else references (weakly held, must be cleared).
	orphan := kernel.table_new(L)
	ov: kernel.TValue
	kernel.set_gc(&ov, kernel.obj2gco(orphan))
	testing.expect(t, kernel.table_setint(L, weak, 1, &ov) == .Ok)

	// key 2 -> a string we root on the stack (strongly held, must survive).
	kept := kernel.string_new(L, "kept-weak-value")
	push_root(L, kernel.obj2gco(kept))
	kv: kernel.TValue
	kernel.set_string(&kv, kept)
	testing.expect(t, kernel.table_setint(L, weak, 2, &kv) == .Ok)

	kernel.api_gc(L, kernel.GCCOLLECT)

	// The orphaned value is gone; the rooted value is intact.
	r1: kernel.TValue
	kernel.table_getint(weak, 1, &r1)
	testing.expect(t, kernel.is_nil(&r1), "weak value with no other reference was cleared")

	r2: kernel.TValue
	kernel.table_getint(weak, 2, &r2)
	testing.expect(t, kernel.is_collectable(&r2), "rooted weak value survived")
	testing.expect_value(t, str_contents(kernel.str_value(&r2)), "kept-weak-value")
}

// The count of finalizer invocations, bumped by `phase7_finalizer` below. A
// package-level counter is the honest, observable signal that a `__gc` handler
// actually ran during collection.
@(private = "file")
phase7_final_count: int

// A minimal `__gc` finalizer: it ignores its argument and records that it ran.
// The "c" calling convention matches the kernel's `C_Function` type, so the call
// protocol can invoke it directly.
@(private = "file")
phase7_finalizer :: proc "c" (L: rawptr) -> i32 {
	phase7_final_count += 1
	return 0
}

// An object whose metatable carries `__gc` must have that finalizer run exactly
// once when the object becomes unreachable and is collected. We give a table such
// a metatable (enrolling it via `luaC_checkfinalizer`), never root the table,
// collect, and confirm the finalizer fired a single time.
@(test)
gc_phase7_finalizer_runs :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	phase7_final_count = 0

	// Root the metatable for as long as we are wiring it up; the finalizable
	// table itself is deliberately left unrooted.
	mt := kernel.table_new(L)
	push_root(L, kernel.obj2gco(mt))

	gckey := kernel.string_new(L, "__gc")
	gk: kernel.TValue
	kernel.set_string(&gk, gckey)
	gv: kernel.TValue
	kernel.set_c_function(&gv, phase7_finalizer)
	testing.expect(t, kernel.table_set(L, mt, &gk, &gv) == .Ok)

	victim := kernel.table_new(L)
	victim.metatable = mt
	kernel.gc_checkfinalizer(L, kernel.obj2gco(victim), mt)

	// The victim is unreachable: collecting must separate it, resurrect it for
	// the finalizer, and run `__gc` once.
	kernel.api_gc(L, kernel.GCCOLLECT)
	testing.expect_value(t, phase7_final_count, 1)

	pop_root(L) // drop the metatable root
}
