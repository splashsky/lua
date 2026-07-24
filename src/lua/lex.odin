package lua

// lex.odin -- our analogue of reference Lua's `llex.h` / `llex.c`.
//
// The tokenizer. It turns a stream of source bytes (via ZIO) into a stream of
// tokens for the parser: keywords, names, string/number literals (with all of
// Lua's escape and long-bracket rules), and operators. It also owns reserved-
// word recognition and produces the precise syntax-error messages Lua is known
// for, which means it raises protected errors -- hence its dependence on the
// control/error primitives.
//
// A faithful transcription of `llex.c`. The interesting subtleties, all carried
// over deliberately, are called out in comments where they bite: bytes are kept
// as `int`s (so EOZ = -1 never collides with a real 0..255 byte), single-char
// tokens ARE their byte value, and the shared token buffer must be reset at every
// entry and around long comments.

// ---------------------------------------------------------------------------
// Token codes
// ---------------------------------------------------------------------------
//
// Reference Lua's `enum RESERVED`. Single-char tokens (`+`, `{`, `;`, ...) are
// represented by their own byte value, so the multi-char and reserved-word tokens
// have to start above every possible byte. `FIRST_RESERVED` is `UCHAR_MAX + 1`.

FIRST_RESERVED :: 256

// Reserved words, in ORDER RESERVED. Their positions matter: `luaX_init` marks
// each interned keyword with `extra = index + 1`, and the scanner turns that back
// into `extra - 1 + FIRST_RESERVED` to recover the token.
TK_AND :: FIRST_RESERVED + 0
TK_BREAK :: FIRST_RESERVED + 1
TK_DO :: FIRST_RESERVED + 2
TK_ELSE :: FIRST_RESERVED + 3
TK_ELSEIF :: FIRST_RESERVED + 4
TK_END :: FIRST_RESERVED + 5
TK_FALSE :: FIRST_RESERVED + 6
TK_FOR :: FIRST_RESERVED + 7
TK_FUNCTION :: FIRST_RESERVED + 8
TK_GLOBAL :: FIRST_RESERVED + 9
TK_GOTO :: FIRST_RESERVED + 10
TK_IF :: FIRST_RESERVED + 11
TK_IN :: FIRST_RESERVED + 12
TK_LOCAL :: FIRST_RESERVED + 13
TK_NIL :: FIRST_RESERVED + 14
TK_NOT :: FIRST_RESERVED + 15
TK_OR :: FIRST_RESERVED + 16
TK_REPEAT :: FIRST_RESERVED + 17
TK_RETURN :: FIRST_RESERVED + 18
TK_THEN :: FIRST_RESERVED + 19
TK_TRUE :: FIRST_RESERVED + 20
TK_UNTIL :: FIRST_RESERVED + 21
TK_WHILE :: FIRST_RESERVED + 22

// The number of reserved words. Reference `NUM_RESERVED = TK_WHILE - FIRST_RESERVED + 1`.
NUM_RESERVED :: TK_WHILE - FIRST_RESERVED + 1

// Other multi-character terminals, then the "value" tokens (numbers/name/string).
TK_IDIV :: FIRST_RESERVED + 23
TK_CONCAT :: FIRST_RESERVED + 24
TK_DOTS :: FIRST_RESERVED + 25
TK_EQ :: FIRST_RESERVED + 26
TK_GE :: FIRST_RESERVED + 27
TK_LE :: FIRST_RESERVED + 28
TK_NE :: FIRST_RESERVED + 29
TK_SHL :: FIRST_RESERVED + 30
TK_SHR :: FIRST_RESERVED + 31
TK_DBCOLON :: FIRST_RESERVED + 32
TK_EOS :: FIRST_RESERVED + 33
TK_FLT :: FIRST_RESERVED + 34
TK_INT :: FIRST_RESERVED + 35
TK_NAME :: FIRST_RESERVED + 36
TK_STRING :: FIRST_RESERVED + 37

