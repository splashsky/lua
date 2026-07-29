package lua


// gc_run.odin -- the collector *driver*: the part of reference Lua's `lgc.c` that
// turns the object model + marking + traversal (in gc.odin) into a working
// incremental and generational garbage collector.
//
// The split between gc.odin and this file is purely organizational -- both are the
// single `lua` package, so everything here shares gc.odin's namespace. gc.odin owns
// the object-facing pieces (colors, ages, barriers, per-type traversal, sizing).
// This file owns the *machinery*: the incremental state machine (`singlestep`),
// the atomic phase, the sweep, weak-table clearing, ephemeron convergence, `__gc`
// finalization, the generational transitions, and the public pacing entry points
// (`luaC_step`, `luaC_checkGC`, `luaC_fullgc`, `luaC_changemode`).
//
// It is a faithful port: the function names, the ordering inside `atomic`, and the
// state transitions all mirror lgc.c so the *observable* behavior (weak clearing,
// finalizer ordering, `collectgarbage` counts and modes) matches reference Lua.

// ---------------------------------------------------------------------------
// Driver constants
// ---------------------------------------------------------------------------

// The maximum number of objects a single incremental sweep step reclaims before
// yielding back to the mutator. Reference Lua's `GCSWEEPMAX`.
GCSWEEPMAX :: 20

// The nominal "work" a single-finalizer step reports. Reference Lua's `CWUFIN`
// ("cost of work until finalization"): finalizers are expensive, so one counts
// for a chunk of the step budget.
CWUFIN :: 10

// `singlestep` sentinel return values (all negative so they never collide with a
// real positive work count). Reference Lua's same-named macros.
STEP2PAUSE :: -3 // finished the collection; entered the pause state
ATOMICSTEP :: -2 // just ran the atomic step
STEP2MINOR :: -1 // shifted to (or stayed in) minor generational collections

// Apply a float-coded GC parameter to `x` (computing roughly `param% * x`).
// Reference Lua's `applygcparam`.
apply_gc_param :: #force_inline proc "contextless" (g: ^Global_State, idx: int, x: L_Mem) -> L_Mem {
	return luaO_applyparam(g.gcparams[idx], x)
}

// ---------------------------------------------------------------------------
// Pacing
// ---------------------------------------------------------------------------

// Set the "time" (in bytes of future allocation) before the next incremental
// cycle begins: the threshold is roughly `marked * pause / 100`. Reference Lua's
// `setpause`.
setpause :: proc(g: ^Global_State) {
	threshold := apply_gc_param(g, LUA_GCPPAUSE, g.gc_marked)
	debt := threshold - gettotalbytes(g)
	if debt < 0 {
		debt = 0
	}
	luaE_setdebt(g, debt)
}

// Set the debt for the next *minor* collection: it fires once total bytes grow
// `minormul%` past the base established by the last major collection. Reference
// Lua's `setminordebt`.
setminordebt :: proc(g: ^Global_State) {
	luaE_setdebt(g, apply_gc_param(g, LUA_GCPMINORMUL, g.gc_majorminor))
}

// Is there enough headroom (Lua stack + C-call depth) to safely run a finalizer?
// Reference Lua's `luaD_checkminstack`.
luaD_checkminstack :: proc(L: ^Lua_State) -> bool {
	return L.stack_size < MAXSTACK - BASIC_STACK_SIZE && int(get_ccalls(L)) < LUAI_MAXCCALLS - 2
}

// ---------------------------------------------------------------------------
// Weak-table clearing + ephemeron convergence
// ---------------------------------------------------------------------------

// Traverse all ephemeron tables repeatedly, propagating marks from live keys to
// their values, until a full pass marks nothing new (convergence). The traversal
// direction is flipped each round to speed up convergence on in-table chains.
// Reference Lua's `convergeephemerons`.
convergeephemerons :: proc(g: ^Global_State) {
	dir := false
	changed := true
	for changed {
		next := g.ephemeron
		g.ephemeron = nil // tables re-add themselves as they are traversed
		changed = false
		for next != nil {
			t := (^Table)(next)
			next = t.gclist // the list is rebuilt during the loop
			set2black(obj2gco(t)) // out of the list (for now)
			if traverse_ephemeron(g, t, dir) { // marked some value?
				propagate_all(g) // propagate those marks
				changed = true // and revisit every ephemeron table again
			}
		}
		dir = !dir
	}
}

