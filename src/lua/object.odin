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
// The float<->string boundary is pure Odin. Decimal conversion uses
// `core:strconv`'s big-decimal fallback, which rounds halfway cases to even and
// therefore covers the full binary64 range, including subnormals. We put a thin
// Lua/C compatibility layer around it for the exact `%g` spelling rules.

import "base:intrinsics"
import "base:runtime"
import "core:math"
import "core:strconv"
import strconv_decimal "core:strconv/decimal"

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
// The `L` parameter is really a `^Lua_State`, but typing it that way here would
// make object.odin depend on state.odin, which in turn depends on this file. The
// stdlib works around it exactly as reference's C does with its forward
// declaration: every native function takes the pointer untyped and immediately
// recovers it with `state(Lp)`.
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
	f := math.floor(n)
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
// Locale note: this freestanding conversion layer deliberately fixes the radix
// character to '.'. Reference Lua can follow LC_NUMERIC through libc; without
// libc there is no process locale to consult, so we consistently use the C
// locale instead.

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

// Parse a hexadecimal floating-point numeral without ever accumulating into a
// float. We locate its highest set bit, then retain exactly the bits binary64 can
// store plus a guard bit and a sticky "anything else was nonzero" bit. That is
// enough information to perform IEEE-754 round-to-nearest, ties-to-even for
// normals, subnormals, underflow, and carry into infinity.
@(private = "file")
strx_to_number :: proc(s: []byte) -> (Number, int, bool) {
	n := len(s)
	i := 0
	for i < n && is_space(s[i]) {i += 1} 	// skip initial spaces

	neg := false
	if i < n && (s[i] == '-' || s[i] == '+') {
		neg = s[i] == '-'
		i += 1
	}

	if !(i + 1 < n && s[i] == '0' && (s[i + 1] == 'x' || s[i + 1] == 'X')) {
		return 0, 0, false
	}
	i += 2
	mant_start := i

	digits := 0
	digits_before_dot := 0
	first_nonzero := -1
	first_value: byte
	hasdot := false
	for i < n {
		c := s[i]
		if c == '.' {
			if hasdot {break} 	// a second dot ends the numeral
			hasdot = true
			digits_before_dot = digits
		} else if is_xdigit(c) {
			value := hexavalue(c)
			if first_nonzero < 0 && value != 0 {
				first_nonzero = digits
				first_value = value
			}
			digits += 1
		} else {
			break
		}
		i += 1
	}

	if digits == 0 {
		return 0, 0, false // no digits at all
	}
	if !hasdot {
		digits_before_dot = digits
	}
	mant_end := i

	explicit_exp := 0
	if i < n && (s[i] == 'p' || s[i] == 'P') {
		i += 1
		exp_neg := false
		if i < n && (s[i] == '-' || s[i] == '+') {
			exp_neg = s[i] == '-'
			i += 1
		}
		if !(i < n && is_digit(s[i])) {
			return 0, 0, false // 'p' must be followed by at least one digit
		}
		for i < n && is_digit(s[i]) {
			if explicit_exp < 100000 {
				explicit_exp = explicit_exp * 10 + int(s[i] - '0')
			}
			i += 1
		}
		if exp_neg {explicit_exp = -explicit_exp}
	}

	sign_bit := neg ? (u64(1) << 63) : 0
	if first_nonzero < 0 {
		return transmute(Number)sign_bit, i, true
	}

	highest_bit := 0
	for v := first_value; v > 1; v >>= 1 {
		highest_bit += 1
	}
	top_exp := explicit_exp +
		4 * (digits_before_dot - first_nonzero - 1) + highest_bit
	target_exp := top_exp - 52
	if target_exp < -1074 {
		target_exp = -1074
	}

	mant: u64
	guard := false
	sticky := false
	digit_index := 0
	bit_exp := top_exp
	started := false
	for c in s[mant_start:mant_end] {
		if !is_xdigit(c) {continue}
		value := hexavalue(c)
		if digit_index < first_nonzero {
			digit_index += 1
			continue
		}
		first_bit := 3
		if !started {
			first_bit = highest_bit
			started = true
		}
		for bit := first_bit; bit >= 0; bit -= 1 {
			set := value & (1 << uint(bit)) != 0
			if bit_exp >= target_exp {
				mant = (mant << 1) | u64(set ? 1 : 0)
			} else if bit_exp == target_exp - 1 {
				guard = set
			} else if set {
				sticky = true
			}
			bit_exp -= 1
		}
		digit_index += 1
	}
	if bit_exp >= target_exp {
		mant <<= uint(bit_exp - target_exp + 1)
		bit_exp = target_exp - 1
	}

	if guard && (sticky || mant & 1 != 0) {
		mant += 1
	}

	if top_exp < -1022 {
		if mant >= u64(1) << 52 {
			return transmute(Number)(sign_bit | (u64(1) << 52)), i, true
		}
		return transmute(Number)(sign_bit | mant), i, true
	}

	if mant == u64(1) << 53 {
		mant >>= 1
		top_exp += 1
	}
	if top_exp > 1023 {
		return transmute(Number)(sign_bit | 0x7ff0_0000_0000_0000), i, true
	}
	exp_field := u64(top_exp + 1023)
	bits := sign_bit | (exp_field << 52) | (mant & 0x000f_ffff_ffff_ffff)
	return transmute(Number)bits, i, true
}

// The pure-Odin runtime has no libc locale. This is intentionally the C locale.
lua_getlocaledecpoint :: proc "contextless" () -> byte {
	return '.'
}

// Parse the decimal prefix after Lua's ASCII leading-space handling. strconv's
// fast path handles small exact cases; difficult inputs fall back to an exact
// decimal representation which is shifted and rounded to nearest-even binary64.
// Its `ok` result also reports range overflow, whereas C parsing still returns inf,
// so syntax is checked here and range status is deliberately not used.
@(private = "file")
parse_decimal_slice :: proc "contextless" (s: []byte) -> (Number, int) {
	context = runtime.default_context()
	n := len(s)
	i := 0
	for i < n && is_space(s[i]) {i += 1}
	start := i
	if i < n && (s[i] == '+' || s[i] == '-') {i += 1}

	digits := 0
	for i < n && is_digit(s[i]) {i += 1; digits += 1}
	if i < n && s[i] == '.' {
		i += 1
		for i < n && is_digit(s[i]) {i += 1; digits += 1}
	}
	if digits == 0 {
		return 0, 0
	}
	if i < n && (s[i] == 'e' || s[i] == 'E') {
		i += 1
		if i < n && (s[i] == '+' || s[i] == '-') {i += 1}
		if i >= n || !is_digit(s[i]) {
			return 0, 0
		}
		for i < n && is_digit(s[i]) {i += 1}
	}

	// Do not use parse_f64_prefix's small-number fast path here: its chained
	// floating multiplications are excellent for general parsing but do not
	// promise byte-for-byte C-parser rounding on every boundary. Feeding the
	// validated token directly through strconv's exact decimal engine keeps all
	// source digits until its final nearest-even binary64 rounding step.
	d: strconv_decimal.Decimal
	strconv_decimal.set(&d, string(s[start:i]))
	info := strconv.Float_Info{mantbits = 52, expbits = 11, bias = -1023}
	bits, _ := strconv.decimal_to_float_bits(&d, &info)
	return transmute(Number)bits, i
}

