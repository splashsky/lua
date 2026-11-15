package kernel
// mem.odin -- our analogue of reference Lua's `lmem.h` / `lmem.c`.
//
// The single choke-point for all kernel allocation. Every byte the kernel
// allocates flows through here, which is what lets us reproduce reference Lua's
// honest out-of-memory behavior: an allocation failure triggers an emergency
// garbage collection and a retry, and a *preallocated* memory-error value means
// reporting OOM never itself needs to allocate.
//
// Because our value and frame stacks are growable arrays, this is also where the
// grow/shrink helpers live -- and why persistent state stores indices, not
// pointers, into anything that can move (see docs/ARCHITECTURE.md, Decision 3).

import "core:mem"

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

// ---------------------------------------------------------------------------
// Fallible raw allocation
// ---------------------------------------------------------------------------

// Every kernel allocation ultimately lands in one of these three helpers. They
// return a raw pointer (nil on failure) rather than raising an error. State-aware
// callers can retry with an emergency collection as described below.

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
// A failed allocation can trigger an emergency collection and retry. A final
// failure leaves the debt untouched so accounting stays exact.

// Reference Lua's `gettotalbytes`: bytes actually live right now. `GCtotalbytes`
// carries "allocated + debt", so subtracting the debt yields the true figure.
gettotalbytes :: #force_inline proc "contextless" (g: ^Global_State) -> L_Mem {
	return g.gc_total_bytes - g.gc_debt
}

// Set the collector's debt to `debt`, keeping `GCtotalbytes = live + debt` --
// reference Lua's `luaE_setdebt`. The debt is clamped so total bytes never
// overflows `MAX_LMEM`. A negative-or-zero debt means "a collection is due".
state_setdebt :: proc "contextless" (g: ^Global_State, debt: L_Mem) {
	tb := gettotalbytes(g)
	d := debt
	if d > MAX_LMEM - tb {
		d = MAX_LMEM - tb // saturate: total bytes hits MAX_LMEM
	}
	g.gc_total_bytes = tb + d
	g.gc_debt = d
}

// Resize (or allocate, or free) a block on behalf of state `L`, keeping the GC
// byte accounting exact -- reference Lua's `luaM_realloc_`. Passing `block == nil`
// with `osize == 0` allocates; passing `nsize == 0` frees. On a first failure we
// try an emergency collection (if one is safe right now) to reclaim memory, then
// retry once. If it still fails we return nil *without* touching the debt, so the
// caller can raise while the numbers stay consistent.
state_realloc :: proc(L: ^State, block: rawptr, osize: uint, nsize: uint) -> rawptr {
	g := L.g
	newblock := raw_realloc(g.alloc, block, osize, nsize)
	if newblock == nil && nsize > 0 {
		// Emergency collection is only safe once the state is fully built and the
		// collector isn't temporarily forbidding it (during a finalizer, or while
		// already inside an emergency step). Reference Lua's `cantryagain`:
		// `completestate(g) && !g->gcstopem`.
		if completestate(g) && g.gcstopem == 0 {
			gc_fullgc(L, true) // emergency: reclaim unreachable objects
			newblock = raw_realloc(g.alloc, block, osize, nsize)
		}
		if newblock == nil {
			return nil // still no luck: do not update the debt on failure
		}
	}
	// Accounting subtlety mirrored from reference Lua's split between
	// `luaM_malloc_` and `luaM_realloc_`: for a *fresh* allocation (`block == nil`)
	// the `osize` argument does NOT carry a byte count -- it carries the object's
	// type tag (see `raw_alloc`/`luaC_newobj`, which ride the tag through to the
	// allocator callback in that slot). The real previous size is therefore zero,
	// and the debt must grow by the whole `nsize`. Only genuine reallocations of an
	// existing block treat `osize` as the old byte count.
	old_bytes := block == nil ? uint(0) : osize
	g.gc_debt -= L_Mem(nsize) - L_Mem(old_bytes)
	return newblock
}

// Free a block of `osize` bytes on behalf of state `L`, crediting the debt --
// reference Lua's `luaM_free_`.
state_free :: proc(L: ^State, block: rawptr, osize: uint) {
	if block == nil {
		return
	}
	g := L.g
	raw_free(g.alloc, block, osize)
	g.gc_debt += L_Mem(osize)
}

// ---------------------------------------------------------------------------
// Growable typed vectors (Proto arrays, parser dynamic arrays)
// ---------------------------------------------------------------------------
//
// The parser and code generator build a `Proto`'s parallel arrays (code, line
// info, constants, nested protos, locals, upvalues) plus their own scratch
// arrays (active variables, gotos, labels) by appending one element at a time
// and growing on demand. Reference Lua expresses this with the `luaM_growvector`
// macro over `luaM_growaux_`; these two generic helpers are our equivalent.
//
// Both take the *address* of the `[^]T` backing pointer and the `int` count/size
// field so they can update them in place -- exactly the `(&array, &size)` pair
// reference Lua threads through. Element size is `size_of(T)`, so callers never
// pass a byte size.

// Ensure the array behind `arr` has room for at least one element beyond the
// `nelems` already in use, growing (usually doubling) up to `limit`. On success
// `arr^` and `size^` are updated; if even `limit` cannot hold one more element we
// raise the same "too many X" error reference Lua's `luaM_growaux_` raises, and
// an out-of-memory realloc raises `.Err_Mem` like `luaM_saferealloc_`.
grow_vector :: proc(L: ^State, arr: ^[^]$T, nelems: int, size: ^int, limit: int, what: string) {
	if nelems + 1 <= size^ { 	// does one extra element still fit?
		return // nothing to be done
	}
	newsize, ok := grow_size(uint(size^), uint(nelems + 1), uint(limit))
	if !ok {
		// The hard limit itself cannot hold what we need: a compile-time "too
		// many locals/constants/opcodes/..." error. During parsing there is no
		// running Lua frame, so this is exactly reference `luaG_runerror`'s
		// no-source path: push the message and throw a runtime error.
		object_pushfstring(L, "too many %s (limit is %d)", what, limit)
		throw(L, .Err_Run)
	}
	oldbytes := uint(size^) * size_of(T)
	newbytes := uint(newsize) * size_of(T)
	newblock := state_realloc(L, arr^, oldbytes, newbytes)
	if newblock == nil && newbytes > 0 { 	// realloc failed outright?
		throw(L, .Err_Mem)
	}
	arr^ = cast([^]T)newblock
	size^ = int(newsize) // update only once everything else is OK
}

// Shrink the array behind `arr` to exactly `final_n` elements, releasing the
// slack -- reference Lua's `luaM_shrinkvector_`. Prototypes reuse the size field
// as the element count, so `close_func` trims each array to what it actually
// used. A failed shrink (should never happen when shrinking) raises `.Err_Mem`.
shrink_vector :: proc(L: ^State, arr: ^[^]$T, size: ^int, final_n: int) {
	oldbytes := uint(size^) * size_of(T)
	newbytes := uint(final_n) * size_of(T)
	newblock := state_realloc(L, arr^, oldbytes, newbytes)
	if newblock == nil && newbytes > 0 {
		throw(L, .Err_Mem)
	}
	arr^ = cast([^]T)newblock
	size^ = final_n
}
