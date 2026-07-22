package stdlib

// utf8lib.odin -- our analogue of reference Lua's `lutf8lib.c`.
//
// The utf8 library: char/codepoint/len/offset/codes and the utf8.charpattern
// constant. It implements Lua's specific, permissive view of UTF-8 (including
// its handling of over-long and out-of-range sequences), which we must match.
//
// TODO(phase-9): implement the utf8.* functions and charpattern.