// Convert one float spelling -- decimal or hex -- with a whole-string check,
// faithful to reference Lua's `l_str2dloc`. The decimal path defers to the C
// pure-Odin decimal or hexadecimal parser. Either way the entire slice, bar
// trailing spaces, must be consumed.
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
		val, end = parse_decimal_slice(s)
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
// The radix is always '.', our documented freestanding C-locale behavior.
@(private = "file")
str_to_double :: proc(s: []byte) -> (Number, bool) {
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

	return str2dloc(s, mode)
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

// Render an unsigned integer in hexadecimal. This small helper replaces the
// handful of fixed `%x`/`%p` calls outside string.format's general printf engine.
unsigned_to_hex_str :: proc "contextless" (
	buf: []byte,
	x: u64,
	uppercase := false,
	min_digits := 1,
) -> int {
	digits := uppercase ? "0123456789ABCDEF" : "0123456789abcdef"
	value := x
	tmp: [16]byte
	pos := len(tmp)
	for value != 0 || len(tmp) - pos < min_digits {
		pos -= 1
		tmp[pos] = digits[value & 15]
		value >>= 4
	}
	return copy(buf, tmp[pos:])
}

// MSVC's `%p` spelling (and therefore the Windows reference interpreter's) is
// an uppercase, zero-padded pointer-width hexadecimal number without `0x`.
pointer_to_str :: proc "contextless" (buf: []byte, p: rawptr) -> int {
	return unsigned_to_hex_str(buf, u64(uintptr(p)), true, size_of(uintptr) * 2)
}

// Produce the C99 `%a` spelling used by Lua's `%q`. The significand is derived
// directly from the IEEE-754 bits, so it is exact rather than a decimal
// conversion followed by another rounding. Subnormals are normalized just as
// the Windows CRT does (for example, the least subnormal is `0x1p-1074`).
number_to_hex_str :: proc "contextless" (buf: []byte, x: Number) -> int {
	hex_digits := "0123456789abcdef"
	bits := transmute(u64)x
	neg := bits >> 63 != 0
	exp_field := int((bits >> 52) & 0x7ff)
	frac := bits & 0x000f_ffff_ffff_ffff
	out := 0
	if neg {
		buf[out] = '-'
		out += 1
	}
	buf[out] = '0'
	buf[out + 1] = 'x'
	out += 2

	exponent := 0
	frac_digits := 0
	frac_bits := frac
	if exp_field == 0 {
		if frac == 0 {
			buf[out] = '0'
			out += 1
		} else {
			highest := 0
			v := frac
			for v > 1 {
				v >>= 1
				highest += 1
			}
			exponent = highest - 1074
			buf[out] = '1'
			out += 1
			frac_bits = frac ~ (u64(1) << uint(highest))
			frac_digits = (highest + 3) / 4
			frac_bits <<= uint(frac_digits * 4 - highest)
		}
	} else {
		exponent = exp_field - 1023
		buf[out] = '1'
		out += 1
		frac_digits = 13
	}

	for frac_digits > 0 && (frac_bits & 15) == 0 {
		frac_bits >>= 4
		frac_digits -= 1
	}
	if frac_digits > 0 {
		buf[out] = '.'
		out += 1
		shift := (frac_digits - 1) * 4
		for shift >= 0 {
			buf[out] = hex_digits[int((frac_bits >> uint(shift)) & 15)]
			out += 1
			shift -= 4
		}
	}

	buf[out] = 'p'
	out += 1
	if exponent < 0 {
		buf[out] = '-'
		exponent = -exponent
	} else {
		buf[out] = '+'
	}
	out += 1
	tmp: [4]byte
	pos := len(tmp)
	for {
		pos -= 1
		tmp[pos] = byte('0' + exponent % 10)
		exponent /= 10
		if exponent == 0 {break}
	}
	out += copy(buf[out:], tmp[pos:])
	return out
}

// Render C `%g` with precision P. `%g` uses scientific notation when the decimal
// exponent is below -4 or at least P; otherwise it uses fixed notation. In both
// forms insignificant trailing zeroes and a trailing radix point disappear, and
// scientific exponents contain a sign and at least two digits. Odin's strconv
// decimal engine implements those rules and exact halfway rounding; unlike its
// public spelling we remove the leading '+' required by that API.
// Format one finite binary64 value with Odin's correctly-rounded big-decimal
// engine. The returned spelling deliberately retains the leading sign which
// strconv emits for positive values; callers implementing printf need that sign
// in order to apply '+', space, and zero padding in the right order.
format_float_decimal :: proc "contextless" (
	buf: []byte,
	x: Number,
	fmt: byte,
	precision: int,
) -> int {
	context = runtime.default_context()
	return len(strconv.generic_ftoa(buf, f64(x), fmt, precision, 64))
}

@(private = "file")
format_g :: proc "contextless" (buf: []byte, x: Number, precision: int) -> int {
	text := buf[:format_float_decimal(buf, x, 'g', precision)]
	if len(text) > 0 && text[0] == '+' {
		copy(buf, text[1:])
		return len(text) - 1
	}
	return len(text)
}

// First try "%.15g": it gives Lua's pleasant short spelling for ordinary
// values such as 1.1. We parse those bytes back with the same correctly-rounded
// parser; only when they do not reproduce the original binary64 do we use
// "%.17g", which is sufficient to identify every double uniquely. Finally a
// bare sign-and-digits result receives ".0" so it remains visibly a float.
@(private = "file")
float_to_str :: proc "contextless" (buf: []byte, x: Number) -> int {
	context = runtime.default_context()
	bits := transmute(u64)x
	exp := (bits >> 52) & 0x7ff
	frac := bits & 0x000f_ffff_ffff_ffff
	if exp == 0x7ff {
		if frac == 0 {
			return copy(buf, bits >> 63 != 0 ? "-inf" : "inf")
		}
		// MSVC's `%g`, used by the Windows reference build, marks a negative
		// indefinite NaN this way. Positive NaNs are simply "nan".
		return copy(buf, bits >> 63 != 0 ? "-nan(ind)" : "nan")
	}

	length := format_g(buf, x, 15)
	check, _ := parse_decimal_slice(buf[:length])
	if check != x { 	// not enough precision to round-trip?
		length = format_g(buf, x, 17)
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
// This tiny helper is on the interpreter's hottest path. Growth of this large
// file previously made the optimiser stop inlining it, costing about 30% of
// arithmetic throughput, so the directive is load-bearing rather than stylistic.
@(private = "file")
int_arith :: #force_inline proc "contextless" (op: Arith_Op, v1, v2: Integer) -> (Integer, bool) {
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

// Pure-Odin elementary functions used by Lua's arithmetic and math library.
//
// Why not the obvious `core:math` sine, cosine, power, and exponential?  In the Odin
// version we build with, those four names are declarations of LLVM intrinsics.
// LLVM lowers the intrinsics to calls to the platform math library, so merely
// changing the spelling of the call would leave exactly the dependency we are
// trying to remove.  The code below is real arithmetic, not a differently
// spelled foreign call.  Its lineage is fdlibm/musl and the corresponding ports
// in Go's math package.
//
// Sine and cosine share fdlibm's rem-pi/2 reduction.  Medium arguments subtract
// three carefully split pieces of pi/2; huge arguments multiply base-2^24
// chunks by the relevant window of a long 2/pi expansion.  The result is kept
// as a two-double head and tail, then minimax kernels approximate sin and cos
// on [-pi/4,pi/4].
@(private = "file")
num_sincos_cephes :: proc "contextless" (xin: Number) -> (sine, cosine: Number) #no_bounds_check {
	PI4A :: 7.85398125648498535156e-1
	PI4B :: 3.77489470793079817668e-8
	PI4C :: 2.69515142907905952645e-15
	REDUCE_THRESHOLD :: 1 << 29

	bits := transmute(u64)xin
	abs_bits := bits & 0x7fff_ffff_ffff_ffff
	if abs_bits == 0 {
		return xin, 1 // preserve the sign of zero
	}
	if abs_bits >= 0x7ff0_0000_0000_0000 {
		if abs_bits > 0x7ff0_0000_0000_0000 {
			return xin, xin // preserve a NaN payload
		}
		nan := transmute(Number)u64(0x7ff8_0000_0000_0000)
		return nan, nan
	}

	x := transmute(Number)abs_bits
	sin_negative := bits >> 63 != 0
	cos_negative := false
	j: u64
	z: Number

	if x >= REDUCE_THRESHOLD {
		j, z = num_trig_reduce(x)
	} else {
		j = u64(x * (4 / 3.141592653589793238462643383279502884))
		y := Number(j)
		// Odd octants are represented relative to their far endpoint.  Moving
		// to that endpoint keeps the polynomial argument centered on zero.
		if j & 1 != 0 {
			j += 1
			y += 1
		}
		j &= 7
		z = ((x - y*PI4A) - y*PI4B) - y*PI4C
	}

	if j > 3 {
		j -= 4
		sin_negative = !sin_negative
		cos_negative = !cos_negative
	}
	if j > 1 {
		cos_negative = !cos_negative
	}

	zz := z * z
	// Cephes/fdlibm minimax kernels.  Written in Horner form, these are
	// z + z^3 P(z^2) and 1 - z^2/2 + z^4 Q(z^2).
	sin_poly := 1.58962301576546568060e-10
	sin_poly = sin_poly*zz - 2.50507477628578072866e-8
	sin_poly = sin_poly*zz + 2.75573136213857245213e-6
	sin_poly = sin_poly*zz - 1.98412698295895385996e-4
	sin_poly = sin_poly*zz + 8.33333333332211858878e-3
	sin_poly = sin_poly*zz - 1.66666666666666307295e-1
	sine = z + z*zz*sin_poly

	cos_poly := -1.13585365213876817300e-11
	cos_poly = cos_poly*zz + 2.08757008419747316778e-9
	cos_poly = cos_poly*zz - 2.75573141792967388112e-7
	cos_poly = cos_poly*zz + 2.48015872888517045348e-5
	cos_poly = cos_poly*zz - 1.38888888888730564116e-3
	cos_poly = cos_poly*zz + 4.16666666666665929218e-2
	cosine = 1.0 - 0.5*zz + zz*zz*cos_poly

	if j == 1 || j == 2 {
		sine, cosine = cosine, sine
	}
	if sin_negative {
		sine = -sine
	}
	if cos_negative {
		cosine = -cosine
	}
	return
}

// Payne-Hanek reduction by pi/4 used by the older compact kernel below.
// `x` is finite and positive.  The returned
// octant is modulo eight and `z` is the small residual in radians.
@(private = "file")
num_trig_reduce :: proc "contextless" (x: Number) -> (j: u64, z: Number) #no_bounds_check {
	@(static, rodata) four_over_pi := [20]u64 {
		0x0000000000000001, 0x45f306dc9c882a53,
		0xf84eafa3ea69bb81, 0xb6c52b3278872083,
		0xfca2c757bd778ac3, 0x6e48dc74849ba5c0,
		0x0c925dd413a32439, 0xfc3bd63962534e7d,
		0xd1046bea5d768909, 0xd338e04d68befc82,
		0x7323ac7306a673e9, 0x3908bf177bf25076,
		0x3ff12fffbc0b301f, 0xde5e2316b414da3e,
		0xda6cfd9e4f96136e, 0x9e8c7ecd3cbfd45a,
		0xea4f758fd7cbe2f6, 0x7a0e73ef14a525d4,
		0xd7f6bf623f1aba10, 0xac06608df8f6d757,
	}
	SHIFT :: 52
	BIAS :: 1023

	ix := transmute(u64)x
	exponent := int((ix >> SHIFT) & 0x7ff) - BIAS - SHIFT
	ix = (ix & 0x000f_ffff_ffff_ffff) | (u64(1) << SHIFT)

	digit := uint(exponent + 61) / 64
	shift := uint(exponent + 61) % 64
	// Odin defines an over-wide unsigned shift as zero.  That lets the same
	// expression cover the uncommon, but valid, shift==0 window boundary.
	z0 := (four_over_pi[digit] << shift) |
		(four_over_pi[digit+1] >> (64-shift))
	z1 := (four_over_pi[digit+1] << shift) |
		(four_over_pi[digit+2] >> (64-shift))
	z2 := (four_over_pi[digit+2] << shift) |
		(four_over_pi[digit+3] >> (64-shift))

	p2 := u128(z2) * u128(ix)
	p1 := u128(z1) * u128(ix)
	z2_hi := u64(p2 >> 64)
	z1_hi, z1_lo := u64(p1 >> 64), u64(p1)
	lo := z1_lo + z2_hi
	carry := u64(lo < z1_lo)
	hi := z0*ix + z1_hi
	old_hi := hi
	hi += carry
	_ = old_hi // addition modulo 2^64 is intentional

	j = hi >> 61
	hi = hi<<3 | lo>>61
	leading := uint(0)
	probe := hi
	for probe & (u64(1)<<63) == 0 {
		leading += 1
		probe <<= 1
	}
	e := u64(BIAS - (leading + 1))
	hi = (hi << (leading + 1)) | (lo >> (64-(leading+1)))
	hi >>= 12
	hi |= e << SHIFT
	z = transmute(Number)hi
	if j & 1 != 0 {
		j = (j + 1) & 7
		z -= 1
	}
	return j, z * (3.141592653589793238462643383279502884 / 4)
}

@(private = "file")
num_sin_kernel :: proc "contextless" (x, tail: Number) -> Number {
	S1 :: -1.66666666666666324348e-1
	S2 :: 8.33333333332248946124e-3
	S3 :: -1.98412698298579493134e-4
	S4 :: 2.75573137070700676789e-6
	S5 :: -2.50507602534068634195e-8
	S6 :: 1.58969099521155010221e-10
	z := x*x
	w := z*z
	r := S2 + z*(S3+z*S4) + z*w*(S5+z*S6)
	v := z*x
	return x - ((z*(0.5*tail-v*r)-tail)-v*S1)
}

@(private = "file")
num_cos_kernel :: proc "contextless" (x, tail: Number) -> Number {
	C1 :: 4.16666666666666019037e-2
	C2 :: -1.38888888888741095749e-3
	C3 :: 2.48015872894767294178e-5
	C4 :: -2.75573143513906633035e-7
	C5 :: 2.08757232129817482790e-9
	C6 :: -1.13596475577881948265e-11
	z := x*x
	w := z*z
	r := z*(C1+z*(C2+z*C3)) + w*w*(C4+z*(C5+z*C6))
	half_z := 0.5*z
	w = 1-half_z
	return w + (((1-w)-half_z)+(z*r-x*tail))
}

// The large fdlibm reducer works in base 2^24.  It multiplies only the window
// of 2/pi that can affect the low three quotient bits, then reconstructs the
// remainder as a two-double expansion.  Retaining that tail keeps results near enormous
// multiples of pi/2 accurate to the last bit.
@(private = "file")
num_rem_pio2_large :: proc "contextless" (input: [3]Number, nx, e0: int) -> (n: int, y0, y1: Number) #no_bounds_check {
	IPIO2 := [66]i32 {
		0xA2F983,0x6E4E44,0x1529FC,0x2757D1,0xF534DD,0xC0DB62,
		0x95993C,0x439041,0xFE5163,0xABDEBB,0xC561B7,0x246E3A,
		0x424DD2,0xE00649,0x2EEA09,0xD1921C,0xFE1DEB,0x1CB129,
		0xA73EE8,0x8235F5,0x2EBB44,0x84E99C,0x7026B4,0x5F7E41,
		0x3991D6,0x398353,0x39F49C,0x845F8B,0xBDF928,0x3B1FF8,
		0x97FFDE,0x05980F,0xEF2F11,0x8B5A0A,0x6D1F6D,0x367ECF,
		0x27CB09,0xB74F46,0x3F669E,0x5FEA2D,0x7527BA,0xC7EBE5,
		0xF17B3D,0x0739F7,0x8A5292,0xEA6BFB,0x5FB11F,0x8D5D08,
		0x560330,0x46FC7B,0x6BABF0,0xCFBC20,0x9AF436,0x1DA9E3,
		0x91615E,0xE61B08,0x659985,0x5F14A0,0x68408D,0xFFD880,
		0x4D7327,0x310606,0x1556CA,0x73A8C9,0x60E27B,0xC08C6B,
	}
	PIO2 := [5]Number {
		1.57079625129699707031e+0,
		7.54978941586159635335e-8,
		5.39030252995776476554e-15,
		3.28200341580791294123e-22,
		1.27065575308067607349e-29,
	}
	f, fq, q: [20]Number
	iq: [20]i32
	jk, jp := 4, 4
	jx := nx-1
	jv := (e0-3)/24
	if jv < 0 {
		jv = 0
	}
	q0 := e0-24*(jv+1)
	j := jv-jx
	m := jx+jk
	for i := 0; i <= m; i += 1 {
		f[i] = j < 0 ? 0 : Number(IPIO2[j])
		j += 1
	}
	for i := 0; i <= jk; i += 1 {
		fw := Number(0)
		for jj := 0; jj <= jx; jj += 1 {
			fw += input[jj]*f[jx+i-jj]
		}
		q[i] = fw
	}

	jz := jk
	ih := 0
	z := Number(0)
	for {
		z = q[jz]
		i, jj := 0, jz
		for jj > 0 {
			fw := Number(i32(math.ldexp(z, -24)))
			iq[i] = i32(z-16777216.0*fw)
			z = q[jj-1]+fw
			i += 1
			jj -= 1
		}
		z = math.ldexp(z, q0)
		z -= 8*math.floor(z*0.125)
		n = int(i32(z))
		z -= Number(n)
		ih = 0
		if q0 > 0 {
			i = int(iq[jz-1] >> uint(24-q0))
			n += i
			iq[jz-1] -= i32(i << uint(24-q0))
			ih = int(iq[jz-1] >> uint(23-q0))
		} else if q0 == 0 {
			ih = int(iq[jz-1] >> 23)
		} else if z >= 0.5 {
			ih = 2
		}
		if ih > 0 {
			n += 1
			carry := false
			for ii := 0; ii < jz; ii += 1 {
				value := iq[ii]
				if !carry {
					if value != 0 {
						carry = true
						iq[ii] = 0x1000000-value
					}
				} else {
					iq[ii] = 0xffffff-value
				}
			}
			if q0 == 1 {
				iq[jz-1] &= 0x7fffff
			} else if q0 == 2 {
				iq[jz-1] &= 0x3fffff
			}
			if ih == 2 {
				z = 1-z
				if carry {
					z -= math.ldexp(Number(1), q0)
				}
			}
		}

		need_more := false
		if z == 0 {
			bits := i32(0)
			for ii := jz-1; ii >= jk; ii -= 1 {
				bits |= iq[ii]
			}
			if bits == 0 {
				k := 1
				for iq[jk-k] == 0 {
					k += 1
				}
				for ii := jz+1; ii <= jz+k; ii += 1 {
					f[jx+ii] = Number(IPIO2[jv+ii])
					fw := Number(0)
					for jj := 0; jj <= jx; jj += 1 {
						fw += input[jj]*f[jx+ii-jj]
					}
					q[ii] = fw
				}
				jz += k
				need_more = true
			}
		}
		if !need_more {
			break
		}
	}

	if z == 0 {
		jz -= 1
		q0 -= 24
		for iq[jz] == 0 {
			jz -= 1
			q0 -= 24
		}
	} else {
		z = math.ldexp(z, -q0)
		if z >= 16777216 {
			fw := Number(i32(math.ldexp(z, -24)))
			iq[jz] = i32(z-16777216*fw)
			jz += 1
			q0 += 24
			iq[jz] = i32(fw)
		} else {
			iq[jz] = i32(z)
		}
	}

	fw := math.ldexp(Number(1), q0)
	for i := jz; i >= 0; i -= 1 {
		q[i] = fw*Number(iq[i])
		fw *= 1.0/16777216.0
	}
	for i := jz; i >= 0; i -= 1 {
		fw = 0
		for k := 0; k <= jp && k <= jz-i; k += 1 {
			fw += PIO2[k]*q[i+k]
		}
		fq[jz-i] = fw
	}
	fw = 0
	for i := jz; i >= 0; i -= 1 {
		fw += fq[i]
	}
	y0 = ih == 0 ? fw : -fw
	fw = fq[0]-fw
	for i := 1; i <= jz; i += 1 {
		fw += fq[i]
	}
	y1 = ih == 0 ? fw : -fw
	return n&7, y0, y1
}