// Clear entries with unmarked keys from every weak table in list `l`. Reference
// Lua's `clearbykeys`.
clearbykeys :: proc(g: ^Global_State, l: ^GCObject) {
	o := l
	for o != nil {
		h := (^Table)(o)
		sz := sizenode(h)
		for i in 0 ..< sz {
			n := &h.node[i]
			if iscleared(g, gckey_n(n)) { // unmarked key?
				set_empty(&n.val) // remove the entry
			}
			if is_empty(&n.val) {
				clearkey(n) // and retire its (now unused) key
			}
		}
		o = h.gclist
	}
}

// Clear entries with unmarked values from every weak table in list `l`, stopping
// at `f` (a node pointer used to skip tables already processed in an earlier
// atomic sub-step). Reference Lua's `clearbyvalues`.
clearbyvalues :: proc(g: ^Global_State, l: ^GCObject, f: ^GCObject) {
	o := l
	for o != f {
		h := (^Table)(o)
		for i in 0 ..< int(h.asize) {
			if iscleared(g, gcvalue_n(&h.array[i])) { // value collected?
				set_empty(&h.array[i]) // remove the entry
			}
		}
		sz := sizenode(h)
		for i in 0 ..< sz {
			n := &h.node[i]
			if iscleared(g, gcvalue_n(&n.val)) { // unmarked value?
				set_empty(&n.val) // remove the entry
			}
			if is_empty(&n.val) {
				clearkey(n)
			}
		}
		o = h.gclist
	}
}

// ---------------------------------------------------------------------------
// Sweeping
// ---------------------------------------------------------------------------

// Shrink the string table if it has become sparse (never during an emergency
// collection, which must not allocate). Reference Lua's `checkSizes`.
checkSizes :: proc(L: ^Lua_State, g: ^Global_State) {
	if !g.gcemergency {
		if g.strt.nuse < g.strt.size / 4 {
			luaS_resize(L, g.strt.size / 2)
		}
	}
}

// Sweep at most `countin` objects from the list at `p`, freeing the dead (those
// wearing the stale "other" white) and repainting every survivor the fresh current
// white with a NEW age (ready for the next cycle). Returns where to continue, or
// nil at end of list. Reference Lua's `sweeplist`.
sweeplist :: proc(L: ^Lua_State, p: ^^GCObject, countin: L_Mem) -> ^^GCObject {
	g := L.g
	ow := other_white(g)
	white := luaC_white(g) // the fresh current white
	pp := p
	n := countin
	for pp^ != nil && n > 0 {
		n -= 1
		curr := pp^
		marked := curr.marked
		if (marked & ow) != 0 { // is 'curr' dead?
			pp^ = curr.next // unlink...
			freeobj(L, curr) // ...and reclaim
		} else { // survivor: fresh white, NEW age
			curr.marked = (marked & ~Byte(MASK_COLORS | AGE_BITS)) | white | G_NEW
			pp = &curr.next
		}
	}
	return pp^ == nil ? nil : pp
}

// Sweep a list until a live object (or the end). Used by `entersweep` so the sweep
// cursor points *inside* the list, letting objects created after "now" be skipped
// by the real sweep. Reference Lua's `sweeptolive`.
sweeptolive :: proc(L: ^Lua_State, p: ^^GCObject) -> ^^GCObject {
	old := p
	pp := p
	for {
		pp = sweeplist(L, pp, 1)
		if pp != old {
			break
		}
	}
	return pp
}

// Enter the first sweep phase, positioning the sweep cursor inside `allgc`.
// Reference Lua's `entersweep`.
entersweep :: proc(L: ^Lua_State) {
	g := L.g
	g.gcstate = GCSswpallgc
	g.sweepgc = sweeptolive(L, &g.allgc)
}

// Do one sweep step: advance the cursor if a list is in progress, otherwise move
// to the next state and point the cursor at the next list. `fast` sweeps the whole
// list in one go. Reference Lua's `sweepstep`.
sweepstep :: proc(L: ^Lua_State, g: ^Global_State, nextstate: u8, nextlist: ^^GCObject, fast: bool) {
	if g.sweepgc != nil {
		g.sweepgc = sweeplist(L, g.sweepgc, fast ? MAX_LMEM : GCSWEEPMAX)
	} else {
		g.gcstate = nextstate
		g.sweepgc = nextlist
	}
}

