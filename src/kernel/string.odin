package kernel
// string.odin -- our analogue of reference Lua's `lstring.h` / `lstring.c`.
//
// String management and interning. Lua distinguishes *short* strings (interned
// in a global string table so equality is a pointer compare) from *long* strings
// (kept separately, hashed lazily). This file owns that table, the hashing, and
// string creation -- which is why it's tightly bound to both the GC (strings are
// collectable) and `state` (the table lives in global_State).
//
// Representation deviation, faithful but tidier: reference Lua stores a string's
// character data immediately *after* the `TString` header in the same allocation
// (a "flexible array member" in C). We do exactly the same thing, but since Odin
// has no flexible array members we don't declare a trailing field at all -- we
// compute the address of the inline character bytes from the header's size via
// `str_bytes`. This single-block layout is not a nicety: it's what the Phase-3 GC
// design requires so a string is *never* half-constructed across a second
// allocation that could trigger an emergency collection.

import "base:intrinsics"
import "core:mem"

// ---------------------------------------------------------------------------
// Tunables (reference luaconf.h / lstring.c)
// ---------------------------------------------------------------------------

// Strings no longer than this are "short": interned and pointer-comparable.
// Anything longer is a "long" string, hashed lazily and never interned.
// Reference Lua's `LUAI_MAXSHORTLEN`.
MAXSHORTLEN :: 40

// The intern table starts with this many buckets.
// Reference Lua's `MINSTRTABSIZE`.
MINSTRTABSIZE :: 128

// The tiny address-keyed cache in front of `luaS_new`, sized exactly as
// reference Lua: `STRCACHE_N` rows of `STRCACHE_M` slots each.
STRCACHE_N :: 53
STRCACHE_M :: 2

// The one string that must exist before we can *report* running out of memory.
// Interned and fixed at state startup so raising ERRMEM never itself allocates.
// Reference Lua's `MEMERRMSG`.
MEMERRMSG :: "not enough memory"

// A generous ceiling on how large the intern-table bucket array may grow, so a
// pathological program can't wrap the size arithmetic. Reference Lua caps at
// `MAX_INT`; a power-of-two well below that is plenty and keeps `& (size-1)`
// masking valid.
MAXSTRTB :: 1 << 26

// ---------------------------------------------------------------------------
// The string object
// ---------------------------------------------------------------------------

// A Lua string. The common `next`, `tt`, and `marked` fields are intentionally
// written inline instead of embedding a `GCObject`. Reference C's CommonHeader
// macro does the same thing, allowing `extra` and `hash` to occupy the header's
// would-be padding; nesting the header would make every string 8 bytes larger.
// The character bytes are NOT a field here -- they live in the same heap block
// right after this struct (see the file header) and are reached through
// `str_bytes`.
//
// Fields:
//   * `extra` -- for short strings, a nonzero value marks a reserved word (the
//     lexer stamps these in Phase 4); for long strings, 1 means "hash already
//     computed" (lazy hashing). Reference Lua overloads `extra` the same way.
//   * `hash`  -- the string's hash. For short strings it's always valid; for long
//     strings it starts as the seed and is finalized on first use.
//   * `len`   -- the byte length (reference splits this into `shrlen`/`u.lnglen`;
//     we unify it, which is observably identical and simpler).
//   * `hnext` -- intern-chain link (short strings only): the next string sharing
//     this bucket in the global string table.
TString :: struct {
	next:   ^GCObject,
	tt:     u8,
	marked: u8,
	extra:  u8,
	hash:   u32,
	len:    uint,
	hnext:  ^TString,
}

#assert(offset_of(TString, next) == 0)
#assert(offset_of(TString, tt) == 8)
#assert(offset_of(TString, marked) == 9)
#assert(size_of(TString) == 32)

// The number of bytes a string object of length `len` occupies: the header plus
// the inline characters plus the trailing NUL we always append (so the bytes can
// be handed to C-style APIs). Reference Lua's `sizelstring`.
sizelstring :: #force_inline proc "contextless" (len: uint) -> uint {
	return size_of(TString) + (len + 1)
}

