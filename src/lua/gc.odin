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

// ---------------------------------------------------------------------------
// Object colors (the `marked` byte)
// ---------------------------------------------------------------------------
//
// The GC paints every object one of three colors, encoded in bits of the shared
// `marked` byte (see object.odin's GCObject). The layout is lifted verbatim from
// reference Lua's lgc.h so the bit tricks below read identically:
//
//   bits 0-2 : object "age" for generational mode (unused in Phase 3, kept 0)
//   bit 3    : WHITE0   -- one of two "white" (candidate-for-collection) shades
//   bit 4    : WHITE1   -- the other white shade
//   bit 5    : BLACK    -- reachable and fully scanned
//   bit 6    : FINALIZED -- queued for a __gc finalizer (Phase 7)
//   bit 7    : reserved for tests
//
// "Gray" is the absence of any color bit: an object that is reachable but whose
// children haven't been scanned yet. The two whites let the collector flip the
// meaning of "white" between cycles so newly created objects (painted the new
// current white) are never mistaken for leftovers from the cycle just finished
// (which wear the *other*, now-stale white). That flip is the whole trick behind
// not having to repaint every survivor on every cycle.

WHITE0BIT :: 3
WHITE1BIT :: 4
BLACKBIT :: 5
FINALIZEDBIT :: 6

WHITEBITS :: (1 << WHITE0BIT) | (1 << WHITE1BIT) // 0x18
// Every color bit at once: both whites plus black. Used to strip an object down
// to gray before repainting it. Reference Lua's `maskcolors`.
MASK_COLORS :: WHITEBITS | (1 << BLACKBIT) // 0x38

// Is the object one of the two whites (i.e. a collection candidate)?
is_white :: #force_inline proc "contextless" (o: ^GCObject) -> bool {
	return (o.marked & WHITEBITS) != 0
}

// Is the object black (reachable and scanned)?
is_black :: #force_inline proc "contextless" (o: ^GCObject) -> bool {
	return (o.marked & (1 << BLACKBIT)) != 0
}

// Is the object gray (reachable, not yet scanned) -- neither white nor black?
is_gray :: #force_inline proc "contextless" (o: ^GCObject) -> bool {
	return (o.marked & (WHITEBITS | (1 << BLACKBIT))) == 0
}

// The white shade *not* currently in use: an object wearing it is a leftover from
// the previous cycle and is therefore dead. Reference Lua's `otherwhite`.
other_white :: #force_inline proc "contextless" (g: ^Global_State) -> Byte {
	return g.currentwhite ~ WHITEBITS
}

// Is this object dead -- wearing the stale (other) white? Reference `isdead`.
is_dead :: #force_inline proc "contextless" (g: ^Global_State, o: ^GCObject) -> bool {
	return (o.marked & other_white(g)) != 0
}

// Flip an object between the two whites (used to resurrect a dead-but-uncollected
// string during interning). Reference `changewhite`.
change_white :: #force_inline proc "contextless" (o: ^GCObject) {
	o.marked ~= WHITEBITS
}

// The current white shade as a bare bitmask -- the color every freshly created
// object is painted. Reference `luaC_white`.
luaC_white :: #force_inline proc "contextless" (g: ^Global_State) -> Byte {
	return g.currentwhite & WHITEBITS
}

// Repaint an object gray: clear all three color bits. Reference `set2gray`.
set2gray :: #force_inline proc "contextless" (o: ^GCObject) {
	o.marked &= ~Byte(MASK_COLORS)
}

// Repaint an object black: clear the white bits, set the black bit. Reference
// `set2black` / `nw2black`.
set2black :: #force_inline proc "contextless" (o: ^GCObject) {
	o.marked = (o.marked & ~Byte(WHITEBITS)) | (1 << BLACKBIT)
}

// ---------------------------------------------------------------------------
// GC-stop flags and re-entrancy
// ---------------------------------------------------------------------------
//
// `gcstp` is a small bitset that, when nonzero, forbids the collector from
// running. Reference Lua's GCSTP* flags. We use GCSTPGC while a state is still
// being built (no automatic or emergency collection until it is complete).
GCSTPGC :: 2 // collection stopped by the implementation
GCSTPUSR :: 1 // collection stopped by the user (collectgarbage("stop"))