// Delete every object in list `p` up to (but not including) `limit`. Reference
// Lua's `deletelist`.
deletelist :: proc(L: ^Lua_State, p: ^GCObject, limit: ^GCObject) {
	o := p
	for o != limit {
		next := o.next
		freeobj(L, o)
		o = next
	}
}

// ---------------------------------------------------------------------------
// Finalization
// ---------------------------------------------------------------------------

// Pop the next object to finalize off `tobefnz`, re-link it into `allgc`, and mark
// it "normal" again. Reference Lua's `udata2finalize`.
udata2finalize :: proc(g: ^Global_State) -> ^GCObject {
	o := g.tobefnz
	g.tobefnz = o.next // remove from 'tobefnz'
	o.next = g.allgc // return it to 'allgc'
	g.allgc = o
	o.marked &= ~Byte(1 << FINALIZEDBIT) // object is "normal" again
	if issweepphase(g) {
		makewhite(g, o) // "sweep" it so it is not immediately collected
	} else if getage(o) == G_OLD1 {
		g.firstold1 = o // it is the first OLD1 object in the list
	}
	return o
}

// The protected body run for one finalizer: call the finalizer with its one
// argument. Reference Lua's `dothecall`.
dothecall :: proc(L: ^Lua_State, ud: rawptr) -> Thread_Status {
	luaD_callnoyield(L, L.top - 2, 0)
	return .Ok
}

// Run one pending finalizer. GC and debug hooks are suspended for its duration, it
// runs inside a protected call, and any error it raises is turned into a warning
// (never propagated) -- reference Lua's `GCTM`. The `CIST_FIN` flag marks the
// frame so `error`/traceback can tell it apart.
GCTM :: proc(L: ^Lua_State) {
	g := L.g
	v: TValue
	set_gc(&v, udata2finalize(g))
	tm := luaT_gettmbyobj(L, &v, TM_GC)
	if !is_nil(tm) { // is there actually a finalizer?
		oldah := L.allowhook
		oldgcstp := g.gcstp
		g.gcstp |= GCSTPGC // no GC steps while the finalizer runs
		L.allowhook = 0 // no debug hooks either
		set_obj(&L.stack[L.top].val, tm) // push the finalizer...
		L.top += 1
		set_obj(&L.stack[L.top].val, &v) // ...and its argument
		L.top += 1
		L.frames[L.ci].callstatus |= CIST_FIN // running a finalizer
		status := luaD_pcall(L, dothecall, nil, L.top - 2, 0)
		L.frames[L.ci].callstatus &~= CIST_FIN
		L.allowhook = oldah // restore hooks
		g.gcstp = oldgcstp // restore GC-stopped state
		if status != .Ok { // error while running __gc?
			luaE_warnerror(L, "__gc")
			L.top -= 1 // pop the error object
		}
	}
}

// Run every pending finalizer. Reference Lua's `callallpendingfinalizers`.
callallpendingfinalizers :: proc(L: ^Lua_State) {
	g := L.g
	for g.tobefnz != nil {
		GCTM(L)
	}
}

// Find the address of the terminating nil `next` link of list `p` (so elements can
// be appended at its end). Reference Lua's `findlast`.
findlast :: proc(p: ^^GCObject) -> ^^GCObject {
	pp := p
	for pp^ != nil {
		pp = &pp^.next
	}
	return pp
}

// Move every unreachable (or, if `all`, *every*) finalizable object from `finobj`
// to `tobefnz`. Reference Lua's `separatetobefnz`.
separatetobefnz :: proc(g: ^Global_State, all: bool) {
	p := &g.finobj
	lastnext := findlast(&g.tobefnz)
	for p^ != g.finobjold1 {
		curr := p^
		if curr == nil {
			break
		}
		if !(is_white(curr) || all) { // not being collected?
			p = &curr.next // leave it in 'finobj'
		} else {
			if curr == g.finobjsur { // removing the survival cursor?
				g.finobjsur = curr.next
			}
			p^ = curr.next // remove from 'finobj'
			curr.next = lastnext^ // link at the end of 'tobefnz'
			lastnext^ = curr
			lastnext = &curr.next
		}
	}
}

// If `*p` points at `o`, advance it past `o`. Reference Lua's `checkpointer`.
checkpointer :: proc(p: ^^GCObject, o: ^GCObject) {
	if o == p^ {
		p^ = o.next
	}
}

