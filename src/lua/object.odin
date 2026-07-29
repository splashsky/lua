package lua

// object.odin -- our analogue of reference Lua's `lobject.h` / `lobject.c`.
//
// The heart of the value model. This is where the tagged-value type (`TValue`)
// lives: the union of number / boolean / nil / light-userdata / GC-collectable
// object, together with the type tags and the collectable-object header shared
// by strings, tables, closures, userdata, threads, and prototypes.
//
// Everything downstream -- the VM, the GC, the API -- speaks in these types, so
// this file defines the vocabulary of the entire implementation. It also carries
// the state-free numeric machinery reference Lua keeps here: string<->number
// conversion, number->string formatting, float<->integer coercion, and the raw
// arithmetic the compiler uses for constant folding.
//
// A deliberate, documented decision (correctness first): the float<->string
// boundary defers to the platform C library via `core:c/libc` -- the very same
// component reference Lua uses (luaconf.h formats floats with C `printf("%g")`
// and parses them with `strtod`). This makes our results *byte-identical* to
// reference Lua on the same platform instead of merely close. `core:c/libc` is
// part of Odin's standard library, so this stays within "std-lib-only Odin". A
// pure-Odin `%g` formatter can replace it later without changing any observable
// behavior, validated against a differential corpus. Integer formatting and all
// numeric *parsing* below are already pure Odin.

import "core:c/libc"

// ---------------------------------------------------------------------------
// Type tags
// ---------------------------------------------------------------------------

// The base type tags, matching the LUA_T* constants in reference Lua's lua.h.
// These occupy bits 0-3 of a value's tag byte. `TNONE` (-1) is the "no value"
// sentinel used at the C API boundary; it never appears in a live `TValue`.
TNONE :: -1
TNIL :: 0
TBOOLEAN :: 1
TLIGHTUSERDATA :: 2
TNUMBER :: 3
TSTRING :: 4
TTABLE :: 5
TFUNCTION :: 6
TUSERDATA :: 7
TTHREAD :: 8

// Number of "real" base types (LUA_NUMTYPES). Used for table sizing later.
NUM_TYPES :: 9

// Extra tags for collectable things that are never first-class Lua values:
// upvalues, function prototypes, and the special "dead key" marker tables use
// for removed keys. They continue the numbering past the base types.
TUPVAL :: 9
TPROTO :: 10
TDEADKEY :: 11

// ---------------------------------------------------------------------------
// Variant tags
// ---------------------------------------------------------------------------

// A value's full tag byte packs three things:
//   bits 0-3: the base type (a LUA_T* above)
//   bits 4-5: a "variant" selecting between representations of that type
//   bit 6   : the collectable flag (BIT_ISCOLLECTABLE)
// `make_variant` builds the (base | variant) pair exactly like reference Lua's
// `makevariant(t, v)`.
make_variant :: #force_inline proc "contextless" (t: int, v: int) -> Byte {
	return Byte(t | (v << 4))
}

// The concrete variant tags. Nil has four variants that all read as "nil" to Lua
// code but mean different things internally (a real nil, an empty table slot, the
// absent-key sentinel, and a fast-path "not a table" marker). Booleans split into
// false/true. Numbers split into integer/float. Strings into short/long.
VNIL :: 0 // make_variant(TNIL, 0)
VEMPTY :: 0x10 // make_variant(TNIL, 1)
VABSTKEY :: 0x20 // make_variant(TNIL, 2)
VNOTABLE :: 0x30 // make_variant(TNIL, 3)

VFALSE :: 1 // make_variant(TBOOLEAN, 0)
VTRUE :: 0x11 // make_variant(TBOOLEAN, 1)

VNUMINT :: 3 // make_variant(TNUMBER, 0)
VNUMFLT :: 0x13 // make_variant(TNUMBER, 1)

VSHRSTR :: 4 // make_variant(TSTRING, 0)
VLNGSTR :: 0x14 // make_variant(TSTRING, 1)

VLIGHTUSERDATA :: 2 // make_variant(TLIGHTUSERDATA, 0)
VUSERDATA :: 7 // make_variant(TUSERDATA, 0)

VLCL :: 6 // make_variant(TFUNCTION, 0)  -- Lua closure
VLCF :: 0x16 // make_variant(TFUNCTION, 1)  -- light C function
VCCL :: 0x26 // make_variant(TFUNCTION, 2)  -- C closure

VTABLE :: 5 // make_variant(TTABLE, 0)
VTHREAD :: 8 // make_variant(TTHREAD, 0)
VPROTO :: 10 // make_variant(TPROTO, 0)
VUPVAL :: 9 // make_variant(TUPVAL, 0)

// Bit 6 marks a tag as pointing at a collectable (GC-managed) object. `ctb`
// ("collectable tag bits") sets it; `is_collectable_tag` tests it. Reference Lua:
// BIT_ISCOLLECTABLE / ctb / iscollectable.
BIT_ISCOLLECTABLE :: 1 << 6

ctb :: #force_inline proc "contextless" (t: int) -> Byte {
	return Byte(t | BIT_ISCOLLECTABLE)
}

// Compile-time cross-checks that our hand-computed variant literals really do
// equal make_variant(...). If anyone edits a number wrong, the build fails here
// rather than misbehaving at runtime.
// (`make_variant` is a runtime proc, so we spell the check as the same bit math
// it performs: base | (variant << 4).)
#assert(VEMPTY == (TNIL | (1 << 4)))
#assert(VABSTKEY == (TNIL | (2 << 4)))
#assert(VNOTABLE == (TNIL | (3 << 4)))
#assert(VTRUE == (TBOOLEAN | (1 << 4)))
#assert(VNUMFLT == (TNUMBER | (1 << 4)))
#assert(VLNGSTR == (TSTRING | (1 << 4)))
#assert(VLCF == (TFUNCTION | (1 << 4)))
#assert(VCCL == (TFUNCTION | (2 << 4)))

// ---------------------------------------------------------------------------
// The value representation
// ---------------------------------------------------------------------------

// A light C function: a plain C-callable procedure with no captured upvalues.
// The `L` parameter is really a `^State`, but `State` isn't defined until a later
// phase, so we type it as `rawptr` for now.
// TODO(phase-2): retype `L` to `^State` once the state type exists.
C_Function :: #type proc "c" (L: rawptr) -> i32

// `Value` is the raw 8-byte payload of a Lua value: the union of every concrete
// representation. Which member is live is decided entirely by the accompanying
// tag byte -- the union itself carries no discriminant. We use Odin's
// `#raw_union` (an untagged overlay) rather than a tagged `union` precisely
// because reference Lua's `Value` is an untagged C union and we must match its
// size, alignment, and aliasing behavior exactly.
Value :: struct #raw_union {
	gc: ^GCObject, // collectable objects (strings, tables, ...)
	p:  rawptr, // light userdata
	f:  C_Function, // light C functions
	i:  Integer, // integer numbers
	n:  Number, // float numbers
	ub: Byte, // unused; mirrors reference Lua's warning-suppression member
}

// `TValue` is a full tagged value: the payload plus its type tag. This is the
// currency of the whole interpreter. `TValuefields` in reference Lua is these two
// members; we keep them as a named struct.
TValue :: struct {
	value_: Value,
	tt_:    Byte,
}

// Entries on the Lua stack. A stack slot is usually just a `TValue`, but slots
// holding to-be-closed variables also thread a `delta` linking to the next such
// slot -- so the slot is an overlay (`#raw_union`) of a plain value and a value
// with that extra `delta`. Matches reference Lua's `StackValue`.
StackValue :: struct #raw_union {
	val:     TValue,
	tbclist: struct {
		value_: Value,
		tt_:    Byte,
		delta:  u16,
	},
}

// The common header every collectable object begins with: a link in the GC's
// sweep list, the object's own type tag, and its GC mark bits. Reference Lua's
// `CommonHeader` / `GCObject`. This standalone type is for the collector's typed
// lists and links; concrete objects repeat these fields inline at the same
// offsets so their own small fields can use the trailing padding.
GCObject :: struct {
	next:   ^GCObject,
	tt:     Byte,
	marked: Byte,
}

// The layout guarantees the rest of the kernel silently relies on. If any of
// these ever fails, something is deeply wrong (a member grew, alignment shifted)
// and every downstream assumption -- stack indexing, dump/undump sizing, GC
// pointer punning -- would be unsafe. Better to fail the build loudly.
#assert(size_of(Value) == 8)
#assert(align_of(Value) == 8)
#assert(size_of(TValue) == 16)
#assert(offset_of(TValue, tt_) == 8)
#assert(size_of(StackValue) == 16)
#assert(align_of(StackValue) == 8)

// ---------------------------------------------------------------------------
// Tag inspection
// ---------------------------------------------------------------------------