// ---------------------------------------------------------------------------
// GCObject <-> typed-object conversions
// ---------------------------------------------------------------------------
//
// Every collectable type embeds `GCObject` as its first field, so a pointer to
// the object and a pointer to its header share an address. These helpers make the
// punning explicit and searchable instead of scattering raw casts. `obj2gco`
// turns any typed object pointer into a `^GCObject`; the typed `gco2*` casts go
// the other way and assume the caller has already checked the tag.

obj2gco :: #force_inline proc "contextless" (o: rawptr) -> ^GCObject {
	return (^GCObject)(o)
}

// ---------------------------------------------------------------------------
// Object creation
// ---------------------------------------------------------------------------

// Allocate a fresh collectable object of type `tt` and `size` bytes, paint it the
// current white, and link it at the head of the `allgc` sweep list -- reference
// Lua's `luaC_newobj`. The object is born white (a collection candidate) and
// unrooted; the caller must make it reachable before the next allocation that
// could trigger a collection. Returns nil if the allocation fails (the caller
// raises the memory error, since it has the context to unwind).
luaC_newobj :: proc(L: ^Lua_State, tt: Byte, size: uint) -> ^GCObject {
	g := L.g
	p := state_realloc(L, nil, uint(no_variant(tt)), size)
	if p == nil {
		return nil
	}
	o := (^GCObject)(p)
	o.marked = luaC_white(g)
	o.tt = tt
	o.next = g.allgc
	g.allgc = o
	return o
}

// Move a freshly created object off the sweep list and onto the permanent
// `fixedgc` list, where the collector never visits it -- reference Lua's
// `luaC_fix`. Used for the handful of strings (metamethod names, the memory-error
// message) that must exist for the entire life of the state. It must be called
// immediately after creation, while the object is still the head of `allgc`.
luaC_fix :: proc(L: ^Lua_State, o: ^GCObject) {
	g := L.g
	assert(g.allgc == o, "luaC_fix: object must be the newest allgc entry")
	set2gray(o) // fixed objects are gray forever...
	o.marked = (o.marked & ~Byte(AGE_BITS)) | G_OLD // ...and old forever
	g.allgc = o.next // unlink from the sweep list
	o.next = g.fixedgc // and prepend to the fixed list
	g.fixedgc = o
}

// Generational-age constants (bits 0-2 of `marked`). Only G_OLD is meaningful in
// Phase 3 (fixed objects); the rest arrive with the generational collector.
AGE_BITS :: 7
G_OLD :: 4

// ---------------------------------------------------------------------------
// Write barriers
// ---------------------------------------------------------------------------
//
// A write barrier preserves the collector's core invariant -- a black object must
// never hold the only reference to a white one -- when the mutator stores a
// pointer into an already-scanned (black) object. In Phase 3 the collector only
// ever runs stop-the-world, to completion, between mutator actions, so there are
// no black objects while the mutator runs and these barriers are effectively
// no-ops. They are wired in at every store site now, though, so that when the
// incremental collector lands in Phase 7 the barriers become load-bearing without
// having to hunt down every mutation. Reference Lua's `luaC_barrier_` /
// `luaC_barrierback_`.

// Forward barrier: `o` (black) now points at `v` (white). Reference restores the
// invariant by marking `v`. Guarded so it only acts mid-collection.
luaC_barrier :: proc(L: ^Lua_State, o: ^GCObject, v: ^GCObject) {
	g := L.g
	if is_black(o) && is_white(v) && keep_invariant(g) {
		reallymarkobject(g, v)
	}
}

// Back barrier: a black container `o` (a table) got a new white entry. Rather than
// mark the entry, reference Lua paints the container gray again so it is
// re-scanned. Guarded identically.
luaC_barrierback :: proc(L: ^Lua_State, o: ^GCObject) {
	g := L.g
	if is_black(o) && keep_invariant(g) {
		set2gray(o)
		// TODO(phase-7): link onto g.grayagain for re-scan in the atomic phase.
	}
}

// The invariant must be preserved only while a collection is in progress. In
// Phase 3 that is exactly the window in which `gc_full` runs, tracked by
// `gcrunning`. Reference Lua's `keepinvariant` keys off the GC state machine.
keep_invariant :: #force_inline proc "contextless" (g: ^Global_State) -> bool {
	return g.gcrunning
}

