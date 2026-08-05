package stdlib

// utf8lib.odin -- our analogue of reference Lua's `lutf8lib.c`.
//
// The utf8 library: char/codepoint/len/offset/codes plus the utf8.charpattern
// constant. It implements Lua's specific, deliberately permissive view of UTF-8.
// Lua accepts sequences up to six bytes encoding values up to 0x7FFFFFFF (the
// historical UTF-8 ceiling, MAXUTF) and only enforces the "real" Unicode limits
// (no code point above 0x10FFFF, no surrogates) when the caller asks for the
// strict mode. That looseness is a feature callers rely on, so we mirror it byte
// for byte rather than substituting a stricter modern decoder.

import "base:runtime"
import kernel "lang:kernel"

// A code point at or below this is a legal Unicode scalar value (excluding the
// surrogate range checked separately). Strict decoding rejects anything above it.
@(private = "file")
MAXUNICODE :: 0x10FFFF

// The widest value the classic 6-byte UTF-8 form can encode. Lax decoding accepts
// anything up to here; this is what makes Lua's utf8 library "permissive".
@(private = "file")
MAXUTF :: 0x7FFFFFFF

@(private = "file")
MSG_INVALID :: "invalid UTF-8 code"

// The one-line contextless cast we reuse in every entry point, matching the
// pattern established by the other stdlib files.
@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
}

// Is this byte a UTF-8 continuation byte (10xxxxxx)? Reference `iscont`.
@(private = "file")
u_iscont :: #force_inline proc "contextless" (c: u8) -> bool {
	return (c & 0xC0) == 0x80
}

// Read one byte of the subject string, returning 0 for any out-of-range index.
//
// Reference Lua works on NUL-terminated C strings, so its decoder is free to peek
// one byte past a truncated multi-byte sequence and land on the '\0' terminator --
// which is never a continuation byte, so the truncation is detected as an invalid
// sequence. We operate on Odin slices with no terminator, so we reproduce that
// exact behaviour by treating any index outside the slice as a 0 byte. This keeps
// us both faithful and memory-safe.
@(private = "file")
u_byte :: #force_inline proc "contextless" (s: []u8, i: int) -> u8 {
	if i < 0 || i >= len(s) {
		return 0
	}
	return s[i]
}

// Translate a possibly-negative string position into a 1-based absolute one --
// reference `u_posrelat` (a copy of the one in the string library). A negative
// position counts back from the end; a magnitude larger than the string clamps to
// 0 rather than wrapping.
@(private = "file")
u_posrelat :: proc "contextless" (pos: kernel.Integer, ln: int) -> kernel.Integer {
	if pos >= 0 {
		return pos
	}
	// `0 - (unsigned)pos` recreates C's `0u - (size_t)pos`: the magnitude of the
	// negative position, computed in the unsigned domain so it can never overflow.
	mag := u64(0) - u64(pos)
	if mag > u64(ln) {
		return 0
	}
	return kernel.Integer(ln) + pos + 1
}

// Decode one UTF-8 sequence beginning at byte index `start`.
//
// Returns the index one past the decoded sequence, the code point, and an `ok`
// flag that is false for any malformed or (in strict mode) out-of-range sequence.
// This is a direct port of reference `utf8_decode`; `limits` stores the smallest
// value each sequence length may legally encode, so we can reject overlong forms.
@(private = "file")
utf8_decode :: proc "contextless" (s: []u8, start: int, strict: bool) -> (next: int, val: u32, ok: bool) {
	limits := [6]u32{~u32(0), 0x80, 0x800, 0x10000, 0x200000, 0x4000000}
	c := u32(u_byte(s, start))
	res: u32 = 0
	count := 0
	if c < 0x80 {
		// Plain ASCII: the byte is the code point and there are no continuations.
		res = c
	} else {
		// A lead byte has its top bits set; each set high bit past 0x80 promises one
		// continuation byte. We keep shifting `c` left, consuming a continuation for
		// every bit, exactly as the reference loop does.
		for c & 0x40 != 0 {
			count += 1
			cc := u32(u_byte(s, start + count))
			if !u_iscont(u8(cc)) {
				return 0, 0, false
			}
			res = (res << 6) | (cc & 0x3F)
			c <<= 1
		}
		// Fold in the payload bits carried by the lead byte itself.
		res |= (c & 0x7F) << u32(count * 5)
		if count > 5 || res > MAXUTF || res < limits[count] {
			return 0, 0, false
		}
	}
	if strict {
		// Strict mode is real-Unicode mode: no oversized code points and no UTF-16
		// surrogate halves (which are illegal as standalone scalar values).
		if res > MAXUNICODE || (0xD800 <= res && res <= 0xDFFF) {
			return 0, 0, false
		}
	}
	// The reference advances by `count` continuation bytes then `+1` for the lead.
	return start + count + 1, res, true
}

