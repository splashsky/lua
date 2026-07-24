package lua

// func.odin -- our analogue of reference Lua's `lfunc.h` / `lfunc.c`.
//
// Functions and their supporting cast: the `Proto` (a compiled function
// prototype -- bytecode, constants, nested protos, debug info), Lua closures and
// C/Odin closures, and *upvalues*, including the delicate open/closed upvalue
// machinery that lets closures share and then capture local variables as scopes
// exit.
//
// Open upvalues point into a thread's value stack while it's live, so -- per our
// index-not-pointer rule -- this interacts carefully with stack growth and the
// GC.
//
// TODO(phase-3): Proto, closures (Lua + native), upvalue open/close, and the
// upvalue list threaded through the stack.

// ---------------------------------------------------------------------------
// Prototypes and their satellite structures
// ---------------------------------------------------------------------------

// A single machine instruction word. Our ABI fixes this at 32 bits (see
// limits.odin) so dumped bytecode is byte-identical to reference Lua's.

// One upvalue *description* inside a prototype -- reference Lua's `Upvaldesc`.
// This is compile-time metadata (produced by the parser) telling the VM, when it
// instantiates a closure from this prototype, where each upvalue comes from:
// either a register in the immediately enclosing function (`instack`) or an
// upvalue of that enclosing function. `name` is kept only for debugging.
Upvaldesc :: struct {
	name:    ^TString, // upvalue name (debug info); may be nil
	instack: u8, // 1 if the upvalue lives in the enclosing function's registers
	idx:     u8, // index into that stack (or into the outer upvalue list)
	kind:    u8, // variable kind (regular / const / to-be-closed / ...)
}

// One local-variable *description* -- reference Lua's `LocVar`. Pure debug info:
// it records a local's name and the bytecode range (`startpc`..`endpc`) over
// which that name is live, so the debug library can report variable names.
LocVar :: struct {
	varname: ^TString, // the local's name
	startpc: int, // first instruction where the variable is active
	endpc:   int, // first instruction where it is dead again
}

// Maps an instruction to an absolute source line -- reference Lua's
// `AbsLineInfo`. Line numbers are normally stored as small per-instruction
// deltas in `lineinfo`; when a delta won't fit in a byte, the absolute line is
// recorded here instead, and binary search over this array speeds line lookups.
AbsLineInfo :: struct {
	pc:   int,
	line: int,
}

// Prototype flag bits -- reference Lua's `PF_*`. `PF_FIXED` marks a prototype
// whose code/line arrays live in read-only fixed memory (e.g. a preloaded
// chunk), so those arrays must *not* be freed. The vararg-related flags are the
// parser's business in Phase 4; we define them all so the meanings are recorded.
PF_VAHID :: 1 // function has hidden vararg arguments
PF_VATAB :: 2 // function has a vararg table
PF_FIXED :: 4 // prototype has parts in fixed (non-freeable) memory

// A compiled function *prototype* -- reference Lua's `Proto`. One prototype is
// the immutable, shareable template a closure is stamped from: its bytecode, its
// constant pool, the nested prototypes for functions defined inside it, the
// upvalue/local debug descriptors, and the line-info tables. Many closures can
// share a single prototype; the per-instance state (captured upvalues) lives on
// the closure, not here.
//
// The reference struct stores each array as a raw pointer plus a matching `size*`
// count. We keep that shape exactly (multipointers `[^]T` + `int` counts) so the
// dumper/undumper in Phase 8 can serialize it field-for-field, byte-compatibly.
Proto :: struct {
	using header:    GCObject, // MUST be first: enables ^GCObject punning
	numparams:       u8, // number of fixed (named) parameters
	flag:            u8, // PF_* bits
	maxstacksize:    u8, // registers this function needs
	sizeupvalues:    int, // length of `upvalues`
	sizek:           int, // length of `k`
	sizecode:        int, // length of `code`
	sizelineinfo:    int, // length of `lineinfo`
	sizep:           int, // length of `p`
	sizelocvars:     int, // length of `locvars`
	sizeabslineinfo: int, // length of `abslineinfo`
	linedefined:     int, // source line where the function begins (debug)
	lastlinedefined: int, // source line where it ends (debug)
	k:               [^]TValue, // constant pool
	code:            [^]Instruction, // the bytecode
	p:               [^]^Proto, // prototypes of nested functions
	upvalues:        [^]Upvaldesc, // upvalue descriptors
	lineinfo:        [^]i8, // per-instruction line deltas (reference `ls_byte`)
	abslineinfo:     [^]AbsLineInfo, // absolute-line checkpoints
	locvars:         [^]LocVar, // local-variable descriptors (debug)
	source:          ^TString, // chunk name / source (debug)
	gclist:          ^GCObject, // GC gray-list thread
}