// Strip a tag down to just its base type (bits 0-3): reference Lua's `novariant`.
no_variant :: #force_inline proc "contextless" (t: Byte) -> Byte {
	return t & 0x0F
}

// Keep base type + variant but drop the collectable bit (bits 0-5): `withvariant`.
with_variant :: #force_inline proc "contextless" (t: Byte) -> Byte {
	return t & 0x3F
}

// The raw tag byte of a value (`rawtt`).
raw_tag :: #force_inline proc "contextless" (o: ^TValue) -> Byte {
	return o.tt_
}

// The value's type-with-variant tag (`ttypetag`) and bare base type (`ttype`).
type_tag :: #force_inline proc "contextless" (o: ^TValue) -> Byte {
	return with_variant(o.tt_)
}

base_type :: #force_inline proc "contextless" (o: ^TValue) -> Byte {
	return no_variant(o.tt_)
}

// Is this value's payload a pointer the GC owns?
is_collectable :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return (o.tt_ & BIT_ISCOLLECTABLE) != 0
}

// ---------------------------------------------------------------------------
// Type predicates
// ---------------------------------------------------------------------------
//
// These mirror the ttis* macro family. "Any nil" tests the base type (so all
// four nil variants count); the sharper tests compare the exact tag byte.

is_nil :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TNIL
}

is_strict_nil :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VNIL
}

// A table slot with no value carries the VEMPTY tag; reading it as a Lua value
// yields nil. `is_empty` mirrors reference Lua's `isempty`, which -- like us --
// simply tests the base type, so it accepts every nil variant. Kept as a named
// predicate because the table and GC code read far more clearly asking "is this
// slot empty?" than "is this value nil?".
is_empty :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TNIL
}

is_boolean :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TBOOLEAN
}

is_false :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VFALSE
}

is_true :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VTRUE
}

// Lua truthiness: only nil and false are falsy. `l_isfalse` in reference Lua.
is_falsy :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return is_false(o) || is_nil(o)
}

is_number :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TNUMBER
}

is_integer :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VNUMINT
}

is_float :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VNUMFLT
}

// ---------------------------------------------------------------------------
// Accessors
// ---------------------------------------------------------------------------
//
// Read the payload as a particular representation. Callers must have checked the
// tag first (these don't re-check), exactly like reference Lua's ivalue/fltvalue.

int_value :: #force_inline proc "contextless" (o: ^TValue) -> Integer {
	return o.value_.i
}

flt_value :: #force_inline proc "contextless" (o: ^TValue) -> Number {
	return o.value_.n
}

gc_value :: #force_inline proc "contextless" (o: ^TValue) -> ^GCObject {
	return o.value_.gc
}

ptr_value :: #force_inline proc "contextless" (o: ^TValue) -> rawptr {
	return o.value_.p
}

// Read any number as a float, converting an integer on the fly (`nvalue`).
num_value :: #force_inline proc "contextless" (o: ^TValue) -> Number {
	return is_integer(o) ? Number(o.value_.i) : o.value_.n
}

// ---------------------------------------------------------------------------
// Setters / constructors
// ---------------------------------------------------------------------------
//
// A crucial subtlety carried over from reference Lua: setting a value to nil or a
// boolean changes ONLY the tag byte and leaves the payload untouched. We never
// zero the payload "for cleanliness" -- doing so would be wasted work, and code
// must never compare whole `TValue` memory (two nils can have different garbage
// in their payload and still be equal). See the review notes.

set_nil :: #force_inline proc "contextless" (o: ^TValue) {
	o.tt_ = VNIL
}

set_empty :: #force_inline proc "contextless" (o: ^TValue) {
	o.tt_ = VEMPTY
}

set_false :: #force_inline proc "contextless" (o: ^TValue) {
	o.tt_ = VFALSE
}

set_true :: #force_inline proc "contextless" (o: ^TValue) {
	o.tt_ = VTRUE
}

// A boolean from an Odin bool.
set_bool :: #force_inline proc "contextless" (o: ^TValue, b: bool) {
	o.tt_ = b ? VTRUE : VFALSE
}

set_int :: #force_inline proc "contextless" (o: ^TValue, x: Integer) {
	o.value_.i = x
	o.tt_ = VNUMINT
}

set_float :: #force_inline proc "contextless" (o: ^TValue, x: Number) {
	o.value_.n = x
	o.tt_ = VNUMFLT
}

set_light_userdata :: #force_inline proc "contextless" (o: ^TValue, p: rawptr) {
	o.value_.p = p
	o.tt_ = VLIGHTUSERDATA
}

set_c_function :: #force_inline proc "contextless" (o: ^TValue, f: C_Function) {
	o.value_.f = f
	o.tt_ = VLCF
}

// Point a value at a collectable object. The value's tag is the object's own tag
// with the collectable bit added (`setgcovalue`): a value and the object it
// references always agree on their variant. This single helper is intentionally
// NOT over-generalized into "set any GC value" magic -- the object already knows
// its variant in its header `tt`, so we simply read it and add the collectable
// bit. Specific typed constructors (set_string, set_table, ...) will layer on top
// once those object types exist.
set_gc :: #force_inline proc "contextless" (o: ^TValue, obj: ^GCObject) {
	o.value_.gc = obj
	o.tt_ = ctb(int(obj.tt))
}

// Copy a value wholesale (payload + tag): reference Lua's `setobj`.
set_obj :: #force_inline proc "contextless" (dst: ^TValue, src: ^TValue) {
	dst.value_ = src.value_
	dst.tt_ = src.tt_
}

// ---------------------------------------------------------------------------
// Full userdata
// ---------------------------------------------------------------------------
//
// Reference Lua's `Udata` (lobject.h). Full userdata is a GC-managed block of raw
// bytes the host allocates through the API (`lua_newuserdatauv`) to hold a C/Odin
// object -- a file handle, a socket, whatever. Unlike *light* userdata (a bare
// pointer that is not collectable and carries no metatable), full userdata is a
// first-class collectable object with its own metatable and an optional set of
// associated *user values* (arbitrary Lua values the host can stash alongside the
// bytes, indexed 1..nuvalue).
//
// The layout matches reference Lua's single-allocation trick: the fixed header is
// immediately followed, inline, by `nuvalue` user-value slots and then the `len`
// raw data bytes -- one allocation holds everything. We compute those trailing
// offsets by hand (Odin has no C flexible-array member), which also lets us avoid
// reference Lua's separate `Udata0` variant: because we never materialize a `uv[1]`
// array in the struct, the `nuvalue == 0` case needs no special offset.

// A single user-value slot. Reference Lua wraps the `TValue` in a union with a
// max-alignment member so the raw data bytes that follow are always suitably
// aligned; our `TValue` is already 16 bytes and 8-aligned, which covers every
// scalar Odin/C type, so the plain `TValue` *is* that maximally-aligned slot.
UValue :: TValue

// Keep the common GC fields inline, exactly as reference C's CommonHeader macro
// does. This lets the small `nuvalue` field use the bytes that would otherwise be
// padding inside a nested 16-byte `GCObject`; embedding the header again would
// quietly add 8 bytes before every userdata payload.
Udata :: struct {
	next:      ^GCObject,
	tt:        u8,
	marked:    u8,
	nuvalue:   u16, // number of trailing user-value slots
	len:       uint, // number of raw data bytes
	metatable: ^Table, // this userdata's own metatable (nil if none)
	gclist:    ^GCObject, // GC gray-list thread
	// Inline after this header: `nuvalue` UValue slots, then `len` data bytes.
}

#assert(offset_of(Udata, next) == 0)
#assert(offset_of(Udata, tt) == 8)
#assert(offset_of(Udata, marked) == 9)
#assert(size_of(Udata) == 40)
#assert(size_of(Udata) % align_of(UValue) == 0)

// The byte size of a full-userdata block carrying `nuvalue` user values and `size`
// data bytes -- reference Lua's `sizeudata`. Header + inline user values + data.
size_udata :: #force_inline proc "contextless" (nuvalue: int, size: uint) -> uint {
	return size_of(Udata) + uint(nuvalue) * size_of(UValue) + size
}

// A pointer to user-value slot `i` (0-based internally; the API exposes 1-based) --
// reference Lua's `getusedvalue`/`&u->uv[i]`. The slots begin immediately after the
// header.
udata_uv :: #force_inline proc "contextless" (u: ^Udata, i: int) -> ^TValue {
	base := uintptr(u) + uintptr(size_of(Udata))
	return (^TValue)(base + uintptr(i) * size_of(UValue))
}

// A multipointer to the raw data bytes -- reference Lua's `getudatamem`. They sit
// just past the user-value slots.
udata_mem :: #force_inline proc "contextless" (u: ^Udata) -> [^]u8 {
	base := uintptr(u) + uintptr(size_of(Udata)) + uintptr(u.nuvalue) * size_of(UValue)
	return ([^]u8)(base)
}

