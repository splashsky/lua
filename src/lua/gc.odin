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

// Repaint an object the *current* white, clearing black and the old white --
// reference Lua's `makewhite`. Used by the sweep and by the forward barrier's
// sweep-phase shortcut. The age bits are preserved.
makewhite :: #force_inline proc "contextless" (g: ^Global_State, o: ^GCObject) {
	o.marked = (o.marked & ~Byte(MASK_COLORS)) | luaC_white(g)
}

// Is the object flagged for finalization (its `__gc` has been noticed and it now
// lives on the `finobj`/`tobefnz` lists)? Reference `tofinalize`.
tofinalize :: #force_inline proc "contextless" (o: ^GCObject) -> bool {
	return (o.marked & (1 << FINALIZEDBIT)) != 0
}

// (The GCSTP* stop flags and the GCS* state-machine phases live in state.odin,
// alongside the Global_State fields they control.)

// ---------------------------------------------------------------------------
// GCObject <-> typed-object conversions
// ---------------------------------------------------------------------------
//
// Every collectable type spells out the three `GCObject` fields at offset zero,
// so its pointer and a header pointer share an address. Keep this conversion
// constrained to that closed set: accepting rawptr would make it too easy to
// manufacture a GC header from an unrelated allocation. Code using the result
// must touch only `next`, `tt`, and `marked`; copying the whole 16-byte
// `GCObject` would overwrite concrete fields packed into its trailing padding.

obj2gco :: #force_inline proc "contextless" (x: ^$T) -> ^GCObject
	where T == Table || T == TString || T == Udata || T == UpVal ||
	      T == CClosure || T == LClosure || T == Proto || T == Lua_State
{
	return (^GCObject)(x)
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

// Generational-mode object ages, stored in bits 0-2 of `marked` -- reference
// Lua's `G_*` (lgc.h). A young object is NEW or SURVIVAL; it ages toward OLD as
// it survives successive cycles. TOUCHED1/TOUCHED2 track an old object that a
// back barrier re-grayed this cycle (or the previous one). See the long comment
// in reference lgc.h for the full age-transition rationale.
G_NEW :: 0 // created during the current cycle
G_SURVIVAL :: 1 // survived one cycle
G_OLD0 :: 2 // turned old by a forward barrier this cycle
G_OLD1 :: 3 // first full cycle as old (may still point to survivals)
G_OLD :: 4 // really old: never revisited
G_TOUCHED1 :: 5 // old, touched (re-grayed) this cycle
G_TOUCHED2 :: 6 // old, touched in the previous cycle

AGE_BITS :: 7 // mask of all three age bits (0b111)

// Read / write an object's age, leaving the color bits untouched.
getage :: #force_inline proc "contextless" (o: ^GCObject) -> u8 {
	return o.marked & AGE_BITS
}
setage :: #force_inline proc "contextless" (o: ^GCObject, a: u8) {
	o.marked = (o.marked & ~u8(AGE_BITS)) | a
}

// Is the object "old" in the generational sense (past the young ages)? Reference
// `isold`. Old objects are (mostly) exempt from being revisited each minor cycle.
isold :: #force_inline proc "contextless" (o: ^GCObject) -> bool {
	return getage(o) > G_SURVIVAL
}

// The age an object advances to when it survives a generational sweep --
// reference Lua's `nextage[]`. NEW->SURVIVAL->OLD1->OLD (the OLD/TOUCHED states
// are handled specially by the gray-list correction, not this table).
@(rodata)
nextage := [G_TOUCHED2 + 1]u8 {
	G_SURVIVAL, // G_NEW      -> G_SURVIVAL
	G_OLD1, // G_SURVIVAL -> G_OLD1
	G_OLD1, // G_OLD0     -> G_OLD1
	G_OLD, // G_OLD1     -> G_OLD
	G_OLD, // G_OLD      -> G_OLD (stays)
	G_TOUCHED1, // G_TOUCHED1 -> G_TOUCHED1 (kept until corrected)
	G_TOUCHED2, // G_TOUCHED2 -> G_TOUCHED2 (kept until corrected)
}

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

