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
// object.odin implements these semantics directly through core:strconv.
NUMBER_FMT :: "%.15g"
NUMBER_FMT_N :: "%.17g"

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

// ---------------------------------------------------------------------------
// Embedding-API constants (reference `lua.h`)
// ---------------------------------------------------------------------------
// These belong to the public C-API surface that Phase 6 (`api.odin`) implements.
// They live here alongside the other `luaconf`/`lua.h` tunables so the whole
// kernel can see them without a cross-file import (Odin packages share one
// namespace anyway).

// The registry's pseudo-index -- reference Lua's `LUA_REGISTRYINDEX`. The C API
// addresses a handful of "not really on the stack" locations with fixed negative
// indices well below any legal stack slot: the registry itself sits here, and the
// running C function's upvalues sit just below it (`lua_upvalueindex`). Reference
// derives the base from `INT_MAX/2` (not `LUAI_MAXSTACK`) precisely so it can never
// collide with a real negative (top-relative) index, whose magnitude is bounded by
// the far smaller `LUAI_MAXSTACK`.
LUA_REGISTRYINDEX :: -(2147483647 / 2 + 1000)

// The pseudo-index of the `i`-th upvalue of the running C function -- reference
// Lua's `lua_upvalueindex` macro. Upvalue 1 is `LUA_REGISTRYINDEX - 1`, and so on
// downward, so `index2value` recognizes any `idx < LUA_REGISTRYINDEX` as an upvalue.
lua_upvalueindex :: #force_inline proc "contextless" (i: int) -> int {
	return LUA_REGISTRYINDEX - i
}

// The magic prefix of a precompiled (binary) chunk -- reference Lua's
// `LUA_SIGNATURE`. `lua_load` peeks the first byte: an ESC (0x1b) means "binary,
// hand off to the undumper"; anything else means "source text, hand off to the
// parser".
LUA_SIGNATURE :: "\x1bLua"

// The arithmetic operator selectors accepted by `lua_arith` -- reference Lua's
// `LUA_OPADD` .. `LUA_OPBNOT`. Their integer values deliberately match our internal
// `Arith_Op` enum (0..13) *and* the `TM_ADD`-relative metamethod order, so the API
// can pass them straight through.
LUA_OPADD :: 0
LUA_OPSUB :: 1
LUA_OPMUL :: 2
LUA_OPMOD :: 3
LUA_OPPOW :: 4
LUA_OPDIV :: 5
LUA_OPIDIV :: 6
LUA_OPBAND :: 7
LUA_OPBOR :: 8
LUA_OPBXOR :: 9
LUA_OPSHL :: 10
LUA_OPSHR :: 11
LUA_OPUNM :: 12
LUA_OPBNOT :: 13

// The comparison selectors accepted by `lua_compare` -- reference Lua's `LUA_OPEQ`
// / `LUA_OPLT` / `LUA_OPLE`.
LUA_OPEQ :: 0
LUA_OPLT :: 1
LUA_OPLE :: 2

// The `what` selectors for `lua_gc` -- reference Lua's `LUA_GC*`. Phase 6 wires the
// ones the current (deterministic, Phase-3-foundation) collector can honor; the
// incremental/generational knobs land with the full collector in Phase 7.
LUA_GCSTOP :: 0
LUA_GCRESTART :: 1
LUA_GCCOLLECT :: 2
LUA_GCCOUNT :: 3
LUA_GCCOUNTB :: 4
LUA_GCSTEP :: 5
LUA_GCISRUNNING :: 6
LUA_GCGEN :: 7
LUA_GCINC :: 8
LUA_GCPARAM :: 9 // adjust a GC parameter (reference LUA_GCPARAM)

// The tunable GC parameters, indices into `Global_State.gcparams` -- reference
// Lua's `LUA_GCP*` (lua.h). Each is stored float-coded (see luaO_codeparam).
LUA_GCPMINORMUL :: 0 // % new bytes that triggers a minor collection
LUA_GCPMAJORMINOR :: 1 // % that shifts a major cycle back to minor
LUA_GCPMINORMAJOR :: 2 // % old bytes that shifts minor -> major
LUA_GCPPAUSE :: 3 // % heap growth before the next incremental cycle
LUA_GCPSTEPMUL :: 4 // GC "speed": work units per allocated word
LUA_GCPSTEPSIZE :: 5 // GC granularity, in bytes per step
LUA_GCPN :: 6 // number of GC parameters

// The reference default values for those parameters (lgc.h). Percentages are
// fed through `luaO_codeparam`; STEPSIZE is a byte count recovered by applying
// the coded value to 100.
LUAI_GCPAUSE :: 250
LUAI_GCMUL :: 200
LUAI_GCSTEPSIZE_PCT :: 200 * size_of(Table)
LUAI_GENMINORMUL :: 20
LUAI_MINORMAJOR :: 70
LUAI_MAJORMINOR :: 50
// The public type selectors returned by `lua_type` and passed to `lua_typename`
// -- reference Lua's `LUA_TNONE` / `LUA_T*` (lua.h). These are just re-exports of
// the kernel's base tags under their public API spelling, so the standard library
// (a separate package) can name types without reaching into `object.odin`.
LUA_TNONE :: TNONE
LUA_TNIL :: TNIL
LUA_TBOOLEAN :: TBOOLEAN
LUA_TLIGHTUSERDATA :: TLIGHTUSERDATA
LUA_TNUMBER :: TNUMBER
LUA_TSTRING :: TSTRING
LUA_TTABLE :: TTABLE
LUA_TFUNCTION :: TFUNCTION
LUA_TUSERDATA :: TUSERDATA
LUA_TTHREAD :: TTHREAD
