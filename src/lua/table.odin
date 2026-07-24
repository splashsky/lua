package lua

// table.odin -- our analogue of reference Lua's `ltable.h` / `ltable.c`.
//
// The Lua table: the language's one and only data structure, and a subtle one.
// It's a hybrid of a contiguous *array part* (for integer keys 1..n) and a
// *hash part* (for everything else), with a rehash algorithm that decides how to
// split keys between the two to keep both dense. Getting the array/hash boundary
// and the `#` length semantics right is essential for behavioral correctness.
//
// Representation deviation (faithful behavior, simpler memory): reference Lua
// 5.5 packs the array part as an "inverted" values array plus a parallel tag
// array with a length hint squeezed in between, and stores a `lastfree` cursor in
// a hidden slot before the node block. Those are pure space/speed optimizations.
// Since our overriding goal is *observable* correctness, we use the obvious layout
// instead: the array part is a plain `[^]TValue` (an absent slot carries the
// VEMPTY tag), the length hint is an ordinary field, and the free-slot search is a
// simple linear scan. Every algorithm below -- hashing, collision handling, the
// rehash sizing, `next` ordering, and the `#` border search -- is ported faithfully
// so the *behavior* matches reference Lua exactly; only the bytes differ.

import "core:math"

// ---------------------------------------------------------------------------
// Node and Table
// ---------------------------------------------------------------------------

// One hash-part slot -- reference Lua's `Node`. It stores a value plus a *split*
// key (the key's payload and tag as separate fields, so the value's own tag byte
// stays adjacent to its payload). `next` is a *relative* offset, in Node units, to
// the next slot in this bucket's collision chain (0 means "end of chain") --
// reference Lua's `gnext`. Relative offsets survive the whole node block being
// reallocated, which is why reference uses them and we do too.
Node :: struct {
	val:     TValue, // MUST be first: a `^TValue` at a node aliases its value
	key_tt:  Byte, // the key's tag (reference's `key_tt_`)
	key_val: Value, // the key's payload (reference's `key_val`)
	next:    int, // relative chain offset to the next colliding node
}

// The `val` field sits at offset 0 so a `^TValue` pointing at a node's value can
// be cast back to `^Node` (reference's `nodefromval`). `luaH_next` relies on this.
#assert(offset_of(Node, val) == 0)

// A Lua table. The header comes first (GC punning). See the file banner for how
// the array/hash parts are represented.
//
//   * `flags`     -- the fast-metamethod-absence cache (low bits) plus BITDUMMY
//     (bit 6), which records that the hash part is the shared empty `dummy_node`.
//   * `lsizenode` -- log2 of the number of hash slots (so `sizenode == 1<<lsizenode`).
//   * `asize`     -- number of slots in the array part.
//   * `array`     -- the array part; key `i` (1-based) lives at `array[i-1]`.
//   * `node`      -- the hash part (or the shared dummy when empty).
//   * `len_hint`  -- a remembered border to speed up repeated `#t` (reference keeps
//     this in the array block; we make it a field).
//   * `metatable` -- this table's metatable, or nil.
//   * `gclist`    -- threads the table onto the GC's gray worklist while marking.
Table :: struct {
	using header: GCObject,
	flags:        u8,
	lsizenode:    u8,
	asize:        u32,
	array:        [^]TValue,
	node:         [^]Node,
	len_hint:     u32,
	metatable:    ^Table,
	gclist:       ^GCObject,
}

#assert(offset_of(Table, header) == 0)

// Bit 6 of `flags`: the hash part is the shared dummy node. Reference `BITDUMMY`.
BITDUMMY :: 1 << 6

is_dummy :: #force_inline proc "contextless" (t: ^Table) -> bool {
	return (t.flags & BITDUMMY) != 0
}

// Point a value at a table -- reference Lua's `sethvalue`. The value's tag is the
// table tag plus the collectable bit; the header sits at offset 0, so `&t.header`
// is the object the value references.
set_table :: #force_inline proc "contextless" (o: ^TValue, t: ^Table) {
	set_gc(o, &t.header)
}

// `sizenode == 2^lsizenode`, reference's `sizenode`/`twoto`. Even the dummy has
// one slot (lsizenode 0 -> 1), so indexing the hash part never needs a guard.
twoto :: #force_inline proc "contextless" (x: u8) -> int {
	return 1 << uint(x)
}

sizenode :: #force_inline proc "contextless" (t: ^Table) -> int {
	return twoto(t.lsizenode)
}

// Clear the metamethod-absence cache bits, forcing the next metamethod lookup to
// re-probe. Reference Lua's `invalidateTMcache`. Called whenever a string key is
// newly inserted, since that key might be a metamethod name.
invalidateTMcache :: #force_inline proc "contextless" (t: ^Table) {
	t.flags &= ~maskflags
}

// ---------------------------------------------------------------------------
// The shared empty hash part and the "absent" sentinel
// ---------------------------------------------------------------------------