// A write barrier preserves the collector's core invariant -- a black object must
// never hold the only reference to a white one -- when the mutator stores a
// pointer into an already-scanned (black) object. These wrappers are wired in at
// every collectable store site across the codebase; the internal `_` routines do
// the real work and are only reached when the invariant is actually at risk.
// Reference Lua's `luaC_barrier` / `luaC_barrierback` (lgc.h) and their `_`
// bodies (lgc.c).

// Forward barrier: black `o` acquired a reference to white `v`. During marking we
// restore the invariant by marking `v` immediately; during sweep we instead paint
// `o` back to white so the (now legal) edge stops re-triggering the barrier.
// Generationally, a forward edge out of an old object drags `v` up to G_OLD0 so
// it is not reclaimed by the next minor cycle. Reference `luaC_barrier_`.
luaC_barrier_ :: proc(L: ^Lua_State, o: ^GCObject, v: ^GCObject) {
	g := L.g
	if keepinvariant(g) { // during propagate/atomic: mark the new child
		reallymarkobject(g, v)
		if isold(o) {
			assert(!isold(v)) // an old object cannot already be older here
			setage(v, G_OLD0) // adopt the child into the old generation
		}
	} else { // during sweep: recolor the parent white (incremental only)
		assert(issweepphase(g))
		if g.gckind == KGC_INC {
			makewhite(g, o)
		}
	}
}

// The wrapper: only bother if `o` is black and `v` is white. Reference
// `luaC_objbarrier` / `luaC_barrier`.
luaC_barrier :: #force_inline proc(L: ^Lua_State, o: ^GCObject, v: ^GCObject) {
	if is_black(o) && is_white(v) {
		luaC_barrier_(L, o, v)
	}
}

// Back barrier: a black container `o` (a table) acquired a white entry. Rather
// than mark the entry, we re-gray the container so it is rescanned in the atomic
// phase. A generational old container becomes G_TOUCHED1 so the correction pass
// keeps it on a gray list. Reference `luaC_barrierback_`.
luaC_barrierback_ :: proc(L: ^Lua_State, o: ^GCObject) {
	g := L.g
	if getage(o) == G_TOUCHED2 { // already threaded on a gray list?
		set2gray(o) // just recolor: it is revisited anyway
	} else {
		linkobjgclist(o, &g.grayagain) // (re)link for an atomic-phase rescan
	}
	if isold(o) {
		setage(o, G_TOUCHED1) // note that it was touched this cycle
	}
}

// The wrapper: only act on a black container while the invariant holds. Reference
// `luaC_objbarrierback` / `luaC_barrierback`. (We conservatively skip the
// stored-value white test; re-graying a black container is always safe.)
luaC_barrierback :: #force_inline proc(L: ^Lua_State, o: ^GCObject) {
	g := L.g
	if is_black(o) && keepinvariant(g) {
		luaC_barrierback_(L, o)
	}
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
	g.gc_marked += L_Mem(objsize(o)) // count every byte we bring into the live set
	switch o.tt {
	case VSHRSTR, VLNGSTR:
		set2black(o) // strings have no outgoing references

	case VUPVAL:
		uv := (^UpVal)(o)
		if uv.open {
			set2gray(obj2gco(uv)) // open upvalues are revisited via their thread
		} else {
			set2black(obj2gco(uv))
		}
		mark_value(g, upval_value(uv)) // mark the referenced value

	case VTABLE, VLCL, VCCL, VPROTO, VTHREAD:
		linkobjgclist(o, &g.gray) // has children: scan later

	case VUSERDATA:
		// Full userdata carries a metatable and (optionally) user values. With no
		// user values there is nothing to revisit, so we mark the metatable and
		// blacken in place; otherwise defer to a gray-list scan. Reference Lua's
		// `reallymarkobject` LUA_VUSERDATA case.
		u := (^Udata)(o)
		if u.nuvalue == 0 {
			if u.metatable != nil {
				mark_object_n(g, obj2gco(u.metatable))
			}
			set2black(o)
		} else {
			linkobjgclist(o, &g.gray)
		}

	case:
		assert(false, "reallymarkobject: not a markable object")
	}
}