@(private = "file")
num_rem_pio2_wide :: proc "contextless" (x: Number) -> (n: int, y0, y1: Number) {
	INVPIO2 :: 6.36619772367581382433e-1
	PIO2_1 :: 1.57079632673412561417e+0
	PIO2_2 :: 6.07710050630396597660e-11
	PIO2_3 :: 2.02226624871116645580e-21
	PIO2_3T :: 8.47842766036889956997e-32
	PIO4 :: 7.85398163397448278999e-1
	TOINT :: 6755399441055744.0

	fn := x*INVPIO2 + (x < 0 ? -TOINT : TOINT)
	fn -= x < 0 ? -TOINT : TOINT
	n = int(i32(fn))

	// PIO2_1 has 33 significant bits.  fdlibm therefore stops its ordinary
	// Cody-Waite path once n needs more than 20 bits: n*PIO2_1 would cease to
	// be exact.  Splitting the integer quotient at bit 12 leaves at most 19
	// significant bits in the high part and 12 in the low part, making every
	// product with each 33-bit pi/2 chunk exact all the way to n=2^31-1.
	// A rounded 2/pi product can be one integer off only when x is extremely
	// close to a half-way boundary.  Correct that quotient explicitly instead
	// of sending a rare but perfectly ordinary input to Payne-Hanek.
	for _ in 0..<2 {
		n_hi := (i64(n)>>12)<<12
		f_hi := Number(n_hi)
		f_lo := fn-f_hi
		hi, lo := x, Number(0)
		products := [8]Number{
			f_hi*PIO2_1, f_lo*PIO2_1,
			f_hi*PIO2_2, f_lo*PIO2_2,
			f_hi*PIO2_3, f_lo*PIO2_3,
			f_hi*PIO2_3T, f_lo*PIO2_3T,
		}
		for product in products {
			next := hi-product
			lo += (hi-next)-product
			hi = next
		}
		y0 = hi+lo
		y1 = hi-y0+lo
		if y0 >= -PIO4 && y0 <= PIO4 {
			return
		}
		adjust := y0 < 0 ? -1 : 1
		n += adjust
		fn += Number(adjust)
	}
	return
}

