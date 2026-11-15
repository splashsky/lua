package tests

// number_test.odin -- Phase 1 tests for numeric conversion (object.odin).
//
// String<->number parsing, number->string formatting, and float<->integer
// coercion are subtle, and Lua pins down their behavior precisely. These tests
// assert Lua's *documented, observable* results (curated reference outputs and
// round-trip guarantees), not whatever our code happens to emit -- so they truly
// prove correctness rather than being fitted to the implementation.

import "core:strconv"
import "core:testing"
import kernel "lang:kernel"

// Convert a number value to its Lua string form, returning an Odin string view.
@(private = "file")
num_str :: proc(v: ^kernel.TValue, buf: []byte) -> string {
	n := kernel.number_to_str(v, buf)
	return string(buf[:n])
}

// ---- string -> number -------------------------------------------------------

@(test)
str2num_integers :: proc(t: ^testing.T) {
	v, sz := kernel.str_to_number(transmute([]byte)string("42"))
	testing.expect(t, sz == 3) // consumed length (2) + 1
	testing.expect(t, kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), 42)

	// Surrounding Lua whitespace is allowed.
	v, sz = kernel.str_to_number(transmute([]byte)string("  -7\t "))
	testing.expect(t, sz != 0 && kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), -7)

	// Signed decimal boundaries convert exactly as integers.
	v, _ = kernel.str_to_number(transmute([]byte)string("9223372036854775807"))
	testing.expect(t, kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), kernel.MAX_INTEGER)
	v, _ = kernel.str_to_number(transmute([]byte)string("-9223372036854775808"))
	testing.expect(t, kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), kernel.MIN_INTEGER)
}

@(test)
str2num_hex_wraps :: proc(t: ^testing.T) {
	// Hex integers wrap mod 2^64 (no overflow check), per reference Lua.
	v, _ := kernel.str_to_number(transmute([]byte)string("0x10"))
	testing.expect(t, kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), 16)

	v, _ = kernel.str_to_number(transmute([]byte)string("0xFFFFFFFFFFFFFFFF"))
	testing.expect(t, kernel.is_integer(&v))
	testing.expect_value(t, kernel.int_value(&v), -1) // wraps to -1
}

@(test)
str2num_floats :: proc(t: ^testing.T) {
	v, _ := kernel.str_to_number(transmute([]byte)string("3.14"))
	testing.expect(t, kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 3.14)

	v, _ = kernel.str_to_number(transmute([]byte)string("1e10"))
	testing.expect(t, kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 1e10)

	// Hex float: 0x1p4 == 16.0, 0x1.8p1 == 3.0.
	v, _ = kernel.str_to_number(transmute([]byte)string("0x1p4"))
	testing.expect(t, kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 16.0)
	v, _ = kernel.str_to_number(transmute([]byte)string("0x1.8p1"))
	testing.expect(t, kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 3.0)
}

@(test)
str2num_decimal_overflow_becomes_float :: proc(t: ^testing.T) {
	// Too big for an integer -> falls through to a float (never rejected).
	v, sz := kernel.str_to_number(transmute([]byte)string("9223372036854775808"))
	testing.expect(t, sz != 0)
	testing.expect(t, kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 9223372036854775808.0)

	v, sz = kernel.str_to_number(transmute([]byte)string("99999999999999999999"))
	testing.expect(t, sz != 0 && kernel.is_float(&v))
	testing.expect_value(t, kernel.flt_value(&v), 1e20)
}

@(test)
str2num_preserves_negative_zero :: proc(t: ^testing.T) {
	v, _ := kernel.str_to_number(transmute([]byte)string("-0.0"))
	testing.expect(t, kernel.is_float(&v))
	f := kernel.flt_value(&v)
	testing.expect(t, f == 0.0) // it is a zero...
	bits := transmute(u64)f
	testing.expect(t, (bits >> 63) == 1) // ...with the sign bit set (-0.0)
}

@(test)
str2num_decimal_fast_path_boundaries :: proc(t: ^testing.T) {
	// These exercise both sides of every fast-path guard. The expected bits come
	// from Odin's independent correctly-rounded parser, not from our parser.
	cases := []string {
		"0.1",
		"-0.0",
		"1.5",
		"3.14",
		"9007199254740992e22",
		"9007199254740993e22",
		"9007199254740992e-22",
		"9007199254740992e23",
		"9007199254740992e-23",
		"1234567890123456789e-22",
		"1e-308",
		"1e309",
	}
	for s in cases {
		expected, expected_ok := strconv.parse_f64(s)
		// strconv reports range overflow through `ok` while still returning the
		// same infinity that C strtod (and Lua) return.
		testing.expectf(t, expected_ok || s == "1e309", "independent parser rejected %q", s)
		v, size := kernel.str_to_number(transmute([]byte)s)
		testing.expectf(t, size == uint(len(s)) + 1, "%q returned the wrong consumed length", s)
		testing.expectf(t, kernel.is_float(&v), "%q did not parse as a float", s)
		got := kernel.flt_value(&v)
		testing.expectf(t, transmute(u64)got == transmute(u64)expected,
			"%q parsed to bits %x, expected %x", s, transmute(u64)got, transmute(u64)expected)
	}
}