// Fix up the generational cursors when `o` is removed from `allgc`. Reference
// Lua's `correctpointers`.
correctpointers :: proc(g: ^Global_State, o: ^GCObject) {
	checkpointer(&g.survival, o)
	checkpointer(&g.old1, o)
	checkpointer(&g.reallyold, o)
	checkpointer(&g.firstold1, o)
}

// If `o` has a `__gc` finalizer, move it off `allgc` and onto `finobj`, so the
// collector will run its finalizer instead of immediately reclaiming it. Called
// when a finalizer is first established on an object's metatable. Reference Lua's
// `luaC_checkfinalizer`.
luaC_checkfinalizer :: proc(L: ^Lua_State, o: ^GCObject, mt: ^Table) {
	g := L.g
	// gfasttm(g, mt, TM_GC): honor the fast-absence cache.
	has_gc := false
	if mt != nil && (mt.flags & Byte(u32(1) << u32(TM_GC))) == 0 {
		has_gc = !is_nil_or_absent(luaT_gettm(mt, TM_GC, g.tmname[TM_GC]))
	}
	if tofinalize(o) || !has_gc || (g.gcstp & GCSTPCLS) != 0 {
		return // already flagged, no finalizer, or the state is closing
	}
	if issweepphase(g) {
		makewhite(g, o) // "sweep" 'o'
		if g.sweepgc == &o.next { // don't strand the sweep cursor
			g.sweepgc = sweeptolive(L, g.sweepgc)
		}
	} else {
		correctpointers(g, o)
	}
	// Find and unlink 'o' from 'allgc'.
	p := &g.allgc
	for p^ != o {
		p = &p^.next
	}
	p^ = o.next
	o.next = g.finobj // link into 'finobj'
	g.finobj = o
	o.marked |= Byte(1 << FINALIZEDBIT)
}

// A lookup result that is nil either because there is no metatable slot (a real
// nil pointer) or because the slot holds a nil value. Reference callers use
// `notm`/NULL checks; this collapses both to one predicate.
is_nil_or_absent :: #force_inline proc "contextless" (tm: ^TValue) -> bool {
	return tm == nil || is_nil(tm)
}

// ---------------------------------------------------------------------------
// The atomic phase
// ---------------------------------------------------------------------------

// The single indivisible step that closes the mark phase: it marks the last roots
// that the mutator may have changed, drains every gray list, converges ephemerons,
// clears weak tables, separates and marks the objects headed for finalization, and
// finally flips the current white so the coming sweep can tell survivors from the
// dead. The exact ordering here matters for correctness and matches reference
// Lua's `atomic` step for step.
atomic :: proc(L: ^Lua_State) {
	g := L.g
	grayagain := g.grayagain // save the original grayagain list
	g.grayagain = nil
	g.gcstate = GCSatomic
	mark_object(g, obj2gco(L)) // the currently running thread
	mark_value(g, &g.registry) // the registry (mutable via the API)
	markmt(g) // the global per-type metatables
	propagate_all(g) // empty the gray list
	remarkupvals(g) // barrier open upvalues of (maybe) dead threads
	propagate_all(g) // propagate those changes
	g.gray = grayagain
	propagate_all(g) // traverse the saved grayagain list
	convergeephemerons(g)
	// Every strongly reachable object is now marked.
	// Clear weak-valued entries before checking finalizers.
	clearbyvalues(g, g.weak, nil)
	clearbyvalues(g, g.allweak, nil)
	origweak := g.weak
	origall := g.allweak
	separatetobefnz(g, false) // move unreachable finalizables to 'tobefnz'
	markbeingfnz(g) // resurrect them (and their reachable graph)
	propagate_all(g) // propagate the resurrection
	convergeephemerons(g)
	// Every resurrected object is now marked too.
	clearbykeys(g, g.ephemeron) // remove dead keys from ephemeron tables
	clearbykeys(g, g.allweak) // remove dead keys from all-weak tables
	clearbyvalues(g, g.weak, origweak) // clear values from resurrected tables
	clearbyvalues(g, g.allweak, origall)
	luaS_clearcache(g) // drop any about-to-die entries from the string cache
	g.currentwhite = other_white(g) // flip: survivors become "old" white
}

// ---------------------------------------------------------------------------
// Generational collector
// ---------------------------------------------------------------------------