// Push an object onto the front of the gray list `*list`, threading the link
// through the object's own `gclist` field and painting it gray. Reference Lua's
// `linkobjgclist` / `linkgclist_`. Costs no allocation, which is what lets an
// emergency collection run when memory is exhausted.
linkobjgclist :: proc(o: ^GCObject, list: ^^GCObject) {
	gl := get_gclist(o)
	gl^ = list^
	list^ = o
	set2gray(o)
}

// Convenience for the common "link onto the main gray worklist" case.
link_gray :: #force_inline proc(g: ^Global_State, o: ^GCObject) {
	linkobjgclist(o, &g.gray)
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
	case VUSERDATA:
		return &(^Udata)(o).gclist
	}
	assert(false, "get_gclist: object never lives on the gray list")
	return nil
}

// ---------------------------------------------------------------------------
// Propagation -- scanning gray objects
// ---------------------------------------------------------------------------

// Scan every object on the gray worklist, marking its children, until the list
// drains. Reference Lua's `propagateall`.
propagate_all :: proc(g: ^Global_State) {
	for g.gray != nil {
		propagatemark(g)
	}
}

// Pop one object off the gray list, blacken it, mark its children, and report the
// amount of work done (used by the incremental step controller to bound each
// slice). Reference Lua's `propagatemark`.
propagatemark :: proc(g: ^Global_State) -> L_Mem {
	o := g.gray
	g.gray = get_gclist(o)^ // pop
	set2black(o) // mark it black (its children become the new frontier)
	switch o.tt {
	case VTABLE:
		return traverse_table(g, (^Table)(o))
	case VLCL:
		return traverse_lclosure(g, (^LClosure)(o))
	case VCCL:
		return traverse_cclosure(g, (^CClosure)(o))
	case VPROTO:
		return traverse_proto(g, (^Proto)(o))
	case VTHREAD:
		return traverse_thread(g, (^Lua_State)(o))
	case VUSERDATA:
		return traverse_udata(g, (^Udata)(o))
	case:
		assert(false, "propagatemark: unexpected gray object")
		return 0
	}
}

// ---------------------------------------------------------------------------
// Weak-reference helpers
// ---------------------------------------------------------------------------

// The collectable object behind a value, or nil for non-collectable values.
// Reference Lua's `gcvalueN`.
gcvalue_n :: #force_inline proc "contextless" (v: ^TValue) -> ^GCObject {
	return is_collectable(v) ? gc_value(v) : nil
}

// The collectable object behind a node's key, or nil. Reference `gckeyN`.
gckey_n :: #force_inline proc "contextless" (n: ^Node) -> ^GCObject {
	return (n.key_tt & BIT_ISCOLLECTABLE) != 0 ? n.key_val.gc : nil
}

// Is a value still white (i.e. not yet reached this cycle)? Reference `valiswhite`.
val_is_white :: #force_inline proc "contextless" (v: ^TValue) -> bool {
	return is_collectable(v) && is_white(gc_value(v))
}

// Decide whether a weak-table entry keyed/valued by `o` is "cleared": i.e. the
// object is unreachable and the entry must be removed. Strings are treated as
// values, not references, so they are marked (kept) and never clear an entry.
// Reference Lua's `iscleared`.
iscleared :: proc(g: ^Global_State, o: ^GCObject) -> bool {
	if o == nil {
		return false // a non-collectable value never clears an entry
	} else if no_variant(o.tt) == TSTRING {
		reallymarkobject(g, o) // strings are values: keep them alive
		return false
	} else {
		return is_white(o)
	}
}

// ---------------------------------------------------------------------------
// Per-type traversal
// ---------------------------------------------------------------------------

