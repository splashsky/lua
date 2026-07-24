package lua

// state.odin -- our analogue of reference Lua's `lstate.h` / `lstate.c`.
//
// Defines the two central runtime structures:
//   * `lua_State`   -- one thread of execution: its value stack, its explicit
//                      call-frame stack, current status, error-handling boundary
//                      chain, and hook state.
//   * `global_State`-- state shared by all threads in a Lua universe: the string
//                      table (interning), the GC's bookkeeping and object lists,
//                      the registry, the main thread, and the memory allocator.
//
// A crucial deviation from a naive port (see docs/ARCHITECTURE.md, Decisions 2
// and 3): the value stack and the call-frame stack are arrays this state owns,
// addressed by *index*, never the native Odin call stack and never retained
// pointers. That is what makes faithful error unwinding and coroutine
// suspend/resume possible without setjmp/longjmp.
//
// TODO(phase-2): define lua_State / global_State, stack + frame arrays as
// index-addressed structures, thread status, and creation/teardown.

// ---------------------------------------------------------------------------
// Call frames
// ---------------------------------------------------------------------------

// The continuation function a C frame parks so it can be resumed after a yield --
// reference Lua's `lua_KFunction`. It receives the thread, the status the call is
// being continued with, and the opaque context the C function stashed.
K_Function :: #type proc "c" (L: rawptr, status: i32, ctx: K_Context) -> i32

// The opaque context a C continuation carries across a yield -- reference Lua's
// `lua_KContext`. It is exactly pointer-width and signed (reference default
// `ptrdiff_t`); Odin's `int` is pointer-width on our targets.
K_Context :: distinct int

// A debug hook -- reference Lua's `lua_Hook`. It is handed the thread and a
// filled-in activation record. `Lua_Debug` is defined with the debug machinery;
// the pointer is opaque here so the frame struct doesn't depend on it.
Hook_Proc :: #type proc "c" (L: rawptr, ar: rawptr)

// `Call_Info` is one activation record on a thread's explicit call-frame stack --
// reference Lua's `CallInfo`. The reference struct is a doubly linked list node
// holding raw stack *pointers*; ours lives in a growable array and stores stack
// *indices* instead (Decision 4: nothing that can move is addressed by pointer).
// The previous/next links become simple index arithmetic (frame `ci-1` is the
// caller), which is why they aren't fields here.
//
// CRITICAL (Decision 4, reaffirmed in the Phase-5 design review): because the
// frame array can be reallocated by any nested call/metamethod/hook, code must
// hold a frame *index* across any re-entrant operation and re-derive
// `&L.frames[idx]` afterward -- never cache a `^Call_Info` across a call.
//
// The `u` union mirrors reference Lua's: a Lua frame needs its saved program
// counter (for us an *index* into `Proto.code`, not a pointer), a line/count
// trap flag, and its vararg overflow count; a C frame needs its yield
// continuation, the caller's error handler to restore, and the continuation's
// context. `u2` overlays three disjoint uses (a C function's protected-call
// function index, a yielding function's yielded-value count, a returning
// function's result count while closing to-be-closed variables).
Call_Info :: struct {
	func:       int, // stack index of this frame's function slot
	top:        int, // stack index one past this frame's usable region
	u:          struct #raw_union {
		l: struct {
			// only for Lua frames
			savedpc:    int, // index of the NEXT instruction in Proto.code
			trap:       i32, // nonzero while tracing lines/counts
			nextraargs: int, // # extra args a vararg call received
		},
		c: struct {
			// only for C frames
			k:           K_Function, // continuation to run after a yield
			old_errfunc: int, // caller's errfunc, to restore
			ctx:         K_Context, // continuation context
		},
	},
	u2:         int, // funcidx | nyield | nres (disjoint uses, per reference)
	callstatus: u32, // CIST_* flag bits (also packs the wanted-results count)
}