// Point a value at a full userdata -- reference Lua's `setuvalue`. Full userdata is
// collectable, so `set_gc` tags the value with the userdata variant plus the
// collectable bit.
set_userdata :: #force_inline proc "contextless" (o: ^TValue, u: ^Udata) {
	set_gc(o, obj2gco(u))
}

// Recover the `^Udata` a value points at -- reference Lua's `uvalue`.
udata_value :: #force_inline proc "contextless" (o: ^TValue) -> ^Udata {
	return (^Udata)(o.value_.gc)
}

// ---------------------------------------------------------------------------
// The remaining `ttis*` type predicates and value accessors
// ---------------------------------------------------------------------------
//
// The number/nil/boolean predicates live above; these cover the collectable and
// function variants the embedding API and standard libraries lean on. Each mirrors
// a reference Lua `ttis*` macro. `type_tag` drops the collectable bit, so comparing
// against the bare variant tag is exact.

is_string :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TSTRING
}

is_table :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VTABLE
}

is_thread :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VTHREAD
}

// Full (collectable) userdata only -- reference Lua's `ttisfulluserdata`.
is_full_userdata :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VUSERDATA
}

// Light userdata (a bare, non-collectable pointer) -- reference `ttislightuserdata`.
is_light_userdata :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VLIGHTUSERDATA
}

// Any function: a Lua closure, a C closure, or a light C function -- `ttisfunction`.
is_function :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return no_variant(o.tt_) == TFUNCTION
}

// A light (upvalue-less) C function value -- reference Lua's `ttislcf`.
is_light_cfunction :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return o.tt_ == VLCF
}

// A C/Odin closure (native function + captured values) -- reference `ttisCclosure`.
is_c_closure :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VCCL
}

// A Lua closure (prototype + shared upvalues) -- reference Lua's `ttisLclosure`.
is_lua_closure :: #force_inline proc "contextless" (o: ^TValue) -> bool {
	return type_tag(o) == VLCL
}

// Value accessors: recover the typed object pointer behind a collectable value.
// Reference Lua's `hvalue` / `thvalue` / `clLvalue` / `clCvalue` / `fvalue`.
table_value :: #force_inline proc "contextless" (o: ^TValue) -> ^Table {
	return (^Table)(o.value_.gc)
}

thread_value :: #force_inline proc "contextless" (o: ^TValue) -> ^Lua_State {
	return (^Lua_State)(o.value_.gc)
}

lua_closure_value :: #force_inline proc "contextless" (o: ^TValue) -> ^LClosure {
	return (^LClosure)(o.value_.gc)
}

c_closure_value :: #force_inline proc "contextless" (o: ^TValue) -> ^CClosure {
	return (^CClosure)(o.value_.gc)
}

// The light C function pointer inside a VLCF value -- reference Lua's `fvalue`.
cfunction_value :: #force_inline proc "contextless" (o: ^TValue) -> C_Function {
	return o.value_.f
}


// ---------------------------------------------------------------------------
// Full arithmetic with metamethod fallback (for the embedding API)
// ---------------------------------------------------------------------------

// Perform `op` on `p1`/`p2`, storing the result at stack index `res` -- reference
// Lua's `luaO_arith`. The state-free `raw_arith` handles the numeric domains; on a
// non-numeric operand we fall back to the corresponding binary metamethod (which is
// how `"10" + 5` and userdata operators work), and on integer division/modulo by
// zero we raise the same runtime error the VM does. `lua_arith` is the public
// entry point that reaches this.
luaO_arith :: proc(L: ^Lua_State, op: int, p1, p2: ^TValue, res: int) {
	r, st := raw_arith(Arith_Op(op), p1, p2)
	switch st {
	case .Ok:
		set_obj(stack_value(L, res), &r)
	case .Div_By_Zero:
		if Arith_Op(op) == .IDiv {
			luaG_runerror(L, "attempt to perform 'n//0'")
		} else {
			luaG_runerror(L, "attempt to perform 'n%%0'")
		}
	case .No_Number:
		// Map the operator selector onto its metamethod event (they share order).
		luaT_trybinTM(L, p1, p2, res, (op - LUA_OPADD) + TM_ADD)
	}
}


// ---------------------------------------------------------------------------
// GC parameter codec (float-coded bytes)
// ---------------------------------------------------------------------------
//
// Lua 5.5 stores each tunable GC parameter as a single "floating-point byte":
// four exponent bits and four mantissa bits, excess-7, IEEE-754-style with an
// implicit leading one when normalized. This lets a percentage as large as a few
// thousand fit in a byte with enough precision for pacing. `luaO_codeparam`
// encodes a raw value; `luaO_applyparam` computes `p% * x` for a coded `p`. The
// three routines are transcribed verbatim from reference Lua's lobject.c so the
// pacing arithmetic matches bit for bit.

// ceil(log2(x)): the smallest n with x <= (1 << n). Reference `luaO_ceillog2`.
luaO_ceillog2 :: proc "contextless" (x: u32) -> u8 {
	// log_2[i-1] = ceil(log2(i)) for i in 1..256.
	@(static, rodata)
	log_2 := [256]u8 {
		0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4,
		5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
		6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
		8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
	}
	l := 0
	v := x - 1
	for v >= 256 {
		l += 8
		v >>= 8
	}
	return u8(l) + log_2[v]
}

// Encode a value as a floating-point byte (eeeexxxx). Reference `luaO_codeparam`.
luaO_codeparam :: proc "contextless" (p: uint) -> u8 {
	// The overflow ceiling from reference: 0x1F << (0xF - 7 - 1), times 100.
	if p >= (uint(0x1F) << (0xF - 7 - 1)) * 100 {
		return 0xFF // saturate to the maximum representable value
	}
	q := (u32(p) * 128 + 99) / 100 // round the /100 up
	if q < 0x10 {
		return u8(q) // subnormal: exponent bits already zero
	}
	log := u32(luaO_ceillog2(q + 1)) - 5 // q >= 0x10 => ceil(log2(q+1)) >= 5
	return u8(((q >> log) - 0x10) | ((log + 1) << 4))
}

// Compute `p% * x` for a float-coded `p`, saturating at MAX_LMEM. Reference
// `luaO_applyparam`.
luaO_applyparam :: proc "contextless" (p: u8, x: L_Mem) -> L_Mem {
	m := L_Mem(p & 0xF) // mantissa
	e := int(p >> 4) // exponent
	if e > 0 { // normalized?
		e -= 1 // correct the excess used to flag normalization
		m += 0x10 // restore the implicit leading one (max 0x1F)
	}
	e -= 7 // remove the excess-7 bias
	if e >= 0 {
		if x < (MAX_LMEM / 0x1F) >> uint(e) { // no overflow?
			return (x * m) << uint(e)
		}
		return MAX_LMEM
	}
	e = -e
	if x < MAX_LMEM / 0x1F { // multiply first for more precision
		return (x * m) >> uint(e)
	} else if (x >> uint(e)) < MAX_LMEM / 0x1F {
		return (x >> uint(e)) * m
	}
	return MAX_LMEM
}


// the low 32 bits of the address is fine; it need not round-trip back to a
// pointer. (Reference masks with UINT_MAX for exactly the same reason.)
point2uint :: #force_inline proc "contextless" (p: rawptr) -> u32 {
	return u32(uintptr(p))
}

// ---------------------------------------------------------------------------
// Float <-> integer coercion
// ---------------------------------------------------------------------------

// The rounding mode for a float->integer conversion, mirroring reference Lua's
// `F2Imod`: demand an exact integral value, or round down, or round up.
F2I_Mode :: enum {
	Eq, // no rounding; only an already-integral float converts
	Floor, // take the floor
	Ceil, // take the ceiling
}

// Range-check + truncating cast of an already-integral float to an integer.
// This is reference Lua's `lua_numbertointeger` macro and nothing more: it does
// NOT check integrality (callers pass a value they've already floored/ceiled). It
// succeeds only when `f` sits within [MIN_INTEGER, MAX_INTEGER]. The bounds are
// written as `f >= 2^63-as-float(min)` and `f < 2^63` because MIN_INTEGER is
// exactly representable as a double but MAX_INTEGER is not.
number_to_integer_range :: proc "contextless" (f: Number) -> (Integer, bool) {
	// -(Number)MIN_INTEGER is exactly 2^63; the strict `<` keeps 2^63 itself out.
	if f >= Number(MIN_INTEGER) && f < -Number(MIN_INTEGER) {
		return Integer(f), true
	}
	return 0, false
}