@(private = "file")
num_rem_pio2 :: proc "contextless" (x: Number) -> (n: int, y0, y1: Number) #no_bounds_check {
	PIO4 :: 7.85398163397448278999e-1
	INVPIO2 :: 6.36619772367581382433e-1
	PIO2_1 :: 1.57079632673412561417e+0
	PIO2_1T :: 6.07710050650619224932e-11
	PIO2_2 :: 6.07710050630396597660e-11
	PIO2_2T :: 2.02226624879595063154e-21
	PIO2_3 :: 2.02226624871116645580e-21
	PIO2_3T :: 8.47842766036889956997e-32
	TOINT :: 6755399441055744.0

	bits := transmute(u64)x
	ix := u32(bits>>32) & 0x7fff_ffff
	if ix < 0x4139_21fb {
		fn := x*INVPIO2 + (x < 0 ? -TOINT : TOINT)
		fn -= x < 0 ? -TOINT : TOINT
		n = int(i32(fn))
		r := x-fn*PIO2_1
		w := fn*PIO2_1T
		if r-w < -PIO4 {
			n -= 1; fn -= 1; r = x-fn*PIO2_1; w = fn*PIO2_1T
		} else if r-w > PIO4 {
			n += 1; fn += 1; r = x-fn*PIO2_1; w = fn*PIO2_1T
		}
		y0 = r-w
		ey := int((transmute(u64)y0>>52)&0x7ff)
		ex := int(ix>>20)
		if ex-ey > 16 {
			t := r
			w = fn*PIO2_2
			r = t-w
			w = fn*PIO2_2T-((t-r)-w)
			y0 = r-w
			ey = int((transmute(u64)y0>>52)&0x7ff)
			if ex-ey > 49 {
				t = r
				w = fn*PIO2_3
				r = t-w
				w = fn*PIO2_3T-((t-r)-w)
				y0 = r-w
			}
		}
		y1 = (r-y0)-w
		return
	}
	if ix < 0x41e9_21fb {
		return num_rem_pio2_wide(x)
	}

	normalized_bits := (bits & 0x000f_ffff_ffff_ffff) | (u64(1023+23)<<52)
	z := transmute(Number)normalized_bits
	pieces: [3]Number
	for i in 0..<2 {
		pieces[i] = Number(i32(z))
		z = (z-pieces[i])*16777216
	}
	pieces[2] = z
	nx := 3
	for pieces[nx-1] == 0 {
		nx -= 1
	}
	n, y0, y1 = num_rem_pio2_large(pieces, nx, int(ix>>20)-(1023+23))
	if bits>>63 != 0 {
		return -n, -y0, -y1
	}
	return
}

