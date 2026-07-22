package stdlib

// mathlib.odin -- our analogue of reference Lua's `lmathlib.c`.
//
// The math library: the usual floating-point functions (sin/cos/exp/log/sqrt/
// ...), the integer/float-aware helpers (floor/ceil/abs/fmod/modf/tointeger/
// type), min/max, the mathematical constants, and the pseudo-random generator
// (math.random / math.randomseed) whose algorithm and seeding Lua specifies.
//
// TODO(phase-9): implement the math.* functions and the RNG against the API.
