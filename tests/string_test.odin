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
import lua "luao:lua"

// Read a TString's bytes back as an ordinary Odin string, so tests can assert on
// content without poking at internal layout beyond the documented accessors.
str_contents :: proc(ts: ^lua.TString) -> string {
	return string(lua.str_bytes(ts)[:ts.len])
}

// Two short strings with identical contents, built from two distinct buffers, must
// intern to the exact same object. Pointer equality here is the whole point of
// interning: it makes string comparison a single pointer compare everywhere else.
@(test)
short_strings_are_interned :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	buf_a := [5]u8{'h', 'e', 'l', 'l', 'o'}
	buf_b := [5]u8{'h', 'e', 'l', 'l', 'o'}
	// Different backing storage on purpose -- a real intern must not rely on the
	// caller's pointer identity.
	testing.expect(t, &buf_a[0] != &buf_b[0], "buffers must be distinct")

	a := lua.luaS_newlstr(L, ([^]u8)(&buf_a[0]), 5)
	b := lua.luaS_newlstr(L, ([^]u8)(&buf_b[0]), 5)
	testing.expect(t, a != nil && b != nil)
	testing.expect(t, a == b, "equal short strings must intern to one object")
	testing.expect_value(t, str_contents(a), "hello")
	testing.expect(t, a.tt == lua.VSHRSTR, "short strings carry the VSHRSTR tag")
}

// Distinct contents must yield distinct objects, and the general equality helper
// must agree with identity for interned strings.
@(test)
distinct_short_strings_differ :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	a := lua.luaS_new(L, "alpha")
	b := lua.luaS_new(L, "beta")
	c := lua.luaS_new(L, "alpha")
	testing.expect(t, a != b, "different contents must not share an object")
	testing.expect(t, a == c, "repeat of the same content re-uses the object")
	testing.expect(t, lua.luaS_eqstr(a, c), "eqstr must hold for interned equals")
	testing.expect(t, !lua.luaS_eqstr(a, b), "eqstr must fail for different strings")
}

// Long strings (longer than MAXSHORTLEN) are intentionally never interned: two
// equal-content long strings are two separate objects, each tagged VLNGSTR. This
// matters because long strings are hashed lazily and compared by content, not
// identity, so the VM must never assume long-string identity means equality.
@(test)
long_strings_are_not_interned :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	// 50 bytes -- comfortably past the 40-byte short-string boundary.
	buf_a: [50]u8
	buf_b: [50]u8
	for i in 0 ..< 50 {
		buf_a[i] = 'x'
		buf_b[i] = 'x'
	}

	a := lua.luaS_newlstr(L, ([^]u8)(&buf_a[0]), 50)
	b := lua.luaS_newlstr(L, ([^]u8)(&buf_b[0]), 50)
	testing.expect(t, a != nil && b != nil)
	testing.expect(t, a.tt == lua.VLNGSTR, "long strings carry the VLNGSTR tag")
	testing.expect(t, a != b, "equal long strings stay as separate objects")

	// Content is still equal, and the long-string comparison helper must say so
	// even though the objects differ.
	testing.expect(t, lua.luaS_eqlngstr(a, b), "eqlngstr compares by content")
	testing.expect_value(t, len(str_contents(a)), 50)
}

// Interning must survive the string table growing. We create far more distinct
// short strings than the initial 128-bucket table holds, forcing at least one
// resize, then prove every one of them still interns (a second lookup returns the
// same object). If a resize dropped or duplicated an entry, one of these identity
// checks would fail.
@(test)
string_table_grows_and_keeps_interning :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	testing.expect(t, L != nil)
	defer lua.close_state(L)

	firsts: [400]^lua.TString
	for i in 0 ..< 400 {
		buf: [16]u8
		n := format_uint_into(buf[:], u64(i))
		firsts[i] = lua.luaS_newlstr(L, ([^]u8)(&buf[0]), uint(n))
		testing.expect(t, firsts[i] != nil)
	}
	// Re-intern each: it must return the identical object stored the first time.
	for i in 0 ..< 400 {
		buf: [16]u8
		n := format_uint_into(buf[:], u64(i))
		again := lua.luaS_newlstr(L, ([^]u8)(&buf[0]), uint(n))
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
