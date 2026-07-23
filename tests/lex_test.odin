package tests

// lex_test.odin -- Phase 4 tests for the tokenizer (lex.odin).
//
// These prove the scanner honestly: we drive a real `LexState` over an in-memory
// input stream and assert on the exact token codes, semantic payloads, and line
// numbers it produces -- the same observable stream the parser will consume. We
// deliberately cover the corners that bite: `->` as two tokens (Lua has no arrow),
// `global` staying a plain name under the compat default, number classification
// (int vs float, overflow-to-float, hex floats), every escape form, long strings
// with their newline-normalization and initial-newline rules, comment skipping,
// look-ahead, and the precise syntax-error messages (raised through the protected
// boundary, so we catch them and read the message back off the stack).
//
// Nothing here hardcodes an internal to force a pass: every expectation is a fact
// about Lua's documented lexical grammar.

import "core:testing"
import lua "luao:lua"

// ---------------------------------------------------------------------------
// In-memory input plumbing
// ---------------------------------------------------------------------------

// A one-shot reader that hands the whole source to the ZIO on the first call and
// signals end-of-input thereafter. This mirrors how an embedder streams a chunk
// through `lua_Reader`.
Src_Reader :: struct {
	data: [^]u8,
	len:  uint,
	done: bool,
}

src_read :: proc "c" (L: ^lua.Lua_State, data: rawptr, size: ^uint) -> [^]u8 {
	r := (^Src_Reader)(data)
	if r.done {
		size^ = 0
		return nil
	}
	r.done = true
	size^ = r.len
	return r.data
}

// Everything a test needs to keep alive while lexing. `ls` holds pointers into
// `buff`/`z`/`rd`, so this struct must outlive the scan (it lives on the test's
// stack, which it does).
Lexer_Fixture :: struct {
	L:    ^lua.Lua_State,
	ls:   lua.LexState,
	z:    lua.Zio,
	buff: lua.Mbuffer,
	rd:   Src_Reader,
}

// Stand up a fresh state and point a LexState at `source`. We root both the source
// name and the anchor table on the Lua stack -- exactly as the real parser does --
// so that an emergency collection mid-scan can never reclaim them.
setup_lexer :: proc(fx: ^Lexer_Fixture, source: string, chunkname: string) {
	L := lua.new_state(lua.default_allocator())
	fx.L = L

	// Source name, rooted on the stack.
	srcname := lua.luaS_newlstr(L, ([^]u8)(raw_data(chunkname)), uint(len(chunkname)))
	sv := lua.stack_value(L, L.top)
	lua.set_string(sv, srcname)
	L.top += 1

	// Anchor table, rooted on the stack.
	h := lua.luaH_new(L)
	hv := lua.stack_value(L, L.top)
	lua.set_gc(hv, &h.header)
	L.top += 1

	lua.mbuffer_init(&fx.buff)
	fx.rd = Src_Reader {
		data = ([^]u8)(raw_data(source)),
		len  = uint(len(source)),
		done = false,
	}
	lua.zio_init(L, &fx.z, src_read, &fx.rd)

	fx.ls.buff = &fx.buff
	fx.ls.h = h
	first := lua.zio_getc(&fx.z)
	lua.luaX_setinput(L, &fx.ls, &fx.z, srcname, first)
}

// Release everything the fixture owns. `close_state` frees all remaining objects
// (including anchored strings) and verifies the byte accounting unwinds to zero.
teardown_lexer :: proc(fx: ^Lexer_Fixture) {
	lua.mbuffer_free(fx.L, &fx.buff)
	lua.close_state(fx.L)
}

// Pull the next token and hand back the whole Token (code + seminfo).
scan :: proc(fx: ^Lexer_Fixture) -> lua.Token {
	lua.luaX_next(&fx.ls)
	return fx.ls.t
}

// A NAME/STRING token's text as an ordinary Odin string.
tok_text :: proc(tok: lua.Token) -> string {
	ts := tok.seminfo.ts
	return string(lua.str_bytes(ts)[:ts.len])
}

// ---------------------------------------------------------------------------
// Operators, punctuation, and the missing '->' token
// ---------------------------------------------------------------------------