// ---------------------------------------------------------------------------
// Marking
// ---------------------------------------------------------------------------

// Mark a value if it is collectable and still white. Reference `markvalue`.
mark_value :: #force_inline proc(g: ^Global_State, o: ^TValue) {
	if is_collectable(o) && is_white(o.value_.gc) {
		reallymarkobject(g, o.value_.gc)
	}
}

// Mark an object (known collectable) if white. Reference `markobject`.
mark_object :: #force_inline proc(g: ^Global_State, o: ^GCObject) {
	if is_white(o) {
		reallymarkobject(g, o)
	}
}

// Mark a possibly-nil object. Reference `markobjectN`.
mark_object_n :: #force_inline proc(g: ^Global_State, o: ^GCObject) {
	if o != nil && is_white(o) {
		reallymarkobject(g, o)
	}
}

// Bring a white object into the reachable set -- reference Lua's
// `reallymarkobject`. Leaf objects (strings) are blackened on the spot since they
// have nothing to scan. Upvalues mark their referent inline (open ones stay gray;
// closed ones can go black). Everything with children is pushed onto the gray
// worklist to be scanned later by `propagate`. The gray list is threaded through
// each object's own `gclist` field, so building it costs no allocation -- which is
// exactly what lets an *emergency* collection run when memory is exhausted.
reallymarkobject :: proc(g: ^Global_State, o: ^GCObject) {
	switch o.tt {
	case VSHRSTR, VLNGSTR:
		set2black(o) // strings have no outgoing references

	case VUPVAL:
		uv := (^UpVal)(o)
		if uv.open {
			set2gray(uv) // open upvalues are revisited via their thread
		} else {
			set2black(uv)
		}
		mark_value(g, upval_value(uv)) // mark the referenced value

	case VTABLE, VLCL, VCCL, VPROTO, VTHREAD:
		link_gray(g, o) // has children: scan later

	case:
		assert(false, "reallymarkobject: not a markable object")
	}
}

// Push an object onto the gray worklist, threading the link through its own
// `gclist` field and painting it gray. Reference `linkobjgclist`.
link_gray :: proc(g: ^Global_State, o: ^GCObject) {
	gl := get_gclist(o)
	gl^ = g.gray
	g.gray = o
	set2gray(o)
}

// Return a pointer to an object's `gclist` field so the collector can thread it
// onto (and pop it off) the gray worklist. Only the types that ever appear on the
// gray list are handled. Reference Lua reaches these fields through its `GCUnion`.
get_gclist :: proc(o: ^GCObject) -> ^^GCObject {
	switch o.tt {
	case VTABLE:
		return &(^Table)(o).gclist
	case VLCL:
		return &(^LClosure)(o).gclist
	case VCCL:
		return &(^CClosure)(o).gclist
	case VPROTO:
		return &(^Proto)(o).gclist
	case VTHREAD:
		return &(^Lua_State)(o).gclist
	}
	assert(false, "get_gclist: object never lives on the gray list")
	return nil
}

// ---------------------------------------------------------------------------
// Propagation -- scanning gray objects
// ---------------------------------------------------------------------------

// Scan every object on the gray worklist, marking its children, until the list
// drains. Each object is blackened as it is scanned. Reference Lua's
// `propagateall` / `propagatemark`.
propagate_all :: proc(g: ^Global_State) {
	for g.gray != nil {
		o := g.gray
		g.gray = get_gclist(o)^ // pop
		set2black(o)
		traverse(g, o)
	}
}

// Mark all the objects reachable from one gray object, according to its type.
traverse :: proc(g: ^Global_State, o: ^GCObject) {
	switch o.tt {
	case VTABLE:
		traverse_table(g, (^Table)(o))
	case VLCL:
		traverse_lclosure(g, (^LClosure)(o))
	case VCCL:
		traverse_cclosure(g, (^CClosure)(o))
	case VPROTO:
		traverse_proto(g, (^Proto)(o))
	case VTHREAD:
		traverse_thread(g, (^Lua_State)(o))
	case:
		assert(false, "traverse: unexpected gray object")
	}
}