// Sweep a list to enter generational mode: free the dead, turn every survivor OLD.
// Surviving threads go on grayagain, open upvalues stay gray, everything else goes
// black. Reference Lua's `sweep2old`.
sweep2old :: proc(L: ^Lua_State, p: ^^GCObject) {
	g := L.g
	pp := p
	for pp^ != nil {
		curr := pp^
		if is_white(curr) { // dead?
			pp^ = curr.next
			freeobj(L, curr)
		} else {
			setage(curr, G_OLD)
			if curr.tt == VTHREAD {
				linkobjgclist(curr, &g.grayagain) // threads must be watched
			} else if curr.tt == VUPVAL && (^UpVal)(curr).open {
				set2gray(curr) // open upvalues are always gray
			} else {
				set2black(curr)
			}
			pp = &curr.next
		}
	}
}

// Sweep for a minor generational cycle: free the dead and advance the ages of the
// survivors (new objects go back to white/survival; older ones keep their color).
// Accumulates the bytes that just became OLD1 into `paddedold`. Reference Lua's
// `sweepgen`.
sweepgen :: proc(L: ^Lua_State, g: ^Global_State, p: ^^GCObject, limit: ^GCObject, pfirstold1: ^^GCObject, paddedold: ^L_Mem) -> ^^GCObject {
	addedold: L_Mem = 0
	white := luaC_white(g)
	pp := p
	for pp^ != limit {
		curr := pp^
		if is_white(curr) { // dead?
			pp^ = curr.next
			freeobj(L, curr)
		} else {
			age := getage(curr)
			if age == G_NEW { // new objects go back to white (survival)
				curr.marked = (curr.marked & ~Byte(MASK_COLORS | AGE_BITS)) | white | G_SURVIVAL
			} else {
				setage(curr, nextage[age]) // all others become older
				if getage(curr) == G_OLD1 {
					addedold += L_Mem(objsize(curr)) // bytes becoming old
					if pfirstold1^ == nil {
						pfirstold1^ = curr
					}
				}
			}
			pp = &curr.next
		}
	}
	paddedold^ += addedold
	return pp
}

// Correct one gray list after a generational sweep: drop white (dead/young)
// objects, advance TOUCHED1 -> TOUCHED2 (kept), keep non-white threads, and turn
// everything else black and remove it. Returns the address of the final link so
// lists can be chained. Reference Lua's `correctgraylist`.
correctgraylist :: proc(p: ^^GCObject) -> ^^GCObject {
	pp := p
	for pp^ != nil {
		curr := pp^
		next := get_gclist(curr)
		if is_white(curr) {
			pp^ = next^ // remove all white (dead or young) objects
		} else if getage(curr) == G_TOUCHED1 {
			set2black(curr) // black, ready for the next barrier
			setage(curr, G_TOUCHED2)
			pp = next // keep it in the list
		} else if curr.tt == VTHREAD {
			pp = next // keep non-white threads on the list
		} else {
			if getage(curr) == G_TOUCHED2 {
				setage(curr, G_OLD) // advance TOUCHED2 -> OLD
			}
			set2black(curr)
			pp^ = next^ // and remove it
		}
	}
	return pp
}

// Correct every gray list, coalescing them all into `grayagain`. Reference Lua's
// `correctgraylists`.
correctgraylists :: proc(g: ^Global_State) {
	list := correctgraylist(&g.grayagain)
	list^ = g.weak
	g.weak = nil
	list = correctgraylist(list)
	list^ = g.allweak
	g.allweak = nil
	list = correctgraylist(list)
	list^ = g.ephemeron
	g.ephemeron = nil
	correctgraylist(list)
}

// Mark the OLD1 objects black at the start of a young collection (so their
// still-young children are found). Reference Lua's `markold`.
markold :: proc(g: ^Global_State, from: ^GCObject, to: ^GCObject) {
	for p := from; p != to; p = p.next {
		if getage(p) == G_OLD1 {
			setage(p, G_OLD) // now they are fully old
			if is_black(p) {
				reallymarkobject(g, p)
			}
		}
	}
}

// Wrap up a minor cycle: correct gray lists, shrink structures, return to the
// propagate state, and run any pending finalizers. Reference Lua's
// `finishgencycle`.
finishgencycle :: proc(L: ^Lua_State, g: ^Global_State) {
	correctgraylists(g)
	checkSizes(L, g)
	g.gcstate = GCSpropagate // skip the restart
	if !g.gcemergency && luaD_checkminstack(L) {
		callallpendingfinalizers(L)
	}
}