// The printable spellings of every non-single-char token, indexed by
// `token - FIRST_RESERVED`. ORDER RESERVED -- this array must stay lock-step with
// the constants above. Reference Lua's `luaX_tokens`.
@(rodata)
luaX_tokens := [?]string {
	"and",
	"break",
	"do",
	"else",
	"elseif",
	"end",
	"false",
	"for",
	"function",
	"global",
	"goto",
	"if",
	"in",
	"local",
	"nil",
	"not",
	"or",
	"repeat",
	"return",
	"then",
	"true",
	"until",
	"while",
	"//",
	"..",
	"...",
	"==",
	">=",
	"<=",
	"~=",
	"<<",
	">>",
	"::",
	"<eof>",
	"<number>",
	"<integer>",
	"<name>",
	"<string>",
}

// ---------------------------------------------------------------------------
// Scanner state
// ---------------------------------------------------------------------------

// The semantic payload a token can carry -- reference Lua's `SemInfo`. A number
// literal fills `r` or `i`; a name/string literal fills `ts`. It is a raw union
// because only one field is ever live at a time (the token code says which).
SemInfo :: struct #raw_union {
	r:  Number, // a float literal's value
	i:  Integer, // an integer literal's value
	ts: ^TString, // a name or string literal's interned text
}

// A scanned token: its code plus any semantic payload. Reference `Token`.
Token :: struct {
	token:   int,
	seminfo: SemInfo,
}

// The full scanner state, shared with the parser once it exists -- reference
// Lua's `LexState`. The `fs`/`dyd` fields point at parser-owned structures the
// lexer never dereferences (they only ride along so a single `LexState` serves
// both), which is why `parse.odin` gives them placeholder types for now.
LexState :: struct {
	current:    int, // current character, or EOZ (kept as int on purpose)
	linenumber: int, // input line counter
	lastline:   int, // line of the last token consumed
	t:          Token, // current token
	lookahead:  Token, // look-ahead token
	fs:         ^FuncState, // current function (parser)
	L:          ^Lua_State,
	z:          ^Zio, // input stream
	buff:       ^Mbuffer, // buffer for building token text
	h:          ^Table, // anchors scanned strings against collection
	dyd:        ^Dyndata, // dynamic parser structures
	source:     ^TString, // current source name
	envn:       ^TString, // the "_ENV" name
	brkn:       ^TString, // the "break" name (used as a label)
	glbn:       ^TString, // the "global" name (when not reserved)
}

// ---------------------------------------------------------------------------
// Low-level input + buffer helpers
// ---------------------------------------------------------------------------

// Pull the next byte from the stream into `current` -- reference macro `next`.
@(private = "file")
advance :: #force_inline proc(ls: ^LexState) {
	ls.current = zio_getc(ls.z)
}

// Is the current character a newline (either flavor)? Reference `currIsNewline`.
@(private = "file")
curr_is_newline :: #force_inline proc(ls: ^LexState) -> bool {
	return ls.current == '\n' || ls.current == '\r'
}

// Append character `c` to the token buffer, growing it 1.5x when full. Reference
// Lua's `save`. On genuine overflow it raises "lexical element too long"; note
// `lexerror` diverges (longjmp), so the growth code below never runs in that case.
@(private = "file")
save :: proc(ls: ^LexState, c: int) {
	b := ls.buff
	if b.n + 1 > b.buffsize {
		if b.buffsize >= MAX_SIZE / 3 * 2 { // larger than MAX_SIZE/1.5?
			lexerror(ls, "lexical element too long", 0)
		}
		newsize := b.buffsize + (b.buffsize >> 1) // 1.5x the old size
		mbuffer_resize(ls.L, b, newsize)
	}
	b.buffer[b.n] = byte(c)
	b.n += 1
}

// Save the current character, then advance. Reference macro `save_and_next`.
@(private = "file")
save_and_next :: #force_inline proc(ls: ^LexState) {
	save(ls, ls.current)
	advance(ls)
}