// Every table with no hash entries shares this single read-only node, so indexing
// code never has to special-case "no hash part". Its value is empty and its key is
// a DEADKEY sentinel that equals no real key -- crucially NOT a nil key, so the
// free-slot search never mistakes it for a usable slot. Reference `dummynode_`.
@(private = "file")
dummy_node := Node {
	val    = TValue{tt_ = VEMPTY},
	key_tt = TDEADKEY,
}

@(private = "file")
dummy_ptr :: #force_inline proc "contextless" () -> [^]Node {
	return ([^]Node)(&dummy_node)
}

// The value returned by a lookup that found no entry -- reference Lua's
// `absentkey` / `isabstkey`. Distinct from nil so callers can tell "no such key"
// from "key mapped to nil" (which, in a table, cannot happen anyway).
@(private = "file")
absentkey := TValue{tt_ = VABSTKEY}

is_absent :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VABSTKEY
}

// ---------------------------------------------------------------------------
// Size limits (reference ltable.c)
// ---------------------------------------------------------------------------

// Largest power of two that fits an array index in an unsigned int, and the
// matching hash-size ceiling. Reference `MAXABITS` / `MAXHBITS` / `MAXASIZE`.
MAXABITS :: 31
MAXHBITS :: 30
MAXASIZE :: u32(1) << MAXABITS

// ---------------------------------------------------------------------------
// Node key helpers
// ---------------------------------------------------------------------------

// The composite tag a collectable key of the given variant carries, i.e. with the
// collectable bit set. Short- and long-string keys are the ones we compare against
// by tag, so we spell those out. Reference uses `ctb(LUA_VSHRSTR)` etc.
KTT_SHRSTR :: Byte(VSHRSTR | BIT_ISCOLLECTABLE)
KTT_LNGSTR :: Byte(VLNGSTR | BIT_ISCOLLECTABLE)

set_node_key :: #force_inline proc "contextless" (n: ^Node, key: ^TValue) {
	n.key_val = key.value_
	n.key_tt = key.tt_
}

get_node_key :: #force_inline proc "contextless" (out: ^TValue, n: ^Node) {
	out.value_ = n.key_val
	out.tt_ = n.key_tt
}

set_nil_key :: #force_inline proc "contextless" (n: ^Node) {
	n.key_tt = VNIL
}

// The index of node `n` within table `t`'s node block, so relative `next` offsets
// can be turned into absolute indices. Reference does this with pointer subtraction.
@(private = "file")
node_index :: #force_inline proc "contextless" (t: ^Table, n: ^Node) -> int {
	return int((uintptr(n) - uintptr(t.node)) / size_of(Node))
}

// ---------------------------------------------------------------------------
// Hashing
// ---------------------------------------------------------------------------
//
// These return the *index* of a key's main position. `hashpow2` masks (good for
// already-well-mixed hashes like string hashes); `hashmod` uses a remainder
// against an odd modulus (better for values with many factors of two, like
// pointers). Reference Lua's `hashpow2` / `hashmod` / `hashint` / `l_hashfloat`.

@(private = "file")
hashpow2_i :: #force_inline proc "contextless" (t: ^Table, n: u32) -> int {
	return int(n & u32(sizenode(t) - 1))
}

@(private = "file")
hashmod_i :: #force_inline proc "contextless" (t: ^Table, n: u32) -> int {
	return int(u64(n) % (u64(sizenode(t) - 1) | 1))
}

@(private = "file")
hashint_i :: #force_inline proc "contextless" (t: ^Table, i: Integer) -> int {
	// A non-negative int-sized key hashes via a plain remainder; larger keys use
	// the full unsigned value. Both reduce to the same modulo expression here.
	ui := s2u(i)
	return int(ui % (u64(sizenode(t) - 1) | 1))
}

@(private = "file")
hashstr_i :: #force_inline proc "contextless" (t: ^Table, ts: ^TString) -> int {
	return hashpow2_i(t, ts.hash)
}

// Hash a float. Faithful port of reference's `l_hashfloat`, numerical subtleties
// and all: split off the exponent with `frexp`, scale the mantissa by 2^31, add
// the exponent, and fold. inf/-inf/NaN all hash to 0.
@(private = "file")
l_hashfloat :: proc "contextless" (n: Number) -> u32 {
	m, i := math.frexp(n)
	scaled := m * -Number(min(i32)) // -(Number)INT_MIN == 2^31
	ni, ok := number_to_integer_range(scaled)
	if !ok {
		return 0 // inf/-inf/NaN
	}
	u := u32(i32(i)) + u32(u64(ni))
	return u <= u32(max(i32)) ? u : ~u
}

// The main position (bucket index) for any key -- reference Lua's `mainpositionTV`.
@(private = "file")
mainposition_i :: proc "contextless" (t: ^Table, key: ^TValue) -> int {
	switch type_tag(key) {
	case VNUMINT:
		return hashint_i(t, int_value(key))
	case VNUMFLT:
		return hashmod_i(t, l_hashfloat(flt_value(key)))
	case VSHRSTR:
		return hashstr_i(t, str_value(key))
	case VLNGSTR:
		return hashpow2_i(t, luaS_hashlongstr(str_value(key)))
	case VFALSE:
		return hashpow2_i(t, 0)
	case VTRUE:
		return hashpow2_i(t, 1)
	case VLIGHTUSERDATA:
		return hashmod_i(t, point2uint(key.value_.p))
	case VLCF:
		return hashmod_i(t, point2uint(rawptr(key.value_.f)))
	case:
		return hashmod_i(t, point2uint(key.value_.gc))
	}
}