// `callstatus` layout and flag bits, matching reference Lua 5.5's `CIST_*`
// (lstate.h). The low byte packs the *expected number of results + 1*; bits 8-11
// count `__call`-metamethod recursion; bits 12-14 hold the "recover status" used
// to carry an error code across a yielding `__close`; bit 15 is `CIST_C`; the
// remaining flags climb from there.
CIST_NRESULTS :: u32(0xff) // bits 0-7: (wanted results + 1)
CIST_CCMT :: u32(8) // offset of the __call-metamethod counter (bits 8-11)
MAX_CCMT :: u32(0xf) << CIST_CCMT // full __call counter
CIST_RECST :: u32(12) // offset of the 3-bit recover-status field (bits 12-14)
CIST_C :: u32(1) << (CIST_RECST + 3) // frame runs a C (Odin) function (bit 15)
CIST_FRESH :: CIST_C << 1 // frame is a fresh `luaV_execute` invocation
CIST_CLSRET :: CIST_FRESH << 1 // frame is closing to-be-closed variables
CIST_TBC :: CIST_CLSRET << 1 // frame has to-be-closed variables
CIST_OAH :: CIST_TBC << 1 // saved original value of `allowhook`
CIST_HOOKED :: CIST_OAH << 1 // frame is running a debug hook
CIST_YPCALL :: CIST_HOOKED << 1 // frame is a yieldable protected call
CIST_TAIL :: CIST_YPCALL << 1 // frame was entered by a tail call
CIST_HOOKYIELD :: CIST_TAIL << 1 // last hook call yielded
CIST_FIN :: CIST_HOOKYIELD << 1 // frame "called" a finalizer

// The maximum results a call may request, which must fit in the `CIST_NRESULTS`
// byte -- reference Lua's `MAXRESULTS`.
MAXRESULTS :: 250

// Decode the wanted-results count packed in a `callstatus` -- reference Lua's
// `get_nresults`. The stored value is (wanted + 1), so `LUA_MULTRET` (-1) rides
// through as 0.
get_nresults :: #force_inline proc "contextless" (cs: u32) -> int {
	return int(cs & CIST_NRESULTS) - 1
}

// Whether frame `ci` is running a Lua function (not a C function) -- reference
// `isLua`.
is_lua_frame :: #force_inline proc "contextless" (ci: ^Call_Info) -> bool {
	return (ci.callstatus & CIST_C) == 0
}

// The 3-bit "recover status" packed into `callstatus` (bits 12-14). A yielding
// `__close` needs to remember which error code interrupted it so that, once the
// close finishes, the surrounding `pcall` can report that original status. These
// two helpers read and write that field -- reference `getcistrecst`/`setcistrecst`.
get_cist_recst :: #force_inline proc "contextless" (ci: ^Call_Info) -> Thread_Status {
	return Thread_Status((ci.callstatus >> CIST_RECST) & 7)
}
set_cist_recst :: #force_inline proc "contextless" (ci: ^Call_Info, st: Thread_Status) {
	ci.callstatus = (ci.callstatus & ~(u32(7) << CIST_RECST)) | (u32(st) << CIST_RECST)
}

// The `CIST_OAH` bit stashes the caller's `allowhook` across a call so it can be
// restored afterward -- reference `getoah`/`setoah`. `get_oah` returns the saved
// hook flag (0/1); `set_oah` records the current value into the frame.
get_oah :: #force_inline proc "contextless" (ci: ^Call_Info) -> u8 {
	return (ci.callstatus & CIST_OAH) != 0 ? 1 : 0
}
set_oah :: #force_inline proc "contextless" (ci: ^Call_Info, v: u8) {
	if v != 0 {
		ci.callstatus |= CIST_OAH
	} else {
		ci.callstatus &= ~CIST_OAH
	}
}

// Whether frame `ci` is running Lua code and not a hook -- reference `isLuacode`.
is_lua_code :: #force_inline proc "contextless" (ci: ^Call_Info) -> bool {
	return (ci.callstatus & (CIST_C | CIST_HOOKED)) == 0
}