// Drop the last `n` saved characters from the buffer -- reference `luaZ_buffremove`.
// The escape readers use this to erase the raw `\xNN` / `\u{...}` / `\ddd` text
// after decoding it, leaving only the decoded byte(s).
@(private = "file")
buff_remove :: #force_inline proc(ls: ^LexState, n: uint) {
	ls.buff.n -= n
}

// ---------------------------------------------------------------------------
// Initialization
// ---------------------------------------------------------------------------

// Intern the reserved-word strings and the `_ENV` name once, at state creation,
// and fix them so the collector never frees them -- reference Lua's `luaX_init`.
// Marking each keyword with `extra = i + 1` is what lets `isreserved` recognize it
// later; `_ENV` is fixed but left with `extra == 0` so it stays a normal name.
luaX_init :: proc(L: ^Lua_State) {
	e := luaS_new(L, LUA_ENV) // create the env name
	luaC_fix(L, &e.header) // never collect this name
	for i in 0 ..< NUM_RESERVED {
		ts := luaS_new(L, luaX_tokens[i])
		luaC_fix(L, &ts.header) // reserved words are never collected
		ts.extra = u8(i + 1) // mark as reserved word #(i+1)
	}
}

// Point a `LexState` at a fresh input stream and prime the first character --
// reference Lua's `luaX_setinput`. The caller is responsible for having set
// `ls.buff` (a token buffer) and `ls.h` (the anchor table) beforehand, exactly as
// the parser does. `_ENV`, `break`, and `global` are all fixed strings, so caching
// them here is safe. Under `LUA_COMPAT_GLOBAL` we clear `global`'s reserved mark so
// it lexes as an ordinary identifier.
luaX_setinput :: proc(L: ^Lua_State, ls: ^LexState, z: ^Zio, source: ^TString, firstchar: int) {
	ls.t.token = 0
	ls.L = L
	ls.current = firstchar
	ls.lookahead.token = TK_EOS // no look-ahead token yet
	ls.z = z
	ls.fs = nil
	ls.linenumber = 1
	ls.lastline = 1
	ls.source = source
	ls.envn = luaS_new(L, LUA_ENV) // get env string
	ls.brkn = luaS_new(L, "break") // get "break" string
	when LUA_COMPAT_GLOBAL {
		// Compatibility mode: "global" is not a reserved word.
		ls.glbn = luaS_new(L, "global")
		ls.glbn.extra = 0 // mark it as not reserved
	}
	mbuffer_resize(ls.L, ls.buff, LUA_MINBUFFER) // initialize the buffer
}

// ---------------------------------------------------------------------------
// String anchoring
// ---------------------------------------------------------------------------

// Anchor a scanned string in the scanner's table so it survives until compilation
// finishes (by which point the parser will have referenced it somewhere), and
// deduplicate long strings to a single copy. Reference Lua's `anchorstr`.
//
// The one memory-safety subtlety: before storing the string we push it on the Lua
// stack. That matters because `luaH_set` can trigger an allocation, which can
// trigger an emergency collection -- and the freshly created, not-yet-stored
// string is reachable only through the stack at that instant. We also call
// `luaC_checkGC` here (as reference does) to pace the incremental collector while
// the new string is still anchored on the stack.
@(private = "file")
anchorstr :: proc(ls: ^LexState, ts: ^TString) -> ^TString {
	L := ls.L
	oldts: TValue
	luaH_getstr(ls.h, ts, &oldts)
	if !is_nil(&oldts) { // string already present?
		return str_value(&oldts) // reuse the stored copy
	}
	// Create a new entry: t[string] = string, keeping it rooted meanwhile.
	stv := stack_value(L, L.top)
	set_string(stv, ts) // push (anchor) the string on the stack
	L.top += 1
	luaH_set(L, ls.h, stv, stv)
	luaC_checkGC(L) // pace the collector while the string is still anchored
	L.top -= 1 // remove the string from the stack
	return ts
}

// Create a string from raw bytes and anchor it. Reference `luaX_newstring`.
luaX_newstring :: proc(ls: ^LexState, str: [^]u8, l: uint) -> ^TString {
	return anchorstr(ls, luaS_newlstr(ls.L, str, l))
}