// Convert a float to an integer under the given rounding mode. Faithful port of
// `luaV_flttointeger`: floor first, and if the value wasn't already integral,
// either fail (Eq), or bump the floor up to the ceiling (Ceil).
float_to_integer :: proc "contextless" (n: Number, mode: F2I_Mode) -> (Integer, bool) {
	f := libc.floor(n)
	if n != f { 	// not an integral value?
		if mode == .Eq {
			return 0, false // Eq demands an exact integer
		} else if mode == .Ceil {
			f += 1 // floor -> ceiling (we know n != f here)
		}
	}
	return number_to_integer_range(f)
}

// Try to read a value as a float WITHOUT string coercion. Integers convert
// exactly (well, as exactly as double allows for huge magnitudes, matching C).
// Reference Lua's `luaV_tonumberns` -- the string-coercing variant is `vm_tonumber`
// (vm.odin), which parses numeric strings via `l_strton` before delegating here.
to_number_no_string :: proc "contextless" (o: ^TValue) -> (Number, bool) {
	if is_integer(o) {
		return Number(o.value_.i), true
	} else if is_float(o) {
		return o.value_.n, true
	}
	return 0, false
}

// Try to read a value as an integer WITHOUT string coercion, rounding per `mode`.
// Reference Lua's `luaV_tointegerns`.
to_integer_no_string :: proc "contextless" (o: ^TValue, mode: F2I_Mode) -> (Integer, bool) {
	if is_float(o) {
		return float_to_integer(o.value_.n, mode)
	} else if is_integer(o) {
		return o.value_.i, true
	}
	return 0, false
}

// Raw primitive equality -- reference Lua's `luaV_rawequalobj` (i.e.
// `luaV_equalobj` with no state, so no `__eq` metamethod is ever consulted). The
// code generator leans on this to deduplicate numeric constants (see
// `luaK_numberK`) and to sanity-check the constant cache, so it must faithfully
// mirror how the VM decides two values are "primitively" equal.
//
// The one subtlety: an integer and a float count as equal when the float has an
// integral value equal to the integer (e.g. `1` and `1.0`). Everything else must
// share the exact tag-with-variant; strings compare by interned identity (short)
// or by contents (long), and other collectables compare by pointer.
raw_equal :: proc "contextless" (t1, t2: ^TValue) -> bool {
	if type_tag(t1) != type_tag(t2) {
		// Different variants can still be equal, but only for two numbers where
		// one is a float carrying an integral value matching the other.
		if no_variant(t1.tt_) != no_variant(t2.tt_) || no_variant(t1.tt_) != TNUMBER {
			return false
		}
		i1, ok1 := to_integer_no_string(t1, .Eq)
		i2, ok2 := to_integer_no_string(t2, .Eq)
		return ok1 && ok2 && i1 == i2
	}
	switch type_tag(t1) {
	case VNIL, VFALSE, VTRUE:
		return true // nil==nil, false==false, true==true
	case VNUMINT:
		return int_value(t1) == int_value(t2)
	case VNUMFLT:
		return flt_value(t1) == flt_value(t2)
	case VSHRSTR, VLNGSTR:
		return luaS_eqstr(str_value(t1), str_value(t2))
	case:
		// Tables, closures, userdata, threads: raw equality is pointer identity.
		return t1.value_.gc == t2.value_.gc
	}
}

// ---------------------------------------------------------------------------
// ASCII character classes (locale-independent)
// ---------------------------------------------------------------------------
//
// Number parsing must not depend on the C locale, so we use Lua's own fixed ASCII
// notion of spaces/digits (reference Lua's lctype). These are file-private for
// now; the full ctype table lands in ctype.odin in a later phase.

@(private = "file")
is_space :: #force_inline proc "contextless" (c: byte) -> bool {
	// Space, tab, newline, vertical tab, form feed, carriage return -- C isspace.
	return c == ' ' || c == '\t' || c == '\n' || c == '\v' || c == '\f' || c == '\r'
}

@(private = "file")
is_digit :: #force_inline proc "contextless" (c: byte) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
is_xdigit :: #force_inline proc "contextless" (c: byte) -> bool {
	return is_digit(c) || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// The numeric value of a hex digit. Faithful to `luaO_hexavalue`; caller must
// have verified `c` is a hex digit.
hexavalue :: #force_inline proc "contextless" (c: byte) -> Byte {
	if is_digit(c) {
		return Byte(c - '0')
	}
	lower := c | 0x20 // ASCII lowercase
	return Byte(lower - 'a') + 10
}

// ---------------------------------------------------------------------------
// String -> number
// ---------------------------------------------------------------------------
//
// Locale note: reference Lua honors the current LC_NUMERIC decimal point when
// parsing and formatting numbers. Parsing is now locale-aware here: the decimal
// path defers to the C library's `strtod` (which reads the active locale radix)
// and, mirroring reference `l_str2d`, retries a failed parse with any '.' rewritten
// to `localeconv()->decimal_point` -- so `tonumber("3.4")` still works under a
// comma-radix locale like pt_BR. Formatting likewise rides the C library's
// snprintf in `number_to_str`, so it emits the locale radix too. In the default
// "C" locale the point is '.', keeping the common case byte-identical.

// Try to parse `s` as an integer, faithful to reference Lua's `l_str2int`.
// Accepts optional surrounding Lua-ASCII whitespace, an optional sign, and either
// a decimal run or an `0x`/`0X` hex run. Decimal overflow is rejected (so it can
// fall through to the float parser and become an inf); hex wraps mod 2^64 exactly
// like C unsigned arithmetic. The whole slice must be consumed (only trailing
// spaces allowed), which is also what rejects an embedded NUL byte.
@(private = "file")
str_to_int :: proc "contextless" (s: []byte) -> (Integer, bool) {
	MAX_BY_10 :: Unsigned(MAX_INTEGER / 10)
	MAX_LAST_D :: int(MAX_INTEGER % 10)

	i := 0
	n := len(s)
	for i < n && is_space(s[i]) {i += 1} 	// skip leading spaces

	neg := 0
	if i < n && s[i] == '-' {
		neg = 1
		i += 1
	} else if i < n && s[i] == '+' {
		i += 1
	}

	a: Unsigned = 0
	empty := true

	if i + 1 < n && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X') {
		// Hexadecimal: no overflow check -- reference Lua lets it wrap mod 2^64.
		i += 2
		for i < n && is_xdigit(s[i]) {
			a = a * 16 + Unsigned(hexavalue(s[i]))
			empty = false
			i += 1
		}
	} else {
		// Decimal: reject overflow so the caller can retry as a float.
		for i < n && is_digit(s[i]) {
			d := int(s[i] - '0')
			if a >= MAX_BY_10 && (a > MAX_BY_10 || d > MAX_LAST_D + neg) {
				return 0, false
			}
			a = a * 10 + Unsigned(d)
			empty = false
			i += 1
		}
	}

	for i < n && is_space(s[i]) {i += 1} 	// skip trailing spaces
	if empty || i != n {
		return 0, false // no digits, or leftover junk (incl. embedded NUL)
	}
	// Apply the sign in unsigned space so negating MIN_INTEGER can't overflow,
	// then reinterpret the bits as signed. `0 - a` is the wraparound negation.
	result := neg == 1 ? (0 - a) : a
	return u2s(result), true
}

// Assemble a hexadecimal floating-point numeral (like "0x1.8p3"), a faithful port
// of reference Lua's `lua_strx2number`. Returns the value, the index just past
// what it consumed, and whether anything valid was found. Kept in pure Odin (no
// platform strtod) so hex-float behavior doesn't vary by C library.
@(private = "file")
strx_to_number :: proc "contextless" (s: []byte) -> (Number, int, bool) {
	MAX_SIG_DIG :: 30

	n := len(s)
	i := 0
	for i < n && is_space(s[i]) {i += 1} 	// skip initial spaces

	neg := false
	if i < n && s[i] == '-' {
		neg = true
		i += 1
	} else if i < n && s[i] == '+' {
		i += 1
	}

	// Require the '0x'/'0X' prefix.
	if !(i + 1 < n && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
		return 0, 0, false
	}
	i += 2

	dot := lua_getlocaledecpoint() // reference honors the locale radix in hex too

	r: Number = 0.0 // mantissa accumulator
	sigdig := 0 // significant digits read
	nosigdig := 0 // leading zeros (non-significant)
	e := 0 // power-of-two exponent correction
	hasdot := false

	for i < n {
		c := s[i]
		if c == dot {
			if hasdot {break} 	// a second dot ends the numeral
			hasdot = true
		} else if is_xdigit(c) {
			if sigdig == 0 && c == '0' {
				nosigdig += 1
			} else {
				sigdig += 1
				if sigdig <= MAX_SIG_DIG {
					r = r * 16.0 + Number(hexavalue(c))
				} else {
					e += 1 // too many digits: count for the exponent only
				}
			}
			if hasdot {e -= 1} 	// a fractional digit lowers the exponent
		} else {
			break
		}
		i += 1
	}

	if nosigdig + sigdig == 0 {
		return 0, 0, false // no digits at all
	}

	end := i // valid up to here
	e *= 4 // each hex digit is 4 binary places

	// Optional binary exponent: 'p'/'P' then a signed decimal exponent.
	if i < n && (s[i] == 'p' || s[i] == 'P') {
		i += 1
		eneg := false
		if i < n && s[i] == '-' {
			eneg = true
			i += 1
		} else if i < n && s[i] == '+' {
			i += 1
		}
		if !(i < n && is_digit(s[i])) {
			return 0, 0, false // 'p' must be followed by at least one digit
		}
		exp1 := 0
		for i < n && is_digit(s[i]) {
			exp1 = exp1 * 10 + int(s[i] - '0')
			i += 1
		}
		if eneg {exp1 = -exp1}
		e += exp1
		end = i
	}

	if neg {r = -r}
	return libc.ldexp(r, i32(e)), end, true
}

