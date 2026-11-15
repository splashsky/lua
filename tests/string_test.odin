package tests

// string_test.odin -- Phase 3 tests for the string subsystem (string.odin).
//
// These prove the two observable promises the string layer makes: short strings
// are *interned* (equal contents always yield the very same object, so identity
// comparison is content comparison), and long strings are deliberately *not*
// interned (each is its own object, hashed lazily). We prove interning honestly by
// building two strings from separate byte buffers -- if the pointers come back
// equal, that can only be because the table genuinely deduplicated by content, not
// because we handed the same literal address in twice.

import "core:testing"
import kernel "lang:kernel"

// Read a TString's bytes back as an ordinary Odin string, so tests can assert on
// content without poking at internal layout beyond the documented accessors.
str_contents :: proc(ts: ^kernel.TString) -> string {
	return string(kernel.str_bytes(ts)[:ts.len])
}

@(test)
string_byte_comparison_handles_long_unaligned_ranges :: proc(t: ^testing.T) {
	a, b: [1040]u8
	for i in 0 ..< len(a) {
		a[i] = u8(i % 251)
		b[i] = a[i]
	}
	lengths := [29]int{0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 39, 40, 63, 64, 65, 79, 80, 95, 96, 1000, 1024}
	for offset in 0 ..< 8 {
		for n in lengths {
			testing.expect(t, kernel.mem_eq(([^]u8)(&a[offset]), ([^]u8)(&b[offset]), uint(n)))
			if n == 0 do continue
			positions := [3]int{0, n / 2, n - 1}
			for pos in positions {
				b[offset + pos] ~= 0xff
				testing.expect(t, !kernel.mem_eq(([^]u8)(&a[offset]), ([^]u8)(&b[offset]), uint(n)))
				b[offset + pos] ~= 0xff
			}
		}
	}
	// Exercise every byte of the short-range word and tail paths, not just
	// the first, middle, and last bytes of a few representative lengths.
	for offset in 0 ..< 8 {
		for n in 1 ..< 64 {
			for pos in 0 ..< n {
				b[offset + pos] ~= 0xff
				equal := kernel.mem_eq(([^]u8)(&a[offset]), ([^]u8)(&b[offset]), uint(n))
				b[offset + pos] ~= 0xff
				if equal {
					testing.expectf(t, false, "comparison missed byte %d at offset %d, length %d", pos, offset, n)
					return
				}
			}
		}
	}
}

@(test)
string_short_and_long_boundary_storage :: proc(t: ^testing.T) {
	c: Counting_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = counting_alloc, ud = &c})
	if !testing.expect(t, L != nil) do return
	data: [kernel.MAXSHORTLEN + 1]u8
	for i in 0 ..< len(data) do data[i] = u8(i)
	short := kernel.string_newlstr(L, &data[0], kernel.MAXSHORTLEN)
	long := kernel.string_newlstr(L, &data[0], kernel.MAXSHORTLEN + 1)
	testing.expect_value(t, short.tt, kernel.Byte(kernel.VSHRSTR))
	testing.expect_value(t, long.tt, kernel.Byte(kernel.VLNGSTR))
	testing.expect_value(t, short.len, uint(kernel.MAXSHORTLEN))
	testing.expect_value(t, long.len, uint(kernel.MAXSHORTLEN + 1))
	testing.expect(t, kernel.mem_eq(kernel.str_bytes(short), &data[0], kernel.MAXSHORTLEN))
	testing.expect(t, kernel.mem_eq(kernel.str_bytes(long), &data[0], kernel.MAXSHORTLEN + 1))
	testing.expect_value(t, kernel.str_bytes(short)[kernel.MAXSHORTLEN], u8(0))
	testing.expect_value(t, kernel.str_bytes(long)[kernel.MAXSHORTLEN + 1], u8(0))
	testing.expect_value(t, kernel.string_alloc_size(short), kernel.sizelstring(kernel.MAXSHORTLEN))
	testing.expect_value(t, kernel.string_alloc_size(long), kernel.sizelstring(kernel.MAXSHORTLEN + 1))
	kernel.close_state(L)
	testing.expect_value(t, c.outstanding, 0)
}

