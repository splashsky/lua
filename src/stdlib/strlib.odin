package stdlib

// strlib.odin -- our analogue of reference Lua's `lstrlib.c`.
//
// The string library, and the biggest of the standard libraries. Beyond the
// simple operations (len/sub/upper/lower/rep/reverse/byte/char) it contains two
// substantial subsystems with lots of spec corners:
//   * Lua *patterns* -- find/match/gmatch/gsub, a bespoke matcher (not regex).
//   * string.pack / string.unpack / string.packsize and string.format -- binary
//     packing and printf-style formatting.
// Both need heavy, honest test coverage.
//
// TODO(phase-9): basic ops, the pattern matcher, and pack/unpack/format.