// ---------------------------------------------------------------------------
// Line tracking
// ---------------------------------------------------------------------------

// Consume a newline sequence (any of \n, \r, \n\r, \r\n counts as ONE line break)
// and bump the line counter. Reference Lua's `inclinenumber`. It raises if a chunk
// somehow exceeds INT_MAX lines (matching reference's C-int line counter).
@(private = "file")
inclinenumber :: proc(ls: ^LexState) {
	old := ls.current
	// caller guarantees curr_is_newline(ls)
	advance(ls) // skip '\n' or '\r'
	if curr_is_newline(ls) && ls.current != old {
		advance(ls) // skip the paired '\n\r' or '\r\n'
	}
	ls.linenumber += 1
	if ls.linenumber >= int(max(i32)) {
		lexerror(ls, "chunk has too many lines", 0)
	}
}

// ---------------------------------------------------------------------------
// Error reporting
// ---------------------------------------------------------------------------

// Render a token for an error message -- reference Lua's `luaX_token2str`. Single
// printable bytes become `'x'`; control bytes become `'<\NN>'`; multi-char tokens
// and reserved words are quoted; value tokens use their descriptive spelling.
luaX_token2str :: proc(ls: ^LexState, token: int) -> string {
	if token < FIRST_RESERVED { // single-byte symbol?
		if is_print(token) {
			return string(str_slice(luaO_pushfstring(ls.L, "'%c'", token)))
		} else { // control character
			return string(str_slice(luaO_pushfstring(ls.L, "'<\\%d>'", token)))
		}
	} else {
		s := luaX_tokens[token - FIRST_RESERVED]
		if token < TK_EOS { // fixed-format symbol or reserved word?
			return string(str_slice(luaO_pushfstring(ls.L, "'%s'", s)))
		} else { // names, strings, and numerals
			return s
		}
	}
}

// Like `luaX_token2str`, but for value tokens it shows the actual text scanned
// (still sitting in the buffer) rather than the generic `<name>` placeholder.
// Reference Lua's `txtToken`.
@(private = "file")
txtToken :: proc(ls: ^LexState, token: int) -> string {
	switch token {
	case TK_NAME, TK_STRING, TK_FLT, TK_INT:
		return string(
			str_slice(luaO_pushfstring(ls.L, "'%s'", string(ls.buff.buffer[:ls.buff.n]))),
		)
	case:
		return luaX_token2str(ls, token)
	}
}

// Raise a syntax error at the current position -- reference Lua's `lexerror`.
// It prefixes the message with `source:line:`, optionally appends `near <token>`,
// and throws `.Err_Syntax`. The final formatted message is left on top of the
// stack for `set_error_object` to pick up as the error value.
@(private = "file")
lexerror :: proc(ls: ^LexState, msg: string, token: int) {
	full := luaG_addinfo(ls.L, msg, ls.source, ls.linenumber)
	msg2 := string(str_slice(full))
	if token != 0 {
		luaO_pushfstring(ls.L, "%s near %s", msg2, txtToken(ls, token))
	}
	throw(ls.L, .Err_Syntax)
}

// Raise a syntax error blaming the current token -- reference `luaX_syntaxerror`.
luaX_syntaxerror :: proc(ls: ^LexState, msg: string) {
	lexerror(ls, msg, ls.t.token)
}

// ---------------------------------------------------------------------------
// Small scan helpers
// ---------------------------------------------------------------------------

// If the current char equals `c`, consume it and report success. Reference
// `check_next1`. (Does NOT save into the buffer -- used for pure operators.)
@(private = "file")
check_next1 :: proc(ls: ^LexState, c: int) -> bool {
	if ls.current == c {
		advance(ls)
		return true
	}
	return false
}