// The Lua closure a frame is executing -- reference Lua's `ci_func`. Only valid
// for Lua frames.
ci_func :: #force_inline proc "contextless" (L: ^Lua_State, ci: ^Call_Info) -> ^LClosure {
	return (^LClosure)(stack_value(L, ci.func).value_.gc)
}

// ---------------------------------------------------------------------------
// The nCcalls split: C-call depth (low 16 bits) + non-yieldable count (high 16)
// ---------------------------------------------------------------------------
//
// Reference Lua packs two counters into `nCcalls` so both can be saved/restored
// with one move: the low half is how deep we are in native recursion (the
// overflow guard), the high half is how many of those calls forbid yielding.

// A single non-yieldable call: increments both halves at once -- reference `nyci`.
nyci :: u32(0x10000) | u32(1)

// The real number of nested C calls -- reference `getCcalls`.
get_ccalls :: #force_inline proc "contextless" (L: ^Lua_State) -> u32 {
	return L.n_ccalls & 0xffff
}

// Whether this thread may yield: true iff there are no non-yieldable calls on its
// stack -- reference `yieldable`.
yieldable :: #force_inline proc "contextless" (L: ^Lua_State) -> bool {
	return (L.n_ccalls & 0xffff0000) == 0
}

// Enter / leave a non-yieldable region -- reference `incnny`/`decnny`.
incnny :: #force_inline proc "contextless" (L: ^Lua_State) {
	L.n_ccalls += 0x10000
}
decnny :: #force_inline proc "contextless" (L: ^Lua_State) {
	L.n_ccalls -= 0x10000
}

// ---------------------------------------------------------------------------
// The string table (placeholder)
// ---------------------------------------------------------------------------

// Reference Lua interns every short string in this open-addressed table
// (`stringtable`). The real entries are `TString*`, a Phase-3 type, so for now
// the bucket array is typed as `^GCObject` and the table simply starts empty.
// Phase 3 fills this in; `close_state` already knows to free the bucket array.
String_Table :: struct {
	hash: [^]^TString, // array of ^TString buckets (open hashing with chains)
	nuse: int, // number of strings currently interned
	size: int, // number of buckets
}

// The embedder-supplied panic function (reference Lua's `lua_CFunction` panic).
// Called as an absolute last resort when an error reaches a thread with no
// protected boundary at all. It uses the C calling convention because embedders
// written in C must be able to supply one.
Panic_Proc :: #type proc "c" (L: ^Lua_State) -> i32

// ---------------------------------------------------------------------------
// A thread of execution
// ---------------------------------------------------------------------------

// `Lua_State` is one Lua thread: the main thread, or (Phase 5) a coroutine. It
// owns a value stack and a call-frame stack, both growable arrays addressed by
// index, plus the status/error/hook bookkeeping for this line of execution.
//
// It is itself a collectable object (a thread has GC type `VTHREAD`), so it
// begins with the common GC header -- that first-field placement lets a
// `^GCObject` alias any `^Lua_State` (asserted just below).
Lua_State :: struct {
	using header: GCObject, // MUST be first: enables ^GCObject punning
	status:       Thread_Status, // last status of this thread
	allowhook:    u8, // whether debug hooks may fire (Phase 5)
	g:            ^Global_State, // the shared state this thread belongs to

	// value stack ------------------------------------------------------
	// `stack` is the base of an allocation of `stack_size + EXTRA_STACK`
	// slots. `stack_size` is the usable count (reference's `stack_last`);
	// the extra tail slots are the reserve error-handling headroom. `top`
	// is the index of the first free slot. All three are indices, never
	// pointers, so a reallocation never invalidates anything.
	stack:        [^]StackValue,
	stack_size:   int,
	top:          int,

	// call-frame stack -------------------------------------------------
	frames:          [^]Call_Info,
	frames_capacity: int, // allocated frame slots
	ci:              int, // index of the current (innermost) frame
	nci:             int, // number of frames currently in use

	// to-be-closed variables + open upvalues ---------------------------
	tbclist:   int, // stack index of the newest to-be-closed slot
	openupval: ^UpVal, // list head of this thread's open upvalues (by index)

	// control ----------------------------------------------------------
	n_ccalls:             u32, // nested non-yieldable calls (overflow guard)
	errfunc:              int, // stack index of the current message handler
	oldpc:                int, // last program counter (for hooks/line info)
	errorJmp:             ^Lua_Longjmp, // innermost active protected boundary (nil if none)

	// debug hooks (Phase 5) --------------------------------------------
	hook:          Hook_Proc, // the installed hook, if any
	hookmask:      i32, // which hook events are enabled (LUA_MASK*)
	basehookcount: i32, // reload value for the instruction-count hook
	hookcount:     i32, // instructions remaining until the next count hook
	// values transferred to/from a call, for the call/return hooks
	transfer_first: int, // offset of the first transferred value
	transfer_n:     int, // number of transferred values

	twups:  ^Lua_State, // link in the list of threads with open upvalues
	gclist: ^GCObject, // GC gray-list thread (a thread has children to scan)
}