// Scan a full userdata: its metatable and every user value, then `genlink` so a
// generationally-old udata that was touched gets revisited. Reference Lua's
// `traverseudata`.
traverse_udata :: proc(g: ^Global_State, u: ^Udata) -> L_Mem {
	if u.metatable != nil {
		mark_object_n(g, obj2gco(u.metatable))
	}
	for i in 0 ..< int(u.nuvalue) {
		mark_value(g, udata_uv(u, i))
	}
	genlink(g, obj2gco(u))
	return 1 + L_Mem(u.nuvalue)
}

// Scan the array part of a table, marking every live collectable slot. Returns
// true if anything was newly marked (used by ephemeron convergence). Reference
// Lua's `traversearray`.
traverse_array :: proc(g: ^Global_State, t: ^Table) -> bool {
	marked := false
	for i in 0 ..< int(t.asize) {
		o := gcvalue_n(&t.array[i])
		if o != nil && is_white(o) {
			marked = true
			reallymarkobject(g, o)
		}
	}
	return marked
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

// Scan a strong (non-weak) table: metatable, array, and every hash entry's key and
// value. Reference Lua's `traversestrongtable`.
traverse_strong_table :: proc(g: ^Global_State, t: ^Table) {
	traverse_array(g, t)
	sz := sizenode(t)
	for i in 0 ..< sz {
		n := &t.node[i]
		if is_empty(node_val(n)) {
			clearkey(n) // deleted slot: let a collectable key die
		} else {
			mark_key(g, n)
			mark_value(g, node_val(n))
		}
	}
	genlink(g, obj2gco(t))
}

// Scan a table with weak values (strong keys). Keys are marked; if any value is
// (or could be) white the table is queued for clearing in the atomic phase.
// During propagate it must be revisited atomically, so it lands on grayagain.
// Reference Lua's `traverseweakvalue`.
traverse_weakvalue :: proc(g: ^Global_State, t: ^Table) {
	// If there is an array part, assume it may hold white values (not worth
	// scanning just to find out).
	hasclears := t.asize > 0
	sz := sizenode(t)
	for i in 0 ..< sz {
		n := &t.node[i]
		if is_empty(node_val(n)) {
			clearkey(n)
		} else {
			mark_key(g, n)
			if !hasclears && iscleared(g, gcvalue_n(node_val(n))) {
				hasclears = true // a white value: the table must be cleared
			}
		}
	}
	if g.gcstate == GCSpropagate {
		linkobjgclist(obj2gco(t), &g.grayagain)
	} else if hasclears {
		linkobjgclist(obj2gco(t), &g.weak)
	} else {
		genlink(g, obj2gco(t))
	}
}

// Scan an ephemeron table (weak keys). A value is kept only while its key is
// reachable, so this may need several convergence passes. Returns true if it
// marked anything (convergence must continue). Reference Lua's `traverseephemeron`.
traverse_ephemeron :: proc(g: ^Global_State, t: ^Table, inv: bool) -> bool {
	hasclears := false // table has white keys
	hasww := false // table has a white-key -> white-value entry
	marked := traverse_array(g, t) // array part has strong (non-weak) indices
	nsize := sizenode(t)
	for i in 0 ..< nsize {
		// `inv` walks the hash part in reverse (see convergeephemerons).
		idx := inv ? nsize - 1 - i : i
		n := &t.node[idx]
		if is_empty(node_val(n)) {
			clearkey(n)
		} else if iscleared(g, gckey_n(n)) { // key not (yet) reachable?
			hasclears = true
			if val_is_white(node_val(n)) {
				hasww = true
			}
		} else if val_is_white(node_val(n)) { // reachable key, unmarked value
			marked = true
			reallymarkobject(g, gc_value(node_val(n)))
		}
	}
	if g.gcstate == GCSpropagate {
		linkobjgclist(obj2gco(t), &g.grayagain)
	} else if hasww {
		linkobjgclist(obj2gco(t), &g.ephemeron)
	} else if hasclears {
		linkobjgclist(obj2gco(t), &g.allweak)
	} else {
		genlink(g, obj2gco(t))
	}
	return marked
}

// (result & 1) iff weak values; (result & 2) iff weak keys. Reads the table's
// `__mode` metafield. Reference Lua's `getmode`.
getmode :: proc(g: ^Global_State, t: ^Table) -> int {
	// gfasttm: honor the metatable's fast-absence cache before a real lookup.
	mt := t.metatable
	mode: ^TValue = nil
	if mt != nil && (mt.flags & Byte(u32(1) << u32(TM_MODE))) == 0 {
		mode = luaT_gettm(mt, TM_MODE, g.tmname[TM_MODE])
	}
	if mode == nil || !is_string(mode) {
		return 0 // ignore non-string modes
	}
	ts := (^TString)(gc_value(mode))
	smode := str_bytes(ts)
	n := int(ts.len)
	weakkey := false
	weakvalue := false
	for i in 0 ..< n {
		if smode[i] == 'k' {
			weakkey = true
		}
		if smode[i] == 'v' {
			weakvalue = true
		}
	}
	return (int(weakkey) << 1) | int(weakvalue)
}

// Dispatch a table's traversal by its weak mode, marking the metatable first.
// Returns the traversal work estimate. Reference Lua's `traversetable`.
traverse_table :: proc(g: ^Global_State, t: ^Table) -> L_Mem {
	if t.metatable != nil {
		mark_object_n(g, obj2gco(t.metatable))
	}
	switch getmode(g, t) {
	case 0:
		traverse_strong_table(g, t)
	case 1:
		traverse_weakvalue(g, t)
	case 2:
		traverse_ephemeron(g, t, false)
	case 3:
		// All weak: nothing to traverse now, but during propagate the
		// metatable still needs an atomic revisit.
		if g.gcstate == GCSpropagate {
			linkobjgclist(obj2gco(t), &g.grayagain)
		} else {
			linkobjgclist(obj2gco(t), &g.allweak)
		}
	}
	return 1 + 2 * L_Mem(sizenode(t)) + L_Mem(t.asize)
}

// Scan a Lua closure: its prototype and each of its upvalues.
traverse_lclosure :: proc(g: ^Global_State, cl: ^LClosure) -> L_Mem {
	if cl.p != nil {
		mark_object_n(g, obj2gco(cl.p))
	}
	for i in 0 ..< int(cl.nupvalues) {
		uv := cl.upvals[i]
		if uv != nil {
			mark_object_n(g, obj2gco(uv))
		}
	}
	return 1 + L_Mem(cl.nupvalues)
}

// Scan a C/Odin closure: each captured upvalue is a plain value.
traverse_cclosure :: proc(g: ^Global_State, cl: ^CClosure) -> L_Mem {
	for i in 0 ..< int(cl.nupvalues) {
		mark_value(g, &cl.upvalue[i])
	}
	return 1 + L_Mem(cl.nupvalues)
}

// Scan a prototype: its source name, constants, nested prototypes, upvalue names,
// and local-variable names. Reference Lua's `traverseproto`.
traverse_proto :: proc(g: ^Global_State, f: ^Proto) -> L_Mem {
	if f.source != nil {
		mark_object_n(g, obj2gco(f.source))
	}
	for i in 0 ..< f.sizek {
		mark_value(g, &f.k[i])
	}
	for i in 0 ..< f.sizeupvalues {
		if f.upvalues[i].name != nil {
			mark_object_n(g, obj2gco(f.upvalues[i].name))
		}
	}
	for i in 0 ..< f.sizep {
		if f.p[i] != nil {
			mark_object_n(g, obj2gco(f.p[i]))
		}
	}
	for i in 0 ..< f.sizelocvars {
		if f.locvars[i].varname != nil {
			mark_object_n(g, obj2gco(f.locvars[i].varname))
		}
	}
	return 1 + L_Mem(f.sizek) + L_Mem(f.sizeupvalues) + L_Mem(f.sizep) + L_Mem(f.sizelocvars)
}

// Scan a thread: every live stack value plus its open upvalues. Threads keep open
// upvalues alive through the `twups` list processed in the atomic phase; an old or
// still-propagating thread is queued on grayagain so a barrier-touched stack gets
// revisited. On the final (atomic) traversal the dead stack tail is nil-cleared,
// the stack may be shrunk, and the thread is re-linked into `twups` if it still has
// open upvalues. Reference Lua's `traversethread`.
traverse_thread :: proc(g: ^Global_State, th: ^Lua_State) -> L_Mem {
	if isold(obj2gco(th)) || g.gcstate == GCSpropagate {
		linkobjgclist(obj2gco(th), &g.grayagain)
	}
	if th.stack == nil {
		return 1 // a thread that never got its stack (mid-construction)
	}
	for i in 0 ..< th.top {
		mark_value(g, &th.stack[i].val)
	}
	for uv := th.openupval; uv != nil; uv = uv.open_next {
		mark_object_n(g, obj2gco(uv))
	}
	if g.gcstate == GCSatomic { // final traversal?
		if !g.gcemergency {
			shrink_stack(th) // never resize the stack during an emergency GC
		}
		// Clear the dead slice past `top` so stale collectable values there are
		// not accidentally kept next cycle.
		for i in th.top ..< th.stack_size + EXTRA_STACK {
			set_nil(&th.stack[i].val)
		}
		// `remarkupvals` may have unlinked this thread; put it back if it still
		// owns open upvalues (a thread out of `twups` self-loops its link).
		if th.twups == th && th.openupval != nil {
			th.twups = g.twups
			g.twups = th
		}
	}
	return 1 + L_Mem(th.stack_size)
}

// A generationally-old, barrier-touched object needs one more visit. TOUCHED1
// objects go back on grayagain; TOUCHED2 objects simply advance to OLD. This is a
// no-op in incremental mode (nothing is ever TOUCHED). Reference Lua's `genlink`.
genlink :: proc(g: ^Global_State, o: ^GCObject) {
	if getage(o) == G_TOUCHED1 {
		linkobjgclist(o, &g.grayagain)
	} else if getage(o) == G_TOUCHED2 {
		setage(o, G_OLD)
	}
}

// ---------------------------------------------------------------------------
// Object sizing (for GC pacing)
// ---------------------------------------------------------------------------

// The total number of live bytes an object owns: its header struct plus every
// satellite allocation (a table's array/hash, a proto's arrays, a thread's stack
// and frames, a closure's inline upvalue tail, a userdata's payload). Reference
// Lua accumulates this into `GCmarked` during marking so pacing reflects the true
// live set. Header-only sizing would only skew *when* the next cycle starts; it
// never changes *what* gets collected (that is driven by exact debt accounting).
objsize :: proc(o: ^GCObject) -> uint {
	switch o.tt {
	case VSHRSTR, VLNGSTR:
		return string_alloc_size((^TString)(o))
	case VUPVAL:
		return size_of(UpVal)
	case VTABLE:
		t := (^Table)(o)
		res := uint(size_of(Table))
		res += uint(t.asize) * size_of(TValue)
		if !is_dummy(t) {
			res += sizehash(t) // nodes plus the `lastfree` box, as reference counts them
		}
		return res
	case VLCL:
		return size_lclosure(int((^LClosure)(o).nupvalues))
	case VCCL:
		return size_cclosure(int((^CClosure)(o).nupvalues))
	case VPROTO:
		f := (^Proto)(o)
		res := uint(size_of(Proto))
		res += uint(f.sizecode) * size_of(Instruction)
		res += uint(f.sizelineinfo) * size_of(i8)
		res += uint(f.sizeabslineinfo) * size_of(AbsLineInfo)
		res += uint(f.sizep) * size_of(^Proto)
		res += uint(f.sizek) * size_of(TValue)
		res += uint(f.sizelocvars) * size_of(LocVar)
		res += uint(f.sizeupvalues) * size_of(Upvaldesc)
		return res
	case VTHREAD:
		th := (^Lua_State)(o)
		res := uint(size_of(LX))
		if th.stack != nil {
			res += uint(th.stack_size + EXTRA_STACK) * size_of(StackValue)
		}
		res += uint(th.frames_capacity) * size_of(Call_Info)
		return res
	case VUSERDATA:
		u := (^Udata)(o)
		return size_udata(int(u.nuvalue), uint(u.len))
	case:
		return 0
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
	case VUSERDATA:
		u := (^Udata)(o)
		state_free(L, u, size_udata(int(u.nuvalue), u.len))
	case:
		assert(false, "freeobj: unknown object type")
	}
}

// ---------------------------------------------------------------------------
// Root marking (used by restartcollection / atomic)
// ---------------------------------------------------------------------------

// Mark the per-base-type metatables. Reference Lua's `markmt`.
markmt :: proc(g: ^Global_State) {
	for i in 0 ..< NUM_TYPES {
		if g.mt[i] != nil {
			mark_object_n(g, obj2gco(g.mt[i]))
		}
	}
}

// Mark every object currently queued for finalization, so a resurrected object's
// finalizer still sees a live object graph. Reference Lua's `markbeingfnz`.
markbeingfnz :: proc(g: ^Global_State) {
	for o := g.tobefnz; o != nil; o = o.next {
		mark_object(g, o)
	}
}

// For each unmarked thread, simulate a barrier between its open upvalues and their
// values, then drop it (and any thread with no open upvalues) from the `twups`
// list. Reference Lua's `remarkupvals`. A thread out of the list self-loops its
// `twups` link.
remarkupvals :: proc(g: ^Global_State) {
	p := &g.twups
	for p^ != nil {
		thread := p^
		if !is_white(obj2gco(thread)) && thread.openupval != nil {
			p = &thread.twups // keep marked thread with upvalues in the list
		} else {
			p^ = thread.twups // unlink...
			thread.twups = thread // ...and mark it out of the list
			for uv := thread.openupval; uv != nil; uv = uv.open_next {
				if !is_white(obj2gco(uv)) { // already visited?
					mark_value(g, upval_value(uv))
				}
			}
		}
	}
}

// Reset every gray list to empty. Reference Lua's `cleargraylists`.
cleargraylists :: proc(g: ^Global_State) {
	g.gray = nil
	g.grayagain = nil
	g.weak = nil
	g.allweak = nil
	g.ephemeron = nil
}

// Mark the root set and reset the gray lists to start a fresh collection cycle.
// `gc_marked` is zeroed to count the live bytes discovered this cycle. Reference
// Lua's `restartcollection`.
restartcollection :: proc(g: ^Global_State) {
	cleargraylists(g)
	g.gc_marked = 0
	mark_object(g, obj2gco(&g.main_thread.l))
	mark_value(g, &g.registry)
	markmt(g)
	markbeingfnz(g) // finalizing objects left over from the previous cycle
}

// Free absolutely every collectable object at state teardown -- reference Lua's
// `luaC_freeallobjects`. The embedded main thread is special: its struct is part
// of the global block (freed wholesale by `close_state`), so we free everything it
// owns *except* that struct.
luaC_freeallobjects :: proc(L: ^Lua_State) {
	g := L.g
	g.gcstp = GCSTPCLS // no extra finalizers may be enrolled after this point
	luaC_changemode(L, KGC_INC) // finalization only runs in incremental mode
	separatetobefnz(g, true) // separate every object that has a finalizer
	callallpendingfinalizers(L)
	main := obj2gco(&g.main_thread.l)
	deletelist(L, g.allgc, main)
	g.allgc = main
	main.next = nil
	deletelist(L, g.fixedgc, nil) // the fixed strings come down too
	g.fixedgc = nil
}
