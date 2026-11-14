package tests

// arith_test.odin -- Phase 1 tests for the raw arithmetic layer (object.odin).
//
// The raw arithmetic is what the compiler will use to constant-fold, so its
// results must exactly match reference Lua's defined integer/float semantics:
// two's-complement wraparound, floor division/modulo, logical shifts, and the
// integer-vs-float domain rules. These tests check those defined behaviors.

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

@(private = "file")
ival :: proc(x: kernel.Integer) -> kernel.TValue {
	v: kernel.TValue
	kernel.set_int(&v, x)
	return v
}

@(private = "file")
fval :: proc(x: kernel.Number) -> kernel.TValue {
	v: kernel.TValue
	kernel.set_float(&v, x)
	return v
}

// Keep the black-box Lua conformance chunk in the normal Odin suite instead of
// letting it quietly rot as an unreferenced file. Loading the file through the
// public auxiliary API also checks the same parser/VM/library path an embedding
// application uses; a direct raw_arith-only test would miss the diagnostic bug
// this chunk is meant to guard.
@(test)
arithmetic_semantics_chunk :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	if L == nil {
		return
	}
	defer kernel.close_state(L)
	stdlib.aux_openlibs(L)

	status := stdlib.aux_loadfilex(L, "tests/arithmetic_semantics.lua")
	if status == .Ok {
		status = kernel.api_pcall(L, 0, 0, 0)
	}
	if status != .Ok {
		message, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "arithmetic_semantics.lua failed: %s", message)
	}
}

// Run raw_arith on two integer operands, expecting an integer result.
@(private = "file")
ii :: proc(op: kernel.Arith_Op, a, b: kernel.Integer) -> (kernel.Integer, kernel.Arith_Status) {
	x, y := ival(a), ival(b)
	res, st := kernel.raw_arith(op, &x, &y)
	return kernel.int_value(&res), st
}

@(test)
integer_arithmetic_wraps :: proc(t: ^testing.T) {
	// Two's-complement wraparound on overflow, exactly as Lua defines it.
	r, st := ii(.Add, kernel.MAX_INTEGER, 1)
	testing.expect(t, st == .Ok && r == kernel.MIN_INTEGER)

	r, _ = ii(.Sub, kernel.MIN_INTEGER, 1)
	testing.expect_value(t, r, kernel.MAX_INTEGER)

	r, _ = ii(.Mul, kernel.MIN_INTEGER, -1) // 2^63 wraps back to MIN_INTEGER
	testing.expect_value(t, r, kernel.MIN_INTEGER)

	r, _ = ii(.Unm, kernel.MIN_INTEGER, 0) // negating MIN_INTEGER wraps to itself
	testing.expect_value(t, r, kernel.MIN_INTEGER)
}

@(test)
integer_floor_division :: proc(t: ^testing.T) {
	// Lua's // is floor division, which differs from C truncation for mixed signs.
	cases := []struct {
		a, b, want: kernel.Integer,
	}{{7, 2, 3}, {-7, 2, -4}, {7, -2, -4}, {-7, -2, 3}, {6, 3, 2}}
	for c in cases {
		r, st := ii(.IDiv, c.a, c.b)
		testing.expectf(t, st == .Ok && r == c.want, "%v // %v = %v (want %v)", c.a, c.b, r, c.want)
	}

	// MIN_INTEGER // -1 must not trap; it wraps to MIN_INTEGER.
	r, st := ii(.IDiv, kernel.MIN_INTEGER, -1)
	testing.expect(t, st == .Ok && r == kernel.MIN_INTEGER)

	// Division by zero is reported, not crashed.
	_, st = ii(.IDiv, 1, 0)
	testing.expect(t, st == .Div_By_Zero)
}

@(test)
integer_modulo :: proc(t: ^testing.T) {
	// The result takes the sign of the divisor (floor-mod).
	cases := []struct {
		a, b, want: kernel.Integer,
	}{{7, 3, 1}, {-7, 3, 2}, {7, -3, -2}, {-7, -3, -1}}
	for c in cases {
		r, st := ii(.Mod, c.a, c.b)
		testing.expectf(t, st == .Ok && r == c.want, "%v %% %v = %v (want %v)", c.a, c.b, r, c.want)
	}

	// MIN_INTEGER % -1 == 0 (and must not trap).
	r, st := ii(.Mod, kernel.MIN_INTEGER, -1)
	testing.expect(t, st == .Ok && r == 0)

	_, st = ii(.Mod, 1, 0)
	testing.expect(t, st == .Div_By_Zero)
}

@(test)
integer_bitwise_and_shifts :: proc(t: ^testing.T) {
	r, _ := ii(.Band, 0b1100, 0b1010)
	testing.expect_value(t, r, 0b1000)
	r, _ = ii(.Bor, 0b1100, 0b1010)
	testing.expect_value(t, r, 0b1110)
	r, _ = ii(.Bxor, 0b1100, 0b1010)
	testing.expect_value(t, r, 0b0110)
	r, _ = ii(.Bnot, 0, 0) // ~0 == -1
	testing.expect_value(t, r, -1)
	// Regression: unary bitwise-not must invert the FIRST operand. The compiler
	// folds ~x by calling with (x, 0), so a wrong operand would silently give -1.
	r, _ = ii(.Bnot, 5, 0) // ~5 == -6
	testing.expect_value(t, r, -6)
	r, _ = ii(.Bnot, -1, 0) // ~(-1) == 0
	testing.expect_value(t, r, 0)

	// Shift left, with the out-of-range results Lua defines (>= NBITS -> 0).
	r, _ = ii(.Shl, 1, 4)
	testing.expect_value(t, r, 16)
	r, _ = ii(.Shl, 1, 64)
	testing.expect_value(t, r, 0)
	r, _ = ii(.Shl, 1, -1) // negative count shifts right
	testing.expect_value(t, r, 0)

	// Shift right is logical (zero-fill), so -1 >> 1 is a large positive value.
	r, _ = ii(.Shr, -1, 1)
	testing.expect_value(t, r, kernel.Integer(kernel.MAX_INTEGER)) // 0x7fff...ffff
	r, _ = ii(.Shr, 256, 4)
	testing.expect_value(t, r, 16)
	r, _ = ii(.Shr, 1, 64)
	testing.expect_value(t, r, 0)
}