@(private = "file")
num_sincos :: proc "contextless" (x: Number) -> (sine, cosine: Number) {
	bits := transmute(u64)x
	ax := bits & 0x7fff_ffff_ffff_ffff
	if ax == 0 {
		return x, 1
	}
	if ax >= 0x7ff0_0000_0000_0000 {
		if ax > 0x7ff0_0000_0000_0000 {
			return x, x
		}
		nan := transmute(Number)u64(0x7ff8_0000_0000_0000)
		return nan, nan
	}
	if ax <= 0x3fe9_21fb_5444_2d18 {
		return num_sin_kernel(x, 0), num_cos_kernel(x, 0)
	}
	n, hi, lo := num_rem_pio2(x)
	s := num_sin_kernel(hi, lo)
	c := num_cos_kernel(hi, lo)
	switch n&3 {
	case 0: return s, c
	case 1: return c, -s
	case 2: return -s, -c
	case:   return -c, s
	}
}

num_sin :: proc "contextless" (x: Number) -> Number {
	bits := transmute(u64)x
	ax := bits & 0x7fff_ffff_ffff_ffff
	if ax == 0 {
		return x // preserve -0
	}
	if ax >= 0x7ff0_0000_0000_0000 {
		if ax > 0x7ff0_0000_0000_0000 {
			return x // preserve a NaN payload
		}
		return transmute(Number)u64(0x7ff8_0000_0000_0000)
	}

	// 0x3fe921fb54442d18 is pi/4 rounded to binary64.  The fdlibm sine
	// polynomial is proved for the whole interval [-pi/4, pi/4], so values in
	// this range need no quadrant calculation and, more importantly, no
	// subtraction of an approximate pi/2.  Skipping reduction is exact as a
	// routing decision: its error contribution is zero, while reducing here
	// would only add the rounding error of that unnecessary subtraction.
	if ax <= 0x3fe9_21fb_5444_2d18 {
		return num_sin_kernel(x, 0)
	}

	n, hi, lo := num_rem_pio2(x)
	if n&1 == 0 {
		s := num_sin_kernel(hi, lo)
		return n&2 == 0 ? s : -s
	}
	c := num_cos_kernel(hi, lo)
	return n&2 == 0 ? c : -c
}