// The exact allocation size of an existing string, used when freeing it.
string_alloc_size :: #force_inline proc "contextless" (ts: ^TString) -> uint {
	return sizelstring(ts.len)
}

// A multipointer to a string's inline character bytes: just past the header.
// Reference Lua's `getstr` / `getshrstr` / `getlngstr` (all the same address).
str_bytes :: #force_inline proc "contextless" (ts: ^TString) -> [^]u8 {
	return ([^]u8)(uintptr(ts) + uintptr(size_of(TString)))
}

// The characters as an Odin slice, for convenient content comparison/printing.
str_slice :: #force_inline proc "contextless" (ts: ^TString) -> []u8 {
	return str_bytes(ts)[:ts.len]
}

// Point a value at a string object. A thin typed wrapper over `set_gc` that
// exists purely so call sites read as "store this string" -- reference `setsvalue`.
set_string :: #force_inline proc "contextless" (o: ^TValue, ts: ^TString) {
	set_gc(o, obj2gco(ts))
}

// View a string-typed value's payload as a `^TString` -- reference `tsvalue`.
// The caller must already know the value is a string (tag not re-checked).
str_value :: #force_inline proc "contextless" (o: ^TValue) -> ^TString {
	return (^TString)(o.value_.gc)
}

// ---------------------------------------------------------------------------
// Hashing and equality
// ---------------------------------------------------------------------------

// Hash a byte range with a seed -- reference Lua's `luaS_hash`. The loop folds
// each byte into a running value with a shift-xor-add mix. Odin's `+` on fixed
// unsigned integers wraps modulo 2^32 (there is no overflow trap), which matches
// C's unsigned overflow semantics exactly, so our hashes agree with reference Lua
// bit-for-bit given the same seed.
string_hash :: proc "contextless" (str: [^]u8, l: uint, seed: u32) -> u32 {
	h := seed ~ u32(l)
	for i := l; i > 0; i -= 1 {
		h ~= (h << 5) + (h >> 2) + u32(str[i - 1])
	}
	return h
}

// Ensure a long string's hash is computed, computing it on first request and
// caching the result (flagged by `extra == 1`). Short strings never call this;
// they're hashed eagerly at creation. Reference Lua's `luaS_hashlongstr`.
string_hashlongstr :: proc "contextless" (ts: ^TString) -> u32 {
	when INTERNAL_ASSERTS {assert_contextless(ts.tt == VLNGSTR)}
	if ts.extra == 0 {
		ts.hash = string_hash(str_bytes(ts), ts.len, ts.hash)
		ts.extra = 1
	}
	return ts.hash
}

// Are two byte ranges equal? A tiny helper so equality reads clearly.
mem_eq :: #force_inline proc "contextless" (a: [^]u8, b: [^]u8, n: uint) -> bool {
	// Use bounded unaligned word loads for short ranges, and the standard block
	// comparison for longer ones. Neither path reads past the supplied bytes.
	if n >= 64 do return mem.compare_ptrs(rawptr(a), rawptr(b), int(n)) == 0
	i: uint = 0
	for n - i >= 8 {
		if intrinsics.unaligned_load((^u64)(&a[i])) != intrinsics.unaligned_load((^u64)(&b[i])) {
			return false
		}
		i += 8
	}
	if n - i >= 4 {
		if intrinsics.unaligned_load((^u32)(&a[i])) != intrinsics.unaligned_load((^u32)(&b[i])) do return false
		i += 4
	}
	if n - i >= 2 {
		if intrinsics.unaligned_load((^u16)(&a[i])) != intrinsics.unaligned_load((^u16)(&b[i])) do return false
		i += 2
	}
	if n - i != 0 && a[i] != b[i] do return false
	return true
}

