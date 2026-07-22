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
// TODO(phase-4): the token enum, the scanner (next/lookahead), literal parsing,
// reserved words, and error reporting with line tracking.