@(test)
str2num_rejects_garbage :: proc(t: ^testing.T) {
	fails := []string {
		"", // empty
		"   ", // only spaces
		"abc", // not a number
		"1_000", // underscores are NOT accepted (unlike Odin literals)
		"inf", // Lua numerals never spell infinity
		"nan", // ...or NaN
		"0x", // 0x with no digits
		"1 2", // junk after the number
		"0x1p", // 'p' with no exponent digits
	}
	for s in fails {
		_, sz := kernel.str_to_number(transmute([]byte)s)
		testing.expectf(t, sz == 0, "expected %q to fail parsing", s)
	}

	// Embedded NUL must be rejected via the full-length consume check.
	buf := [4]byte{'4', '2', 0, '9'}
	_, sz := kernel.str_to_number(buf[:])
	testing.expect(t, sz == 0)
}

// ---- number -> string -------------------------------------------------------

@(test)
tostring_curated_reference_outputs :: proc(t: ^testing.T) {
	// These are Lua's documented, platform-stable renderings.
	buf: [kernel.N2S_BUFF_SZ]byte
	v: kernel.TValue

	cases := []struct {
		f:        f64,
		expected: string,
	} {
		{1.0, "1.0"}, // integral float gets ".0"
		{-0.0, "-0.0"}, // signed zero, with ".0"
		{100.0, "100.0"},
		{0.1, "0.1"}, // round-trips at %.15g, no ".0"
		{3.14, "3.14"},
		{1e100, "1e+100"}, // exponent form, no ".0"
		{-2.5, "-2.5"},
	}
	for c in cases {
		kernel.set_float(&v, c.f)
		got := num_str(&v, buf[:])
		testing.expectf(t, got == c.expected, "tostring(%v): got %q want %q", c.f, got, c.expected)
	}

	// Integers format without any decimal point.
	kernel.set_int(&v, 0)
	testing.expect_value(t, num_str(&v, buf[:]), "0")
	kernel.set_int(&v, -1234567890)
	testing.expect_value(t, num_str(&v, buf[:]), "-1234567890")
	kernel.set_int(&v, kernel.MAX_INTEGER)
	testing.expect_value(t, num_str(&v, buf[:]), "9223372036854775807")
	kernel.set_int(&v, kernel.MIN_INTEGER)
	testing.expect_value(t, num_str(&v, buf[:]), "-9223372036854775808")

	// Pairwise digit generation must preserve leading zeroes inside the number
	// while suppressing them in its most significant pair.
	ints := []struct { n: kernel.Integer, text: string }{
		{9, "9"}, {10, "10"}, {99, "99"}, {100, "100"},
		{101, "101"}, {1000, "1000"}, {10001, "10001"},
		{1000000001, "1000000001"}, {-10001, "-10001"},
	}
	for c in ints {
		kernel.set_int(&v, c.n)
		testing.expect_value(t, num_str(&v, buf[:]), c.text)
	}
}

@(test)
tostring_float_round_trips :: proc(t: ^testing.T) {
	// Lua guarantees a float's tostring parses back to the identical double. This
	// exercises the %.15g -> %.17g precision-recovery path for hard values. We
	// read back with an INDEPENDENT parser (core:strconv) to avoid circularity.
	buf: [kernel.N2S_BUFF_SZ]byte
	v: kernel.TValue

	values := []f64 {
		1.0 / 3.0,
		2.0 / 3.0,
		3.141592653589793,
		2.718281828459045,
		1e-300,
		1e300,
		1.7976931348623157e308, // near DBL_MAX
		2.2250738585072014e-308, // smallest normal
		0.30000000000000004, // classic 0.1+0.2
		123456789.123456789,
	}
	for f in values {
		kernel.set_float(&v, f)
		s := num_str(&v, buf[:])
		back, ok := strconv.parse_f64(s)
		testing.expectf(t, ok, "could not parse back %q", s)
		testing.expectf(t, back == f, "round-trip failed: %v -> %q -> %v", f, s, back)
	}
}

// ---- float <-> integer coercion --------------------------------------------

@(test)
float_to_integer_modes :: proc(t: ^testing.T) {
	i, ok := kernel.float_to_integer(3.0, .Eq)
	testing.expect(t, ok && i == 3)

	_, ok = kernel.float_to_integer(3.5, .Eq)
	testing.expect(t, !ok) // Eq rejects non-integral

	i, ok = kernel.float_to_integer(3.5, .Floor)
	testing.expect(t, ok && i == 3)
	i, ok = kernel.float_to_integer(3.5, .Ceil)
	testing.expect(t, ok && i == 4)
	i, ok = kernel.float_to_integer(-3.5, .Floor)
	testing.expect(t, ok && i == -4)
	i, ok = kernel.float_to_integer(-3.5, .Ceil)
	testing.expect(t, ok && i == -3)

	// MIN_INTEGER is exactly representable as a double and must convert exactly.
	i, ok = kernel.float_to_integer(f64(kernel.MIN_INTEGER), .Eq)
	testing.expect(t, ok && i == kernel.MIN_INTEGER)

	// Out of range fails.
	_, ok = kernel.float_to_integer(1e100, .Floor)
	testing.expect(t, !ok)
	// 2^63 is exactly -(double)MIN_INTEGER and is deliberately excluded.
	_, ok = kernel.number_to_integer_range(9223372036854775808.0)
	testing.expect(t, !ok)
}