// Equality of two long strings -- reference Lua's `luaS_eqlngstr`. Short-string
// equality is just pointer identity (thanks to interning) and needs no helper.
string_eqlngstr :: proc "contextless" (a: ^TString, b: ^TString) -> bool {
	when INTERNAL_ASSERTS {assert_contextless(a.tt == VLNGSTR && b.tt == VLNGSTR)}
	return a == b || (a.len == b.len && mem_eq(str_bytes(a), str_bytes(b), a.len))
}

// General string equality -- reference Lua's `luaS_eqstr`. Two strings of the same
// kind are compared appropriately (short by identity, long by content); strings of
// different kinds can never be equal in our world, where every short string is
// interned (so a long string always exceeds the short-string length limit).
string_eqstr :: proc "contextless" (a: ^TString, b: ^TString) -> bool {
	if a.tt != b.tt {
		return false
	}
	if a.tt == VSHRSTR {
		return a == b // interned: identity is equality
	}
	return string_eqlngstr(a, b)
}

// ---------------------------------------------------------------------------
// The intern table
// ---------------------------------------------------------------------------

// `lmod` for power-of-two sizes: fold a hash into `[0, size)` with a mask. The
// intern table's size is always a power of two, so this is reference Lua's `lmod`.
str_mod :: #force_inline proc "contextless" (h: u32, size: int) -> int {
	return int(h & u32(size - 1))
}

// Rehash the bucket array when it grows or shrinks -- reference Lua's
// `tablerehash`. New buckets (indices `osize ..< nsize`) are cleared; every
// existing chain is walked and each string re-placed at its position for the new
// size. Nothing allocates: the chains are threaded through the strings' own
// `hnext` links.
tablerehash :: proc(vect: [^]^TString, osize: int, nsize: int) {
	for i in osize ..< nsize {
		vect[i] = nil // clear the freshly added buckets
	}
	for i in 0 ..< osize {
		p := vect[i]
		vect[i] = nil
		for p != nil {
			hnext := p.hnext // save the rest of the old chain
			h := str_mod(p.hash, nsize)
			p.hnext = vect[h] // splice into the new bucket
			vect[h] = p
			p = hnext
		}
	}
}

// Grow or shrink the intern-table bucket array to `nsize` buckets -- reference
// Lua's `luaS_resize`. A shrink depopulates the doomed tail *before* the realloc
// (so no string is stranded); a grow rehashes *after*. A failed reallocation
// leaves the table exactly as it was.
string_resize :: proc(L: ^State, nsize: int) {
	tb := &L.g.strt
	osize := tb.size
	if nsize < osize {
		tablerehash(tb.hash, osize, nsize) // fold the shrinking tail back in first
	}
	newblock := state_realloc(
		L,
		tb.hash,
		uint(osize) * size_of(^TString),
		uint(nsize) * size_of(^TString),
	)
	if newblock == nil {
		// Reallocation failed: undo the shrink so the table stays consistent.
		if nsize < osize {
			tablerehash(tb.hash, nsize, osize)
		}
		return // leave the table as it was
	}
	tb.hash = ([^]^TString)(newblock)
	tb.size = nsize
	if nsize > osize {
		tablerehash(tb.hash, osize, nsize)
	}
}

// Grow the intern table when it's full -- reference Lua's `growstrtab`. We double
// the bucket count while there's room. (Reference also handles the "MAX_INT
// strings" catastrophe by forcing a full GC; our MAXSTRTB cap makes that
// unreachable in practice, and if we're truly at the cap we simply stop growing
// and let chains lengthen, which is correct if slow.)
growstrtab :: proc(L: ^State) {
	tb := &L.g.strt
	if tb.size <= MAXSTRTB / 2 {
		string_resize(L, tb.size * 2)
	}
}

// ---------------------------------------------------------------------------
// String creation
// ---------------------------------------------------------------------------