// Two short strings with identical contents, built from two distinct buffers, must
// intern to the exact same object. Pointer equality here is the whole point of
// interning: it makes string comparison a single pointer compare everywhere else.
@(test)
short_strings_are_interned :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	buf_a := [5]u8{'h', 'e', 'l', 'l', 'o'}
	buf_b := [5]u8{'h', 'e', 'l', 'l', 'o'}
	// Different backing storage on purpose -- a real intern must not rely on the
	// caller's pointer identity.
	testing.expect(t, &buf_a[0] != &buf_b[0], "buffers must be distinct")

	a := kernel.string_newlstr(L, ([^]u8)(&buf_a[0]), 5)
	b := kernel.string_newlstr(L, ([^]u8)(&buf_b[0]), 5)
	testing.expect(t, a != nil && b != nil)
	testing.expect(t, a == b, "equal short strings must intern to one object")
	testing.expect_value(t, str_contents(a), "hello")
	testing.expect(t, a.tt == kernel.VSHRSTR, "short strings carry the VSHRSTR tag")
}

// Distinct contents must yield distinct objects, and the general equality helper
// must agree with identity for interned strings.
@(test)
distinct_short_strings_differ :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	a := kernel.string_new(L, "alpha")
	b := kernel.string_new(L, "beta")
	c := kernel.string_new(L, "alpha")
	testing.expect(t, a != b, "different contents must not share an object")
	testing.expect(t, a == c, "repeat of the same content re-uses the object")
	testing.expect(t, kernel.string_eqstr(a, c), "eqstr must hold for interned equals")
	testing.expect(t, !kernel.string_eqstr(a, b), "eqstr must fail for different strings")
}

// Long strings (longer than MAXSHORTLEN) are intentionally never interned: two
// equal-content long strings are two separate objects, each tagged VLNGSTR. This
// matters because long strings are hashed lazily and compared by content, not
// identity, so the VM must never assume long-string identity means equality.
@(test)
long_strings_are_not_interned :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	// 50 bytes -- comfortably past the 40-byte short-string boundary.
	buf_a: [50]u8
	buf_b: [50]u8
	for i in 0 ..< 50 {
		buf_a[i] = 'x'
		buf_b[i] = 'x'
	}

	a := kernel.string_newlstr(L, ([^]u8)(&buf_a[0]), 50)
	b := kernel.string_newlstr(L, ([^]u8)(&buf_b[0]), 50)
	testing.expect(t, a != nil && b != nil)
	testing.expect(t, a.tt == kernel.VLNGSTR, "long strings carry the VLNGSTR tag")
	testing.expect(t, a != b, "equal long strings stay as separate objects")

	// Content is still equal, and the long-string comparison helper must say so
	// even though the objects differ.
	testing.expect(t, kernel.string_eqlngstr(a, b), "eqlngstr compares by content")
	testing.expect_value(t, len(str_contents(a)), 50)
}

// Interning must survive the string table growing. We create far more distinct
// short strings than the initial 128-bucket table holds, forcing at least one
// resize, then prove every one of them still interns (a second lookup returns the
// same object). If a resize dropped or duplicated an entry, one of these identity
// checks would fail.
@(test)
string_table_grows_and_keeps_interning :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	testing.expect(t, L != nil)
	defer kernel.close_state(L)

	firsts: [400]^kernel.TString
	for i in 0 ..< 400 {
		buf: [16]u8
		n := format_uint_into(buf[:], u64(i))
		firsts[i] = kernel.string_newlstr(L, ([^]u8)(&buf[0]), uint(n))
		testing.expect(t, firsts[i] != nil)
	}
	// Re-intern each: it must return the identical object stored the first time.
	for i in 0 ..< 400 {
		buf: [16]u8
		n := format_uint_into(buf[:], u64(i))
		again := kernel.string_newlstr(L, ([^]u8)(&buf[0]), uint(n))
		testing.expect(t, again == firsts[i], "interning must be stable across growth")
	}
}

// A tiny decimal formatter used only by the tests, so we don't lean on fmt (which
// allocates) inside the kernel's test buffers. Writes the decimal digits of `v`
// into `dst` and returns the count written.
format_uint_into :: proc(dst: []u8, v: u64) -> int {
	if v == 0 {
		dst[0] = '0'
		return 1
	}
	tmp: [20]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + (x % 10))
		x /= 10
		n += 1
	}
	// Reverse into the destination.
	for i in 0 ..< n {
		dst[i] = tmp[n - 1 - i]
	}
	return n
}