num_cos :: proc "contextless" (x: Number) -> Number {
	bits := transmute(u64)x
	ax := bits & 0x7fff_ffff_ffff_ffff
	if ax == 0 {
		return 1
	}
	if ax >= 0x7ff0_0000_0000_0000 {
		if ax > 0x7ff0_0000_0000_0000 {
			return x // preserve a NaN payload
		}
		return transmute(Number)u64(0x7ff8_0000_0000_0000)
	}

	// This is the same direct-kernel boundary as sine: the exact binary64
	// encoding 0x3fe921fb54442d18 is pi/4 rounded to nearest.  fdlibm's cosine
	// kernel has a sub-ulp approximation bound throughout [-pi/4, pi/4], so
	// calling it directly contributes no argument-reduction error at all.
	// This matters especially for tiny inputs: the old shared sincos path also
	// evaluated the entire sine polynomial and discarded it, which was the
	// measured cosine asymmetry rather than an unavoidable cost of cosine.
	if ax <= 0x3fe9_21fb_5444_2d18 {
		return num_cos_kernel(x, 0)
	}

	n, hi, lo := num_rem_pio2(x)
	if n&1 == 0 {
		c := num_cos_kernel(hi, lo)
		return n&2 == 0 ? c : -c
	}
	s := num_sin_kernel(hi, lo)
	return n&2 == 0 ? -s : s
}

// fdlibm's tangent kernel is worth keeping separate from sin/cos.  Dividing two
// independently rounded kernels can lose a second ulp, especially near pi/2;
// this degree-27 odd polynomial carries the reduction tail directly and uses a
// compensated reciprocal for odd quadrants.
@(private = "file")
num_tan_kernel :: proc "contextless" (x_in, tail_in: Number, odd: bool) -> Number {
	@(static, rodata) T := [13]Number{
		3.33333333333334091986e-01, 1.33333333333201242699e-01,
		5.39682539762260521377e-02, 2.18694882948595424599e-02,
		8.86323982359930005737e-03, 3.59207910759131235356e-03,
		1.45620945432529025516e-03, 5.88041240820264096874e-04,
		2.46463134818469906812e-04, 7.81794442939557092300e-05,
		7.14072491382608190305e-05, -1.85586374855275456654e-05,
		2.59073051863633712884e-05,
	}
	PIO4 :: 7.85398163397448278999e-01
	PIO4_LO :: 3.06161699786838301793e-17
	x, tail := x_in, tail_in
	big := (transmute(u64)x & 0x7fff_ffff_0000_0000) >= 0x3fe5_9428_0000_0000
	negative := false
	if big {
		negative = x < 0
		if negative {
			x, tail = -x, -tail
		}
		x = (PIO4-x)+(PIO4_LO-tail)
		tail = 0
	}
	z := x*x
	w2 := z*z
	r := T[1]+w2*(T[3]+w2*(T[5]+w2*(T[7]+w2*(T[9]+w2*T[11]))))
	v := z*(T[2]+w2*(T[4]+w2*(T[6]+w2*(T[8]+w2*(T[10]+w2*T[12])))))
	s := z*x
	r = tail+z*(s*(r+v)+tail)+s*T[0]
	w := x+r
	if big {
		sign := odd ? Number(-1) : Number(1)
		value := sign-2*(x+(r-w*w/(w+sign)))
		return negative ? -value : value
	}
	if !odd {
		return w
	}
	w0 := transmute(Number)(transmute(u64)w & 0xffff_ffff_0000_0000)
	v = r-(w0-x)
	a := -1/w
	a0 := transmute(Number)(transmute(u64)a & 0xffff_ffff_0000_0000)
	return a0+a*(1+a0*w0+a0*v)
}