// utf8.len(s [, i [, j [, lax]]]) -> number of characters starting in [i, j], or
// (fail, position) if the interval is not well-formed. Reference `utflen`.
@(private = "file")
utf8_len :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)aux_checklstring(L, 1)
	ln := len(s)
	posi := u_posrelat(aux_optinteger(L, 2, 1), ln)
	posj := u_posrelat(aux_optinteger(L, 3, -1), ln)
	lax := kernel.api_toboolean(L, 4)
	// Reference folds a `--posi` / `--posj` into these argument checks. We keep the
	// same bounds but decrement explicitly so the byte indices below are 0-based.
	aux_argcheck(L, 1 <= posi, 2, "initial position out of bounds")
	posi -= 1
	aux_argcheck(L, posi <= kernel.Integer(ln), 2, "initial position out of bounds")
	posj -= 1
	aux_argcheck(L, posj < kernel.Integer(ln), 3, "final position out of bounds")
	n: kernel.Integer = 0
	for posi <= posj {
		next, _, ok := utf8_decode(s, int(posi), !lax)
		if !ok {
			aux_pushfail(L) // return fail ...
			kernel.api_pushinteger(L, posi + 1) // ... and the offending position
			return 2
		}
		posi = kernel.Integer(next)
		n += 1
	}
	kernel.api_pushinteger(L, n)
	return 1
}

// utf8.codepoint(s [, i [, j [, lax]]]) -> the code points of every character
// starting in [i, j]. Reference `codepoint`.
@(private = "file")
utf8_codepoint :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)aux_checklstring(L, 1)
	ln := len(s)
	posi := u_posrelat(aux_optinteger(L, 2, 1), ln)
	pose := u_posrelat(aux_optinteger(L, 3, posi), ln)
	lax := kernel.api_toboolean(L, 4)
	aux_argcheck(L, posi >= 1, 2, "out of bounds")
	aux_argcheck(L, pose <= kernel.Integer(ln), 3, "out of bounds")
	if posi > pose {
		return 0 // empty interval: return no values
	}
	if pose - posi >= kernel.Integer(max(i32)) {
		aux_error(L, "string slice too long")
	}
	n := int(pose - posi) + 1 // upper bound on the number of results
	aux_checkstack(L, n, "string slice too long")
	n = 0
	se := int(pose) // byte index just past the last character we consider
	i := int(posi) - 1
	for i < se {
		next, code, ok := utf8_decode(s, i, !lax)
		if !ok {
			aux_error(L, MSG_INVALID)
		}
		kernel.api_pushinteger(L, kernel.Integer(code))
		i = next
		n += 1
	}
	return i32(n)
}

// Check argument `arg` is a valid code point and push it as its UTF-8 encoding.
// Reference `pushutfchar`; the "%U" formatter does the actual UTF-8 escaping.
@(private = "file")
push_utf_char :: proc(L: ^kernel.State, arg: int) {
	code := kernel.Unsigned(aux_checkinteger(L, arg))
	aux_argcheck(L, code <= MAXUTF, arg, "value out of range")
	kernel.api_pushfstring(L, "%U", i64(code))
}

// utf8.char(n1, n2, ...) -> the concatenation of each argument's UTF-8 encoding.
// Reference `utfchar`.
@(private = "file")
utf8_char :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := kernel.api_gettop(L) // number of arguments
	if n == 1 {
		// Fast path for the common single-character case: push it directly.
		push_utf_char(L, 1)
	} else {
		b: Buffer
		aux_buffinit(L, &b)
		for i in 1 ..= n {
			push_utf_char(L, i)
			aux_addvalue(&b)
		}
		aux_pushresult(&b)
	}
	return 1
}