// Scan a table: its metatable, every live array slot, and every live hash entry
// (key and value). Empty hash slots get their (now unused) collectable key marked
// dead so the key object itself can be collected -- reference Lua's `clearkey` in
// `traversestrongtable`. Weak tables are treated as strong here; real weak/
// ephemeron handling is Phase 7.
traverse_table :: proc(g: ^Global_State, t: ^Table) {
	if t.metatable != nil {
		mark_object_n(g, &t.metatable.header)
	}
	// array part
	for i in 0 ..< int(t.asize) {
		mark_value(g, &t.array[i])
	}
	// hash part
	sz := sizenode(t)
	for i in 0 ..< sz {
		n := &t.node[i]
		if is_empty(&n.val) {
			clearkey(n) // deleted slot: let a collectable key die
		} else {
			mark_key(g, n)
			mark_value(g, &n.val)
		}
	}
}

// Mark a node's key if it is a collectable object still white. Reference `markkey`.
mark_key :: proc(g: ^Global_State, n: ^Node) {
	if (n.key_tt & BIT_ISCOLLECTABLE) != 0 && is_white(n.key_val.gc) {
		reallymarkobject(g, n.key_val.gc)
	}
}

// Retire a deleted slot's collectable key by tagging it dead, so equality tests
// stop dereferencing it and the object it named becomes collectable. Reference
// `clearkey`.
clearkey :: proc(n: ^Node) {
	if (n.key_tt & BIT_ISCOLLECTABLE) != 0 {
		n.key_tt = TDEADKEY
	}
}

// Scan a Lua closure: its prototype and each of its upvalues.
traverse_lclosure :: proc(g: ^Global_State, cl: ^LClosure) {
	if cl.p != nil {
		mark_object_n(g, &cl.p.header)
	}
	for i in 0 ..< int(cl.nupvalues) {
		uv := cl.upvals[i]
		if uv != nil {
			mark_object_n(g, &uv.header)
		}
	}
}

// Scan a C/Odin closure: each captured upvalue is a plain value.
traverse_cclosure :: proc(g: ^Global_State, cl: ^CClosure) {
	for i in 0 ..< int(cl.nupvalues) {
		mark_value(g, &cl.upvalue[i])
	}
}

// Scan a prototype: its source name, constants, nested prototypes, upvalue names,
// and local-variable names. Reference Lua's `traverseproto`.
traverse_proto :: proc(g: ^Global_State, f: ^Proto) {
	if f.source != nil {
		mark_object_n(g, &f.source.header)
	}
	for i in 0 ..< f.sizek {
		mark_value(g, &f.k[i])
	}
	for i in 0 ..< f.sizep {
		if f.p[i] != nil {
			mark_object_n(g, &f.p[i].header)
		}
	}
	for i in 0 ..< f.sizeupvalues {
		if f.upvalues[i].name != nil {
			mark_object_n(g, &f.upvalues[i].name.header)
		}
	}
	for i in 0 ..< f.sizelocvars {
		if f.locvars[i].varname != nil {
			mark_object_n(g, &f.locvars[i].varname.header)
		}
	}
}

// Scan a thread: every live value on its stack, plus its open upvalues. Reference
// Lua threads keep open upvalues alive through a separate `twups` list processed
// in the atomic phase; for our stop-the-world collector it is simpler and equally
// correct to mark them directly here. Reference Lua's `traversethread`.
traverse_thread :: proc(g: ^Global_State, th: ^Lua_State) {
	if th.stack == nil {
		return // a thread that never got its stack (mid-construction)
	}
	for i in 0 ..< th.top {
		mark_value(g, &th.stack[i].val)
	}
	for uv := th.openupval; uv != nil; uv = uv.open_next {
		mark_object_n(g, &uv.header)
	}
}

// ---------------------------------------------------------------------------
// Sweeping -- freeing the unreachable
// ---------------------------------------------------------------------------