// The GC punning promise, same as every other collectable object.
#assert(offset_of(Proto, header) == 0)

// ---------------------------------------------------------------------------
// Upvalues
// ---------------------------------------------------------------------------

// The most upvalues a single closure may capture -- reference Lua's `MAXUPVAL`.
// Bounded at 255 because an upvalue index must fit in one VM-instruction operand.
MAXUPVAL :: 255

// An *upvalue*: a variable captured by a closure -- reference Lua's `UpVal`.
//
// An upvalue is "open" while the local it captures is still live on some thread's
// stack: multiple closures then share the *same* upvalue object, and reading or
// writing it goes straight to that stack slot. When the owning scope exits, the
// upvalue is "closed": the current value is copied into the upvalue's own storage
// and future access reads from there. This is what lets a returned closure keep
// mutating a variable that has otherwise left the stack.
//
// Reference Lua points `v.p` either at a stack slot or at its own `u.value`, and
// distinguishes the two by comparing those addresses. Our index-not-pointer rule
// (Decision 4) forbids retaining a stack pointer across reallocation, so we model
// the state explicitly instead: `open` says which case we're in, and an open
// upvalue names its slot by `(thread, stk_index)`, resolved against the live
// backing array only at the moment of access.
UpVal :: struct {
	using header: GCObject, // MUST be first: enables ^GCObject punning
	open:         bool, // true while the captured slot is still on a stack
	thread:       ^Lua_State, // (open only) the thread whose stack holds the slot
	stk_index:    int, // (open only) index of that slot
	value:        TValue, // (closed only) the upvalue's own storage
	// Open upvalues are threaded on their thread's `openupval` list, kept sorted
	// by descending stack index. `open_prev` points at whatever link refers to us
	// (either the previous node's `open_next` or the thread's list head) so we can
	// splice ourselves out in O(1). Reference Lua's `u.open.next` / `previous`.
	open_next:    ^UpVal,
	open_prev:    ^^UpVal,
}

#assert(offset_of(UpVal, header) == 0)

// Resolve an upvalue to the `TValue` it currently stands for -- reference Lua's
// `uplevel`/`upisopen` pair collapsed into one accessor. Open upvalues forward to
// their live stack slot; closed ones read their own storage. Because an open
// upvalue is addressed by index, this is always safe even after a stack
// reallocation moved the backing array.
upval_value :: #force_inline proc "contextless" (uv: ^UpVal) -> ^TValue {
	if uv.open {
		return &uv.thread.stack[uv.stk_index].val
	}
	return &uv.value
}

// ---------------------------------------------------------------------------
// Closures
// ---------------------------------------------------------------------------

// A *C (native) closure* -- reference Lua's `CClosure`. A native function plus a
// vector of captured *values* (not shared upvalue objects -- native closures
// capture by value). Like reference Lua, the upvalue vector is allocated inline,
// right after the struct, so one allocation holds the whole closure. `upvalue`
// points at that trailing region.
CClosure :: struct {
	using header: GCObject, // MUST be first
	nupvalues:    u8, // number of captured values
	gclist:       ^GCObject, // GC gray-list thread
	f:            C_Function, // the native function
	upvalue:      [^]TValue, // inline captured values (single-block, see below)
}

#assert(offset_of(CClosure, header) == 0)

// A *Lua closure* -- reference Lua's `LClosure`. A prototype plus a vector of
// *shared upvalue objects* (Lua closures capture by reference, via `UpVal`).
// Again the upvalue-pointer vector is allocated inline after the struct.
LClosure :: struct {
	using header: GCObject, // MUST be first
	nupvalues:    u8, // number of upvalues (must equal p.sizeupvalues)
	gclist:       ^GCObject, // GC gray-list thread
	p:            ^Proto, // the shared prototype
	upvals:       [^]^UpVal, // inline vector of shared upvalues
}

#assert(offset_of(LClosure, header) == 0)