// If the current char is either of the two bytes in `set`, save and consume it.
// Reference `check_next2`. Used inside numerals (exponent marks and signs).
@(private = "file")
check_next2 :: proc(ls: ^LexState, set: string) -> bool {
	if ls.current == int(set[0]) || ls.current == int(set[1]) {
		save_and_next(ls)
		return true
	}
	return false
}

// ---------------------------------------------------------------------------
// Numerals
// ---------------------------------------------------------------------------

// Scan a numeric literal -- reference Lua's `read_numeral`. It is deliberately
// permissive (it accepts a superset of well-formed numerals) and defers the real
// validation to `str_to_number`, which rejects anything malformed. Handling of the
// `[+-]` exponent sign only after an exponent mark is what stops `3-4` or `0xe+1`
// from being read as one number. Unlike reference we do NOT append a trailing NUL,
// because `str_to_number` takes an exact byte slice rather than a C string.
@(private = "file")
read_numeral :: proc(ls: ^LexState, seminfo: ^SemInfo) -> int {
	expo := "Ee" // exponent marks for decimal; "Pp" for hex
	first := ls.current
	// caller guarantees is_digit(ls.current) (possibly after an initial '.')
	save_and_next(ls)
	if first == '0' && check_next2(ls, "xX") { // hexadecimal?
		expo = "Pp"
	}
	for {
		if check_next2(ls, expo) { // exponent mark?
			check_next2(ls, "-+") // optional exponent sign
		} else if is_xdigit(ls.current) || ls.current == '.' {
			save_and_next(ls)
		} else {
			break
		}
	}
	if is_lalpha(ls.current) { // numeral touching a letter -> force an error
		save_and_next(ls)
	}
	o, size := str_to_number(ls.buff.buffer[:ls.buff.n])
	if size == 0 { // format error?
		lexerror(ls, "malformed number", TK_FLT)
	}
	if is_integer(&o) {
		seminfo.i = o.value_.i
		return TK_INT
	} else {
		seminfo.r = o.value_.n
		return TK_FLT
	}
}

// ---------------------------------------------------------------------------
// Long strings and long comments
// ---------------------------------------------------------------------------

// Read a long-bracket level marker `[=*[` or `]=*]`, leaving the final bracket as
// the current character. Reference Lua's `skip_sep`. Returns the number of `=`s
// plus 2 for a complete marker, 1 for a lone bracket, or 0 for an unterminated
// `[==...`.
@(private = "file")
skip_sep :: proc(ls: ^LexState) -> uint {
	count: uint = 0
	s := ls.current // the opening '[' or closing ']'
	save_and_next(ls)
	for ls.current == '=' {
		save_and_next(ls)
		count += 1
	}
	if ls.current == s {
		return count + 2
	}
	if count == 0 {
		return 1
	}
	return 0
}

// Read the body of a long string (or skip a long comment when `seminfo` is nil) --
// reference Lua's `read_long_string`. An initial newline immediately after the
// opening bracket is dropped, and every internal newline (any flavor) is
// normalized to a single '\n'. The `sep` characters of each delimiter are trimmed
// off before interning.
@(private = "file")
read_long_string :: proc(ls: ^LexState, seminfo: ^SemInfo, sep: uint) {
	line := ls.linenumber // initial line, for the error message
	save_and_next(ls) // skip the 2nd '['
	if curr_is_newline(ls) { // string starts with a newline?
		inclinenumber(ls) // skip it (without storing)
	}
	loop: for {
		switch ls.current {
		case EOZ: // reached end of input before the closing bracket
			what := seminfo != nil ? "string" : "comment"
			msg := string(
				str_slice(
					luaO_pushfstring(
						ls.L,
						"unfinished long %s (starting at line %d)",
						what,
						line,
					),
				),
			)
			lexerror(ls, msg, TK_EOS)
		case ']':
			if skip_sep(ls) == sep {
				save_and_next(ls) // skip the 2nd ']'
				break loop
			}
		case '\n', '\r':
			save(ls, '\n') // normalize the line break
			inclinenumber(ls)
			if seminfo == nil {
				mbuffer_reset(ls.buff) // a comment keeps no content
			}
		case:
			if seminfo != nil {
				save_and_next(ls)
			} else {
				advance(ls)
			}
		}
	}
	if seminfo != nil {
		// Trim `sep` chars from the front (the "[==[") and back (the "]==]").
		seminfo.ts = luaX_newstring(ls, ls.buff.buffer[sep:], ls.buff.n - 2 * sep)
	}
}