@(private = "file")
mainposition_from_node :: proc "contextless" (t: ^Table, i: int) -> int {
	k: TValue
	get_node_key(&k, &t.node[i])
	return mainposition_i(t, &k)
}

// ---------------------------------------------------------------------------
// Key equality
// ---------------------------------------------------------------------------

// Raw equality between a probe key and a node's key -- reference Lua's `equalkey`.
// No metamethods. Floats with integral values were normalized to integers before
// storage, so an integer and a float never compare equal here. `deadok` allows a
// still-collectable object to match a dead key (used only by `next`).
@(private = "file")
equalkey :: proc "contextless" (k1: ^TValue, n: ^Node, deadok: bool) -> bool {
	if k1.tt_ != n.key_tt {
		// Different variants can only match in two special cases.
		if n.key_tt == KTT_SHRSTR && k1.tt_ == KTT_LNGSTR {
			return luaS_eqstr(str_value(k1), (^TString)(n.key_val.gc))
		} else if deadok && n.key_tt == TDEADKEY && is_collectable(k1) {
			return k1.value_.gc == n.key_val.gc
		}
		return false
	}
	switch n.key_tt {
	case VNIL, VFALSE, VTRUE:
		return true
	case VNUMINT:
		return k1.value_.i == n.key_val.i
	case VNUMFLT:
		return k1.value_.n == n.key_val.n
	case VLIGHTUSERDATA:
		return k1.value_.p == n.key_val.p
	case VLCF:
		return k1.value_.f == n.key_val.f
	case KTT_LNGSTR:
		return luaS_eqstr(str_value(k1), (^TString)(n.key_val.gc))
	case:
		// Everything else (short strings, tables, ...) is identity on the object.
		return k1.value_.gc == n.key_val.gc
	}
}

// ---------------------------------------------------------------------------
// Array-index classification
// ---------------------------------------------------------------------------

// Return `k` (as an unsigned 1-based index) if `1 <= k <= limit`, else 0.
// Reference Lua's `checkrange`.
@(private = "file")
checkrange :: #force_inline proc "contextless" (k: Integer, limit: u32) -> u32 {
	if (s2u(k) - 1) < u64(limit) {
		return u32(k)
	}
	return 0
}

// Is `k` a legal array index at all / an index into *this* table's array part?
// Reference `arrayindex` / `ikeyinarray`.
@(private = "file")
arrayindex :: #force_inline proc "contextless" (k: Integer) -> u32 {
	return checkrange(k, MAXASIZE)
}

@(private = "file")
ikeyinarray :: #force_inline proc "contextless" (t: ^Table, k: Integer) -> u32 {
	return checkrange(k, t.asize)
}

@(private = "file")
keyinarray :: #force_inline proc "contextless" (t: ^Table, key: ^TValue) -> u32 {
	return is_integer(key) ? ikeyinarray(t, int_value(key)) : 0
}

@(private = "file")
arraykeyisempty :: #force_inline proc "contextless" (t: ^Table, key: u32) -> bool {
	return is_empty(&t.array[key - 1])
}

// ---------------------------------------------------------------------------
// Lookups
// ---------------------------------------------------------------------------

// "Generic" chained search: walk the collision chain from the key's main position
// until we find it or run off the end. Reference Lua's `getgeneric`. Not used for
// integer or integral-float keys, which the array/int paths handle.
@(private = "file")
getgeneric :: proc "contextless" (t: ^Table, key: ^TValue, deadok: bool) -> ^TValue {
	i := mainposition_i(t, key)
	for {
		n := &t.node[i]
		if equalkey(key, n, deadok) {
			return &n.val
		}
		nx := n.next
		if nx == 0 {
			return &absentkey
		}
		i += nx
	}
}

// Chained search restricted to integer keys living in the hash part -- reference
// Lua's `getintfromhash`.
@(private = "file")
getintfromhash :: proc "contextless" (t: ^Table, key: Integer) -> ^TValue {
	i := hashint_i(t, key)
	for {
		n := &t.node[i]
		if n.key_tt == VNUMINT && n.key_val.i == key {
			return &n.val
		}
		nx := n.next
		if nx == 0 {
			return &absentkey
		}
		i += nx
	}
}

// The value slot for an integer key: array part if in range, else the hash part.
// Package-visible: the VM's GETI/index fast paths and the vararg helpers read the
// raw slot directly (testing `is_empty`) to skip the copying `luaH_get`.
luaH_getint_slot :: proc "contextless" (t: ^Table, key: Integer) -> ^TValue {
	k := ikeyinarray(t, key)
	if k > 0 {
		return &t.array[k - 1]
	}
	return getintfromhash(t, key)
}