// Byte size of a C closure carrying `n` captured values -- reference Lua's
// `sizeCclosure`. The struct header plus the inline value vector.
size_cclosure :: #force_inline proc "contextless" (n: int) -> uint {
	return size_of(CClosure) + uint(n) * size_of(TValue)
}

// Byte size of a Lua closure carrying `n` upvalues -- reference `sizeLclosure`.
size_lclosure :: #force_inline proc "contextless" (n: int) -> uint {
	return size_of(LClosure) + uint(n) * size_of(^UpVal)
}

// Point a value at a Lua closure -- reference Lua's `setclLvalue`.
set_lua_closure :: #force_inline proc "contextless" (o: ^TValue, cl: ^LClosure) {
	set_gc(o, &cl.header)
}

// Point a value at a C closure -- reference Lua's `setclCvalue`.
set_c_closure :: #force_inline proc "contextless" (o: ^TValue, cl: ^CClosure) {
	set_gc(o, &cl.header)
}

// ---------------------------------------------------------------------------
// Closure construction
// ---------------------------------------------------------------------------

// Allocate a C closure with room for `nupvals` captured values -- reference Lua's
// `luaF_newCclosure`. Returns nil on allocation failure (the caller raises the
// memory error, since it holds the unwinding context). The captured slots are
// nil-initialized so a GC that runs before the caller fills them never scans
// garbage. `f` is left nil for the caller to set.
luaF_newCclosure :: proc(L: ^Lua_State, nupvals: int) -> ^CClosure {
	o := luaC_newobj(L, VCCL, size_cclosure(nupvals))
	if o == nil {
		return nil
	}
	c := (^CClosure)(o)
	c.nupvalues = u8(nupvals)
	c.gclist = nil
	c.f = nil
	// The inline value vector begins immediately after the struct body.
	c.upvalue = ([^]TValue)(uintptr(c) + size_of(CClosure))
	for i in 0 ..< nupvals {
		set_nil(&c.upvalue[i])
	}
	return c
}

// Allocate a Lua closure with room for `nupvals` upvalue pointers -- reference
// Lua's `luaF_newLclosure`. The prototype and each upvalue pointer start nil; the
// caller wires them up (via `luaF_initupvals` for fresh closed upvalues, or by
// sharing open ones found with `luaF_findupval`). Returns nil on OOM.
luaF_newLclosure :: proc(L: ^Lua_State, nupvals: int) -> ^LClosure {
	o := luaC_newobj(L, VLCL, size_lclosure(nupvals))
	if o == nil {
		return nil
	}
	c := (^LClosure)(o)
	c.p = nil
	c.nupvalues = u8(nupvals)
	c.gclist = nil
	c.upvals = ([^]^UpVal)(uintptr(c) + size_of(LClosure))
	for i in 0 ..< nupvals {
		c.upvals[i] = nil
	}
	return c
}

// Fill a freshly built Lua closure with brand-new *closed* upvalues, each holding
// nil -- reference Lua's `luaF_initupvals`. Used when a closure has no matching
// open upvalue to share (e.g. the main chunk's `_ENV`). Each new upvalue is
// barriered into the closure so the collector's invariant holds. Returns an error
// status if any upvalue allocation fails.
luaF_initupvals :: proc(L: ^Lua_State, cl: ^LClosure) -> Thread_Status {
	for i in 0 ..< int(cl.nupvalues) {
		o := luaC_newobj(L, VUPVAL, size_of(UpVal))
		if o == nil {
			return throw(L, .Err_Mem)
		}
		uv := (^UpVal)(o)
		uv.open = false // born closed...
		uv.thread = nil
		uv.stk_index = 0
		uv.open_next = nil
		uv.open_prev = nil
		set_nil(&uv.value) // ...holding nil
		cl.upvals[i] = uv
		luaC_barrier(L, &cl.header, &uv.header)
	}
	return .Ok
}

// ---------------------------------------------------------------------------
// Open-upvalue management
// ---------------------------------------------------------------------------