// Allocate a bare string object (header + inline byte storage + trailing NUL) of
// the given tag and hash, with `len` characters -- reference Lua's `createstrobj`.
// The caller fills in the actual bytes. Returns nil if the allocation fails, so
// the caller can raise the memory error with proper unwinding context.
createstrobj :: proc(L: ^State, l: uint, tag: Byte, h: u32) -> ^TString {
	o := gc_newobj(L, tag, sizelstring(l))
	if o == nil {
		return nil
	}
	ts := (^TString)(o)
	ts.hash = h
	ts.extra = 0
	ts.len = l
	ts.hnext = nil
	str_bytes(ts)[l] = 0 // the ending NUL
	return ts
}

// Create a fresh long-string object of length `l` (bytes not yet filled) --
// reference Lua's `luaS_createlngstrobj`. Its hash starts as the seed and is
// finalized lazily by `luaS_hashlongstr`.
string_createlngstrobj :: proc(L: ^State, l: uint) -> ^TString {
	return createstrobj(L, l, VLNGSTR, L.g.seed)
}

// Intern a short string: return the single canonical object for these bytes,
// creating it if absent -- reference Lua's `internshrstr`. If a matching string
// exists but is a not-yet-collected corpse (dead white), we resurrect it by
// flipping it to the current white rather than making a duplicate. Returns nil
// only if a needed allocation fails.
internshrstr :: proc(L: ^State, str: [^]u8, l: uint) -> ^TString {
	g := L.g
	tb := &g.strt
	h := string_hash(str, l, g.seed)
	list := &tb.hash[str_mod(h, tb.size)]
	for ts := list^; ts != nil; ts = ts.hnext {
		if l == ts.len && mem_eq(str, str_bytes(ts), l) {
			if is_dead(g, obj2gco(ts)) {
				change_white(obj2gco(ts)) // resurrect a soon-to-be-swept string
			}
			return ts
		}
	}
	// Not present: make it. Grow the table first if it's crowded, then re-find
	// the (possibly relocated) bucket head.
	if tb.nuse >= tb.size {
		growstrtab(L)
		list = &tb.hash[str_mod(h, tb.size)]
	}
	ts := createstrobj(L, l, VSHRSTR, h)
	if ts == nil {
		return nil
	}
	mem.copy(str_bytes(ts), str, int(l))
	ts.hnext = list^
	list^ = ts
	tb.nuse += 1
	return ts
}

// Create a string from an explicit byte range, choosing short vs long by length
// -- reference Lua's `luaS_newlstr`. Short strings are interned; long strings get
// their own object with the bytes copied in.
string_newlstr :: proc(L: ^State, str: [^]u8, l: uint) -> ^TString {
	if l <= MAXSHORTLEN {
		return internshrstr(L, str, l)
	}
	ts := string_createlngstrobj(L, l)
	if ts == nil {
		return nil
	}
	mem.copy(str_bytes(ts), str, int(l))
	return ts
}

// Create a string from an Odin string value. Convenience wrapper over
// `luaS_newlstr` used throughout the kernel where a length is already known.
string_newlstr_str :: proc(L: ^State, s: string) -> ^TString {
	return string_newlstr(L, raw_data(s), len(s))
}

// Create a string, consulting the tiny address-keyed cache first -- reference
// Lua's `luaS_new`. Callers that repeatedly pass the *same* string literal (its
// data pointer is stable) hit the cache and skip hashing entirely. On a miss the
// new string is inserted at the front of its cache row.
//
// Note we deliberately do NOT route the very first string (the memory-error
// message, made in `luaS_init`) through here: the cache isn't populated yet, and
// dereferencing an empty slot would be undefined. `luaS_init` calls `luaS_newlstr`
// directly for that one string, then fills the cache, after which this is safe.
string_new :: proc(L: ^State, s: string) -> ^TString {
	i := point2uint(raw_data(s)) % STRCACHE_N
	row := &L.g.strcache[i]
	for j in 0 ..< STRCACHE_M {
		p := row[j]
		if p != nil && uint(len(s)) == p.len && mem_eq(raw_data(s), str_bytes(p), uint(len(s))) {
			return p // cache hit
		}
	}
	// Miss: shift the row down and install the freshly created string at front.
	for j := STRCACHE_M - 1; j > 0; j -= 1 {
		row[j] = row[j - 1]
	}
	row[0] = string_newlstr_str(L, s)
	return row[0]
}