num_tan :: proc "contextless" (x: Number) -> Number {
	bits := transmute(u64)x
	ax := bits & 0x7fff_ffff_ffff_ffff
	if ax == 0 {
		return x
	}
	if ax >= 0x7ff0_0000_0000_0000 {
		s, c := num_sincos(x)
		return s/c
	}
	if ax <= 0x3fe9_21fb_5444_2d18 {
		return num_tan_kernel(x, 0, false)
	}
	n, hi, lo := num_rem_pio2(x)
	return num_tan_kernel(hi, lo, n&1 != 0)
}

// The scale can briefly have an exponent outside the binary64 range.  Arm's
// exp algorithm (the implementation used by current musl) repairs those two
// narrow edge bands before converting the constructed bits back to a double.
// The underflow side deliberately rounds at exponent zero before applying
// 2^-1022; that avoids the classic one-extra-rounding error in subnormals.
@(private = "file")
num_exp_special :: proc "contextless" (tmp: Number, sbits, ki: u64) -> Number {
	bits := sbits
	if u32(ki) & 0x8000_0000 == 0 {
		bits -= u64(1009) << 52
		scale := transmute(Number)bits
		return 5.486124068793689e303 * (scale + scale*tmp) // 2^1009
	}
	bits += u64(1022) << 52
	scale := transmute(Number)bits
	y := scale + scale*tmp
	if (y < 0 ? -y : y) < 1 {
		one := y < 0 ? Number(-1) : Number(1)
		lo := scale-y + scale*tmp
		hi := one+y
		lo = one-hi+y+lo
		y = (hi+lo)-one
		if y == 0 {
			y = transmute(Number)(bits & 0x8000_0000_0000_0000)
		}
	}
	return 2.2250738585072014e-308*y // 2^-1022
}

// Evaluate sign*exp(x+xtail).  This is Arm's 2018 table-driven exp, via musl:
//
//	x = k*(ln2/128) + r
//	exp(x) = 2^(k/128) * exp(r)
//
// A 128-entry table supplies a high scale and a tiny correction tail.  Since
// |r| is only ln(2)/256, four polynomial coefficients are enough.  Compared
// with fdlibm's one-entry reduction this trades 2 KiB of read-only data for a
// much shorter dependency chain while retaining musl's < 0.52 ulp bound.
@(private = "file")
num_exp_inline :: #force_inline proc "contextless" (x, xtail: Number, sign_bias: u64) -> Number #no_bounds_check {
	INV_LN2_N :: 1.4426950408889634 * 128
	NEG_LN2_HI_N :: -0.0054152123481117087
	NEG_LN2_LO_N :: -1.2864023111638346e-14
	SHIFT :: 6755399441055744.0
	C2 :: 0.49999999999996786
	C3 :: 0.16666666666665886
	C4 :: 0.0416666808410674
	C5 :: 0.008333335853059549

	x_bits := transmute(u64)x
	abstop := u32((x_bits >> 52) & 0x7ff)
	if abstop < 0x3c9 {
		one := Number(1)
		return sign_bias == 0 ? one : -one
	}
	if abstop >= 0x409 {
		if x_bits>>63 != 0 {
			return transmute(Number)(sign_bias == 0 ? u64(0) : u64(0x8000_0000_0000_0000))
		}
		return transmute(Number)(u64(0x7ff0_0000_0000_0000) |
			(sign_bias == 0 ? u64(0) : u64(0x8000_0000_0000_0000)))
	}
	z := INV_LN2_N*x
	kd := z+SHIFT
	ki := transmute(u64)kd
	kd -= SHIFT
	r := x + kd*NEG_LN2_HI_N + kd*NEG_LN2_LO_N + xtail
	idx := 2*(ki&127)
	top := (ki+sign_bias)<<45
	tail := transmute(Number)EXP_TABLE[idx]
	sbits := EXP_TABLE[idx+1]+top
	r2 := r*r
	tmp := tail+r+r2*(C2+r*C3)+r2*r2*(C4+r*C5)
	if abstop == 0 || abstop >= 0x408 {
		return num_exp_special(tmp, sbits, ki)
	}
	scale := transmute(Number)sbits
	return scale+scale*tmp
}

num_exp :: proc "contextless" (x: Number) -> Number {
	OVERFLOW :: 7.09782712893383973096e+02
	UNDERFLOW :: -7.45133219101941108420e+02
	ux := transmute(u64)x
	ax := ux & 0x7fff_ffff_ffff_ffff
	if ax > 0x7ff0_0000_0000_0000 {
		return x
	}
	if ax == 0x7ff0_0000_0000_0000 {
		return ux>>63 == 0 ? x : 0
	}
	if x > OVERFLOW {
		return transmute(Number)u64(0x7ff0_0000_0000_0000)
	}
	if x < UNDERFLOW {
		return 0
	}
	if ax < 0x3c90_0000_0000_0000 { // |x| < 2^-54
		return 1+x
	}
	return num_exp_inline(x, 0, 0)
}

@(private = "file")
num_pow_odd_integer :: proc "contextless" (x: Number) -> bool {
	ax := x < 0 ? -x : x
	if ax >= Number(u64(1)<<53) {
		// Beyond 2^53 every representable integral double is even.
		return false
	}
	whole, fraction := math.modf(ax)
	return fraction == 0 && (u64(whole) & 1) != 0
}

// Return log(x) as a rounded head plus a roughly 15-bit tail.  This is the log
// half of Arm's pow algorithm, as shipped by musl.  The normalized mantissa is
// split into 128 intervals.  Each table entry chooses c so that z/c-1 is tiny
// and, crucially, exactly representable after the non-FMA split below.
@(private = "file")
num_pow_log_inline :: #force_inline proc "contextless" (ix: u64) -> (result, tail: Number) #no_bounds_check {
	OFF :: u64(0x3fe6_9555_0000_0000)
	LN2_HI :: 0.6931471805598903
	LN2_LO :: 5.497923018708371e-14

	tmp := ix-OFF
	i := (tmp>>45)&127
	k := transmute(i64)tmp>>52
	iz := ix-(tmp&(u64(0xfff)<<52))
	z := transmute(Number)iz
	entry := POW_LOG_TABLE[i]

	// The FMA-free construction from musl: rounding z to 32 significant
	// mantissa bits makes rhi, rlo, and rhi^2 exact products.
	zhi := transmute(Number)((iz+(u64(1)<<31)) & 0xffff_ffff_0000_0000)
	zlo := z-zhi
	rhi := zhi*entry.invc-1
	rlo := zlo*entry.invc
	r := rhi+rlo
	kd := Number(k)
	t1 := kd*LN2_HI+entry.logc
	t2 := t1+r
	lo1 := kd*LN2_LO+entry.logctail
	lo2 := t1-t2+r
	ar := POW_LOG_POLY[0]*r
	ar2 := r*ar
	ar3 := r*ar2
	arhi := POW_LOG_POLY[0]*rhi
	arhi2 := rhi*arhi
	hi := t2+arhi2
	lo3 := rlo*(ar+arhi)
	lo4 := t2-hi+arhi2
	p := ar3*(POW_LOG_POLY[1]+r*POW_LOG_POLY[2]+
		ar2*(POW_LOG_POLY[3]+r*POW_LOG_POLY[4]+
		ar2*(POW_LOG_POLY[5]+r*POW_LOG_POLY[6])))
	lo := lo1+lo2+lo3+lo4+p
	result = hi+lo
	tail = hi-result+lo
	return
}