// Return the current locale's decimal-point character (`localeconv()->decimal_point[0]`,
// exactly reference Lua's `lua_getlocaledecpoint`). In the default "C" locale this is
// '.'; under e.g. pt_BR it becomes ','. We fall back to '.' if the C library hands us
// an empty or null string, so parsing never breaks on a degenerate locale.
lua_getlocaledecpoint :: proc "contextless" () -> byte {
	lc := libc.localeconv()
	if lc != nil && lc.decimal_point != nil {
		dp := ([^]byte)(lc.decimal_point)
		if dp[0] != 0 {
			return dp[0]
		}
	}
	return '.'
}

// Run the C library's `strtod` over a byte slice and report the parsed value plus
// how many bytes it consumed (0 if it recognized nothing). Shared by the verbatim
// and locale-retry decimal attempts so both go through identical NUL-termination.
@(private = "file")
strtod_slice :: proc(s: []byte) -> (Number, int) {
	n := len(s)
	buf := make([]byte, n + 1, context.temp_allocator)
	copy(buf, s)
	buf[n] = 0
	base := raw_data(buf)
	endptr: [^]libc.char
	val := libc.strtod(cstring(base), &endptr)
	return val, int(uintptr(endptr) - uintptr(base))
}

// Convert one float spelling -- decimal or hex -- with a whole-string check,
// faithful to reference Lua's `l_str2dloc`. The decimal path defers to the C
// library's `strtod` (locale-aware); the hex path uses our pure-Odin
// `strx_to_number`. Either way the entire slice, bar trailing spaces, must be
// consumed. Returning ok=false is precisely what triggers the locale
// decimal-point retry in `str_to_double`.
@(private = "file")
str2dloc :: proc(s: []byte, mode: byte) -> (Number, bool) {
	val: Number
	end: int
	if mode == 'x' {
		ok: bool
		val, end, ok = strx_to_number(s)
		if !ok {
			return 0, false
		}
	} else {
		val, end = strtod_slice(s)
		if end == 0 {
			return 0, false
		}
	}
	for end < len(s) && is_space(s[end]) {end += 1}
	if end != len(s) {
		return 0, false
	}
	return val, true
}

// Parse `s` as a decimal or hexadecimal float, faithful to reference Lua's
// `l_str2d`. "inf"/"nan" spellings are rejected (Lua numerals never name them).
// We first try the string verbatim, then -- exactly like reference -- retry with
// any '.' rewritten to the current locale's decimal point. That retry is what lets
// `tonumber("3.4")` (or the hex `"0x.41"`) still parse while a comma-radix locale
// like pt_BR is active: the C library / our hex parser expect the locale radix, so
// we swap the source '.' for the ',' they want and parse again. Both attempts
// demand the whole slice (bar trailing spaces) be consumed.
@(private = "file")
str_to_double :: proc(s: []byte) -> (Number, bool) {
	n := len(s)

	// Classify by the first "special" character, mirroring the strpbrk(".xXnN").
	mode: byte = 0
	for c in s {
		if c == '.' || c == 'x' || c == 'X' || c == 'n' || c == 'N' {
			mode = c | 0x20 // lowercase
			break
		}
	}
	if mode == 'n' {
		return 0, false // reject 'inf'/'nan'
	}

	val, ok := str2dloc(s, mode)
	if !ok {
		dp := lua_getlocaledecpoint()
		dot := -1
		for c, i in s {
			if c == '.' {dot = i; break}
		}
		if dp != '.' && dot >= 0 {
			buf2 := make([]byte, n, context.temp_allocator)
			copy(buf2, s)
			buf2[dot] = dp
			val, ok = str2dloc(buf2, mode)
		}
	}
	return val, ok
}

// Convert a Lua source string to a number value, faithful to `luaO_str2num`:
// first try an integer, then a float. On success returns the parsed value and
// the "size" reference Lua reports -- the consumed length plus one (its callers
// compare this against `stringlength + 1` to demand a whole-string match). On
// failure returns a nil value and size 0.
str_to_number :: proc(s: []byte) -> (o: TValue, size: uint) {
	if iv, ok := str_to_int(s); ok {
		set_int(&o, iv)
		return o, uint(len(s)) + 1
	}
	if fv, ok := str_to_double(s); ok {
		set_float(&o, fv)
		return o, uint(len(s)) + 1
	}
	set_nil(&o)
	return o, 0
}

// ---------------------------------------------------------------------------
// Number -> string
// ---------------------------------------------------------------------------

// Format an integer into `buf` as base-10 ASCII, returning the byte length. Pure
// Odin -- integer formatting has no locale or precision subtleties to match. We
// build the digits in reverse into a scratch array (working in the UNSIGNED
// domain so MIN_INTEGER negates without overflowing) and copy them out.
@(private = "file")
integer_to_str :: proc "contextless" (buf: []byte, x: Integer) -> int {
	tmp: [20]byte // max i64 is 19 digits; sign handled separately
	neg := x < 0
	// Negate in unsigned space: 0 - (unsigned)x is the magnitude even for min.
	mag := neg ? (0 - s2u(x)) : s2u(x)

	pos := len(tmp)
	if mag == 0 {
		pos -= 1
		tmp[pos] = '0'
	} else {
		for mag != 0 {
			pos -= 1
			tmp[pos] = byte('0' + (mag % 10))
			mag /= 10
		}
	}

	out := 0
	if neg {
		buf[out] = '-'
		out += 1
	}
	for j := pos; j < len(tmp); j += 1 {
		buf[out] = tmp[j]
		out += 1
	}
	return out
}

// Format a float into `buf`, faithful to reference Lua's `tostringbuffFloat`.
// First try LUA_NUMBER_FMT ("%.15g"); read the text back and, if it doesn't
// round-trip to the same double, reformat with the higher-precision
// LUA_NUMBER_FMT_N ("%.17g"). Finally, if the result looks like a bare integer
// (only sign and digits -- no '.', 'e', 'inf', 'nan'), append ".0" so it stays
// recognizably a float. We use the C library for both the formatting and the
// read-back so the bytes match reference Lua exactly.
@(private = "file")
float_to_str :: proc "contextless" (buf: []byte, x: Number) -> int {
	cbuf := cast([^]libc.char)raw_data(buf)
	cap := libc.size_t(len(buf))

	length := int(libc.snprintf(cbuf, cap, NUMBER_FMT, x))
	check := libc.strtod(cstring(raw_data(buf)), nil)
	if check != x { 	// not enough precision to round-trip?
		length = int(libc.snprintf(cbuf, cap, NUMBER_FMT_N, x))
	}

	// "Looks like an integer" -> append ".0". We scan for the first character
	// that is neither a sign nor a digit; if that's the terminating position,
	// the whole numeral was just sign+digits.
	looks_integer := true
	for k := 0; k < length; k += 1 {
		c := buf[k]
		if !(c == '-' || is_digit(c)) {
			looks_integer = false
			break
		}
	}
	if looks_integer {
		buf[length] = '.'
		buf[length + 1] = '0'
		length += 2
	}
	return length
}

// Convert a number value to its string form in `buf`, returning the length.
// Faithful to `luaO_tostringbuff`. `buf` must be at least N2S_BUFF_SZ bytes.
number_to_str :: proc "contextless" (o: ^TValue, buf: []byte) -> int {
	if is_integer(o) {
		return integer_to_str(buf, o.value_.i)
	}
	return float_to_str(buf, o.value_.n)
}

// ---------------------------------------------------------------------------
// Raw arithmetic (state-free, no metamethods)
// ---------------------------------------------------------------------------
//
// The arithmetic operators, matching reference Lua's LUA_OP* order so future code
// (notably the compiler's constant folding) can index by them. This is the "raw"
// layer: it operates purely on values and never invokes metamethods or raises
// errors through a `State`. Instead it reports *why* it couldn't produce a plain
// numeric result, so higher layers can react (try a metamethod, or raise a
// runtime error) once they exist.