// Free one object and all of its type-specific satellite allocations, routing
// every byte back through the state allocator so the GC's accounting unwinds
// exactly. Reference Lua's `freeobj`.
freeobj :: proc(L: ^Lua_State, o: ^GCObject) {
	switch o.tt {
	case VSHRSTR:
		ts := (^TString)(o)
		luaS_remove(L, ts) // unlink from the intern table first
		state_free(L, ts, string_alloc_size(ts))
	case VLNGSTR:
		ts := (^TString)(o)
		state_free(L, ts, string_alloc_size(ts))
	case VUPVAL:
		uv := (^UpVal)(o)
		if uv.open {
			unlink_upval(uv) // detach from its thread's open list
		}
		state_free(L, uv, size_of(UpVal))
	case VTABLE:
		luaH_free(L, (^Table)(o))
	case VLCL:
		cl := (^LClosure)(o)
		state_free(L, cl, size_lclosure(int(cl.nupvalues)))
	case VCCL:
		cl := (^CClosure)(o)
		state_free(L, cl, size_cclosure(int(cl.nupvalues)))
	case VPROTO:
		luaF_freeproto(L, (^Proto)(o))
	case VTHREAD:
		free_thread(L, (^Lua_State)(o))
	case:
		assert(false, "freeobj: unknown object type")
	}
}

// Walk the `allgc` list, freeing every object still wearing the dead (other)
// white and repainting every survivor with the fresh current white so the next
// cycle starts clean. Reference Lua's `sweeplist`, collapsed to a single
// stop-the-world pass. The `fixedgc` list is never swept.
sweep_allgc :: proc(L: ^Lua_State) {
	g := L.g
	white := luaC_white(g) // the new current white
	p := &g.allgc
	for p^ != nil {
		curr := p^
		if is_dead(g, curr) {
			p^ = curr.next // unlink...
			freeobj(L, curr) // ...and reclaim
		} else {
			// survivor: strip its colors and repaint the current white
			curr.marked = (curr.marked & ~Byte(MASK_COLORS)) | white
			p = &curr.next
		}
	}
}

// ---------------------------------------------------------------------------
// The collector proper
// ---------------------------------------------------------------------------

// Run one complete, deterministic, stop-the-world mark-and-sweep collection --
// the Phase 3 stand-in for reference Lua's `luaC_fullgc`. The mutator is not
// running concurrently (there is no VM yet, and even in later phases this is
// invoked only at safe points), so we can mark the whole reachable graph and then
// sweep in one shot. Crucially this allocates nothing, which is what makes it safe
// to call from the emergency-out-of-memory path.
//
// `emergency` records that we were triggered by an allocation failure; Phase 7
// uses it to skip optional work (table/stack shrinking) that could itself
// allocate. We already skip all such work, so the flag is only informational here.
gc_full :: proc(L: ^Lua_State, emergency: bool) {
	g := L.g
	if g.gcrunning {
		return // never re-enter the collector
	}
	g.gcrunning = true

	// --- mark ---------------------------------------------------------
	g.gray = nil
	mark_object(g, obj2gco(&g.main_thread.l)) // the main thread and its stack
	mark_value(g, &g.registry) // the registry table
	for i in 0 ..< NUM_TYPES {
		if g.mt[i] != nil {
			mark_object_n(g, &g.mt[i].header) // per-type metatables
		}
	}
	// Fixed objects (metamethod names, the memory-error message) live on the
	// separate `fixedgc` list and are never swept, so they need no root marking.
	propagate_all(g)

	// --- atomic -------------------------------------------------------
	// The API string cache holds weak references keyed by address; any entry
	// about to be swept must be dropped before it dangles. Reference Lua clears
	// it in the atomic phase, before sweeping.
	luaS_clearcache(g)

	// --- flip + sweep -------------------------------------------------
	// Switch the meaning of "white": every survivor is currently black, and
	// every unreachable object still wears the pre-flip white, which is now the
	// stale "other" white the sweep will reclaim.
	g.currentwhite = other_white(g)
	sweep_allgc(L)

	g.gcrunning = false
	_ = emergency
}

// Free absolutely every collectable object at state teardown -- reference Lua's
// `luaC_freeallobjects`. The embedded main thread is special: its struct is part
// of the global block (freed wholesale by `close_state`), so we free everything it
// owns *except* that struct. Its open upvalues, being separate objects on the
// `allgc` list, are freed by the loop like any other object.
luaC_freeallobjects :: proc(L: ^Lua_State) {
	g := L.g
	main := obj2gco(&g.main_thread.l)
	p := g.allgc
	for p != nil {
		next := p.next
		if p != main {
			freeobj(L, p)
		}
		p = next
	}
	g.allgc = main
	main.next = nil
	// The fixed strings come down too.
	p = g.fixedgc
	for p != nil {
		next := p.next
		freeobj(L, p)
		p = next
	}
	g.fixedgc = nil
}