// Positive finite core of pow.  The log table above and the shared exp table
// replace fdlibm's general double-double path.  We still carry a head/tail
// product into exp, so large exponents do not magnify a rounded log.  Arm's
// published non-FMA error bound is about 0.54 ulp.
@(private = "file")
num_pow_positive :: #force_inline proc "contextless" (a, y: Number, negative_result: bool) -> Number {
	ix := transmute(u64)a
	if ix>>52 == 0 {
		// log_inline encodes negative exponents in the sign bit.  Scaling by
		// 2^52 normalizes every subnormal without losing a bit.
		ix = transmute(u64)(a*4503599627370496.0)
		ix -= u64(52)<<52
	}
	hi, lo := num_pow_log_inline(ix)

	// Dekker-style split used by musl when hardware FMA is unavailable.
	iy := transmute(u64)y
	yhi := transmute(Number)(iy & 0xffff_ffff_f800_0000)
	ylo := y-yhi
	lhi := transmute(Number)(transmute(u64)hi & 0xffff_ffff_f800_0000)
	llo := hi-lhi+lo
	ehi := yhi*lhi
	elo := ylo*lhi+y*llo
	sign_bias := negative_result ? u64(0x40000) : u64(0)
	return num_exp_inline(ehi, elo, sign_bias)
}

// Power needs more care than `exp(y*log(x))`: that tempting formula rounds exact
// powers, mishandles negative bases, and loses the signs of zero and infinity.
// fdlibm instead computes log2(|x|) as a high/low pair, multiplies both pieces
// by y, and evaluates 2^(high+low) with another split reduction.  In particular,
// representable integer powers such as 2^53 and 2^1023 are assembled exactly.
num_pow :: proc "contextless" (x, y: Number) -> Number {
	ux, uy := transmute(u64)x, transmute(u64)y
	ax, ay := ux & 0x7fff_ffff_ffff_ffff, uy & 0x7fff_ffff_ffff_ffff
	inf_bits :: u64(0x7ff0_0000_0000_0000)
	nan_bits :: u64(0x7ff8_0000_0000_0000)

	if ay == 0 || x == 1 {
		return 1
	}
	if y == 1 {
		return x
	}
	if ax > inf_bits || ay > inf_bits {
		return transmute(Number)nan_bits
	}
	if ax == 0 {
		if y < 0 {
			if ux >> 63 != 0 && num_pow_odd_integer(y) {
				return transmute(Number)u64(0xfff0_0000_0000_0000)
			}
			return transmute(Number)inf_bits
		}
		if ux >> 63 != 0 && num_pow_odd_integer(y) {
			return x
		}
		return 0
	}
	if ay == inf_bits {
		if x == -1 {
			return 1
		}
		if ((x < 0 ? -x : x) < 1) == (uy >> 63 == 0) {
			return 0
		}
		return transmute(Number)inf_bits
	}
	if ax == inf_bits {
		if ux >> 63 != 0 {
			// pow(-inf,y) has the same magnitude/sign rules as pow(-0,-y).
			zero := transmute(Number)u64(0x8000_0000_0000_0000)
			return num_pow(zero, -y)
		}
		return y < 0 ? 0 : transmute(Number)inf_bits
	}
	if y == 0.5 {
		return math.sqrt(x)
	}
	if y == -0.5 {
		return 1 / math.sqrt(x)
	}
	if y == 1.5 && x > 0 {
		// x^(3/2) is both common and exactly reducible to the already-fast,
		// correctly rounded square root plus one multiply.
		return x*math.sqrt(x)
	}

	if x < 0 {
		_, fraction := math.modf(y < 0 ? -y : y)
		if fraction != 0 {
			return transmute(Number)nan_bits
		}
		if x == -1 {
			return num_pow_odd_integer(y) ? -1 : 1
		}
		return num_pow_positive(-x, y, num_pow_odd_integer(y))
	}
	return num_pow_positive(x, y, false)
}

// A correct IEEE-754 double `fmod`, implemented in pure Odin.
//
// Why not the C-runtime fmod? On at least one target toolchain (Windows/MSVC via
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

// Float arithmetic dispatch, faithful to `numarith`. This tiny helper is on the
// interpreter's hottest path. Growth of this large file previously made the
// optimiser stop inlining it, costing about 30% of arithmetic throughput, so
// the directive is load-bearing rather than stylistic.
@(private = "file")
flt_arith :: #force_inline proc "contextless" (op: Arith_Op, v1, v2: Number) -> Number {
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
		// Reference Lua already special-cases squares.  Cubes are just as
		// common in numeric code and two hardware multiplies preserve all IEEE
		// signs/special values, so avoid the general logarithm there too.
		if v2 == 2 {
			return v1*v1
		}
		if v2 == 3 {
			return v1*v1*v1
		}
		return num_pow(v1, v2)
	case .IDiv:
		return math.floor(v1 / v2)
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
// This small dispatcher is on the interpreter's hottest path. Growth of this
// large file previously made the optimiser stop inlining it, costing about 30%
// of arithmetic throughput, so the directive is load-bearing rather than stylistic.
raw_arith :: #force_inline proc "contextless" (op: Arith_Op, p1, p2: ^TValue) -> (res: TValue, status: Arith_Status) {
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
				intrinsics.mem_copy_non_overlapping(newblock, rawptr(buff.b), int(buff.blen))
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
	intrinsics.mem_copy_non_overlapping(rawptr(&buff.b[buff.blen]), rawptr(src), int(length))
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
			w := pointer_to_str(pbuf[:], p)
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
