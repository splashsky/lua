package lua

// gc.odin -- our analogue of reference Lua's `lgc.h` / `lgc.c`.
//
// The garbage collector: a faithful incremental + generational mark-and-sweep,
// because its behavior is *observable* (weak tables, `__gc` finalizers,
// `collectgarbage` counts and modes) and matching it is part of correctness.
//
// We build it in two passes (see docs/ARCHITECTURE.md, Decision on GC split):
//   * Phase 3 -- the foundation: object headers/lists, roots, write barriers,
//     the non-moving invariant, the emergency-OOM path, and deterministic manual
//     collection we can unit-test before the VM exists.
//   * Phase 7 -- the full collector: the incremental state machine, generational
//     transitions, weak tables/ephemerons, finalization ordering, and GC pacing/
//     debt. Finalizers need protected calls + a running VM, so they wait.
//
// Write barriers get added as each collectable type is introduced, never bolted
// on afterward.
//
// TODO(phase-3): GC foundation. TODO(phase-7): the full incremental/generational
// collector, weak objects, and finalizers.