// Shift from minor collections to incremental (major) collections: clear the
// generational cursors and continue as a fresh incremental cycle. Reference Lua's
// `minor2inc`.
minor2inc :: proc(L: ^Lua_State, g: ^Global_State, kind: u8) {
	g.gc_majorminor = g.gc_marked // live-byte base
	g.gckind = kind
	g.reallyold = nil
	g.old1 = nil
	g.survival = nil
	g.finobjrold = nil
	g.finobjold1 = nil
	g.finobjsur = nil
	entersweep(L) // continue as an incremental cycle
	luaE_setdebt(g, apply_gc_param(g, LUA_GCPSTEPSIZE, 100))
}

// Decide whether the accumulated old bytes justify shifting to major mode.
// Reference Lua's `checkminormajor`.
checkminormajor :: proc(g: ^Global_State) -> bool {
	limit := apply_gc_param(g, LUA_GCPMINORMAJOR, g.gc_majorminor)
	if limit == 0 {
		return false // 'minormajor' 0 disables major collections
	}
	return g.gc_marked >= limit
}

// Perform one young (minor) collection: mark OLD1 roots, run the atomic step, then
// sweep the nursery and survival lists, advancing the generational cursors.
// Finally decide whether to shift to major mode. Reference Lua's `youngcollection`.
youngcollection :: proc(L: ^Lua_State, g: ^Global_State) {
	addedold1: L_Mem = 0
	marked := g.gc_marked // preserve across the atomic step (which loses it)
	dummy: ^GCObject = nil
	if g.firstold1 != nil {
		markold(g, g.firstold1, g.reallyold)
		g.firstold1 = nil
	}
	markold(g, g.finobj, g.finobjrold)
	markold(g, g.tobefnz, nil)

	atomic(L) // will lose 'g.gc_marked'

	g.gcstate = GCSswpallgc
	psurvival := sweepgen(L, g, &g.allgc, g.survival, &g.firstold1, &addedold1)
	sweepgen(L, g, psurvival, g.old1, &g.firstold1, &addedold1)
	g.reallyold = g.old1
	g.old1 = psurvival^ // 'survival' survivors are old now
	g.survival = g.allgc // all news are survivors

	psurvival = sweepgen(L, g, &g.finobj, g.finobjsur, &dummy, &addedold1)
	sweepgen(L, g, psurvival, g.finobjold1, &dummy, &addedold1)
	g.finobjrold = g.finobjold1
	g.finobjold1 = psurvival^
	g.finobjsur = g.finobj

	sweepgen(L, g, &g.tobefnz, nil, &dummy, &addedold1)

	g.gc_marked = marked + addedold1 // total added-old bytes

	if checkminormajor(g) {
		minor2inc(L, g, KGC_GENMAJOR) // shift to major mode
		g.gc_marked = 0 // avoid a pause in the first major cycle
	} else {
		finishgencycle(L, g)
	}
}

// Turn a completed atomic cycle into generational mode: clear gray lists, sweep
// everything OLD, and set up the generational cursors. Reference Lua's
// `atomic2gen`.
atomic2gen :: proc(L: ^Lua_State, g: ^Global_State) {
	cleargraylists(g)
	g.gcstate = GCSswpallgc
	sweep2old(L, &g.allgc)
	g.reallyold = g.allgc
	g.old1 = g.allgc
	g.survival = g.allgc
	g.firstold1 = nil

	sweep2old(L, &g.finobj)
	g.finobjrold = g.finobj
	g.finobjold1 = g.finobj
	g.finobjsur = g.finobj

	sweep2old(L, &g.tobefnz)

	g.gckind = KGC_GENMINOR
	g.gc_majorminor = g.gc_marked // "base" number of bytes
	g.gc_marked = 0 // count added-old bytes from here
	finishgencycle(L, g)
}

// Enter generational mode: run a full incremental cycle to the end of its atomic
// phase (so all weak tables are cleared and marks are exact), then convert to
// generational. Reference Lua's `entergen`.
entergen :: proc(L: ^Lua_State, g: ^Global_State) {
	luaC_runtilstate(L, GCSpause, true) // finish any current cycle
	luaC_runtilstate(L, GCSpropagate, true) // start a fresh one
	atomic(L)
	atomic2gen(L, g)
	setminordebt(g)
}