// Create a new open upvalue capturing stack slot `level` on thread `L`, and splice
// it into `L`'s open-upvalue list right where `prev` points -- reference Lua's
// (static) `newupval`. The list is kept sorted by descending stack index, which is
// why the caller hands us the exact insertion link. Returns nil on OOM.
newupval :: proc(L: ^Lua_State, level: int, prev: ^^UpVal) -> ^UpVal {
	o := luaC_newobj(L, VUPVAL, size_of(UpVal))
	if o == nil {
		return nil
	}
	uv := (^UpVal)(o)
	next := prev^
	uv.open = true
	uv.thread = L
	uv.stk_index = level // the live value lives in the stack for now
	set_nil(&uv.value)
	uv.open_next = next
	uv.open_prev = prev
	if next != nil {
		next.open_prev = &uv.open_next
	}
	prev^ = uv
	// TODO(phase-7): link L onto the global `twups` list so the incremental GC
	// can find open upvalues of otherwise-unreached threads. With only the main
	// thread (a permanent root) in Phase 3, its stack is always traversed anyway.
	return uv
}

// Find the open upvalue capturing stack slot `level` on `L`, or create one if none
// exists -- reference Lua's `luaF_findupval`. Sharing is the whole point: two
// closures that capture the same local must observe each other's writes, so they
// must point at the *same* `UpVal`. The list is sorted by descending index, so we
// walk until we reach (or pass) the target slot.
luaF_findupval :: proc(L: ^Lua_State, level: int) -> ^UpVal {
	pp := &L.openupval
	for {
		p := pp^
		if p == nil || p.stk_index < level {
			break
		}
		if p.stk_index == level {
			return p // already have one for this slot
		}
		pp = &p.open_next
	}
	return newupval(L, level, pp)
}

// Detach an open upvalue from its thread's open list -- reference Lua's
// `luaF_unlinkupval`. Pure pointer surgery: point our predecessor's link at our
// successor, and (if we have one) our successor back at our predecessor's link.
unlink_upval :: proc(uv: ^UpVal) {
	assert(uv.open, "unlink_upval: upvalue must be open")
	uv.open_prev^ = uv.open_next
	if uv.open_next != nil {
		uv.open_next.open_prev = uv.open_prev
	}
}

// Close every open upvalue at or above stack index `level` on thread `L` --
// reference Lua's `luaF_closeupval`. Closing copies the live stack value into the
// upvalue's own storage and flips it to closed, so the value survives the slot
// leaving the stack. Because open upvalues are sorted with the highest index at
// the head, we can keep closing from the head until we drop below `level`.
luaF_closeupval :: proc(L: ^Lua_State, level: int) {
	for {
		uv := L.openupval
		if uv == nil || uv.stk_index < level {
			break
		}
		unlink_upval(uv) // remove from the open list (updates L.openupval)
		uv.value = L.stack[uv.stk_index].val // move the value into the upvalue
		uv.open = false
		uv.thread = nil
		// Preserve the GC invariant: a closed upvalue can never be gray, and if
		// it was already black we must barrier the value it now owns.
		if !is_white(&uv.header) {
			set2black(&uv.header)
			if is_collectable(&uv.value) {
				luaC_barrier(L, &uv.header, uv.value.value_.gc)
			}
		}
	}
}

// ---------------------------------------------------------------------------
// To-be-closed variables (`<close>`)
// ---------------------------------------------------------------------------
// A `local x <close> = v` variable must have its `__close` metamethod called when
// its scope exits -- normally, via an error, or via a `break`/`goto`/`return` that
// leaves the block. We track these on a per-thread list threaded *through the stack
// slots themselves*: each to-be-closed slot stores, in its `tbclist.delta` overlay,
// the distance back to the previous such slot (with dummy nodes inserted when the
// gap would overflow the 16-bit delta). `L.tbclist` indexes the most recent entry
// (0 -- the base slot -- means "none").

// The special "status" passed to `luaF_close` meaning "there is no error and the
// closing call should be pushed at the current top" -- reference Lua's `CLOSEKTOP`.
CLOSEKTOP :: -1

// The widest gap representable in a single `tbclist.delta` -- reference `MAXDELTA`.
MAXDELTA :: 0xffff

// Invoke the `__close` metamethod of the value at `obj` (with the error object at
// `err`, or none if `err < 0`) -- reference Lua's `callclosemethod`. Assumes
// EXTRA_STACK headroom for the pushed function + arguments.
callclosemethod :: proc(L: ^Lua_State, obj: int, err: int, yy: bool) {
	top := L.top
	func := top
	tm := luaT_gettmbyobj(L, stack_value(L, obj), TM_CLOSE)
	set_obj(stack_value(L, top), tm) // the metamethod to call...
	top += 1
	set_obj(stack_value(L, top), stack_value(L, obj)) // ...with the value as self
	top += 1
	if err >= 0 {
		set_obj(stack_value(L, top), stack_value(L, err)) // and the error object
		top += 1
	}
	L.top = top
	if yy {
		luaD_call(L, func, 0)
	} else {
		luaD_callnoyield(L, func, 0)
	}
}