// utf8.offset(s, n [, i]) -> byte index where the n-th character (counting from
// position i) starts, plus the index of its final byte. n == 0 finds the start of
// the character containing position i. Reference `byteoffset`.
@(private = "file")
utf8_offset :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)aux_checklstring(L, 1)
	ln := len(s)
	n := aux_checkinteger(L, 2)
	// The default starting position depends on the search direction: forward
	// searches start at the front, backward searches start just past the end.
	default_posi: kernel.Integer = n >= 0 ? 1 : kernel.Integer(ln) + 1
	posi := u_posrelat(aux_optinteger(L, 3, default_posi), ln)
	aux_argcheck(L, 1 <= posi, 3, "position out of bounds")
	posi -= 1
	aux_argcheck(L, posi <= kernel.Integer(ln), 3, "position out of bounds")
	if n == 0 {
		// Walk back to the beginning of the byte sequence containing `posi`.
		for posi > 0 && u_iscont(u_byte(s, int(posi))) {
			posi -= 1
		}
	} else {
		if u_iscont(u_byte(s, int(posi))) {
			aux_error(L, "initial position is a continuation byte")
		}
		if n < 0 {
			// Move backward over |n| character starts.
			for n < 0 && posi > 0 {
				posi -= 1
				for posi > 0 && u_iscont(u_byte(s, int(posi))) {
					posi -= 1
				}
				n += 1
			}
		} else {
			n -= 1 // the 1st character is the one already at `posi`
			for n > 0 && posi < kernel.Integer(ln) {
				posi += 1
				for u_iscont(u_byte(s, int(posi))) { // '\0' guard is the slice end
					posi += 1
				}
				n -= 1
			}
		}
	}
	if n != 0 {
		// We ran off an end before locating the requested character.
		aux_pushfail(L)
		return 1
	}
	kernel.api_pushinteger(L, posi + 1) // initial byte position (1-based)
	if (u_byte(s, int(posi)) & 0x80) != 0 {
		// Multi-byte character: advance to its final continuation byte.
		if u_iscont(u_byte(s, int(posi))) {
			aux_error(L, "initial position is a continuation byte")
		}
		for u_iscont(u_byte(s, int(posi) + 1)) {
			posi += 1
		}
	}
	kernel.api_pushinteger(L, posi + 1) // final byte position (1-based)
	return 2
}

// The stateless iterator body shared by utf8.codes. Given the string and the byte
// position of the previous character, it advances to and decodes the next one.
// Reference `iter_aux`.
@(private = "file")
iter_aux :: proc(L: ^kernel.State, strict: bool) -> i32 {
	s := transmute([]u8)aux_checklstring(L, 1)
	ln := len(s)
	n := kernel.Unsigned(kernel.api_tointeger(L, 2))
	if n < kernel.Unsigned(ln) {
		// Skip past the continuation bytes of the character we just returned.
		for u_iscont(u_byte(s, int(n))) {
			n += 1
		}
	}
	if n >= kernel.Unsigned(ln) {
		// Reached the end (this also catches an originally-negative control value).
		return 0
	}
	next, code, ok := utf8_decode(s, int(n), strict)
	if !ok || u_iscont(u_byte(s, next)) {
		aux_error(L, MSG_INVALID)
	}
	kernel.api_pushinteger(L, kernel.Integer(n + 1))
	kernel.api_pushinteger(L, kernel.Integer(code))
	return 2
}

@(private = "file")
iter_auxstrict :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return iter_aux(state(Lp), true)
}

@(private = "file")
iter_auxlax :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	return iter_aux(state(Lp), false)
}

// utf8.codes(s [, lax]) -> iterator triple for a `for p, c in utf8.codes(s)` loop.
// Reference `iter_codes`.
@(private = "file")
iter_codes :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lax := kernel.api_toboolean(L, 2)
	s := transmute([]u8)aux_checkstring(L, 1)
	aux_argcheck(L, !u_iscont(u_byte(s, 0)), 1, MSG_INVALID)
	kernel.api_pushcfunction(L, lax ? iter_auxlax : iter_auxstrict)
	kernel.api_pushvalue(L, 1)
	kernel.api_pushinteger(L, 0)
	return 3
}

@(private = "file")
utf8_funcs := []Reg {
	{"offset", utf8_offset},
	{"codepoint", utf8_codepoint},
	{"char", utf8_char},
	{"len", utf8_len},
	{"codes", iter_codes},
}

// `luaopen_utf8` -- build the table and attach the charpattern constant.
//
// charpattern is a Lua pattern that matches exactly one UTF-8 character. Its bytes
// are `[\0-\x7F\xC2-\xFD][\x80-\xBF]*`: a lead byte (ASCII, or a real multi-byte
// lead in 0xC2..0xFD) followed by any run of continuation bytes. It contains an
// embedded NUL, so we build it as an explicit byte slice rather than a literal.
open_utf8 :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, utf8_funcs)
	charpattern := []u8 {
		'[', 0x00, '-', 0x7F, 0xC2, '-', 0xFD, ']',
		'[', 0x80, '-', 0xBF, ']', '*',
	}
	kernel.api_pushlstring(L, charpattern)
	kernel.api_setfield(L, -2, "charpattern")
	return 1
}