// Change the collector mode to `newmode` (KGC_INC or KGC_GENMINOR). Reference
// Lua's `luaC_changemode`.
luaC_changemode :: proc(L: ^Lua_State, newmode: int) {
	g := L.g
	if g.gckind == KGC_GENMAJOR {
		g.gckind = KGC_INC // already incremental, just rename
	}
	if newmode != int(g.gckind) {
		if newmode == KGC_INC {
			minor2inc(L, g, KGC_INC)
		} else {
			entergen(L, g)
		}
	}
}

// A full collection while in generational mode: drop to incremental, do a full
// incremental collection, then re-enter generational. Reference Lua's `fullgen`.
fullgen :: proc(L: ^Lua_State, g: ^Global_State) {
	minor2inc(L, g, KGC_INC)
	entergen(L, g)
}

// After a major atomic step, decide whether the collector should return to minor
// collections (it does if too little was collected). Reference Lua's
// `checkmajorminor`.
checkmajorminor :: proc(L: ^Lua_State, g: ^Global_State) -> bool {
	if g.gckind == KGC_GENMAJOR {
		numbytes := gettotalbytes(g)
		addedbytes := numbytes - g.gc_majorminor
		limit := apply_gc_param(g, LUA_GCPMAJORMINOR, addedbytes)
		tobecollected := numbytes - g.gc_marked
		if tobecollected > limit {
			atomic2gen(L, g) // back to generational mode
			setminordebt(g)
			return true
		}
	}
	g.gc_majorminor = g.gc_marked // prepare for the next collection
	return false
}

// ---------------------------------------------------------------------------
// The incremental state machine
// ---------------------------------------------------------------------------

// Perform one incremental step and return an estimate of the work done (or one of
// the STEP2*/ATOMICSTEP sentinels). `fast` finishes each state as fast as possible
// (used by full collections and to skip propagation). Reference Lua's
// `singlestep`.
singlestep :: proc(L: ^Lua_State, fast: bool) -> L_Mem {
	g := L.g
	g.gcstopem = 1 // no emergency collections while collecting
	stepresult: L_Mem
	switch g.gcstate {
	case GCSpause:
		restartcollection(g)
		g.gcstate = GCSpropagate
		stepresult = 1
	case GCSpropagate:
		if fast || g.gray == nil {
			g.gcstate = GCSenteratomic // finish the propagate phase
			stepresult = 1
		} else {
			stepresult = propagatemark(g) // traverse one gray object
		}
	case GCSenteratomic:
		atomic(L)
		if checkmajorminor(L, g) {
			stepresult = STEP2MINOR
		} else {
			entersweep(L)
			stepresult = ATOMICSTEP
		}
	case GCSswpallgc:
		sweepstep(L, g, GCSswpfinobj, &g.finobj, fast)
		stepresult = GCSWEEPMAX
	case GCSswpfinobj:
		sweepstep(L, g, GCSswptobefnz, &g.tobefnz, fast)
		stepresult = GCSWEEPMAX
	case GCSswptobefnz:
		sweepstep(L, g, GCSswpend, nil, fast)
		stepresult = GCSWEEPMAX
	case GCSswpend:
		checkSizes(L, g)
		g.gcstate = GCScallfin
		stepresult = GCSWEEPMAX
	case GCScallfin:
		if g.tobefnz != nil && !g.gcemergency && luaD_checkminstack(L) {
			g.gcstopem = 0 // collections are ok during finalizers
			GCTM(L) // run one finalizer
			return CWUFIN
		} else {
			g.gcstate = GCSpause // finish the collection
			stepresult = STEP2PAUSE
		}
	case:
		assert(false, "singlestep: bad gcstate")
		stepresult = 0
	}
	g.gcstopem = 0
	return stepresult
}

// Advance the collector until it reaches `state`. Reference Lua's
// `luaC_runtilstate`. `fast` is used only for full collections and setup.
luaC_runtilstate :: proc(L: ^Lua_State, state: u8, fast: bool) {
	g := L.g
	for state != g.gcstate {
		singlestep(L, fast)
	}
}