Arith_Op :: enum {
	Add  = 0,
	Sub  = 1,
	Mul  = 2,
	Mod  = 3,
	Pow  = 4,
	Div  = 5,
	IDiv = 6,
	Band = 7,
	Bor  = 8,
	Bxor = 9,
	Shl  = 10,
	Shr  = 11,
	Unm  = 12,
	Bnot = 13,
}

// Outcome of a raw arithmetic attempt.
Arith_Status :: enum {
	Ok, // produced a numeric result
	No_Number, // an operand wasn't a number (caller may try a metamethod)
	Div_By_Zero, // integer // or % by zero (caller raises a runtime error)
}

// Integer floor-division, faithful to `luaV_idiv`. Reports Div_By_Zero via `ok`.
@(private = "file")
int_idiv :: proc "contextless" (m, d: Integer) -> (Integer, bool) {
	// The (n)+1 <= 1 trick catches both 0 and -1 in one unsigned test.
	if s2u(d) + 1 <= 1 {
		if d == 0 {
			return 0, false // divide by zero
		}
		return int_neg(m), true // d == -1: avoid MIN_INTEGER/-1 overflow
	}
	q := m / d // C-style truncating division
	if (m ~ d) < 0 && m % d != 0 { 	// different signs and inexact -> floor is one less
		q -= 1
	}
	return q, true
}

// Integer modulus, faithful to `luaV_mod`. Reports "mod by zero" via `ok`.
@(private = "file")
int_mod :: proc "contextless" (m, d: Integer) -> (Integer, bool) {
	if s2u(d) + 1 <= 1 {
		if d == 0 {
			return 0, false // mod by zero
		}
		return 0, true // m % -1 == 0 (also dodges the overflow case)
	}
	r := m % d
	if r != 0 && (r ~ d) < 0 { 	// non-zero remainder with sign differing from divisor
		r += d
	}
	return r, true
}

// Logical/arithmetic shift, faithful to `luaV_shiftl` (shift-right is negate-y).
// Shifts are done in the unsigned domain, so right shifts are logical, exactly as
// reference Lua's `intop(>>, ...)` intends.
@(private = "file")
int_shift_left :: proc "contextless" (x, y: Integer) -> Integer {
	if y < 0 { 	// shift right
		if y <= -NBITS {
			return 0
		}
		return u2s(s2u(x) >> u64(-y))
	}
	// shift left
	if y >= NBITS {
		return 0
	}
	return u2s(s2u(x) << u64(y))
}

// Integer arithmetic dispatch, faithful to `intarith`. All wraparound operations
// go through the unsigned-domain helpers in limits.odin. `ok` is false only for
// division/modulo by zero.
@(private = "file")
int_arith :: proc "contextless" (op: Arith_Op, v1, v2: Integer) -> (Integer, bool) {
	switch op {
	case .Add:
		return int_add(v1, v2), true
	case .Sub:
		return int_sub(v1, v2), true
	case .Mul:
		return int_mul(v1, v2), true
	case .Mod:
		return int_mod(v1, v2)
	case .IDiv:
		return int_idiv(v1, v2)
	case .Band:
		return u2s(s2u(v1) & s2u(v2)), true
	case .Bor:
		return u2s(s2u(v1) | s2u(v2)), true
	case .Bxor:
		return u2s(s2u(v1) ~ s2u(v2)), true
	case .Shl:
		return int_shift_left(v1, v2), true
	case .Shr:
		return int_shift_left(v1, int_neg(v2)), true
	case .Unm:
		return int_neg(v1), true
	case .Bnot:
		// XOR with all-ones inverts the bits. Reference `intop(^, ~0, v1)` uses
		// the FIRST operand: unary bitwise-not is dispatched with the value as
		// v1 and a dummy v2, so we must invert v1.
		return u2s(MAX_UNSIGNED ~ s2u(v1)), true
	case .Pow, .Div:
		// These are float-only and never dispatched here.
		return 0, true
	}
	return 0, true
}

// A correct IEEE-754 double `fmod`, implemented in pure Odin.
//
// Why not `libc.fmod`? On at least one of our target toolchains (Windows/MSVC via
// Odin's `core:c/libc` binding) the linked `fmod` is broken for large magnitudes:
// `fmod(2^54, 3)` wrongly yields `0` instead of `1`, because that implementation
// falls back to the naive `x - trunc(x/y)*y` which loses all precision once `x`
// exceeds `2^53`. `core:math.mod` has the same flaw (`x - round(x/y)*y`). Faithful
// Lua semantics (and the PUC math.lua suite, which checks `2^i % 3` up to the float
// range) demand an exact remainder, so we compute it ourselves the classic way:
// long division on the raw significand bits, exactly as fdlibm/musl do. This is
// also nicely in the spirit of our std-lib-only mandate -- one less libc dependency.
//
// The remainder returned here has the SIGN OF `x` and satisfies `|result| < |y|`,
// matching C `fmod`. The Lua-visible sign correction (remainder takes the divisor's
// sign) is applied separately in `flt_mod` below.
num_fmod :: proc "contextless" (x, y: Number) -> Number {
	ux := transmute(u64)x
	uy := transmute(u64)y
	ex := int(ux >> 52) & 0x7ff // biased exponent of x
	ey := int(uy >> 52) & 0x7ff // biased exponent of y
	sx := ux >> 63 // sign bit of x
	uxi := ux

	// If y is zero, NaN, or infinite -- or x is NaN/infinite -- the result is NaN
	// (0/0 style), which we produce arithmetically so it carries the right payload.
	if (uy << 1) == 0 || ey == 0x7ff || ex == 0x7ff {
		return (x * y) / (x * y)
	}
	// |x| <= |y|: either x is already the remainder, or (if equal magnitude) 0.
	if (uxi << 1) <= (uy << 1) {
		if (uxi << 1) == (uy << 1) {
			return 0 * x // signed zero
		}
		return x
	}

	// Normalize x: turn its significand into an explicit-leading-1 mantissa and let
	// `ex` become the true (unbiased-ish) exponent used by the division loop below.
	if ex == 0 { // subnormal x
		i := uxi << 12
		for i >> 63 == 0 {
			ex -= 1
			i <<= 1
		}
		uxi <<= u64(-ex + 1)
	} else {
		uxi &= (~u64(0)) >> 12
		uxi |= u64(1) << 52
	}
	// Normalize y the same way.
	if ey == 0 { // subnormal y
		i := uy << 12
		for i >> 63 == 0 {
			ey -= 1
			i <<= 1
		}
		uy <<= u64(-ey + 1)
	} else {
		uy &= (~u64(0)) >> 12
		uy |= u64(1) << 52
	}

	// x mod y: repeated shift-and-subtract long division on the mantissas.
	for ex > ey {
		i := uxi - uy
		if i >> 63 == 0 { // no borrow: subtraction was valid
			if i == 0 {
				return 0 * x
			}
			uxi = i
		}
		uxi <<= 1
		ex -= 1
	}
	{
		i := uxi - uy
		if i >> 63 == 0 {
			if i == 0 {
				return 0 * x
			}
			uxi = i
		}
	}
	// Renormalize the remainder's leading 1 back into bit 52.
	for uxi >> 52 == 0 {
		uxi <<= 1
		ex -= 1
	}

	// Reassemble the double: bias the exponent (or shift down into subnormal range),
	// then restore x's sign.
	if ex > 0 {
		uxi -= u64(1) << 52
		uxi |= u64(ex) << 52
	} else {
		uxi >>= u64(-ex + 1)
	}
	uxi |= sx << 63
	return transmute(Number)uxi
}

// Float modulus, faithful to `luaV_modf` / `luai_nummod`: an `fmod` corrected so
// the remainder takes the sign of the divisor.
@(private = "file")
flt_mod :: proc "contextless" (a, b: Number) -> Number {
	m := num_fmod(a, b)
	if (m > 0 ? b < 0 : (m < 0 && b > 0)) {
		m += b
	}
	return m
}

// Float arithmetic dispatch, faithful to `numarith`.
@(private = "file")
flt_arith :: proc "contextless" (op: Arith_Op, v1, v2: Number) -> Number {
	switch op {
	case .Add:
		return v1 + v2
	case .Sub:
		return v1 - v2
	case .Mul:
		return v1 * v2
	case .Div:
		return v1 / v2
	case .Pow:
		// luai_numpow special-cases the common square to avoid calling pow().
		return v2 == 2 ? v1 * v1 : libc.pow(v1, v2)
	case .IDiv:
		return libc.floor(v1 / v2)
	case .Unm:
		return -v1
	case .Mod:
		return flt_mod(v1, v2)
	case .Band, .Bor, .Bxor, .Shl, .Shr, .Bnot:
		// Integer-only operators never reach here.
		return 0
	}
	return 0
}