@(test)
lex_operators_and_symbols :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "+ - * / // % ^ # & ~ | << >> == ~= <= >= < > = ( ) { } ; : :: , . .. ...", "=t")
	defer teardown_lexer(&fx)

	expected := []int {
		'+',
		'-',
		'*',
		'/',
		lua.TK_IDIV,
		'%',
		'^',
		'#',
		'&',
		'~',
		'|',
		lua.TK_SHL,
		lua.TK_SHR,
		lua.TK_EQ,
		lua.TK_NE,
		lua.TK_LE,
		lua.TK_GE,
		'<',
		'>',
		'=',
		'(',
		')',
		'{',
		'}',
		';',
		':',
		lua.TK_DBCOLON,
		',',
		'.',
		lua.TK_CONCAT,
		lua.TK_DOTS,
	}
	for want, i in expected {
		got := scan(&fx)
		testing.expectf(t, got.token == want, "token %d: want %d got %d", i, want, got.token)
	}
	testing.expect_value(t, scan(&fx).token, lua.TK_EOS)
}

// Lua has no '->' token: it must come back as '-' followed by '>'.
@(test)
lex_arrow_is_two_tokens :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "->", "=t")
	defer teardown_lexer(&fx)

	testing.expect_value(t, scan(&fx).token, int('-'))
	testing.expect_value(t, scan(&fx).token, int('>'))
	testing.expect_value(t, scan(&fx).token, lua.TK_EOS)
}

// ---------------------------------------------------------------------------
// Reserved words vs. identifiers
// ---------------------------------------------------------------------------

@(test)
lex_reserved_vs_names :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "and while function foo _ENV goto", "=t")
	defer teardown_lexer(&fx)

	testing.expect_value(t, scan(&fx).token, lua.TK_AND)
	testing.expect_value(t, scan(&fx).token, lua.TK_WHILE)
	testing.expect_value(t, scan(&fx).token, lua.TK_FUNCTION)

	foo := scan(&fx)
	testing.expect_value(t, foo.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(foo), "foo")

	env := scan(&fx)
	// _ENV is fixed but NOT reserved, so it lexes as a plain name.
	testing.expect_value(t, env.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(env), "_ENV")

	testing.expect_value(t, scan(&fx).token, lua.TK_GOTO)
}

// Under LUA_COMPAT_GLOBAL (the default in this tree), "global" is a normal name.
@(test)
lex_global_is_name_under_compat :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "global", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(tok), "global")
}

// Identifiers may contain digits and underscores after the first letter, and a
// non-ASCII byte is not a valid identifier character (it lexes as its own token).
@(test)
lex_identifier_shape :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "_x1 Abc_9", "=t")
	defer teardown_lexer(&fx)

	a := scan(&fx)
	testing.expect_value(t, a.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(a), "_x1")
	b := scan(&fx)
	testing.expect_value(t, b.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(b), "Abc_9")
}

// ---------------------------------------------------------------------------
// Numerals
// ---------------------------------------------------------------------------

@(test)
lex_integer_and_float_literals :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "0 42 0xff 3.5 .5 5. 1e3 0x1p4 0x.8p1", "=t")
	defer teardown_lexer(&fx)

	i0 := scan(&fx);testing.expect_value(t, i0.token, lua.TK_INT);testing.expect_value(t, i0.seminfo.i, 0)
	i1 := scan(&fx);testing.expect_value(t, i1.token, lua.TK_INT);testing.expect_value(t, i1.seminfo.i, 42)
	i2 := scan(&fx);testing.expect_value(t, i2.token, lua.TK_INT);testing.expect_value(t, i2.seminfo.i, 255)

	f0 := scan(&fx);testing.expect_value(t, f0.token, lua.TK_FLT);testing.expect_value(t, f0.seminfo.r, 3.5)
	f1 := scan(&fx);testing.expect_value(t, f1.token, lua.TK_FLT);testing.expect_value(t, f1.seminfo.r, 0.5)
	f2 := scan(&fx);testing.expect_value(t, f2.token, lua.TK_FLT);testing.expect_value(t, f2.seminfo.r, 5.0)
	f3 := scan(&fx);testing.expect_value(t, f3.token, lua.TK_FLT);testing.expect_value(t, f3.seminfo.r, 1000.0)
	f4 := scan(&fx);testing.expect_value(t, f4.token, lua.TK_FLT);testing.expect_value(t, f4.seminfo.r, 16.0)
	f5 := scan(&fx);testing.expect_value(t, f5.token, lua.TK_FLT);testing.expect_value(t, f5.seminfo.r, 1.0) // 0x.8p1 = 0.5*2

	testing.expect_value(t, scan(&fx).token, lua.TK_EOS)
}

// A decimal integer literal too large for a 64-bit integer becomes a float, just
// as reference Lua's `luaO_str2num` decides.
@(test)
lex_integer_overflow_becomes_float :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "99999999999999999999999", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_FLT)
	testing.expect(t, tok.seminfo.r > 9.9e22, "overflowed literal should be a large float")
}