// Verify the value at `level` actually has a `__close` metamethod, raising a
// descriptive error if not -- reference Lua's `checkclosemth`. (The reference names
// the offending variable via `luaG_findlocal`; that name recovery lands with the
// full debug layer, so for now we report "?".)
checkclosemth :: proc(L: ^Lua_State, level: int) {
	tm := luaT_gettmbyobj(L, stack_value(L, level), TM_CLOSE)
	if is_nil(tm) {
		luaG_runerror(L, "variable '%s' got a non-closable value", "?")
	}
}

// Prepare and perform the closing call for the variable at `level` -- reference
// Lua's `prepcallclosemth`. On a normal close there is no error object; on an error
// close the in-flight error object is materialized just above the variable and
// passed as the metamethod's second argument.
prepcallclosemth :: proc(L: ^Lua_State, level: int, status: int, yy: bool) {
	errobj := -1
	switch status {
	case int(Thread_Status.Ok):
		L.top = level + 1 // the call happens at this level
		errobj = -1
	case CLOSEKTOP:
		errobj = -1
	case:
		errobj = level + 1 // error object goes right after the variable
		set_error_object(L, Thread_Status(status), level + 1)
	}
	callclosemethod(L, level, errobj, yy)
}

// Register the variable at stack index `level` as to-be-closed -- reference Lua's
// `luaF_newtbcupval`. A `false`/`nil` value is skipped (it needs no closing);
// otherwise the value must have a `__close` metamethod. Dummy nodes bridge gaps
// wider than a single delta can express.
luaF_newtbcupval :: proc(L: ^Lua_State, level: int) {
	assert(level > L.tbclist, "luaF_newtbcupval: level must be above the current tbc top")
	if is_false(stack_value(L, level)) {
		return // nil/false variables never need closing
	}
	checkclosemth(L, level) // must be closable
	for uint(level - L.tbclist) > MAXDELTA {
		L.tbclist += MAXDELTA // insert a dummy node at the maximum reach
		L.stack[L.tbclist].tbclist.delta = 0
	}
	L.stack[level].tbclist.delta = u16(level - L.tbclist)
	L.tbclist = level
}

// Drop the head of the tbc list (and any dummy nodes behind it) -- reference Lua's
// `poptbclist`.
poptbclist :: proc(L: ^Lua_State) {
	tbc := L.tbclist
	tbc -= int(L.stack[tbc].tbclist.delta)
	for tbc > 0 && L.stack[tbc].tbclist.delta == 0 {
		tbc -= MAXDELTA // skip over dummy nodes
	}
	L.tbclist = tbc
}

// Close all open upvalues and to-be-closed variables at or above `level` --
// reference Lua's `luaF_close`. `status` is `LUA_OK`/`CLOSEKTOP`/an error code and
// controls whether (and what) error object the closing methods receive. Because our
// slots are index-addressed, `level` survives any stack reallocation a closing call
// triggers, so we simply return it unchanged.
luaF_close :: proc(L: ^Lua_State, level: int, status: int, yy: bool) -> int {
	luaF_closeupval(L, level) // ordinary upvalues first
	for L.tbclist >= level && L.tbclist > 0 {
		tbc := L.tbclist
		poptbclist(L)
		prepcallclosemth(L, tbc, status, yy) // run this variable's __close
	}
	return level
}

// ---------------------------------------------------------------------------
// Prototype construction and teardown
// ---------------------------------------------------------------------------