// The GC-punning promise: a `^Lua_State` must be reinterpretable as a
// `^GCObject`, which is only sound if the header sits at offset zero.
#assert(offset_of(Lua_State, header) == 0)

// ---------------------------------------------------------------------------
// The shared global state
// ---------------------------------------------------------------------------

// The embedder's opaque "extra space", `sizeof(void*)` bytes reference Lua places
// in *front* of every `lua_State` (`LUA_EXTRASPACE` in luaconf.h). Embedders use
// it to hang per-thread data off a state without a separate allocation.
LUA_EXTRASPACE :: size_of(rawptr)

// `LX` wraps a thread with that extra space ahead of it, exactly like reference
// Lua's `LX`. Keeping the layout means `&lx.l` is the public `Lua_State*` and the
// extra space is reachable at a fixed negative offset from it.
LX :: struct {
	extra: [LUA_EXTRASPACE]u8,
	l:     Lua_State,
}

// `Global_State` is the state shared by every thread in one Lua universe --
// reference Lua's `global_State`. It holds the allocator, the GC's accounting and
// object lists, the string-intern table, the registry, and (embedded, just like
// reference's `mainth`) the main thread itself. Because the main thread lives
// *inside* this block, a single allocation brings a whole Lua state into being.
//
// Many GC fields (the generational survival/old lists, weak/ephemeron lists,
// finalizer queues), the per-type metatables, the tag-method name cache, the
// string cache, and the warning hook are Phase-3/Phase-7 concerns and are added
// as those subsystems come online. What's here is the minimum a Phase-2 state
// needs plus the byte-accounting scaffold the review insisted we not skip.
Global_State :: struct {
	alloc: Allocator, // reference frealloc + ud

	// GC byte accounting (see mem.odin's state_realloc / state_free) ----
	gc_total_bytes: L_Mem, // reference GCtotalbytes (allocated + debt)
	gc_debt:        L_Mem, // reference GCdebt
	gc_marked:      L_Mem, // reference GCmarked

	// GC mode + roots (inert scaffold until the collector lands) --------
	allgc:        ^GCObject, // list of all collectable objects
	fixedgc:      ^GCObject, // objects never collected (fixed strings)
	gray:         ^GCObject, // the mark phase's gray worklist (threaded gclists)
	currentwhite: u8, // current "white" GC color (see gc.odin)
	gc_state:     u8, // TODO(phase-7): incremental GC phase
	gc_kind:      u8, // KGC_INC / generational
	gcstp:        u8, // GC-stopped flags
	gcrunning:    bool, // true while gc_full is mid-collection (Phase 3)

	strt:     String_Table, // interned short strings
	strcache: [STRCACHE_N][STRCACHE_M]^TString, // address-keyed string cache
	memerrmsg: ^TString, // preallocated "not enough memory" message
	tmname:   [TM_N]^TString, // interned metamethod names, by event id
	mt:       [NUM_TYPES]^Table, // per-base-type metatables (nil until set)
	registry: TValue, // reference l_registry (the registry table)
	nilvalue: TValue, // "state complete" sentinel (see completestate)
	seed:     u32, // hash seed for strings
	panic:    Panic_Proc, // last-resort unhandled-error hook

	main_thread: LX, // the main thread, embedded in this block
}