// Short-string search -- reference Lua's `luaH_Hgetshortstr`. Short strings are
// interned, so a match is a pointer comparison. This is the one lookup the
// metamethod machinery (tm.odin) calls directly.
luaH_Hgetshortstr :: proc "contextless" (t: ^Table, key: ^TString) -> ^TValue {
	i := hashstr_i(t, key)
	for {
		n := &t.node[i]
		if n.key_tt == KTT_SHRSTR && (^TString)(n.key_val.gc) == key {
			return &n.val
		}
		nx := n.next
		if nx == 0 {
			return &absentkey
		}
		i += nx
	}
}

// The value slot for any string key (short via the fast path, long via generic).
@(private = "file")
Hgetstr :: proc "contextless" (t: ^Table, key: ^TString) -> ^TValue {
	if key.tt == VSHRSTR {
		return luaH_Hgetshortstr(t, key)
	}
	ko: TValue
	set_string(&ko, key)
	return getgeneric(t, &ko, false)
}

// The value slot for an arbitrary key -- reference Lua's `luaH_get` dispatcher.
// Package-visible: the VM's GETTABLE/finishget paths test the returned slot with
// `is_empty` to decide between a hit and the metamethod fallback.
luaH_getslot :: proc "contextless" (t: ^Table, key: ^TValue) -> ^TValue {
	switch type_tag(key) {
	case VNUMINT:
		return luaH_getint_slot(t, int_value(key))
	case VSHRSTR:
		return luaH_Hgetshortstr(t, str_value(key))
	case VNIL:
		return &absentkey
	case VNUMFLT:
		k, ok := float_to_integer(flt_value(key), .Eq)
		if ok {
			return luaH_getint_slot(t, k)
		}
		return getgeneric(t, key, false)
	case:
		return getgeneric(t, key, false)
	}
}

// Read `t[key]` into `res` (nil if absent). The public read entry point.
luaH_get :: proc "contextless" (t: ^Table, key: ^TValue, res: ^TValue) {
	slot := luaH_getslot(t, key)
	if is_empty(slot) {
		set_nil(res)
	} else {
		set_obj(res, slot)
	}
}

// Read `t[key]` for an integer key into `res` (nil if absent).
luaH_getint :: proc "contextless" (t: ^Table, key: Integer, res: ^TValue) {
	slot := luaH_getint_slot(t, key)
	if is_empty(slot) {
		set_nil(res)
	} else {
		set_obj(res, slot)
	}
}

// Read `t[key]` for a string key into `res` (nil if absent).
luaH_getstr :: proc "contextless" (t: ^Table, key: ^TString, res: ^TValue) {
	slot := Hgetstr(t, key)
	if is_empty(slot) {
		set_nil(res)
	} else {
		set_obj(res, slot)
	}
}

// ---------------------------------------------------------------------------
// Insertion into the hash part
// ---------------------------------------------------------------------------

// Find any free (nil-key) hash slot -- reference Lua's `getfreepos`. We always do
// the simple linear scan (reference optimizes larger tables with a `lastfree`
// cursor; correctness is identical). Returns an index, or -1 if the hash part is
// full (or is the dummy).
@(private = "file")
getfreepos :: proc "contextless" (t: ^Table) -> int {
	if is_dummy(t) {
		return -1
	}
	i := sizenode(t)
	for i > 0 {
		i -= 1
		if t.node[i].key_tt == VNIL {
			return i
		}
	}
	return -1
}

// Insert a brand-new key/value into the hash part, preserving the main-position
// invariant (a colliding key is only displaced if it isn't in its own main
// position) -- a faithful port of reference Lua's `insertkey`, transcribed to work
// with node *indices* and relative `next` offsets. Returns false if there was no
// free slot (the caller then rehashes and retries).
@(private = "file")
insertkey :: proc "contextless" (t: ^Table, key: ^TValue, value: ^TValue) -> bool {
	mp := mainposition_i(t, key)
	if !is_empty(&t.node[mp].val) || is_dummy(t) {
		free := getfreepos(t)
		if free < 0 {
			return false // no room; caller must rehash
		}
		othern := mainposition_from_node(t, mp)
		if othern != mp {
			// The occupant is out of its main position: relocate it to `free`
			// and give `mp` back to the new key.
			for othern + t.node[othern].next != mp {
				othern += t.node[othern].next // find the node that chains to mp
			}
			t.node[othern].next = free - othern // rechain predecessor to `free`
			t.node[free] = t.node[mp] // move occupant (its `next` moves too)
			if t.node[mp].next != 0 {
				t.node[free].next += mp - free // fix the moved node's chain
				t.node[mp].next = 0
			}
			set_empty(&t.node[mp].val)
		} else {
			// The occupant is in its own main position: the new key takes `free`
			// and links onto the chain.
			if t.node[mp].next != 0 {
				t.node[free].next = (mp + t.node[mp].next) - free
			}
			t.node[mp].next = free - mp
			mp = free
		}
	}
	set_node_key(&t.node[mp], key)
	set_obj(&t.node[mp].val, value)
	return true
}