@(test)
float_arithmetic :: proc(t: ^testing.T) {
	x, y := fval(1.0), fval(2.0)
	res, st := kernel.raw_arith(.Div, &x, &y)
	testing.expect(t, st == .Ok && kernel.is_float(&res) && kernel.flt_value(&res) == 0.5)

	// Even integer operands divide in the float domain for '/'.
	a, b := ival(6), ival(3)
	res, st = kernel.raw_arith(.Div, &a, &b)
	testing.expect(t, st == .Ok && kernel.is_float(&res) && kernel.flt_value(&res) == 2.0)

	// Power, including the a^2 fast path.
	x, y = fval(2.0), fval(10.0)
	res, _ = kernel.raw_arith(.Pow, &x, &y)
	testing.expect_value(t, kernel.flt_value(&res), 1024.0)
	x, y = fval(3.0), fval(2.0)
	res, _ = kernel.raw_arith(.Pow, &x, &y)
	testing.expect_value(t, kernel.flt_value(&res), 9.0)

	// Float modulo takes the sign of the divisor.
	x, y = fval(-5.5), fval(2.0)
	res, _ = kernel.raw_arith(.Mod, &x, &y)
	testing.expect_value(t, kernel.flt_value(&res), 0.5)
}

@(test)
domain_promotion_and_failure :: proc(t: ^testing.T) {
	// int + float promotes to float.
	a, f := ival(1), fval(2.0)
	res, st := kernel.raw_arith(.Add, &a, &f)
	testing.expect(t, st == .Ok && kernel.is_float(&res) && kernel.flt_value(&res) == 3.0)

	// int + int stays integer.
	b := ival(2)
	res, st = kernel.raw_arith(.Add, &a, &b)
	testing.expect(t, st == .Ok && kernel.is_integer(&res) && kernel.int_value(&res) == 3)

	// A non-number operand yields No_Number (the VM would try a metamethod).
	var_nil: kernel.TValue
	kernel.set_nil(&var_nil)
	_, st = kernel.raw_arith(.Add, &a, &var_nil)
	testing.expect(t, st == .No_Number)

	// Bitwise on an integral float is fine (4.0 acts as 4)...
	fi := fval(4.0)
	res, st = kernel.raw_arith(.Band, &fi, &b)
	testing.expect(t, st == .Ok && kernel.is_integer(&res) && kernel.int_value(&res) == 0)

	// ...but a non-integral float has no integer representation -> No_Number.
	fh := fval(4.5)
	_, st = kernel.raw_arith(.Band, &fh, &b)
	testing.expect(t, st == .No_Number)
}

@(test)
ceil_log2_matches_reference :: proc(t: ^testing.T) {
	// ceil(log2(x)): smallest n with x <= 2^n, using reference Lua's table.
	cases := []struct {
		x:    kernel.U32,
		want: kernel.Byte,
	}{{1, 0}, {2, 1}, {3, 2}, {4, 2}, {5, 3}, {8, 3}, {9, 4}, {256, 8}, {257, 9}, {1024, 10}}
	for c in cases {
		testing.expectf(t, kernel.ceil_log2(c.x) == c.want, "ceil_log2(%v) = %v (want %v)", c.x, kernel.ceil_log2(c.x), c.want)
	}
}

@(test)
is_pow2_and_grow_size :: proc(t: ^testing.T) {
	testing.expect(t, kernel.is_pow2(1) && kernel.is_pow2(2) && kernel.is_pow2(1024))
	testing.expect(t, !kernel.is_pow2(3) && !kernel.is_pow2(6))
	// Reference Lua's ispow2 deliberately counts zero as a power of two.
	testing.expect(t, kernel.is_pow2(0))

	// Growth arithmetic: doubles, floors at the minimum, clamps to the limit.
	n, ok := kernel.grow_size(0, 1, 1000)
	testing.expect(t, ok && n == kernel.MIN_ARRAY_SIZE) // first jump to 4
	n, ok = kernel.grow_size(8, 9, 1000)
	testing.expect(t, ok && n == 16) // doubling
	n, ok = kernel.grow_size(600, 700, 1000)
	testing.expect(t, ok && n == 1000) // clamp to limit
	_, ok = kernel.grow_size(0, 2000, 1000)
	testing.expect(t, !ok) // can't satisfy: needed exceeds limit

	// Overflow-guarded array sizing.
	sz, ok2 := kernel.array_bytes(10, 8)
	testing.expect(t, ok2 && sz == 80)
	_, ok2 = kernel.array_bytes(kernel.MAX_SIZE, 2)
	testing.expect(t, !ok2) // would overflow
}