// The incremental GC kind, reference `KGC_INC`. Named so the scaffold reads
// truthfully even though the collector itself is Phase 7.
KGC_INC :: 0

// A state is *fully built* exactly when its `nilvalue` sentinel is nil. During
// construction we park a non-nil value there (an integer 0); the final step of
// `f_luaopen` sets it to nil to announce completion. This lets `close_state`
// tell a half-built state (free objects only) from a finished one. Mirrors
// reference Lua's `completestate`.
completestate :: proc "contextless" (g: ^Global_State) -> bool {
	return is_nil(&g.nilvalue)
}

// A typed view of stack slot `i` as a plain `TValue`. Reference Lua's `s2v`.
// Slots are `StackValue` overlays; the interpreter almost always wants the value
// half. Kept tiny and inlined because it's on every hot path.
stack_value :: #force_inline proc "contextless" (L: ^Lua_State, i: int) -> ^TValue {
	return &L.stack[i].val
}

// ---------------------------------------------------------------------------
// Thread + state creation and teardown
// ---------------------------------------------------------------------------

// The initial capacity of a thread's call-frame array. Reference Lua embeds a
// single `base_ci` and grows a linked list on demand; our index model uses one
// contiguous array instead, so we seed it with a handful of frames and (Phase 5)
// reallocate it when calls nest deeper. The exact seed is not observable.
INITIAL_FRAMES :: 8

// Bring a thread to a consistent, allocation-free baseline -- reference Lua's
// `preinit_thread`. Deliberately touches no memory so it is safe to run before
// any fallible step: if a later allocation fails, teardown sees well-defined
// nil/zero fields rather than garbage.
preinit_thread :: proc(L: ^Lua_State, g: ^Global_State) {
	L.g = g
	L.stack = nil
	L.stack_size = 0
	L.top = 0
	L.frames = nil
	L.frames_capacity = 0
	L.ci = 0
	L.nci = 0
	L.tbclist = 0
	L.openupval = nil
	L.gclist = nil
	L.twups = L // a lone thread points its upvalue-thread link at itself
	L.n_ccalls = 0
	L.errfunc = 0
	L.oldpc = 0
	L.errorJmp = nil
	L.hook = nil
	L.hookmask = 0
	L.basehookcount = 0
	L.hookcount = 0
	L.transfer_first = 0
	L.transfer_n = 0
	L.allowhook = 1
	L.status = .Ok
}

// Ensure a frame exists at index `ci + 1`, growing the frame array if the current
// one is full, and return that index -- our analogue of reference Lua's
// `next_ci`/`luaE_extendCI`. Reference keeps freed `CallInfo` nodes on a
// per-thread free list and reuses them; our contiguous array simply grows its
// capacity and hands back the next slot. Because callers address frames by index,
// a reallocation here invalidates nothing (Decision 4). Raises `Err_Mem` through
// the active boundary on allocation failure.
next_ci :: proc(L: ^Lua_State) -> int {
	next := L.ci + 1
	if next >= L.frames_capacity {
		// Grow the frame array. The 1.5x policy mirrors our other growable
		// arrays; the exact factor is not observable.
		newcap := L.frames_capacity + (L.frames_capacity >> 1)
		if newcap < next + 1 {
			newcap = next + 1
		}
		oldbytes := uint(L.frames_capacity) * size_of(Call_Info)
		newbytes := uint(newcap) * size_of(Call_Info)
		block := state_realloc(L, L.frames, oldbytes, newbytes)
		if block == nil {
			throw(L, .Err_Mem)
		}
		L.frames = ([^]Call_Info)(block)
		L.frames_capacity = newcap
	}
	L.ci = next
	L.nci = next + 1 // active frames are exactly 0..ci (invariant nci == ci+1)
	return next
}