// Insert a key known to fit (space exists, key valid, value non-nil): array part
// if it's an array index, else the hash part. Reference `newcheckedkey`.
@(private = "file")
newcheckedkey :: proc "contextless" (t: ^Table, key: ^TValue, value: ^TValue) {
	i := keyinarray(t, key)
	if i > 0 {
		set_obj(&t.array[i - 1], value)
	} else {
		ok := insertkey(t, key, value)
		assert_contextless(ok, "newcheckedkey: insert into sized table cannot fail")
	}
}

// Add a genuinely new key -- reference Lua's `luaH_newkey`. Nil values are never
// stored. If the hash part is full we rehash (growing array and/or hash) and
// retry. A new key can add a metamethod, so we invalidate the TM cache for string
// keys, and we run the back barrier since a new reference just entered the table.
@(private = "file")
luaH_newkey :: proc(L: ^Lua_State, t: ^Table, key: ^TValue, value: ^TValue) -> Thread_Status {
	if is_nil(value) {
		return .Ok // do not insert nil values
	}
	if !insertkey(t, key, value) {
		st := rehash(L, t, key) // grow, then insert into the roomier table
		if st != .Ok {
			return st
		}
		newcheckedkey(t, key, value)
	}
	if no_variant(key.tt_) == TSTRING {
		invalidateTMcache(t)
	}
	luaC_barrierback(L, &t.header)
	return .Ok
}

// ---------------------------------------------------------------------------
// Writes
// ---------------------------------------------------------------------------

// Store `t[key] = value` for an integer key -- reference Lua's `luaH_setint`.
luaH_setint :: proc(L: ^Lua_State, t: ^Table, key: Integer, value: ^TValue) -> Thread_Status {
	ik := ikeyinarray(t, key)
	if ik > 0 {
		set_obj(&t.array[ik - 1], value)
		if is_collectable(value) {
			luaC_barrierback(L, &t.header)
		}
		return .Ok
	}
	slot := getintfromhash(t, key)
	if !is_absent(slot) {
		set_obj(slot, value)
		if is_collectable(value) {
			luaC_barrierback(L, &t.header)
		}
		return .Ok
	}
	k: TValue
	set_int(&k, key)
	return luaH_newkey(L, t, &k, value)
}

// Store `t[key] = value` for an arbitrary key -- reference Lua's `luaH_set`
// (folded together with `luaH_pset`/`luaH_finishset`, whose split exists purely as
// a VM fast-path optimization). Integral float keys are normalized to integers;
// nil and NaN keys are rejected.
luaH_set :: proc(L: ^Lua_State, t: ^Table, key: ^TValue, value: ^TValue) -> Thread_Status {
	switch type_tag(key) {
	case VNUMINT:
		return luaH_setint(L, t, int_value(key), value)
	case VNUMFLT:
		k, ok := float_to_integer(flt_value(key), .Eq)
		if ok {
			return luaH_setint(L, t, k, value)
		}
		// A non-integral float falls through to the generic path (and the NaN
		// check below, since only there can an insertion actually happen).
		if flt_value(key) != flt_value(key) {
			return throw(L, .Err_Run) // table index is NaN
		}
	case VNIL:
		return throw(L, .Err_Run) // table index is nil
	}
	// Generic: reuse an existing slot if the key is already present.
	slot := getgeneric(t, key, false)
	if !is_absent(slot) {
		set_obj(slot, value)
		if is_collectable(value) {
			luaC_barrierback(L, &t.header)
		}
		return .Ok
	}
	return luaH_newkey(L, t, key, value)
}

// ---------------------------------------------------------------------------
// Rehash: choosing array vs hash sizes
// ---------------------------------------------------------------------------

// Counting scratch for `rehash` -- reference Lua's `Counters`. `nums[i]` counts
// integer keys in the range (2^(i-1), 2^i]; `na` sums them; `total` is all keys;
// `deleted` notes stale hash slots.
@(private = "file")
Counters :: struct {
	total:   u32,
	na:      u32,
	deleted: bool,
	nums:    [MAXABITS + 1]u32,
}

// Is it worth spending `na` array entries instead of `nh` hash nodes? A hash node
// costs ~3x an array slot, so array wins while `na <= nh*3`. Reference `arrayXhash`.
@(private = "file")
arrayXhash :: #force_inline proc "contextless" (na: u32, nh: u32) -> bool {
	return uint(na) <= uint(nh) * 3
}

// Pick the array-part size that packs the most integer keys into the array while
// still satisfying `arrayXhash` -- reference Lua's `computesizes`. On return
// `ct.na` holds how many keys will actually go to the array.
@(private = "file")
computesizes :: proc "contextless" (ct: ^Counters) -> u32 {
	twotoi: u32 = 1
	a: u32 = 0 // keys smaller than 2^i
	na: u32 = 0 // keys destined for the array
	optimal: u32 = 0
	i := 0
	for twotoi > 0 && arrayXhash(twotoi, ct.na) {
		nums := ct.nums[i]
		a += nums
		if nums > 0 && arrayXhash(twotoi, a) {
			optimal = twotoi
			na = a
		}
		i += 1
		twotoi *= 2
	}
	ct.na = na
	return optimal
}

