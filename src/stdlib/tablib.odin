package stdlib

// tablib.odin -- our analogue of reference Lua's `ltablib.c`.
//
// The table library: insert, remove, concat, sort (with an optional comparator),
// pack, unpack, and move. `sort` in particular must match Lua's semantics around
// invalid comparators and error behavior.
//
// TODO(phase-9): implement the table.* functions against the public API.