// Point the current frame back at the freshly created base frame and reset the
// per-frame invariants -- reference Lua's `resetCI`. The base frame is a C/Odin
// frame (`CIST_C`) whose "function" slot is stack index 0 (left nil) and whose
// usable top reaches `1 + LUA_MINSTACK`, guaranteeing a minimum working area.
reset_ci :: proc(L: ^Lua_State) {
	L.ci = 0
	L.nci = 1
	base := &L.frames[0]
	base.func = 0
	set_nil(stack_value(L, 0)) // the base frame's function entry
	base.top = 0 + 1 + LUA_MINSTACK
	base.callstatus = CIST_C
	base.u.c.k = nil // no continuation on the host frame
	base.u.c.old_errfunc = 0
	base.u2 = 0
	L.status = .Ok
	L.errfunc = 0
}

// Allocate and initialize a thread's value stack and call-frame stack --
// reference Lua's `stack_init`. Both allocations flow through the state-aware
// allocator so the GC's byte accounting stays honest. On failure we raise
// `Err_Mem` through the active protected boundary; the half-done state is safe to
// tear down because everything not yet allocated is still nil (see
// `preinit_thread`).
// Allocate and initialize a thread's value stack and call-frame stack --
// reference Lua's `stack_init`. Both allocations flow through the state-aware
// allocator so the GC's byte accounting stays honest. `L1` is the thread being
// initialized; `L` is the thread whose protected boundary should catch an
// allocation failure (they are the same for the main thread, but differ when a
// running thread spawns a coroutine). On failure we raise `Err_Mem` through `L`'s
// boundary; the half-done state is safe to tear down because everything not yet
// allocated is still nil (see `preinit_thread`).
stack_init :: proc(L1: ^Lua_State, L: ^Lua_State) -> Thread_Status {
	// The value stack: BASIC_STACK_SIZE usable slots plus the EXTRA_STACK
	// reserve, every slot erased to nil so nothing ever scans garbage.
	total := BASIC_STACK_SIZE + EXTRA_STACK
	sblock := state_realloc(L, nil, 0, uint(total) * size_of(StackValue))
	if sblock == nil {
		return throw(L, .Err_Mem)
	}
	L1.stack = ([^]StackValue)(sblock)
	for i in 0 ..< total {
		set_nil(&L1.stack[i].val)
	}
	L1.stack_size = BASIC_STACK_SIZE
	L1.tbclist = 0 // no to-be-closed slots yet; anchor at the stack base
	L1.top = 1 // slot 0 is the base frame's function entry

	// The call-frame stack, seeded with room for a few frames.
	fblock := state_realloc(L, nil, 0, uint(INITIAL_FRAMES) * size_of(Call_Info))
	if fblock == nil {
		return throw(L, .Err_Mem)
	}
	L1.frames = ([^]Call_Info)(fblock)
	L1.frames_capacity = INITIAL_FRAMES

	reset_ci(L1)
	return .Ok
}

// Registry index constants -- reference Lua's `LUA_RIDX_*`. The registry is a
// plain table the implementation uses for a few well-known slots: slot 1 is
// reserved (a `false` placeholder), slot 2 is the globals table, slot 3 is the
// main thread. `LUA_RIDX_LAST` is the highest predefined slot.
LUA_RIDX_GLOBALS :: 2
LUA_RIDX_MAINTHREAD :: 3
LUA_RIDX_LAST :: 3

