package lua

// table.odin -- our analogue of reference Lua's `ltable.h` / `ltable.c`.
//
// The Lua table: the language's one and only data structure, and a subtle one.
// It's a hybrid of a contiguous *array part* (for integer keys 1..n) and a
// *hash part* (for everything else), with a rehash algorithm that decides how to
// split keys between the two to keep both dense. Getting the array/hash boundary
// and the `#` length semantics right is essential for behavioral correctness.
//
// TODO(phase-3): the table type (array + node/hash parts), get/set for the
// value kinds, the rehash algorithm, and the border/length logic.