// ---------------------------------------------------------------------------
// Short-string escape handling
// ---------------------------------------------------------------------------

// Assert that an escape's precondition `c` holds; on failure, save the offending
// character (for the error text) and raise. Reference Lua's `esccheck`.
@(private = "file")
esccheck :: proc(ls: ^LexState, c: bool, msg: string) {
	if !c {
		if ls.current != EOZ {
			save_and_next(ls) // add current to buffer for the error message
		}
		lexerror(ls, msg, TK_STRING)
	}
}

// Read one hex digit (saving it), returning its value. Reference `gethexa`.
@(private = "file")
gethexa :: proc(ls: ^LexState) -> int {
	save_and_next(ls)
	esccheck(ls, is_xdigit(ls.current), "hexadecimal digit expected")
	return int(hexavalue(byte(ls.current)))
}

// Read a `\xNN` escape (two hex digits) and erase the saved digits. Reference
// Lua's `readhexaesc`.
@(private = "file")
readhexaesc :: proc(ls: ^LexState) -> int {
	r := gethexa(ls)
	r = (r << 4) + gethexa(ls)
	buff_remove(ls, 2) // remove the two saved hex chars
	return r
}

// Read a `\u{XXXX}` escape into a code point. Reference Lua's `readutf8esc`. It
// saves everything as it goes (for error reporting) and erases exactly `i` chars
// on success -- and `i` intentionally counts the leading backslash, so the caller
// does no further removal.
@(private = "file")
readutf8esc :: proc(ls: ^LexState) -> u32 {
	i: uint = 4 // chars to remove: start with #"\u{X"
	save_and_next(ls) // skip 'u'
	esccheck(ls, ls.current == '{', "missing '{'")
	r := u32(gethexa(ls)) // must have at least one digit
	for {
		save_and_next(ls)
		if !is_xdigit(ls.current) {
			break
		}
		i += 1
		esccheck(ls, r <= (u32(0x7FFFFFFF) >> 4), "UTF-8 value too large")
		r = (r << 4) + u32(hexavalue(byte(ls.current)))
	}
	esccheck(ls, ls.current == '}', "missing '}'")
	advance(ls) // skip '}'
	buff_remove(ls, i) // remove the saved chars (including the backslash)
	return r
}

// Encode a `\u{...}` escape's code point as UTF-8 into the buffer. Reference
// Lua's `utf8esc`. Recall `luaO_utf8esc` right-justifies its output in `buff`.
@(private = "file")
utf8esc :: proc(ls: ^LexState) {
	buff: [UTF8BUFFSZ]u8
	n := luaO_utf8esc(buff[:], readutf8esc(ls))
	for n > 0 { // append the encoded bytes, in order
		save(ls, int(buff[UTF8BUFFSZ - n]))
		n -= 1
	}
}

// Read a `\ddd` decimal escape (up to three digits) and erase the saved digits.
// Reference Lua's `readdecesc`. A value above 255 is an error.
@(private = "file")
readdecesc :: proc(ls: ^LexState) -> int {
	r := 0
	i: uint = 0
	for i < 3 && is_digit(ls.current) {
		r = 10 * r + (ls.current - '0')
		save_and_next(ls)
		i += 1
	}
	esccheck(ls, r <= 255, "decimal escape too large") // UCHAR_MAX
	buff_remove(ls, i) // remove the read digits
	return r
}

// What to do with the decoded escape character once the big switch has classified
// it: some escapes save a computed byte, some (like \u and \z) manage the buffer
// themselves. This models reference Lua's `read_save` / `only_save` / `no_save`
// gotos without needing goto.
@(private = "file")
Esc_Action :: enum {
	Read_Save, // consume one more char, then remove the '\\' and save `c`
	Only_Save, // remove the '\\' and save `c` (char already consumed)
	No_Save, // buffer already handled; do nothing here
}