// Build the registry table and populate its predefined slots -- reference Lua's
// `init_registry`. The registry is where the implementation (and later the C-API)
// stashes globally reachable values: the globals table, the main thread, and
// user-held references. Any allocation here can fail, so we thread the status out.
init_registry :: proc(L: ^Lua_State) -> Thread_Status {
	g := L.g
	registry := luaH_new(L)
	if registry == nil {
		return throw(L, .Err_Mem)
	}
	set_gc(&g.registry, &registry.header)
	if luaH_resize(L, registry, LUA_RIDX_LAST, 0) != .Ok {
		return .Err_Mem
	}

	aux: TValue
	// registry[1] = false (a reserved placeholder slot).
	set_bool(&aux, false)
	if luaH_setint(L, registry, 1, &aux) != .Ok {
		return .Err_Mem
	}
	// registry[LUA_RIDX_MAINTHREAD] = the main thread.
	set_gc(&aux, &L.header)
	if luaH_setint(L, registry, LUA_RIDX_MAINTHREAD, &aux) != .Ok {
		return .Err_Mem
	}
	// registry[LUA_RIDX_GLOBALS] = a fresh table (the globals `_G`).
	globals := luaH_new(L)
	if globals == nil {
		return throw(L, .Err_Mem)
	}
	set_gc(&aux, &globals.header)
	if luaH_setint(L, registry, LUA_RIDX_GLOBALS, &aux) != .Ok {
		return .Err_Mem
	}
	return .Ok
}

// The allocation-heavy half of state creation, run *under* a protected boundary
// so any failure becomes a clean `Err_Mem` rather than a crash -- reference Lua's
// `f_luaopen`. It brings up the stack, the registry, the string subsystem, and the
// metamethod-name table (in that dependency order), re-enables the collector, and
// finally nils the sentinel to announce the state is complete.
f_luaopen :: proc(L: ^Lua_State, ud: rawptr) -> Thread_Status {
	g := L.g
	if status := stack_init(L, L); status != .Ok {
		return status
	}
	if status := init_registry(L); status != .Ok {
		return status
	}
	if status := luaS_init(L); status != .Ok { // interns memerrmsg, fills cache
		return status
	}
	if status := luaT_init(L); status != .Ok { // interns metamethod names
		return status
	}
	luaX_init(L) // intern reserved-word strings and mark them reserved
	g.gcstp = 0 // construction done: allow the collector to run
	set_nil(&g.nilvalue) // state is now fully built
	return .Ok
}

// Create a brand-new Lua state and return its main thread, or nil if even the
// initial allocations fail -- reference Lua's `lua_newstate`. The whole universe
// (global state + embedded main thread) is one allocation; we zero it up front so
// that a failure midway through construction leaves `close_state` looking at
// well-defined fields rather than uninitialized memory (a hazard the review
// flagged explicitly).
new_state :: proc(alloc: Allocator) -> ^Lua_State {
	block := raw_alloc(alloc, size_of(Global_State), uint(TTHREAD))
	if block == nil {
		return nil
	}
	g := (^Global_State)(block)
	g^ = {} // zero everything before touching any field
	g.alloc = alloc

	L := &g.main_thread.l
	L.tt = VTHREAD
	preinit_thread(L, g)

	// Establish the GC color scheme before any object is born: the current white
	// is WHITE0, and the main thread is painted that white like any other object.
	g.currentwhite = 1 << WHITE0BIT
	L.marked = luaC_white(g)

	g.allgc = &L.header // the main thread is (so far) the only object
	L.next = nil
	// TODO(phase-5): mark the main thread non-yieldable (reference incnny sets
	// the high half of nCcalls) once the yieldability model exists.

	g.gray = nil
	g.fixedgc = nil
	g.gcrunning = false
	g.gc_kind = KGC_INC
	g.gc_state = 0
	// Stop the collector for the whole of construction: no automatic or emergency
	// collection may run until `f_luaopen` finishes and clears this.
	g.gcstp = GCSTPGC
	g.strt = {}
	set_nil(&g.registry)
	set_int(&g.nilvalue, 0) // non-nil: signals "not yet built"
	g.panic = nil
	g.seed = make_seed(g) // randomized hash seed (see string.odin)

	// Establish the accounting baseline exactly as reference Lua does: the
	// whole global block counts as allocated, with zero debt. Subsequent
	// stack/frame allocations adjust the debt from here.
	g.gc_total_bytes = L_Mem(size_of(Global_State))
	g.gc_debt = 0
	g.gc_marked = 0

	if run_protected(L, f_luaopen, nil) != .Ok {
		// An allocation failed while building the state; free the partial
		// state (including the block itself) and report failure.
		close_state(L)
		return nil
	}
	return L
}