@(private = "file")
countint :: #force_inline proc "contextless" (key: Integer, ct: ^Counters) {
	k := arrayindex(key)
	if k != 0 {
		ct.nums[ceil_log2(k)] += 1
		ct.na += 1
	}
}

// Count the live keys in the array part, bucketing them by power-of-two slice --
// reference Lua's `numusearray`.
@(private = "file")
numusearray :: proc "contextless" (t: ^Table, ct: ^Counters) {
	ttlg: u32 = 1
	ause: u32 = 0
	i: u32 = 1
	asize := t.asize
	for lg := 0; lg <= MAXABITS; lg += 1 {
		lc: u32 = 0
		lim := ttlg
		if lim > asize {
			lim = asize
			if i > lim {
				break
			}
		}
		for ; i <= lim; i += 1 {
			if !arraykeyisempty(t, i) {
				lc += 1
			}
		}
		ct.nums[lg] += lc
		ause += lc
		ttlg *= 2
	}
	ct.total += ause
	ct.na += ause
}

// Count the live keys in the hash part (and note deletions and integer keys) --
// reference Lua's `numusehash`.
@(private = "file")
numusehash :: proc "contextless" (t: ^Table, ct: ^Counters) {
	total: u32 = 0
	i := sizenode(t)
	for i > 0 {
		i -= 1
		n := &t.node[i]
		if is_empty(&n.val) {
			ct.deleted = true
		} else {
			total += 1
			if n.key_tt == VNUMINT {
				countint(n.key_val.i, ct)
			}
		}
	}
	ct.total += total
}

// Rehash the whole table: count keys, pick the best array size, and resize.
// Reference Lua's `rehash`.
@(private = "file")
rehash :: proc(L: ^Lua_State, t: ^Table, ek: ^TValue) -> Thread_Status {
	ct: Counters
	ct.na = 0
	ct.deleted = false
	ct.total = 1 // count the extra key that triggered this
	if is_integer(ek) {
		countint(int_value(ek), &ct)
	}
	numusehash(t, &ct)
	asize: u32
	if ct.na == 0 {
		asize = t.asize // no new array candidates; keep the array size
	} else {
		numusearray(t, &ct)
		asize = computesizes(&ct)
	}
	nsize := ct.total - ct.na // everything not in the array goes to the hash
	if ct.deleted {
		nsize += nsize >> 2 // slack, so churny insert/delete cycles don't thrash
	}
	return luaH_resize(L, t, asize, nsize)
}

// ---------------------------------------------------------------------------
// Resizing
// ---------------------------------------------------------------------------

// (Re)allocate the array part to `newasize` slots, moving over the common prefix.
// Reference Lua's `resizearray`. Returns (new array, ok); ok is false only when a
// nonzero allocation fails.
@(private = "file")
array_resize :: proc(
	L: ^Lua_State,
	t: ^Table,
	oldasize: u32,
	newasize: u32,
) -> (
	[^]TValue,
	bool,
) {
	if oldasize == newasize {
		return t.array, true
	}
	if newasize == 0 {
		state_free(L, t.array, uint(oldasize) * size_of(TValue))
		return nil, true
	}
	block := state_realloc(L, nil, 0, uint(newasize) * size_of(TValue))
	if block == nil {
		return nil, false
	}
	np := ([^]TValue)(block)
	if oldasize > 0 {
		tomove := oldasize < newasize ? oldasize : newasize
		for i in 0 ..< int(tomove) {
			np[i] = t.array[i]
		}
		state_free(L, t.array, uint(oldasize) * size_of(TValue))
	}
	return np, true
}

// Allocate a hash part with (at least) `size` slots, or point at the shared dummy
// when `size == 0` -- reference Lua's `setnodevector`. Fresh slots start empty
// with nil keys.
@(private = "file")
setnodevector :: proc(L: ^Lua_State, t: ^Table, size: u32) -> Thread_Status {
	if size == 0 {
		t.node = dummy_ptr()
		t.lsizenode = 0
		t.flags |= BITDUMMY
		return .Ok
	}
	lsize := ceil_log2(size)
	if int(lsize) > MAXHBITS {
		return throw(L, .Err_Mem) // "table overflow" (Phase 5 gives the message)
	}
	realsize := twoto(lsize)
	block := state_realloc(L, nil, 0, uint(realsize) * size_of(Node))
	if block == nil {
		return throw(L, .Err_Mem)
	}
	t.node = ([^]Node)(block)
	t.lsizenode = lsize
	t.flags &= ~Byte(BITDUMMY)
	for i in 0 ..< realsize {
		n := &t.node[i]
		n.next = 0
		set_nil_key(n)
		set_empty(&n.val)
	}
	return .Ok
}