// '..' after a number is the concat operator, not part of the number: "1..2"
// however (no spaces) is a single malformed numeral -> a syntax error (below).
@(test)
lex_number_then_concat :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "1 ..2", "=t")
	defer teardown_lexer(&fx)

	a := scan(&fx)
	testing.expect_value(t, a.token, lua.TK_INT)
	testing.expect_value(t, a.seminfo.i, 1)
	testing.expect_value(t, scan(&fx).token, lua.TK_CONCAT)
	c := scan(&fx)
	testing.expect_value(t, c.token, lua.TK_INT)
	testing.expect_value(t, c.seminfo.i, 2)
}

// ---------------------------------------------------------------------------
// Short-string literals and escapes
// ---------------------------------------------------------------------------

@(test)
lex_short_string_escapes :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	// "a\tb\65\x43\u{48}" -> a TAB b A C H
	setup_lexer(&fx, "\"a\\tb\\65\\x43\\u{48}\"", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(tok), "a\tbACH")
	testing.expect_value(t, scan(&fx).token, lua.TK_EOS)
}

// The '\z' escape zaps the following run of whitespace (including newlines).
@(test)
lex_zap_escape :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "\"a\\z   \n\t b\"", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(tok), "ab")
}

// A backslash-newline inside a string is a line continuation storing a single
// '\n', and it advances the line counter.
@(test)
lex_string_line_continuation :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "\"a\\\nb\"", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(tok), "a\nb")
	testing.expect_value(t, fx.ls.linenumber, 2)
}

// Both single and double quotes delimit short strings, and each may contain the
// other quote unescaped.
@(test)
lex_quote_flavors :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "'he said \"hi\"'", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(tok), "he said \"hi\"")
}

// ---------------------------------------------------------------------------
// Long strings and comments
// ---------------------------------------------------------------------------

@(test)
lex_long_string_basic :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "[[hello]] [==[a]b]==]", "=t")
	defer teardown_lexer(&fx)

	a := scan(&fx)
	testing.expect_value(t, a.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(a), "hello")

	// The inner "]b]" is content because it doesn't match the level-2 close.
	b := scan(&fx)
	testing.expect_value(t, b.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(b), "a]b")
}

// A newline immediately after the opening bracket is dropped, and internal
// newlines (any flavor) normalize to '\n'.
@(test)
lex_long_string_newline_rules :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "[[\nline1\r\nline2]]", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_STRING)
	testing.expect_value(t, tok_text(tok), "line1\nline2")
}

@(test)
lex_comments_are_skipped :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "-- short comment\n--[[ long\ncomment ]] 42", "=t")
	defer teardown_lexer(&fx)

	tok := scan(&fx)
	testing.expect_value(t, tok.token, lua.TK_INT)
	testing.expect_value(t, tok.seminfo.i, 42)
	testing.expect_value(t, scan(&fx).token, lua.TK_EOS)
}

// ---------------------------------------------------------------------------
// Line tracking and look-ahead
// ---------------------------------------------------------------------------

@(test)
lex_line_numbers_and_lastline :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "a\n\nb", "=t")
	defer teardown_lexer(&fx)

	scan(&fx) // 'a' on line 1
	testing.expect_value(t, fx.ls.linenumber, 1)
	b := scan(&fx) // 'b' on line 3
	testing.expect_value(t, b.token, lua.TK_NAME)
	testing.expect_value(t, fx.ls.linenumber, 3)
	// lastline is snapshotted at the START of the scan for 'b', so it records the
	// line of the previously consumed token ('a', line 1).
	testing.expect_value(t, fx.ls.lastline, 1)
}

@(test)
lex_lookahead_does_not_consume :: proc(t: ^testing.T) {
	fx: Lexer_Fixture
	setup_lexer(&fx, "local x", "=t")
	defer teardown_lexer(&fx)

	scan(&fx) // consume 'local' as the current token
	ahead := lua.luaX_lookahead(&fx.ls)
	testing.expect_value(t, ahead, lua.TK_NAME)
	// The following next() must return the same token the look-ahead peeked.
	nxt := scan(&fx)
	testing.expect_value(t, nxt.token, lua.TK_NAME)
	testing.expect_value(t, tok_text(nxt), "x")
}

// ---------------------------------------------------------------------------
// Syntax errors (raised through the protected boundary)
// ---------------------------------------------------------------------------

// A protected job that scans up to `n` tokens; a lexer error longjmps out and
// `run_protected` catches it, returning the status. The formatted error message is
// left by the lexer at the top of the stack for us to inspect.
Lex_Job :: struct {
	ls: ^lua.LexState,
	n:  int,
}

lex_job_run :: proc(L: ^lua.Lua_State, ud: rawptr) -> lua.Thread_Status {
	job := (^Lex_Job)(ud)
	for _ in 0 ..< job.n {
		lua.luaX_next(job.ls)
		if job.ls.t.token == lua.TK_EOS {
			break
		}
	}
	return .Ok
}