// Tear a state all the way down and free its backing block -- reference Lua's
// `close_state`. Frees run in the reverse order of allocation, each routed
// through the state-aware allocator so the byte accounting unwinds exactly to the
// size of the global block, which we assert before releasing it.
//
// Object collection, upvalue closing, and finalizer runs (the `completestate`
// branch in reference Lua) are Phase-3/Phase-7 work: there are no GC objects yet.
close_state :: proc(L: ^Lua_State) {
	g := L.g

	// If the state got fully built, tear down the object graph first: close the
	// main thread's open upvalues and free every collectable object (all but the
	// embedded main-thread struct, which is part of this block). A half-built
	// state also has whatever objects f_luaopen managed to allocate before failing
	// on its `allgc` list, so we free unconditionally -- luaC_freeallobjects
	// handles both cases and leaves only the main-thread struct behind.
	luaF_closeupval(L, 0) // close any open upvalues on the main thread
	luaC_freeallobjects(L)

	if L.frames != nil {
		state_free(L, L.frames, uint(L.frames_capacity) * size_of(Call_Info))
		L.frames = nil
		L.frames_capacity = 0
	}
	if L.stack != nil {
		state_free(L, L.stack, uint(L.stack_size + EXTRA_STACK) * size_of(StackValue))
		L.stack = nil
		L.stack_size = 0
	}
	if g.strt.hash != nil {
		state_free(L, g.strt.hash, uint(g.strt.size) * size_of(^TString))
		g.strt.hash = nil
	}

	// Everything but the global block itself must now be accounted for.
	assert(gettotalbytes(g) == L_Mem(size_of(Global_State)))

	raw_free(g.alloc, g, size_of(Global_State))
}

// Create a new coroutine thread belonging to the same global state as `L`, anchor
// it on `L`'s stack, and return it -- reference Lua's `luaE_newthread`. Unlike the
// main thread (which is embedded in the global block), a coroutine is a standalone
// `LX` block whose collectable `Lua_State` sits `LUA_EXTRASPACE` bytes in, so that
// `free_thread` can recover the true base to release it. The new thread inherits
// the parent's hook configuration. Allocation failures raise `Err_Mem` through
// `L`'s protected boundary. Returns the new thread, or never returns on OOM.
luaE_newthread :: proc(L: ^Lua_State) -> ^Lua_State {
	g := L.g
	// TODO(phase-7): luaC_checkGC(L) -- a new thread is a good GC step point.

	// Allocate the LX block and register its inner Lua_State as a GC object. We
	// mirror luaC_newobj by hand because the collectable header lives at offset
	// `LUA_EXTRASPACE` within the block, not at offset 0.
	block := state_realloc(L, nil, uint(no_variant(VTHREAD)), size_of(LX))
	if block == nil {
		throw(L, .Err_Mem)
	}
	lx := (^LX)(block)
	L1 := &lx.l
	L1.tt = VTHREAD
	L1.marked = luaC_white(g)
	L1.next = g.allgc
	g.allgc = &L1.header

	// Anchor the fresh thread on the parent stack so it can't be collected before
	// the caller gets a reference to it.
	set_gc(stack_value(L, L.top), &L1.header)
	inc_top(L)

	preinit_thread(L1, g)
	// Inherit the parent's debug-hook configuration.
	L1.hookmask = L.hookmask
	L1.basehookcount = L.basehookcount
	L1.hook = L.hook
	L1.hookcount = L1.basehookcount

	stack_init(L1, L) // allocate L1's stacks, raising through L on failure
	return L1
}
