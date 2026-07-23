package tests

// arith_test.odin -- Phase 1 tests for the raw arithmetic layer (object.odin).
//
// The raw arithmetic is what the compiler will use to constant-fold, so its
// results must exactly match reference Lua's defined integer/float semantics:
// two's-complement wraparound, floor division/modulo, logical shifts, and the
// integer-vs-float domain rules. These tests check those defined behaviors.

import "core:testing"
import lua "luao:lua"

@(private = "file")
ival :: proc(x: lua.Integer) -> lua.TValue {
	v: lua.TValue
	lua.set_int(&v, x)
	return v
}

@(private = "file")
fval :: proc(x: lua.Number) -> lua.TValue {
	v: lua.TValue
	lua.set_float(&v, x)
	return v
}

// Run raw_arith on two integer operands, expecting an integer result.
@(private = "file")
ii :: proc(op: lua.Arith_Op, a, b: lua.Integer) -> (lua.Integer, lua.Arith_Status) {
	x, y := ival(a), ival(b)
	res, st := lua.raw_arith(op, &x, &y)
	return lua.int_value(&res), st
}

@(test)
integer_arithmetic_wraps :: proc(t: ^testing.T) {
	// Two's-complement wraparound on overflow, exactly as Lua defines it.
	r, st := ii(.Add, lua.MAX_INTEGER, 1)
	testing.expect(t, st == .Ok && r == lua.MIN_INTEGER)

	r, _ = ii(.Sub, lua.MIN_INTEGER, 1)
	testing.expect_value(t, r, lua.MAX_INTEGER)

	r, _ = ii(.Mul, lua.MIN_INTEGER, -1) // 2^63 wraps back to MIN_INTEGER
	testing.expect_value(t, r, lua.MIN_INTEGER)

	r, _ = ii(.Unm, lua.MIN_INTEGER, 0) // negating MIN_INTEGER wraps to itself
	testing.expect_value(t, r, lua.MIN_INTEGER)
}

@(test)
integer_floor_division :: proc(t: ^testing.T) {
	// Lua's // is floor division, which differs from C truncation for mixed signs.
	cases := []struct {
		a, b, want: lua.Integer,
	}{{7, 2, 3}, {-7, 2, -4}, {7, -2, -4}, {-7, -2, 3}, {6, 3, 2}}
	for c in cases {
		r, st := ii(.IDiv, c.a, c.b)
		testing.expectf(t, st == .Ok && r == c.want, "%v // %v = %v (want %v)", c.a, c.b, r, c.want)
	}

	// MIN_INTEGER // -1 must not trap; it wraps to MIN_INTEGER.
	r, st := ii(.IDiv, lua.MIN_INTEGER, -1)
	testing.expect(t, st == .Ok && r == lua.MIN_INTEGER)

	// Division by zero is reported, not crashed.
	_, st = ii(.IDiv, 1, 0)
	testing.expect(t, st == .Div_By_Zero)
}

@(test)
integer_modulo :: proc(t: ^testing.T) {
	// The result takes the sign of the divisor (floor-mod).
	cases := []struct {
		a, b, want: lua.Integer,
	}{{7, 3, 1}, {-7, 3, 2}, {7, -3, -2}, {-7, -3, -1}}
	for c in cases {
		r, st := ii(.Mod, c.a, c.b)
		testing.expectf(t, st == .Ok && r == c.want, "%v %% %v = %v (want %v)", c.a, c.b, r, c.want)
	}

	// MIN_INTEGER % -1 == 0 (and must not trap).
	r, st := ii(.Mod, lua.MIN_INTEGER, -1)
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
	testing.expect_value(t, r, lua.Integer(lua.MAX_INTEGER)) // 0x7fff...ffff
	r, _ = ii(.Shr, 256, 4)
	testing.expect_value(t, r, 16)
	r, _ = ii(.Shr, 1, 64)
	testing.expect_value(t, r, 0)
}