// Read a short (quoted) string literal -- reference Lua's `read_string`. The
// delimiter is kept transiently for error messages, then trimmed along with its
// twin when the finished text is interned.
@(private = "file")
read_string :: proc(ls: ^LexState, del: int, seminfo: ^SemInfo) {
	save_and_next(ls) // keep the opening delimiter (for error messages)
	for ls.current != del {
		switch ls.current {
		case EOZ:
			lexerror(ls, "unfinished string", TK_EOS)
		case '\n', '\r':
			lexerror(ls, "unfinished string", TK_STRING)
		case '\\':
			// An escape sequence. Keep the backslash transiently so error
			// messages can quote it, then decode.
			save_and_next(ls) // keep '\\'
			c := 0
			action := Esc_Action.Read_Save
			switch ls.current {
			case 'a':
				c = 7 // '\a' bell
				action = .Read_Save
			case 'b':
				c = 8 // '\b' backspace
				action = .Read_Save
			case 'f':
				c = 12 // '\f' form feed
				action = .Read_Save
			case 'n':
				c = 10 // '\n'
				action = .Read_Save
			case 'r':
				c = 13 // '\r'
				action = .Read_Save
			case 't':
				c = 9 // '\t'
				action = .Read_Save
			case 'v':
				c = 11 // '\v' vertical tab
				action = .Read_Save
			case 'x':
				c = readhexaesc(ls)
				action = .Read_Save
			case 'u':
				utf8esc(ls)
				action = .No_Save
			case '\n', '\r':
				inclinenumber(ls)
				c = 10 // a line continuation stores a '\n'
				action = .Only_Save
			case '\\', '"', '\'':
				c = ls.current
				action = .Read_Save
			case EOZ:
				action = .No_Save // will raise "unfinished string" next loop
			case 'z':
				// '\z' zaps the following run of whitespace.
				buff_remove(ls, 1) // remove the '\\'
				advance(ls) // skip the 'z'
				for is_space(ls.current) {
					if curr_is_newline(ls) {
						inclinenumber(ls)
					} else {
						advance(ls)
					}
				}
				action = .No_Save
			case:
				esccheck(ls, is_digit(ls.current), "invalid escape sequence")
				c = readdecesc(ls) // decimal escape '\ddd'
				action = .Only_Save
			}
			if action == .Read_Save {
				advance(ls)
			}
			if action == .Read_Save || action == .Only_Save {
				buff_remove(ls, 1) // remove the '\\'
				save(ls, c)
			}
		case:
			save_and_next(ls)
		}
	}
	save_and_next(ls) // skip the closing delimiter
	// Trim the two delimiter bytes we kept at the ends.
	seminfo.ts = luaX_newstring(ls, ls.buff.buffer[1:], ls.buff.n - 2)
}

// ---------------------------------------------------------------------------
// The main scanner
// ---------------------------------------------------------------------------