@(private = "file")
freehash :: proc(L: ^Lua_State, t: ^Table) {
	if !is_dummy(t) {
		state_free(L, t.node, uint(sizenode(t)) * size_of(Node))
	}
}

// Swap the hash parts (and the dummy flag bit) of two tables -- reference Lua's
// `exchangehashpart`. Used to temporarily lend `t` a new hash during resize while
// keeping the old one recoverable on error.
@(private = "file")
exchangehashpart :: proc "contextless" (t1: ^Table, t2: ^Table) {
	ls := t1.lsizenode
	nd := t1.node
	bd1 := t1.flags & BITDUMMY
	t1.lsizenode = t2.lsizenode
	t1.node = t2.node
	t1.flags = (t1.flags & ~Byte(BITDUMMY)) | (t2.flags & BITDUMMY)
	t2.lsizenode = ls
	t2.node = nd
	t2.flags = (t2.flags & ~Byte(BITDUMMY)) | bd1
}

// Re-insert every live key from an old hash part into `t`'s (new) parts --
// reference Lua's `reinserthash`.
@(private = "file")
reinserthash :: proc(L: ^Lua_State, old: ^Table, t: ^Table) {
	size := sizenode(old)
	for j in 0 ..< size {
		o := &old.node[j]
		if !is_empty(&o.val) {
			k: TValue
			get_node_key(&k, o)
			newcheckedkey(t, &k, &o.val)
		}
	}
}

// Move the entries in the array slice that is about to vanish (indices
// [newasize, oldasize)) into the hash part -- reference Lua's `reinsertOldSlice`.
@(private = "file")
reinsert_old_slice :: proc "contextless" (t: ^Table, oldasize: u32, newasize: u32) {
	for i in newasize ..< oldasize {
		if !is_empty(&t.array[i]) {
			key: TValue
			set_int(&key, u2s(u64(i) + 1))
			aux := t.array[i]
			ok := insertkey(t, &key, &aux)
			assert_contextless(ok, "reinsert_old_slice: hash sized for these keys")
		}
	}
}

@(private = "file")
clear_new_slice :: proc "contextless" (t: ^Table, oldasize: u32, newasize: u32) {
	for i in oldasize ..< newasize {
		set_empty(&t.array[i])
	}
}

// Resize a table to new array and hash sizes -- reference Lua's `luaH_resize`,
// with its careful ordering so a mid-resize allocation failure leaves the table in
// a consistent (original) state.
luaH_resize :: proc(L: ^Lua_State, t: ^Table, newasize: u32, nhsize: u32) -> Thread_Status {
	newt: Table // scratch table holding the new hash part
	oldasize := t.asize
	if newasize > MAXASIZE {
		return throw(L, .Err_Mem) // "table overflow"
	}
	newt.flags = 0
	st := setnodevector(L, &newt, nhsize)
	if st != .Ok {
		return st
	}
	if newasize < oldasize {
		// The array is shrinking: relocate the vanishing slice into the new hash.
		exchangehashpart(t, &newt)
		reinsert_old_slice(t, oldasize, newasize)
		exchangehashpart(t, &newt)
	}
	newarray, ok := array_resize(L, t, oldasize, newasize)
	if !ok {
		freehash(L, &newt)
		return throw(L, .Err_Mem)
	}
	exchangehashpart(t, &newt) // now `t` has the new hash, `newt` the old
	t.array = newarray
	t.asize = newasize
	if newarray != nil {
		t.len_hint = newasize / 2
	}
	clear_new_slice(t, oldasize, newasize)
	reinserthash(L, &newt, t) // fold the old hash entries back in
	freehash(L, &newt)
	return .Ok
}

luaH_resizearray :: proc(L: ^Lua_State, t: ^Table, newasize: u32) -> Thread_Status {
	nsize := is_dummy(t) ? u32(0) : u32(sizenode(t))
	return luaH_resize(L, t, newasize, nsize)
}

// ---------------------------------------------------------------------------
// Creation and destruction
// ---------------------------------------------------------------------------

// Allocate an empty table -- reference Lua's `luaH_new`. It starts with no array
// part and the shared dummy hash part; both grow on first insertion. Returns nil
// only if the object allocation fails.
luaH_new :: proc(L: ^Lua_State) -> ^Table {
	o := luaC_newobj(L, VTABLE, size_of(Table))
	if o == nil {
		return nil
	}
	t := (^Table)(o)
	t.metatable = nil
	t.flags = maskflags // no metamethods present yet
	t.array = nil
	t.asize = 0
	t.len_hint = 0
	t.gclist = nil
	setnodevector(L, t, 0) // size 0 never allocates or fails
	return t
}

// Free a table and everything it owns -- reference Lua's `luaH_free`. Called only
// by the GC's `freeobj`, so no error path is needed (frees don't fail).
luaH_free :: proc(L: ^Lua_State, t: ^Table) {
	freehash(L, t)
	array_resize(L, t, t.asize, 0)
	state_free(L, t, size_of(Table))
}

// ---------------------------------------------------------------------------
// Traversal (`next`) and length (`#`)
// ---------------------------------------------------------------------------