// Drive `source` under protection and assert it raises a syntax error whose message
// contains `needle`.
expect_syntax_error :: proc(t: ^testing.T, source: string, needle: string) {
	fx: Lexer_Fixture
	setup_lexer(&fx, source, "=t")
	defer teardown_lexer(&fx)

	job := Lex_Job {
		ls = &fx.ls,
		n  = 16,
	}
	status := lua.run_protected(fx.L, lex_job_run, &job)
	testing.expectf(t, status == .Err_Syntax, "want Err_Syntax for %q, got %v", source, status)

	// The error message string is the last thing the lexer pushed.
	msg := lua.str_value(lua.stack_value(fx.L, fx.L.top - 1))
	text := string(lua.str_bytes(msg)[:msg.len])
	testing.expectf(t, contains(text, needle), "message %q should contain %q", text, needle)
}

// A tiny substring check so tests don't depend on core:strings.
contains :: proc(haystack, needle: string) -> bool {
	if len(needle) == 0 {
		return true
	}
	if len(needle) > len(haystack) {
		return false
	}
	for i in 0 ..= len(haystack) - len(needle) {
		if haystack[i:i + len(needle)] == needle {
			return true
		}
	}
	return false
}

@(test)
lex_malformed_number_errors :: proc(t: ^testing.T) {
	expect_syntax_error(t, "1..2", "malformed number")
}

@(test)
lex_unfinished_string_errors :: proc(t: ^testing.T) {
	expect_syntax_error(t, "\"abc", "unfinished string")
}

@(test)
lex_unfinished_long_string_errors :: proc(t: ^testing.T) {
	expect_syntax_error(t, "[[unterminated", "unfinished long string")
}

@(test)
lex_invalid_escape_errors :: proc(t: ^testing.T) {
	expect_syntax_error(t, "\"\\q\"", "invalid escape sequence")
}

@(test)
lex_bad_long_delimiter_errors :: proc(t: ^testing.T) {
	expect_syntax_error(t, "[==", "invalid long string delimiter")
}

// ---------------------------------------------------------------------------
// Formatting helpers (luaO_utf8esc / luaO_pushfstring)
// ---------------------------------------------------------------------------

@(test)
utf8esc_encodes_right_justified :: proc(t: ^testing.T) {
	buff: [8]u8

	// ASCII: one byte at the very end.
	n := lua.luaO_utf8esc(buff[:], 0x48) // 'H'
	testing.expect_value(t, n, 1)
	testing.expect_value(t, buff[8 - 1], 0x48)

	// Euro sign U+20AC -> E2 82 AC, right-justified.
	n = lua.luaO_utf8esc(buff[:], 0x20AC)
	testing.expect_value(t, n, 3)
	testing.expect_value(t, buff[8 - 3], 0xE2)
	testing.expect_value(t, buff[8 - 2], 0x82)
	testing.expect_value(t, buff[8 - 1], 0xAC)
}

@(test)
pushfstring_formats_faithfully :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	defer lua.close_state(L)

	check :: proc(t: ^testing.T, ts: ^lua.TString, want: string) {
		got := string(lua.str_bytes(ts)[:ts.len])
		testing.expect_value(t, got, want)
	}

	check(t, lua.luaO_pushfstring(L, "%s=%d", "x", 42), "x=42")
	check(t, lua.luaO_pushfstring(L, "%c%c", 65, 66), "AB")
	check(t, lua.luaO_pushfstring(L, "100%%"), "100%")
	check(t, lua.luaO_pushfstring(L, "U+%U", 0x48), "U+H")
	check(t, lua.luaO_pushfstring(L, "%f", 1.5), "1.5")
}

@(test)
chunkid_renders_markers :: proc(t: ^testing.T) {
	out: [lua.LUA_IDSIZE]u8

	// '=' : verbatim name.
	w := lua.luaO_chunkid(out[:], "=stdin")
	testing.expect_value(t, string(out[:w]), "stdin")

	// '@' : file name shown as-is when short.
	w = lua.luaO_chunkid(out[:], "@main.lua")
	testing.expect_value(t, string(out[:w]), "main.lua")

	// literal source : wrapped as [string "..."].
	w = lua.luaO_chunkid(out[:], "print(1)")
	testing.expect_value(t, string(out[:w]), "[string \"print(1)\"]")

	// literal multi-line source : only the first line, then "...".
	w = lua.luaO_chunkid(out[:], "line1\nline2")
	testing.expect_value(t, string(out[:w]), "[string \"line1...\"]")
}