// Scan and return the next token, filling `seminfo` for value tokens. Reference
// Lua's `llex`. The buffer is reset on entry because tokens accumulate into it.
@(private = "file")
llex :: proc(ls: ^LexState, seminfo: ^SemInfo) -> int {
	mbuffer_reset(ls.buff)
	for {
		switch ls.current {
		case '\n', '\r': // line breaks
			inclinenumber(ls)
		case ' ', '\f', '\t', '\v': // other whitespace
			advance(ls)
		case '-': // '-' or a comment
			advance(ls)
			if ls.current != '-' {
				return '-'
			}
			// A comment. Note there is no '->' token in Lua: a lone '-' followed by
			// '>' lexes as '-' then '>'.
			advance(ls)
			if ls.current == '[' { // possibly a long comment
				sep := skip_sep(ls)
				mbuffer_reset(ls.buff) // skip_sep dirtied the buffer
				if sep >= 2 {
					read_long_string(ls, nil, sep) // skip the long comment
					mbuffer_reset(ls.buff)
					continue
				}
			}
			// A short comment: run to end of line (or end of input).
			for !curr_is_newline(ls) && ls.current != EOZ {
				advance(ls)
			}
		case '[': // long string or a lone '['
			sep := skip_sep(ls)
			if sep >= 2 {
				read_long_string(ls, seminfo, sep)
				return TK_STRING
			} else if sep == 0 { // '[=...' missing its second bracket
				lexerror(ls, "invalid long string delimiter", TK_STRING)
			}
			return '['
		case '=':
			advance(ls)
			if check_next1(ls, '=') {
				return TK_EQ
			} else {
				return '='
			}
		case '<':
			advance(ls)
			if check_next1(ls, '=') {
				return TK_LE
			} else if check_next1(ls, '<') {
				return TK_SHL
			} else {
				return '<'
			}
		case '>':
			advance(ls)
			if check_next1(ls, '=') {
				return TK_GE
			} else if check_next1(ls, '>') {
				return TK_SHR
			} else {
				return '>'
			}
		case '/':
			advance(ls)
			if check_next1(ls, '/') {
				return TK_IDIV
			} else {
				return '/'
			}
		case '~':
			advance(ls)
			if check_next1(ls, '=') {
				return TK_NE
			} else {
				return '~'
			}
		case ':':
			advance(ls)
			if check_next1(ls, ':') {
				return TK_DBCOLON
			} else {
				return ':'
			}
		case '"', '\'': // short string literals
			read_string(ls, ls.current, seminfo)
			return TK_STRING
		case '.': // '.', '..', '...', or a number starting with '.'
			save_and_next(ls)
			if check_next1(ls, '.') {
				if check_next1(ls, '.') {
					return TK_DOTS
				} else {
					return TK_CONCAT
				}
			} else if !is_digit(ls.current) {
				return '.'
			} else {
				return read_numeral(ls, seminfo)
			}
		case '0', '1', '2', '3', '4', '5', '6', '7', '8', '9':
			return read_numeral(ls, seminfo)
		case EOZ:
			return TK_EOS
		case:
			if is_lalpha(ls.current) { // identifier or reserved word?
				for {
					save_and_next(ls)
					if !is_lalnum(ls.current) {
						break
					}
				}
				ts := luaS_newlstr(ls.L, ls.buff.buffer, ls.buff.n)
				// A short string with a nonzero `extra` is a reserved word (see
				// luaX_init); recover its token from that index.
				if ts.tt == VSHRSTR && ts.extra > 0 {
					return int(ts.extra) - 1 + FIRST_RESERVED
				} else {
					seminfo.ts = anchorstr(ls, ts)
					return TK_NAME
				}
			} else { // single-char token ('+', '*', '%', '{', '}', ...)
				c := ls.current
				advance(ls)
				return c
			}
		}
	}
}

// ---------------------------------------------------------------------------
// Public token stepping
// ---------------------------------------------------------------------------

// Advance to the next token, honoring any buffered look-ahead. Reference
// `luaX_next`. `lastline` remembers where the just-consumed token was, which the
// parser uses for line-accurate error messages.
luaX_next :: proc(ls: ^LexState) {
	ls.lastline = ls.linenumber
	if ls.lookahead.token != TK_EOS { // is there a look-ahead token?
		ls.t = ls.lookahead // use it
		ls.lookahead.token = TK_EOS // and discharge it
	} else {
		ls.t.token = llex(ls, &ls.t.seminfo) // read a fresh token
	}
}

// Peek one token ahead without consuming the current one -- reference
// `luaX_lookahead`. Only one token of look-ahead is ever needed (asserted).
luaX_lookahead :: proc(ls: ^LexState) -> int {
	assert(ls.lookahead.token == TK_EOS)
	ls.lookahead.token = llex(ls, &ls.lookahead.seminfo)
	return ls.lookahead.token
}
