package lua

// mem.odin -- our analogue of reference Lua's `lmem.h` / `lmem.c`.
//
// The single choke-point for all kernel allocation. Every byte the kernel
// allocates flows through here, which is what lets us reproduce reference Lua's
// honest out-of-memory behavior: an allocation failure triggers an emergency
// garbage collection and a retry, and a *preallocated* memory-error value means
// reporting OOM never itself needs to allocate.
//
// Because our value and frame stacks are growable arrays, this is also where the
// grow/shrink helpers live -- and why the rest of the kernel stores indices, not
// pointers, into anything that can move (see docs/ARCHITECTURE.md, Decision 4).
//
// Phase 1 scope: the fallible allocator abstraction plus the pure size/growth
// arithmetic (all testable without a live `State`). The two pieces that *need* a
// running interpreter -- triggering an emergency GC on failure and raising the
// ERRMEM error -- are deliberately left as TODOs for later phases; see the notes
// on `handle_alloc_failure` below.

import "core:c/libc"

// ---------------------------------------------------------------------------
// The allocator interface
// ---------------------------------------------------------------------------

// `Alloc_Proc` mirrors reference Lua's `lua_Alloc` exactly, right down to the
// four-argument contract, so an embedder's existing allocator can be dropped in
// unchanged:
//
//   ud    -- opaque user pointer handed back on every call
//   ptr   -- block being resized/freed, or nil for a fresh allocation
//   osize -- when ptr != nil: the block's current size in bytes;
//            when ptr == nil: the *type tag* of the object being created
//            (a hint, never a real size -- see `raw_alloc`)
//   nsize -- requested new size in bytes; 0 means "free ptr"
//
// Return value: a pointer to the (re)allocated block, or nil. A nil return with
// nsize != 0 signals failure, and in that case the original `ptr` must remain
// valid and untouched -- exactly the guarantee C's realloc makes.
Alloc_Proc :: #type proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr

// A bundled allocator: the function plus its user pointer. The kernel threads one
// of these around rather than reaching for a global, so multiple independent Lua
// states can each carry their own allocation strategy.
Allocator :: struct {
	alloc: Alloc_Proc,
	ud:    rawptr,
}

// The default allocator, used when an embedder doesn't supply one. It is the
// faithful twin of reference Lua's `l_alloc` (lauxlib.c): a thin shim over the C
// heap. `realloc(nil, n)` behaves as `malloc(n)`, and `nsize == 0` frees. The
// `ud` and `osize` arguments are unused here -- the C heap tracks block sizes
// itself -- but we keep them so the signature matches every other allocator.
default_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	if nsize == 0 {
		libc.free(ptr)
		return nil
	}
	return libc.realloc(ptr, nsize)
}

// A ready-made `Allocator` wrapping `default_alloc`.
default_allocator :: proc "contextless" () -> Allocator {
	return Allocator{alloc = default_alloc, ud = nil}
}

// ---------------------------------------------------------------------------
// Fallible raw allocation
// ---------------------------------------------------------------------------

// Every kernel allocation ultimately lands in one of these three helpers. They
// return a raw pointer (nil on failure) rather than raising an error, because in
// Phase 1 there is no `State` to raise *through* yet. Once the interpreter and GC
// exist, the fail path routes through `handle_alloc_failure` below.

// Allocate `size` bytes for a new object of the given type `tag`. Following the
// review guidance, a zero-byte request short-circuits to nil without bothering
// the allocator (observably identical to what the C heap would hand back). The
// `tag` rides in the `osize` slot precisely because `ptr` is nil -- that's the
// one case where `osize` means "type of thing" instead of "old size".
raw_alloc :: proc(a: Allocator, size: uint, tag: uint) -> rawptr {
	if size == 0 {
		return nil
	}
	return a.alloc(a.ud, nil, tag, size)
}

// Resize an existing block from `osize` to `nsize` bytes. On failure the original
// block is left valid (the allocator contract), so callers can safely keep using
// `ptr`. A request to grow to zero frees the block and yields nil.
raw_realloc :: proc(a: Allocator, ptr: rawptr, osize: uint, nsize: uint) -> rawptr {
	if nsize == 0 {
		if ptr != nil {
			a.alloc(a.ud, ptr, osize, 0)
		}
		return nil
	}
	return a.alloc(a.ud, ptr, osize, nsize)
}

// Free a block of `osize` bytes. Freeing nil is a no-op, matching C.
raw_free :: proc(a: Allocator, ptr: rawptr, osize: uint) {
	if ptr != nil {
		a.alloc(a.ud, ptr, osize, 0)
	}
}

// ---------------------------------------------------------------------------
// Size and growth arithmetic
// ---------------------------------------------------------------------------

// Reference Lua guards every array allocation against size overflow before it
// ever reaches the allocator (`luaM_*` with the `MAX_SIZE` checks). We do the
// same, but as pure functions that report success with a bool instead of
// throwing, so they can be exercised directly in tests.

