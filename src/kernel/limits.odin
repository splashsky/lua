package kernel
// limits.odin -- our analogue of reference Lua's `llimits.h`.
//
// The bedrock types and numeric limits everything else is built on: the
// concrete C-equivalent integer/float types for Lua values, instruction words,
// byte counts, and the assorted MIN/MAX bounds the kernel relies on. Getting
// these exactly right is a correctness matter -- the whole value model, the VM's
// arithmetic, and the bytecode format all inherit their behavior from here.
//
// Reference Lua leaves these choosable via `luaconf.h`; we deliberately pin them
// to Lua 5.5's most common 64-bit configuration (see docs/ARCHITECTURE.md), so
// the values, arithmetic, and bytecode ABI are fixed and byte-reproducible.

import "base:intrinsics"

// ---------------------------------------------------------------------------
// Fundamental value types
// ---------------------------------------------------------------------------

// `Integer` is Lua's integer subtype (`lua_Integer`): a 64-bit signed integer.
// `Number` is Lua's float subtype (`lua_Number`): IEEE-754 binary64 (a double).
// `Unsigned` is the matching unsigned integer (`lua_Unsigned`) we lean on for
// the wraparound arithmetic Lua's integers are defined to perform.
Integer :: i64
Number :: f64
Unsigned :: u64

// A single bytecode word (`Instruction`). Fixed at 32 bits by our ABI so dumped
// bytecode is portable and byte-identical across platforms.
Instruction :: u32

// `Byte` is Lua's `lu_byte`: the unsigned byte used for tags, marks, and small
// counts throughout the kernel. `SByte` is the signed counterpart (`ls_byte`).
Byte :: u8
SByte :: i8

// `L_Mem` / `Lu_Mem` mirror reference Lua's `l_mem` / `lu_mem`: a signed and an
// unsigned integer wide enough to count every byte the kernel might allocate.
// Pinned to 64-bit so the GC's debt/threshold bookkeeping never overflows.
L_Mem :: i64
Lu_Mem :: u64

// `U32` matches reference Lua's `l_uint32`: an exactly-32-bit unsigned integer
// used in a few places (string hashing, parameter encoding) that want that
// precise width regardless of the native int size.
U32 :: u32

// ---------------------------------------------------------------------------
// Numeric limits
// ---------------------------------------------------------------------------

// The bounds of the integer subtype, and the largest unsigned value. These come
// straight from the two's-complement 64-bit representation we pinned above.
MAX_INTEGER :: max(Integer) // 0x7fff_ffff_ffff_ffff
MIN_INTEGER :: min(Integer) // -0x8000_0000_0000_0000
MAX_UNSIGNED :: max(Unsigned) // 0xffff_ffff_ffff_ffff

// The ceiling on a single memory request. Reference Lua keeps two related
// bounds (llimits.h):
//   MAX_SIZET -- the largest value the platform size type can hold (2^64-1 on
//                our 64-bit target). Used to catch multiplication overflow when
//                sizing arrays (luaM_testsize divides MAX_SIZET by the element
//                size), because that product must fit the machine's size type.
//   MAX_SIZE  -- min(MAX_SIZET, MAX_INTEGER) = 2^63-1 here. The largest size Lua
//                will treat as a valid *object* size, so every object size also
//                fits in a lua_Integer.
MAX_SIZET :: uint(max(uint))
MAX_SIZE :: uint(MAX_INTEGER)

// The largest `L_Mem`, mirroring reference Lua's `MAX_LMEM`. Used later by the
// GC and by the floating-point-byte parameter helpers (codeparam/applyparam).
MAX_LMEM :: max(L_Mem)

// ---------------------------------------------------------------------------
// Bit-width helpers
// ---------------------------------------------------------------------------

// `l_numbits(T)` is the number of value bits in a type -- reference Lua's
// `l_numbits`, i.e. `sizeof(t) * CHAR_BIT`. We phrase it as a generic so callers
// read naturally: `num_bits(Integer)` is 64.
num_bits :: #force_inline proc "contextless" ($T: typeid) -> int {
	return size_of(T) * 8
}

// `NBITS` is the shift-relevant width of the integer subtype (64), matching the
// `NBITS` macro used by Lua's shift operators.
NBITS :: 8 * size_of(Integer)

// `is_pow2(x)` reports whether an unsigned value is a power of two -- reference
// Lua's `ispow2`. Note we match reference exactly, including its quirk that ZERO
// counts as a power of two (`(0 & (0-1)) == 0`): callers rely on that behavior.
// Handy for table sizing later.
is_pow2 :: #force_inline proc "contextless" (x: Unsigned) -> bool {
	return (x & (x - 1)) == 0
}

// ---------------------------------------------------------------------------
// ceil(log2(x))
// ---------------------------------------------------------------------------

// `ceil_log2(x)` returns the smallest n such that x <= (1 << n), matching
// reference Lua's `luaO_ceillog2` (lobject.c). Tables and a few other structures
// size themselves in powers of two using this. We keep the same 256-entry lookup
// table so the results are bit-for-bit identical, including the `x--` at entry
// (so ceil_log2(1)==0, ceil_log2(2)==1, ceil_log2(3)==2, ...).
@(private = "file")
CEIL_LOG2_TABLE := [256]Byte{
	0, 1, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 4, 4, 4, 4, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5, 5,
	6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6, 6,
	7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
	7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7, 7,
	8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
	8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
	8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
	8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8, 8,
}

ceil_log2 :: proc "contextless" (x: U32) -> Byte {
	// The table is indexed by (value - 1), so subtract one up front exactly as
	// reference Lua does. We consume the value one byte at a time, adding 8 for
	// each full byte shifted out, then finish with the low-byte lookup.
	l := 0
	v := x - 1
	for v >= 256 {
		l += 8
		v >>= 8
	}
	return Byte(l + int(CEIL_LOG2_TABLE[v]))
}

// ---------------------------------------------------------------------------
// Wraparound integer primitives
// ---------------------------------------------------------------------------

// Lua's integers are defined to wrap on overflow (two's-complement), and the
// reference implementation guarantees this by doing the math on the *unsigned*
// type and casting back (`intop` in lvm.h: `l_castU2S(l_castS2U(v1) op l_castS2U(v2))`).
// We reproduce that exactly: compute in `Unsigned`, then transmute the bit
// pattern back to `Integer`. Transmute (not a checked cast) is what preserves
// the wraparound bits without any range fuss.

s2u :: #force_inline proc "contextless" (x: Integer) -> Unsigned {
	return transmute(Unsigned)x
}

u2s :: #force_inline proc "contextless" (x: Unsigned) -> Integer {
	return transmute(Integer)x
}

int_add :: #force_inline proc "contextless" (a, b: Integer) -> Integer {
	return u2s(s2u(a) + s2u(b))
}

int_sub :: #force_inline proc "contextless" (a, b: Integer) -> Integer {
	return u2s(s2u(a) - s2u(b))
}

int_mul :: #force_inline proc "contextless" (a, b: Integer) -> Integer {
	return u2s(s2u(a) * s2u(b))
}

int_neg :: #force_inline proc "contextless" (a: Integer) -> Integer {
	return u2s(0 - s2u(a))
}
