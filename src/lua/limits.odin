package lua

// limits.odin -- our analogue of reference Lua's `llimits.h`.
//
// The bedrock types and numeric limits everything else is built on: the
// concrete C-equivalent integer/float types for Lua values, instruction words,
// byte counts, and the assorted MIN/MAX bounds the kernel relies on. Getting
// these exactly right is a correctness matter -- the whole value model, the VM's
// arithmetic, and the bytecode format all inherit their behavior from here.
//
// TODO(phase-1): define the fundamental type aliases and limits, e.g.
//   Integer  (lua_Integer)   -- 64-bit signed by our fixed ABI config
//   Number   (lua_Number)    -- IEEE-754 binary64
//   Instruction              -- 32-bit unsigned bytecode word
//   Byte / lu_byte, sizes, and the MAX/MIN bounds used across the kernel.