// Compute `count * elem_size` (the byte size of an array) while detecting
// overflow. Returns (bytes, true) when the product is representable, or (0,
// false) if it would overflow the platform size type. Faithful to reference
// Lua's `luaM_testsize` (lmem.h): it flags overflow when `count + 1 >
// MAX_SIZET / elem_size`, i.e. the product (plus one for a possible sentinel
// slot) would exceed what the size type can hold. Note this uses MAX_SIZET, not
// MAX_SIZE -- it's guarding the machine multiplication, not the object-size rule.
array_bytes :: proc "contextless" (count: uint, elem_size: uint) -> (bytes: uint, ok: bool) {
	if elem_size != 0 && count + 1 > MAX_SIZET / elem_size {
		return 0, false
	}
	return count * elem_size, true
}

// The smallest capacity a growable array jumps to on its first growth, matching
// reference Lua's `MINSIZEARRAY`. Growing straight to 4 avoids a flurry of tiny
// reallocations for arrays that are about to hold a handful of elements.
MIN_ARRAY_SIZE :: 4

// Decide the next capacity for a growable array that currently holds `size`
// elements and needs room for at least `needed` more, never exceeding `limit`.
// This is the arithmetic half of reference Lua's `luaM_growaux_`:
//
//   * the usual case doubles the capacity;
//   * a doubling that overshoots `limit` is clamped to `limit`;
//   * a first growth from a tiny array is floored at MIN_ARRAY_SIZE;
//   * if even `limit` can't satisfy `needed`, we report failure (ok == false)
//     rather than throwing -- the caller (once a `State` exists) turns that into
//     the appropriate "too big" error.
grow_size :: proc "contextless" (size: uint, needed: uint, limit: uint) -> (new_size: uint, ok: bool) {
	// If the array already has the headroom, it doesn't need to grow at all.
	if needed <= size {
		return size, true
	}
	// Can the hard limit even hold what we need? If not, there's no point sizing.
	if needed > limit {
		return 0, false
	}
	// Prefer doubling, but clamp to the limit and honor the minimum first-jump.
	new_size = size * 2
	if new_size < MIN_ARRAY_SIZE {
		new_size = MIN_ARRAY_SIZE
	}
	if new_size > limit {
		new_size = limit
	}
	// Doubling might still fall short of `needed` (e.g. a big single request);
	// in that case grow exactly to what's needed, which we've already checked
	// fits under `limit`.
	if new_size < needed {
		new_size = needed
	}
	return new_size, true
}

// ---------------------------------------------------------------------------
// State-aware allocation (byte accounting)
// ---------------------------------------------------------------------------

// Once a `Global_State` exists, kernel allocations flow through these wrappers
// instead of the bare `raw_*` helpers, because reference Lua tracks every byte it
// hands out so the collector can pace itself. These mirror `luaM_realloc_` and
// `luaM_free_` (lmem.c): the collector's debt is nudged by the exact
// `nsize - osize` delta on every successful (re)allocation and credited back on
// every free. `gettotalbytes` then reports the real live-byte count.
//
// The one piece still deferred is the emergency-collect-then-retry dance on
// failure: that needs a running collector, which is Phase 7. Until then a failed
// allocation simply returns nil (and, per reference Lua, leaves the debt
// untouched so accounting stays exact).

// Reference Lua's `gettotalbytes`: bytes actually live right now. `GCtotalbytes`
// carries "allocated + debt", so subtracting the debt yields the true figure.
gettotalbytes :: #force_inline proc "contextless" (g: ^Global_State) -> L_Mem {
	return g.gc_total_bytes - g.gc_debt
}

// Resize (or allocate, or free) a block on behalf of state `L`, keeping the GC
// byte accounting exact -- reference Lua's `luaM_realloc_`. Passing `block == nil`
// with `osize == 0` allocates; passing `nsize == 0` frees. On a genuine failure
// (nil out with a nonzero request) we return nil *without* touching the debt, so
// the caller can retry or raise while the numbers stay consistent.
state_realloc :: proc(L: ^Lua_State, block: rawptr, osize: uint, nsize: uint) -> rawptr {
	g := L.g
	newblock := raw_realloc(g.alloc, block, osize, nsize)
	if newblock == nil && nsize > 0 {
		// TODO(phase-7): run an emergency GC and retry before giving up.
		return nil // do not update the debt on failure
	}
	g.gc_debt -= L_Mem(nsize) - L_Mem(osize)
	return newblock
}

// Free a block of `osize` bytes on behalf of state `L`, crediting the debt --
// reference Lua's `luaM_free_`.
state_free :: proc(L: ^Lua_State, block: rawptr, osize: uint) {
	if block == nil {
		return
	}
	g := L.g
	raw_free(g.alloc, block, osize)
	g.gc_debt += L_Mem(osize)
}
