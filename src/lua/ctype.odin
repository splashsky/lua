package lua

// ctype.odin -- our analogue of reference Lua's `lctype.h` / `lctype.c`.
//
// A tiny, locale-independent character-classification layer used by the lexer,
// string library, and I/O number reader. These predicates deliberately implement
// the C locale, not the user's current locale. Lua defines its pattern classes in
// terms of C's ctype functions, so making (say) a byte above 0x7f alphabetic in a
// locale-sensitive implementation would silently change `%a`, `%w`, `%p`, and
// friends. Spelling out the C-locale byte ranges also keeps the result identical
// on every host and removes the libc dependency.
//
// A deliberate, documented deviation (non-observable): reference Lua precomputes a
// 257-entry byte table (`luai_ctype_`) indexed by `char + 1` so that -1 (EOZ) has
// a valid slot, then tests property bits with `testprop`. We instead compute each
// property directly from the ASCII ranges. The two approaches are *observably
// identical* on any ASCII platform -- which is the only case reference Lua's own
// table is compiled for (`lctype.h` falls back to <ctype.h> for non-ASCII). Direct
// predicates are clearer and need no init step; the lexer only ever asks these
// yes/no questions, never reads the raw table.
//
// One faithfulness detail carried straight over: Lua's notion of an "alphabetic"
// character for identifiers *includes* the underscore, so `is_lalpha`/`is_lalnum`
// (the "l" is for "Lua") accept `_` while the plain `is_alpha`/`is_alnum` do not.

// Our callers pass characters as `int` because the lexer's current byte is an
// `int` that can also hold EOZ (-1). Every predicate below simply returns false
// for anything outside 0..255, so EOZ and stray negatives classify as "no
// property", exactly like indexing reference Lua's table at slot 0.

// A digit is '0'..'9'. Reference `lisdigit`.
is_digit :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= '0' && c <= '9'
}

// A hexadecimal digit is 0-9, a-f, or A-F. Reference `lisxdigit`.
is_xdigit :: #force_inline proc "contextless" (c: int) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

// Whitespace is space, form-feed, newline, carriage return, tab, vertical tab --
// the exact set C's `isspace` recognizes in the "C" locale, which is what
// reference Lua's `lisspace` encodes. Written out so it doesn't depend on any
// locale at all.
is_space :: #force_inline proc "contextless" (c: int) -> bool {
	return c == ' ' || (c >= '\t' && c <= '\r') // '\t','\n','\v','\f','\r' are 9..13
}

// A plain letter is 'a'..'z' or 'A'..'Z'. Reference has no bare `lisalpha`, but we
// factor it out so the "letter or underscore" variant reads clearly.
is_alpha :: #force_inline proc "contextless" (c: int) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z')
}

// Upper- and lower-case letters are exactly their ASCII ranges in the C locale.
// In particular, bytes 0x80..0xff do not belong to either class.
is_upper :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= 'A' && c <= 'Z'
}

is_lower :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= 'a' && c <= 'z'
}

// A letter or digit.
is_alnum :: #force_inline proc "contextless" (c: int) -> bool {
	return is_alpha(c) || is_digit(c)
}

// The lexer's "identifier-start" class: a letter or an underscore. Reference
// `lislalpha`.
is_lalpha :: #force_inline proc "contextless" (c: int) -> bool {
	return is_alpha(c) || c == '_'
}

// The lexer's "identifier-continue" class: a letter, digit, or underscore.
// Reference `lislalnum`.
is_lalnum :: #force_inline proc "contextless" (c: int) -> bool {
	return is_alnum(c) || c == '_'
}

// Printable ASCII is the range 0x20 (space) through 0x7e (tilde) inclusive.
// Reference `lisprint`.
is_print :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= 0x20 && c <= 0x7e
}

// Control characters are the C0 controls plus DEL. C's `iscntrl` does not
// classify any high byte as a control character in the C locale.
is_cntrl :: #force_inline proc "contextless" (c: int) -> bool {
	return (c >= 0x00 && c <= 0x1f) || c == 0x7f
}

// Graphical characters are printable characters other than space.
is_graph :: #force_inline proc "contextless" (c: int) -> bool {
	return c >= 0x21 && c <= 0x7e
}

// Punctuation is every graphical C-locale byte that is not alphanumeric. This
// range formulation intentionally includes symbols and underscore while
// excluding space, controls, and every byte at or above 0x80.
is_punct :: #force_inline proc "contextless" (c: int) -> bool {
	return is_graph(c) && !is_alnum(c)
}

// Lower-case an ASCII letter; leave everything else untouched. Reference
// `ltolower`, which is defined only for upper-case letters and '.', but the safe
// general form is also exactly C-locale `tolower` for all valid unsigned-byte
// values and EOF. Keeping EOF (-1) unchanged matters to callers that read stdio.
to_lower :: #force_inline proc "contextless" (c: int) -> int {
	if is_upper(c) {
		return c | ('a' - 'A') // set the 0x20 bit
	}
	return c
}

// Upper-case an ASCII letter and leave all other values, including EOF and
// bytes 0x80..0xff, untouched -- exactly C-locale `toupper`.
to_upper :: #force_inline proc "contextless" (c: int) -> int {
	if is_lower(c) {
		return c &~ ('a' - 'A') // clear the 0x20 bit
	}
	return c
}