// Find the traversal index that follows `key` -- reference Lua's `findindex`.
// Array keys are numbered first (1..asize), then hash slots. 0 starts a traversal.
@(private = "file")
findindex :: proc(L: ^Lua_State, t: ^Table, key: ^TValue, asize: u32) -> u32 {
	if is_nil(key) {
		return 0 // first iteration
	}
	i := keyinarray(t, key)
	if i != 0 {
		return i // key is in the array part
	}
	n := getgeneric(t, key, true)
	if is_absent(n) {
		throw(L, .Err_Run) // "invalid key to 'next'"
		return 0
	}
	idx := u32(node_index(t, (^Node)(n)))
	return (idx + 1) + asize // hash slots are numbered after array ones
}

// Advance a table traversal -- reference Lua's `luaH_next`. Given the current
// `key`, write the next key/value into `out_key`/`out_val` and return true, or
// return false at the end. Passing a nil `key` starts the traversal.
luaH_next :: proc(L: ^Lua_State, t: ^Table, key: ^TValue, out_key: ^TValue, out_val: ^TValue) -> bool {
	asize := t.asize
	i := findindex(L, t, key, asize)
	for i < asize {
		if !is_empty(&t.array[i]) {
			set_int(out_key, u2s(u64(i) + 1))
			set_obj(out_val, &t.array[i])
			return true
		}
		i += 1
	}
	for j := i - asize; j < u32(sizenode(t)); j += 1 {
		n := &t.node[j]
		if !is_empty(&n.val) {
			get_node_key(out_key, n)
			set_obj(out_val, &n.val)
			return true
		}
	}
	return false // no more elements
}

@(private = "file")
hashkeyisempty :: proc "contextless" (t: ^Table, key: Unsigned) -> bool {
	return is_empty(getintfromhash(t, u2s(key)))
}

// Binary search for a border within the array part -- reference `binsearch`.
@(private = "file")
binsearch :: proc "contextless" (t: ^Table, i0: u32, j0: u32) -> u32 {
	i := i0
	j := j0
	for j - i > 1 {
		m := (i + j) / 2
		if arraykeyisempty(t, m) {
			j = m
		} else {
			i = m
		}
	}
	return i
}

@(private = "file")
newhint :: #force_inline proc "contextless" (t: ^Table, hint: u32) -> Unsigned {
	t.len_hint = hint
	return Unsigned(hint)
}

// Search the hash part for a border when the array is entirely full -- reference
// Lua's `hash_search`, seeded doubling and all (the seed thwarts a pathological
// actor from constructing a table with a hugely inflated length).
@(private = "file")
hash_search :: proc(L: ^Lua_State, t: ^Table, asize: u32) -> Unsigned {
	i: Unsigned = Unsigned(asize) + 1 // caller guarantees t[i] present
	rnd := L.g.seed
	n := asize > 0 ? int(ceil_log2(asize)) : 0
	mask := (u32(1) << uint(n)) - 1
	incr := (rnd & mask) + 1
	maxint := s2u(MAX_INTEGER)
	j: Unsigned = (Unsigned(incr) <= maxint - i) ? i + Unsigned(incr) : i + 1
	rnd >>= uint(n)
	for !hashkeyisempty(t, j) {
		i = j
		if j <= maxint / 2 - 1 {
			j = j * 2 + Unsigned(rnd & 1)
			rnd >>= 1
		} else {
			j = maxint
			if hashkeyisempty(t, j) {
				break
			}
			return j
		}
	}
	for j - i > 1 {
		m := (i + j) / 2
		if hashkeyisempty(t, m) {
			j = m
		} else {
			i = m
		}
	}
	return i
}

// A border of `t`: an index `n` with `t[n]` present and `t[n+1]` absent (the `#`
// operator). Reference Lua's `luaH_getn`, hint-guided vicinity search included.
luaH_getn :: proc(L: ^Lua_State, t: ^Table) -> Unsigned {
	asize := t.asize
	if asize > 0 {
		maxvicinity :: 4
		limit := t.len_hint
		if limit == 0 || limit > asize {
			limit = 1
		}
		if arraykeyisempty(t, limit) {
			// There is a border before `limit`; look nearby first.
			for i in 0 ..< maxvicinity {
				if limit <= 1 {
					break
				}
				limit -= 1
				if !arraykeyisempty(t, limit) {
					return newhint(t, limit)
				}
			}
			return newhint(t, binsearch(t, 0, limit))
		} else {
			// `limit` is present; look for a border after it.
			for i in 0 ..< maxvicinity {
				if limit >= asize {
					break
				}
				limit += 1
				if arraykeyisempty(t, limit) {
					return newhint(t, limit - 1)
				}
			}
			if arraykeyisempty(t, asize) {
				return newhint(t, binsearch(t, limit, asize))
			}
		}
		t.len_hint = asize
	}
	// No array part, or its last slot is full: the border may be in the hash.
	if is_dummy(t) || hashkeyisempty(t, Unsigned(asize) + 1) {
		return Unsigned(asize)
	}
	return hash_search(L, t, asize)
}