// Perform one incremental "step": convert the step size (in bytes) into units of
// work, then run single steps until that much work is done or the cycle ends.
// Finally, set the debt controlling when the next step runs. Reference Lua's
// `incstep`.
incstep :: proc(L: ^Lua_State, g: ^Global_State) {
	stepsize := apply_gc_param(g, LUA_GCPSTEPSIZE, 100)
	work2do := apply_gc_param(g, LUA_GCPSTEPMUL, stepsize / size_of(rawptr))
	fast := work2do == 0 // special case: do a full collection
	for {
		stres := singlestep(L, fast)
		if stres == STEP2MINOR {
			return // shifted to minor collections; nothing else to do
		} else if stres == STEP2PAUSE || (stres == ATOMICSTEP && !fast) {
			break // end of cycle, or the atomic step in a paced run
		} else {
			work2do -= stres
		}
		if !(fast || work2do > 0) {
			break
		}
	}
	if g.gcstate == GCSpause {
		setpause(g) // pause until the next cycle
	} else {
		luaE_setdebt(g, stepsize)
	}
}

// Perform a GC step if the collector is running; if it was stopped by the user,
// push the debt out so we are not called on every check. Reference Lua's
// `luaC_step`.
luaC_step :: proc(L: ^Lua_State) {
	g := L.g
	if !gcrunning(g) {
		if (g.gcstp & GCSTPUSR) != 0 { // stopped by the user?
			luaE_setdebt(g, 20000)
		}
	} else {
		switch g.gckind {
		case KGC_INC, KGC_GENMAJOR:
			incstep(L, g)
		case KGC_GENMINOR:
			youngcollection(L, g)
			setminordebt(g)
		}
	}
}

// The pacing check wired at safe points across the interpreter: if the debt has
// run out, take a GC step. Reference Lua's `luaC_checkGC` / `luaC_condGC`.
luaC_checkGC :: proc(L: ^Lua_State) {
	if L.g.gc_debt <= 0 {
		luaC_step(L)
	}
}

// ---------------------------------------------------------------------------
// Full collections
// ---------------------------------------------------------------------------

// A full collection in incremental mode. If the invariant is currently held there
// may be black objects, so we first sweep everything back to white (nothing is
// collected, since white has not changed), then run a clean cycle to completion.
// Reference Lua's `fullinc`.
fullinc :: proc(L: ^Lua_State, g: ^Global_State) {
	if keepinvariant(g) { // black objects around?
		entersweep(L) // sweep them back to white
	}
	luaC_runtilstate(L, GCSpause, true) // finish any pending sweep
	luaC_runtilstate(L, GCScallfin, true) // run up to finalizers
	luaC_runtilstate(L, GCSpause, true) // finish the collection
	setpause(g)
}

// Perform a full GC cycle. `isemergency` set a flag that suppresses operations
// which could reenter the interpreter unexpectedly (running finalizers, shrinking
// structures). Reference Lua's `luaC_fullgc`.
luaC_fullgc :: proc(L: ^Lua_State, isemergency: bool) {
	g := L.g
	g.gcemergency = isemergency
	switch g.gckind {
	case KGC_GENMINOR:
		fullgen(L, g)
	case KGC_INC:
		fullinc(L, g)
	case KGC_GENMAJOR:
		g.gckind = KGC_INC
		fullinc(L, g)
		g.gckind = KGC_GENMAJOR
	}
	g.gcemergency = false
}

// A convenience alias kept for the Phase-3 tests, which drive a deterministic full
// collection directly. The real work is the incremental collector above; a "full"
// collection just runs it to completion. `emergency` is threaded through faithfully.
gc_full :: proc(L: ^Lua_State, emergency: bool) {
	luaC_fullgc(L, emergency)
}

// ---------------------------------------------------------------------------
// Warnings
// ---------------------------------------------------------------------------

// Emit a warning through the installed handler, or drop it if none is set --
// reference Lua's `luaE_warning`/`luaE_warnerror`. Used to report an error raised
// by a `__gc` finalizer without propagating it. With no handler installed we emit
// nothing (reference Lua is silent without a callback). The error object the
// finalizer left on the stack top is included, matching reference phrasing
// "error in <where> (<msg>)".
luaE_warnerror :: proc(L: ^Lua_State, whence: cstring) {
	g := L.g
	if g.warnf == nil {
		return
	}
	errobj := &L.stack[L.top - 1].val
	msg: cstring = "error object is not a string"
	if is_string(errobj) {
		// Lua strings are always stored NUL-terminated, so their byte buffer is a
		// valid cstring.
		msg = cstring(str_bytes((^TString)(gc_value(errobj))))
	}
	g.warnf(g.ud_warn, "error in ", 1)
	g.warnf(g.ud_warn, whence, 1)
	g.warnf(g.ud_warn, " (", 1)
	g.warnf(g.ud_warn, msg, 1)
	g.warnf(g.ud_warn, ")", 0)
}
