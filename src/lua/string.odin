package lua

// string.odin -- our analogue of reference Lua's `lstring.h` / `lstring.c`.
//
// String management and interning. Lua distinguishes *short* strings (interned
// in a global string table so equality is a pointer compare) from *long* strings
// (kept separately, hashed lazily). This file owns that table, the hashing, and
// string creation -- which is why it's tightly bound to both the GC (strings are
// collectable) and `state` (the table lives in global_State).
//
// TODO(phase-3): the string type, the interning table with resize, short/long
// string creation, and hashing.