// The raw arithmetic entry point, faithful to `luaO_rawarith`. It decides,
// per operator, whether to work in the integer or float domain:
//   * bitwise/shift ops need both operands to be integers (or integral floats);
//   * '/' and '^' always work in floats;
//   * everything else stays in integers when both operands are integers, else
//     promotes to floats.
// On success it writes `res` and returns Ok. If an operand isn't a number it
// returns No_Number (the VM will try a metamethod later); if an integer divide or
// modulo hits a zero divisor it returns Div_By_Zero (the VM raises an error).
raw_arith :: proc "contextless" (op: Arith_Op, p1, p2: ^TValue) -> (res: TValue, status: Arith_Status) {
	switch op {
	case .Band, .Bor, .Bxor, .Shl, .Shr, .Bnot:
		// Integer-only: operands must be integers or exactly-integral floats.
		i1, ok1 := to_integer_no_string(p1, .Eq)
		i2, ok2 := to_integer_no_string(p2, .Eq)
		if ok1 && ok2 {
			r, _ := int_arith(op, i1, i2) // never divides; ok is always true
			set_int(&res, r)
			return res, .Ok
		}
		return res, .No_Number

	case .Div, .Pow:
		// Float-only.
		n1, ok1 := to_number_no_string(p1)
		n2, ok2 := to_number_no_string(p2)
		if ok1 && ok2 {
			set_float(&res, flt_arith(op, n1, n2))
			return res, .Ok
		}
		return res, .No_Number

	case .Add, .Sub, .Mul, .Mod, .IDiv, .Unm:
		// Stay integer when both are integers; otherwise promote to float.
		if is_integer(p1) && is_integer(p2) {
			r, ok := int_arith(op, p1.value_.i, p2.value_.i)
			if !ok {
				return res, .Div_By_Zero
			}
			set_int(&res, r)
			return res, .Ok
		}
		n1, ok1 := to_number_no_string(p1)
		n2, ok2 := to_number_no_string(p2)
		if ok1 && ok2 {
			set_float(&res, flt_arith(op, n1, n2))
			return res, .Ok
		}
		return res, .No_Number
	}
	return res, .No_Number
}

// ---------------------------------------------------------------------------
// UTF-8 encoding
// ---------------------------------------------------------------------------
//
// Reference Lua's `luaO_utf8esc`. Encodes the code point `x` (an unsigned 32-bit
// value, so it accepts the full extended range Lua allows -- up to 6 bytes, wider
// than the Unicode maximum) into `buff` and returns how many bytes it wrote.
//
// The quirk to remember: the bytes are written *right-justified* at the tail of
// the buffer. The result occupies `buff[UTF8BUFFSZ - n ..< UTF8BUFFSZ]`, not the
// front. This mirrors the C original exactly (it fills from the low-order
// continuation byte backwards), and callers slice from the tail accordingly.

// The buffer size `luaO_utf8esc` needs: 8 bytes is enough for the widest (6-byte)
// encoding with room to spare. Reference Lua's `UTF8BUFFSZ`.
UTF8BUFFSZ :: 8

luaO_utf8esc :: proc "contextless" (buff: []byte, x: u32) -> int {
	n := 1 // number of bytes emitted so far
	if x < 0x80 {
		// Plain ASCII: a single byte, dropped at the very end of the buffer.
		buff[UTF8BUFFSZ - 1] = byte(x)
	} else {
		mfb: u32 = 0x3f // "maximum that fits" in the first byte, shrinks each round
		xx := x
		for {
			// Emit one 6-bit continuation byte (10xxxxxx), filling from the tail
			// backwards. Post-increment `n` mirrors the C `buff[UTF8BUFFSZ-(n++)]`.
			buff[UTF8BUFFSZ - n] = byte(0x80 | (xx & 0x3f))
			n += 1
			xx >>= 6
			mfb >>= 1
			if xx <= mfb {
				break
			}
		}
		// The leading byte carries the length in its high bits (~mfb<<1) plus the
		// remaining payload.
		buff[UTF8BUFFSZ - n] = byte((~mfb << 1) | xx)
	}
	return n
}

// ---------------------------------------------------------------------------
// Formatted string building: luaO_pushvfstring / luaO_pushfstring
// ---------------------------------------------------------------------------
//
// Reference Lua's `luaO_pushvfstring`/`luaO_pushfstring`. These build a Lua string
// from a restricted printf-style format and push it on the stack. Lua only uses a
// tiny subset of conversions internally -- %s %d %I %f %p %c %U %% -- so we
// implement exactly those, faithfully, and keep any unrecognized `%x` literally
// (which is what the reference does with its final `default` case).
//
// The tricky part faithful reproduction demands is memory safety: growing the
// accumulation buffer can trigger an allocation, which can fail. Reference Lua
// handles this without longjmp inside the formatter by recording an error flag and
// then materializing the final string under a *nested* protected call in
// `clearbuff`. We mirror that precisely so an out-of-memory mid-format frees the
// dynamic buffer and reports `.Err_Mem` to the enclosing boundary rather than
// leaking or corrupting the stack.

// The size of the on-stack scratch space inside `Buff_FS`. Reference Lua's
// `BUFVFS = LUA_IDSIZE + N2S_BUFF_SZ + 95`.
BUFVFS :: LUA_IDSIZE + N2S_BUFF_SZ + 95

// The formatting buffer. It starts life pointing at its own inline `space`; only
// if the result outgrows that does it switch to a heap block via the allocator.
Buff_FS :: struct {
	L:        ^Lua_State,
	b:        [^]u8, // current buffer (either &space[0] or a heap block)
	buffsize: uint, // capacity of `b`
	blen:     uint, // bytes used so far
	err:      int, // 0 = ok, 1 = allocation failed, 2 = length overflow
	space:    [BUFVFS]u8,
}

@(private = "file")
buff_init :: proc(L: ^Lua_State, buff: ^Buff_FS) {
	buff.L = L
	buff.b = ([^]u8)(&buff.space[0])
	buff.buffsize = BUFVFS
	buff.blen = 0
	buff.err = 0
}

// Append `length` bytes from `src` to the buffer, growing it if needed. On growth
// failure it sets `err` and stops appending -- it never throws, so the format loop
// can run to completion before the error is surfaced (exactly as reference Lua
// tolerates a failed `getbuff`).
@(private = "file")
buff_add :: proc(buff: ^Buff_FS, src: [^]u8, length: uint) {
	if buff.err != 0 || length == 0 {
		return
	}
	if buff.blen + length > buff.buffsize {
		// Need more room. Double until it fits, guarding against overflow just as
		// reference Lua does (it aborts with a "buffer too large" style error, which
		// we model with err == 2).
		newsize := buff.buffsize
		for newsize < buff.blen + length {
			if newsize >= MAX_SIZE / 2 {
				buff.err = 2
				return
			}
			newsize *= 2
		}
		L := buff.L
		is_static := buff.b == ([^]u8)(&buff.space[0])
		newblock: rawptr
		if is_static {
			// First move off the inline space: allocate fresh and copy what we have.
			newblock = state_realloc(L, nil, 0, newsize)
			if newblock == nil {
				buff.err = 1
				return
			}
			if buff.blen > 0 {
				libc.memcpy(newblock, rawptr(buff.b), buff.blen)
			}
		} else {
			// Already on the heap: a plain resize preserving the contents.
			newblock = state_realloc(L, rawptr(buff.b), buff.buffsize, newsize)
			if newblock == nil {
				buff.err = 1
				return
			}
		}
		buff.b = ([^]u8)(newblock)
		buff.buffsize = newsize
	}
	libc.memcpy(rawptr(&buff.b[buff.blen]), rawptr(src), length)
	buff.blen += length
}

// Append the decimal/float rendering of a single TValue via `number_to_str`,
// which routes through the platform C library for byte-identical output.
@(private = "file")
buff_add_num :: proc(buff: ^Buff_FS, o: ^TValue) {
	tmp: [N2S_BUFF_SZ]u8
	n := number_to_str(o, tmp[:])
	buff_add(buff, ([^]u8)(&tmp[0]), uint(n))
}

// The protected body that turns the finished buffer into an interned Lua string
// and pushes it. It runs under `run_protected` because `luaS_newlstr` can raise on
// OOM; catching it here lets `buff_clear` still free the dynamic buffer.
@(private = "file")
buff_push :: proc(L: ^Lua_State, ud: rawptr) -> Thread_Status {
	buff := (^Buff_FS)(ud)
	if buff.err == 1 {
		// Allocation failed mid-format: surface a memory error to this boundary.
		return throw(L, .Err_Mem)
	}
	if buff.err == 2 {
		// Length overflow: reference Lua appends "..." and carries on with a
		// truncated-but-valid string rather than failing outright.
		dots := "..."
		buff_add(buff, ([^]u8)(raw_data(dots)), 3)
	}
	ts := luaS_newlstr(L, buff.b, buff.blen)
	set_string(stack_value(L, L.top), ts)
	L.top += 1
	return .Ok
}

