package lua

// conf.odin -- our analogue of reference Lua's `luaconf.h`.
//
// This is the project's central knob-board: the tunable constants and
// configuration choices that the rest of the kernel reads. In reference Lua a
// lot of this is #define soup chosen at compile time; here we prefer plain Odin
// constants and (later) typed config so the choices are visible and checkable.
//
// For now it carries the version identity of the language we target. Keeping
// these here (rather than scattered) means the CLI banner, the `_VERSION`
// global, and the bytecode header all agree on exactly one source of truth.

// The Lua version we are faithfully reimplementing. These mirror the numbers in
// lua/src/lua.h for Lua 5.5.0 -- do not drift them independently.
VERSION_MAJOR_N :: 5
VERSION_MINOR_N :: 5
VERSION_RELEASE_N :: 0

// Combined numeric forms, exactly as reference Lua computes them:
//   VERSION_NUM         = MAJOR*100 + MINOR         (e.g. 505)
//   VERSION_RELEASE_NUM = VERSION_NUM*100 + RELEASE (e.g. 50500)
// These matter for bytecode/version checks later, so we compute them the same
// way rather than hardcoding the results.
VERSION_NUM :: VERSION_MAJOR_N * 100 + VERSION_MINOR_N
VERSION_RELEASE_NUM :: VERSION_NUM * 100 + VERSION_RELEASE_N

VERSION_MAJOR :: "5"
VERSION_MINOR :: "5"
VERSION_RELEASE :: "0"

// Human-facing strings. `VERSION` is what Lua exposes as the `_VERSION` global
// ("Lua 5.5"); `RELEASE` is the fully-qualified release ("Lua 5.5.0"); the
// COPYRIGHT/AUTHORS lines match the reference banner the standalone prints.
VERSION :: "Lua " + VERSION_MAJOR + "." + VERSION_MINOR
RELEASE :: VERSION + "." + VERSION_RELEASE
COPYRIGHT :: RELEASE + "  Copyright (C) 1994-2025 Lua.org, PUC-Rio"
AUTHORS :: "R. Ierusalimschy, L. H. de Figueiredo, W. Celes"

// TODO(phase-1+): migrate the real luaconf.h tunables here as they become
// relevant -- number/integer type selection, buffer sizes, stack limits, the
// bytecode ABI config (little-endian, 32-bit Instruction/int, 64-bit integer,
// IEEE-754 binary64), path separators, etc.

// ---------------------------------------------------------------------------
// Numeric formatting (float <-> string boundary)
// ---------------------------------------------------------------------------

// The printf-style formats reference Lua uses to render floats, straight from
// luaconf.h's 64-bit (double) configuration:
//   NUMBER_FMT   ("%.15g")  -- normal precision; keeps 1.1 from becoming noise
//   NUMBER_FMT_N ("%.17g")  -- full precision, used only when %.15g fails to
//                              round-trip the exact double
// These are typed as `cstring` because they are handed directly to the C
// library's `snprintf` (see object.odin's float formatting, and the note there on
// why we match C's `%g` by using C's `%g`).
NUMBER_FMT: cstring : "%.15g"
NUMBER_FMT_N: cstring : "%.17g"

// The scratch-buffer size for converting any single number to a string,
// mirroring reference Lua's `LUA_N2SBUFFSZ`. Comfortably fits the longest float
// or integer rendering plus a sign, the appended ".0", and a NUL.
N2S_BUFF_SZ :: 64

// The maximum length of a "chunk id" -- the short, human-readable source name Lua
// prints in error messages (`luaO_chunkid` truncates to this). Reference Lua's
// `LUA_IDSIZE`.
LUA_IDSIZE :: 60

// The initial size the lexer gives its token-accumulation buffer. Reference Lua's
// `LUA_MINBUFFER`.
LUA_MINBUFFER :: 32

// The name of the upvalue that holds the global environment. Reference Lua's
// `LUA_ENV`.
LUA_ENV :: "_ENV"

// Whether `global` is treated as a plain identifier rather than a reserved word.
// Reference luaconf.h defines `LUA_COMPAT_GLOBAL` unconditionally in 5.5, so the
// default build does NOT reserve `global`; we match that here. Flip to `false`
// to enable the 5.5 `global` declaration keyword.
LUA_COMPAT_GLOBAL :: true

// The "give me all results" sentinel for calls and varargs -- reference Lua's
// `LUA_MULTRET` (lua.h). A call or vararg asked for `LUA_MULTRET` results returns
// as many as it produces, adjusting the stack top rather than a fixed count.
LUA_MULTRET :: -1