// Allocate an empty prototype with every array nil and every count zero --
// reference Lua's `luaF_newproto`. The parser (Phase 4) grows the arrays as it
// emits code. Returns nil on OOM.
luaF_newproto :: proc(L: ^Lua_State) -> ^Proto {
	o := luaC_newobj(L, VPROTO, size_of(Proto))
	if o == nil {
		return nil
	}
	f := (^Proto)(o)
	f.numparams = 0
	f.flag = 0
	f.maxstacksize = 0
	f.sizeupvalues = 0
	f.sizek = 0
	f.sizecode = 0
	f.sizelineinfo = 0
	f.sizep = 0
	f.sizelocvars = 0
	f.sizeabslineinfo = 0
	f.linedefined = 0
	f.lastlinedefined = 0
	f.k = nil
	f.code = nil
	f.p = nil
	f.upvalues = nil
	f.lineinfo = nil
	f.abslineinfo = nil
	f.locvars = nil
	f.source = nil
	f.gclist = nil
	return f
}

// Total heap footprint of a prototype and its arrays -- reference Lua's
// `luaF_protosize`. Used by the GC for accounting. Code and line info are skipped
// when the prototype lives in fixed memory (they weren't heap-allocated).
luaF_protosize :: proc(p: ^Proto) -> uint {
	sz :=
		size_of(Proto) +
		uint(p.sizep) * size_of(^Proto) +
		uint(p.sizek) * size_of(TValue) +
		uint(p.sizelocvars) * size_of(LocVar) +
		uint(p.sizeupvalues) * size_of(Upvaldesc)
	if (p.flag & PF_FIXED) == 0 {
		sz += uint(p.sizecode) * size_of(Instruction)
		sz += uint(p.sizelineinfo) * size_of(i8)
		sz += uint(p.sizeabslineinfo) * size_of(AbsLineInfo)
	}
	return sz
}

// Free a prototype and all of its arrays -- reference Lua's `luaF_freeproto`.
// Every array is returned through the state allocator so byte accounting unwinds
// exactly. Fixed-memory code/line arrays are left alone (they weren't ours).
luaF_freeproto :: proc(L: ^Lua_State, f: ^Proto) {
	if (f.flag & PF_FIXED) == 0 {
		state_free(L, f.code, uint(f.sizecode) * size_of(Instruction))
		state_free(L, f.lineinfo, uint(f.sizelineinfo) * size_of(i8))
		state_free(L, f.abslineinfo, uint(f.sizeabslineinfo) * size_of(AbsLineInfo))
	}
	state_free(L, f.p, uint(f.sizep) * size_of(^Proto))
	state_free(L, f.k, uint(f.sizek) * size_of(TValue))
	state_free(L, f.locvars, uint(f.sizelocvars) * size_of(LocVar))
	state_free(L, f.upvalues, uint(f.sizeupvalues) * size_of(Upvaldesc))
	state_free(L, f, size_of(Proto))
}

// Look up the name of the `local_number`-th local variable live at instruction
// `pc` -- reference Lua's `luaF_getlocalname`. Returns nil if there is no such
// active local. Used by the debug library and error messages.
luaF_getlocalname :: proc(f: ^Proto, local_number: int, pc: int) -> ^TString {
	n := local_number
	for i in 0 ..< f.sizelocvars {
		if f.locvars[i].startpc > pc {
			break // locals are ordered; none further can be active yet
		}
		if pc < f.locvars[i].endpc { // variable is active at pc
			n -= 1
			if n == 0 {
				return f.locvars[i].varname
			}
		}
	}
	return nil
}

// ---------------------------------------------------------------------------
// Thread teardown
// ---------------------------------------------------------------------------

// Free a coroutine thread's owned memory -- reference Lua's `freethread` (called
// from the GC's `freeobj`). The *main* thread is never freed here (its struct is
// part of the global block), so this only ever runs for coroutines created in
// Phase 5 onward; we implement it fully now so the GC is correct the moment
// coroutines exist. Any still-open upvalues are closed first: they may be
// reachable and must not be left pointing into a stack we're about to release.
free_thread :: proc(L: ^Lua_State, th: ^Lua_State) {
	luaF_closeupval(th, 0) // close every open upvalue on this thread
	if th.stack != nil {
		state_free(L, th.stack, uint(th.stack_size + EXTRA_STACK) * size_of(StackValue))
		th.stack = nil
	}
	if th.frames != nil {
		state_free(L, th.frames, uint(th.frames_capacity) * size_of(Call_Info))
		th.frames = nil
	}
	// A coroutine's `Lua_State` is embedded in an `LX` block whose extra space
	// sits *ahead* of the thread struct; free from that true base.
	base := rawptr(uintptr(th) - LUA_EXTRASPACE)
	state_free(L, base, size_of(LX))
}