// Finalize the buffer: push the string under protection, then unconditionally free
// any heap block. Returns the pushed `^TString`, or nil if the protected push
// failed (memory error), matching reference `clearbuff`'s behavior.
@(private = "file")
buff_clear :: proc(buff: ^Buff_FS) -> ^TString {
	L := buff.L
	status := run_protected(L, buff_push, rawptr(buff))
	// Free the dynamic buffer if we ever left the inline space. This must happen
	// whether or not the push succeeded, so an OOM does not leak it.
	if buff.b != ([^]u8)(&buff.space[0]) {
		state_free(L, rawptr(buff.b), buff.buffsize)
	}
	if status != .Ok {
		return nil
	}
	return str_value(stack_value(L, L.top - 1))
}

// Coerce a format argument to the various primitive shapes the conversions need.
// Lua's C `va_arg` is untyped; Odin's `any` is typed, so we accept the handful of
// concrete types our call sites actually pass and fall back gracefully otherwise.
@(private = "file")
fmt_arg_to_string :: proc(a: any) -> string {
	switch v in a {
	case string:
		return v
	case cstring:
		return string(v)
	case ^TString:
		return string(str_slice(v))
	case []u8:
		return string(v)
	case:
		return "(null)" // reference Lua prints "(null)" for a NULL %s
	}
}

@(private = "file")
fmt_arg_to_int :: proc(a: any) -> i64 {
	switch v in a {
	case i64:
		return v
	case int:
		return i64(v)
	case i32:
		return i64(v)
	case u32:
		return i64(v)
	case u64:
		return i64(v)
	case u16:
		return i64(v)
	case i16:
		return i64(v)
	case u8:
		return i64(v)
	case i8:
		return i64(v)
	case rune:
		return i64(v)
	case:
		return 0
	}
}

@(private = "file")
fmt_arg_to_flt :: proc(a: any) -> f64 {
	switch v in a {
	case f64:
		return v
	case f32:
		return f64(v)
	case:
		return 0
	}
}

@(private = "file")
fmt_arg_to_ptr :: proc(a: any) -> rawptr {
	switch v in a {
	case rawptr:
		return v
	case:
		// Any typed pointer erases to its raw address in `any.data`.
		return a.data
	}
}

// The formatter proper. Scans `fmt`, copying literal runs verbatim and expanding
// each recognized `%` conversion by consuming the next positional argument.
luaO_pushvfstring :: proc(L: ^Lua_State, fmt: string, args: ..any) -> ^TString {
	buff: Buff_FS
	buff_init(L, &buff)
	ai := 0 // next argument index
	i := 0
	n := len(fmt)
	for i < n {
		// Copy the literal run up to the next '%'.
		j := i
		for j < n && fmt[j] != '%' {
			j += 1
		}
		if j > i {
			buff_add(&buff, ([^]u8)(raw_data(fmt[i:j])), uint(j - i))
		}
		if j >= n {
			break
		}
		// fmt[j] == '%'. A trailing lone '%' is kept literally.
		if j + 1 >= n {
			buff_add(&buff, ([^]u8)(raw_data(fmt[j:j + 1])), 1)
			break
		}
		spec := fmt[j + 1]
		switch spec {
		case 's':
			s := fmt_arg_to_string(args[ai]);ai += 1
			buff_add(&buff, ([^]u8)(raw_data(s)), uint(len(s)))
		case 'd', 'I':
			o: TValue
			set_int(&o, Integer(fmt_arg_to_int(args[ai])));ai += 1
			buff_add_num(&buff, &o)
		case 'f':
			o: TValue
			set_float(&o, Number(fmt_arg_to_flt(args[ai])));ai += 1
			buff_add_num(&buff, &o)
		case 'c':
			cbuf := [1]u8{byte(fmt_arg_to_int(args[ai]))};ai += 1
			buff_add(&buff, ([^]u8)(&cbuf[0]), 1)
		case 'p':
			p := fmt_arg_to_ptr(args[ai]);ai += 1
			pbuf: [N2S_BUFF_SZ]u8
			w := libc.snprintf(([^]libc.char)(&pbuf[0]), len(pbuf), "%p", p)
			if w > 0 {
				buff_add(&buff, ([^]u8)(&pbuf[0]), uint(w))
			}
		case 'U':
			x := u32(fmt_arg_to_int(args[ai]));ai += 1
			ubuf: [UTF8BUFFSZ]u8
			ln := luaO_utf8esc(ubuf[:], x)
			buff_add(&buff, ([^]u8)(&ubuf[UTF8BUFFSZ - ln]), uint(ln))
		case '%':
			pct := [1]u8{'%'}
			buff_add(&buff, ([^]u8)(&pct[0]), 1)
		case:
			// Unknown conversion: keep the two characters literally, exactly as
			// reference Lua's default branch does.
			buff_add(&buff, ([^]u8)(raw_data(fmt[j:j + 2])), 2)
		}
		i = j + 2
	}
	return buff_clear(&buff)
}

// The convenience wrapper. Reference Lua's `luaO_pushfstring` asserts the result is
// non-nil, but that assertion only holds because a failed format has already
// longjmp'd. Since our `luaO_pushvfstring` returns nil on a caught memory error, we
// re-raise it to the enclosing boundary here so callers see faithful error
// propagation.
luaO_pushfstring :: proc(L: ^Lua_State, fmt: string, args: ..any) -> ^TString {
	ts := luaO_pushvfstring(L, fmt, ..args)
	if ts == nil {
		throw(L, .Err_Mem)
	}
	return ts
}

// ---------------------------------------------------------------------------
// Chunk identifiers: luaO_chunkid
// ---------------------------------------------------------------------------
//
// Reference Lua's `luaO_chunkid`. Turns a source name into the short label Lua puts
// in error messages, honoring the leading marker byte:
//   '='  -> use the rest verbatim (a caller-supplied name), truncated if too long
//   '@'  -> a file name; too-long names are shown as "...<tail>"
//   else -> a literal chunk of source; shown as [string "first line..."]
// It writes into `out` (capacity should be `LUA_IDSIZE`) and returns the number of
// bytes written (no NUL is required by our callers, which slice by the return).
luaO_chunkid :: proc(out: []u8, source: string) -> int {
	RETS :: "..."
	PRE :: "[string \""
	POS :: "\"]"
	bufflen := len(out) // reference starts at LUA_IDSIZE
	srclen := len(source)
	w := 0 // bytes written into `out`

	// Small local helper to copy bytes into `out`, advancing `w`.
	put := proc(out: []u8, w: ^int, s: string) {
		for k in 0 ..< len(s) {
			out[w^] = s[k]
			w^ += 1
		}
	}

	// Reference reads `*source` -- the first byte, or the NUL terminator when
	// the source name is the empty string. An empty name is neither '=' nor
	// '@', so it takes the "string" branch below and renders as `[string ""]`.
	// We must NOT short-circuit here (an early `return 0` would drop the label).
	marker: u8 = 0
	body := ""
	bodylen := 0
	if srclen > 0 {
		marker = source[0]
		body = source[1:] // everything after the marker byte
		bodylen = srclen - 1
	}

	if marker == '=' { // literal, verbatim source name
		if bodylen < bufflen { // small enough: copy it all
			put(out, &w, body)
		} else { // truncate to fit
			put(out, &w, body[:bufflen - 1])
		}
	} else if marker == '@' { // a file name
		if bodylen <= bufflen - 1 { // (srclen-1 <= LUA_IDSIZE-1) small enough
			put(out, &w, body)
		} else { // add "..." before rendering the last part
			put(out, &w, RETS)
			bufflen -= len(RETS)
			keep := bufflen - 1 // keep the last (bufflen - 1) chars of the body
			put(out, &w, body[bodylen - keep:])
		}
	} else { // a chunk of literal source: [string "..."]
		// Find the first newline (Lua shows only the first line).
		nl := -1
		for k in 0 ..< srclen {
			if source[k] == '\n' {
				nl = k
				break
			}
		}
		put(out, &w, PRE)
		bufflen -= len(PRE) + len(RETS) + len(POS) + 1
		if srclen < bufflen && nl == -1 { // whole thing fits on one line
			put(out, &w, source)
		} else {
			// Show up to `bufflen` bytes, stopping at the first newline, then "...".
			limit := srclen
			if nl >= 0 && nl < limit {
				limit = nl
			}
			if bufflen < limit {
				limit = bufflen
			}
			put(out, &w, source[:limit])
			put(out, &w, RETS)
		}
		put(out, &w, POS)
	}
	return w
}