@(test)
float_arithmetic :: proc(t: ^testing.T) {
	x, y := fval(1.0), fval(2.0)
	res, st := lua.raw_arith(.Div, &x, &y)
	testing.expect(t, st == .Ok && lua.is_float(&res) && lua.flt_value(&res) == 0.5)

	// Even integer operands divide in the float domain for '/'.
	a, b := ival(6), ival(3)
	res, st = lua.raw_arith(.Div, &a, &b)
	testing.expect(t, st == .Ok && lua.is_float(&res) && lua.flt_value(&res) == 2.0)

	// Power, including the a^2 fast path.
	x, y = fval(2.0), fval(10.0)
	res, _ = lua.raw_arith(.Pow, &x, &y)
	testing.expect_value(t, lua.flt_value(&res), 1024.0)
	x, y = fval(3.0), fval(2.0)
	res, _ = lua.raw_arith(.Pow, &x, &y)
	testing.expect_value(t, lua.flt_value(&res), 9.0)

	// Float modulo takes the sign of the divisor.
	x, y = fval(-5.5), fval(2.0)
	res, _ = lua.raw_arith(.Mod, &x, &y)
	testing.expect_value(t, lua.flt_value(&res), 0.5)
}

@(test)
domain_promotion_and_failure :: proc(t: ^testing.T) {
	// int + float promotes to float.
	a, f := ival(1), fval(2.0)
	res, st := lua.raw_arith(.Add, &a, &f)
	testing.expect(t, st == .Ok && lua.is_float(&res) && lua.flt_value(&res) == 3.0)

	// int + int stays integer.
	b := ival(2)
	res, st = lua.raw_arith(.Add, &a, &b)
	testing.expect(t, st == .Ok && lua.is_integer(&res) && lua.int_value(&res) == 3)

	// A non-number operand yields No_Number (the VM would try a metamethod).
	var_nil: lua.TValue
	lua.set_nil(&var_nil)
	_, st = lua.raw_arith(.Add, &a, &var_nil)
	testing.expect(t, st == .No_Number)

	// Bitwise on an integral float is fine (4.0 acts as 4)...
	fi := fval(4.0)
	res, st = lua.raw_arith(.Band, &fi, &b)
	testing.expect(t, st == .Ok && lua.is_integer(&res) && lua.int_value(&res) == 0)

	// ...but a non-integral float has no integer representation -> No_Number.
	fh := fval(4.5)
	_, st = lua.raw_arith(.Band, &fh, &b)
	testing.expect(t, st == .No_Number)
}

@(test)
ceil_log2_matches_reference :: proc(t: ^testing.T) {
	// ceil(log2(x)): smallest n with x <= 2^n, using reference Lua's table.
	cases := []struct {
		x:    lua.U32,
		want: lua.Byte,
	}{{1, 0}, {2, 1}, {3, 2}, {4, 2}, {5, 3}, {8, 3}, {9, 4}, {256, 8}, {257, 9}, {1024, 10}}
	for c in cases {
		testing.expectf(t, lua.ceil_log2(c.x) == c.want, "ceil_log2(%v) = %v (want %v)", c.x, lua.ceil_log2(c.x), c.want)
	}
}

@(test)
is_pow2_and_grow_size :: proc(t: ^testing.T) {
	testing.expect(t, lua.is_pow2(1) && lua.is_pow2(2) && lua.is_pow2(1024))
	testing.expect(t, !lua.is_pow2(3) && !lua.is_pow2(6))
	// Reference Lua's ispow2 deliberately counts zero as a power of two.
	testing.expect(t, lua.is_pow2(0))

	// Growth arithmetic: doubles, floors at the minimum, clamps to the limit.
	n, ok := lua.grow_size(0, 1, 1000)
	testing.expect(t, ok && n == lua.MIN_ARRAY_SIZE) // first jump to 4
	n, ok = lua.grow_size(8, 9, 1000)
	testing.expect(t, ok && n == 16) // doubling
	n, ok = lua.grow_size(600, 700, 1000)
	testing.expect(t, ok && n == 1000) // clamp to limit
	_, ok = lua.grow_size(0, 2000, 1000)
	testing.expect(t, !ok) // can't satisfy: needed exceeds limit

	// Overflow-guarded array sizing.
	sz, ok2 := lua.array_bytes(10, 8)
	testing.expect(t, ok2 && sz == 80)
	_, ok2 = lua.array_bytes(lua.MAX_SIZE, 2)
	testing.expect(t, !ok2) // would overflow
}
