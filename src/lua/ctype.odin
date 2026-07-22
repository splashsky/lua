package lua

// ctype.odin -- our analogue of reference Lua's `lctype.h` / `lctype.c`.
//
// A tiny, locale-independent character-classification table used by the lexer
// (is-digit, is-alpha, is-space, is-hex, ...). Reference Lua ships its own table
// precisely so tokenizing doesn't depend on the C locale; we do the same so our
// lexer behaves identically everywhere.
//
// TODO(phase-3): the classification table and the is*/to* helpers the lexer uses.