// Allocate a fresh full userdata with `size` raw data bytes and `nuvalue` user-value
// slots -- reference Lua's `luaS_newudata` (which, like us, lives beside the string
// allocator because both are single-block, header-plus-trailing-bytes objects). The
// data bytes are left uninitialized (the host fills them); the metatable starts nil
// and every user value starts nil so a GC that runs before the host populates them
// never scans garbage. Returns nil on allocation failure (the caller raises).
string_newudata :: proc(L: ^State, size: uint, nuvalue: int) -> ^Udata {
	// Guard the trailing-block arithmetic against wrapping past the address space --
	// reference Lua's `luaM_toobig` check. `size_udata` would otherwise overflow.
	if size > MAX_SIZE - size_udata(nuvalue, 0) {
		debug_runerror(L, "memory allocation error: block too big")
	}
	o := gc_newobj(L, VUSERDATA, size_udata(nuvalue, size))
	if o == nil {
		return nil
	}
	u := (^Udata)(o)
	u.len = size
	u.nuvalue = u16(nuvalue)
	u.metatable = nil
	u.gclist = nil
	for i in 0 ..< nuvalue {
		set_nil(udata_uv(u, i))
	}
	return u
}

// ---------------------------------------------------------------------------
// Table maintenance the GC drives
// ---------------------------------------------------------------------------

// Unlink a short string from its intern-table bucket just before it's freed --
// reference Lua's `luaS_remove`. Long strings are never in the table, so the GC
// only calls this for short ones.
string_remove :: proc(L: ^State, ts: ^TString) {
	tb := &L.g.strt
	p := &tb.hash[str_mod(ts.hash, tb.size)]
	for p^ != ts {
		p = &p^.hnext // walk to the link that points at us
	}
	p^ = p^.hnext // splice ourselves out
	tb.nuse -= 1
}

// Drop any cache entries about to be collected -- reference Lua's
// `luaS_clearcache`, run in the GC's atomic phase before sweeping. A white entry
// would dangle after the sweep, so we replace it with the always-live memerrmsg.
string_clearcache :: proc(g: ^Global_State) {
	for i in 0 ..< STRCACHE_N {
		for j in 0 ..< STRCACHE_M {
			p := g.strcache[i][j]
			if p != nil && is_white(obj2gco(p)) {
				g.strcache[i][j] = g.memerrmsg
			}
		}
	}
}

// Bring the string subsystem online -- reference Lua's `luaS_init`. Allocates the
// bucket array, creates and *fixes* the memory-error message (so it lives
// forever and never needs allocation to report), then primes every cache slot
// with that message so `luaS_new` can safely dereference any slot from now on.
string_init :: proc(L: ^State) -> Thread_Status {
	g := L.g
	tb := &g.strt
	block := state_realloc(L, nil, 0, uint(MINSTRTABSIZE) * size_of(^TString))
	if block == nil {
		return throw(L, .Err_Mem)
	}
	tb.hash = ([^]^TString)(block)
	tablerehash(tb.hash, 0, MINSTRTABSIZE) // clear the new buckets
	tb.size = MINSTRTABSIZE
	tb.nuse = 0

	// Create memerrmsg directly (bypassing the still-empty cache), then fix it.
	g.memerrmsg = string_newlstr_str(L, MEMERRMSG)
	if g.memerrmsg == nil {
		return throw(L, .Err_Mem)
	}
	gc_fix(L, obj2gco(g.memerrmsg))

	for i in 0 ..< STRCACHE_N {
		for j in 0 ..< STRCACHE_M {
			g.strcache[i][j] = g.memerrmsg
		}
	}
	return .Ok
}
