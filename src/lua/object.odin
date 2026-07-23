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
// `CommonHeader` / `GCObject`. Concrete objects (TString, Table, ...) embed this
// as their first field so a `^GCObject` can point at any of them.
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

// Collapse a pointer to a 32-bit unsigned integer for hashing -- reference Lua's
// `point2uint`. We only ever feed the result into a hash function, so truncating
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
// Reference Lua's `tonumberns` minus the string case (strings need interning,
// which arrives in a later phase).
// TODO(phase-4+): add string coercion once TString exists.
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
// parsing (l_str2d's radix-retry) and formatting (appending the locale radix in
// tostringbuffFloat). We hardcode '.' throughout, which is exactly faithful in
// the "C" locale. This is a *deliberate* deferral, not an oversight: the locale
// can only change via os.setlocale, which doesn't exist until the standard-
// library phase, so before then the decimal point is always '.'. When
// os.setlocale lands, wire the radix through localeconv() here and in
// float_to_str, and reproduce l_str2d's copy-and-retry.
// TODO(phase-9/stdlib): locale-aware decimal point once os.setlocale exists.

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

	r: Number = 0.0 // mantissa accumulator
	sigdig := 0 // significant digits read
	nosigdig := 0 // leading zeros (non-significant)
	e := 0 // power-of-two exponent correction
	hasdot := false

	for i < n {
		c := s[i]
		if c == '.' {
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

// Parse `s` as a decimal or hexadecimal float, faithful to reference Lua's
// `l_str2d`. "inf"/"nan" spellings are rejected (Lua numerals never name them).
// The decimal path defers to the C library's `strtod` (matching reference Lua's
// `lua_str2number`); the hex path uses our pure-Odin `strx_to_number`. The whole
// slice must be consumed apart from trailing spaces.
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

	val: Number
	end: int
	if mode == 'x' {
		ok: bool
		val, end, ok = strx_to_number(s)
		if !ok {
			return 0, false
		}
	} else {
		// Decimal via C strtod on a NUL-terminated copy. strtod reports how far it
		// got via endptr, which we turn back into a slice index.
		buf := make([]byte, n + 1, context.temp_allocator)
		copy(buf, s)
		buf[n] = 0
		base := raw_data(buf)
		endptr: [^]libc.char
		val = libc.strtod(cstring(base), &endptr)
		end = int(uintptr(endptr) - uintptr(base))
		if end == 0 {
			return 0, false // nothing recognized
		}
	}

	// Only trailing whitespace may follow the number.
	for end < n && is_space(s[end]) {end += 1}
	if end != n {
		return 0, false
	}
	return val, true
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

// Float modulus, faithful to `luaV_modf` / `luai_nummod`: an `fmod` corrected so
// the remainder takes the sign of the divisor.
@(private = "file")
flt_mod :: proc "contextless" (a, b: Number) -> Number {
	m := libc.fmod(a, b)
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
