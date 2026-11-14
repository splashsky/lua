package kernel
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
// reference Lua 5.5.1's `lua.h` -- do not drift them independently.
VERSION_MAJOR_N :: 5
VERSION_MINOR_N :: 5
VERSION_RELEASE_N :: 1

// Combined numeric forms, exactly as reference Lua computes them:
//   VERSION_NUM         = MAJOR*100 + MINOR         (e.g. 505)
//   VERSION_RELEASE_NUM = VERSION_NUM*100 + RELEASE (e.g. 50501)
// These matter for bytecode/version checks later, so we compute them the same
// way rather than hardcoding the results.
VERSION_NUM :: VERSION_MAJOR_N * 100 + VERSION_MINOR_N
VERSION_RELEASE_NUM :: VERSION_NUM * 100 + VERSION_RELEASE_N

// The decimal spellings of the same three numbers. Reference `luaconf.h` writes
// these out by hand alongside the numeric forms, which is two sources of truth for
// one fact -- exactly the sort of constant that goes stale. We derive them instead,
// so bumping a number above cannot leave a stale string behind.
//
// The slice trick covers one decimal digit per component. If a component ever
// reaches 10, the assertion below fails at compile time rather than silently
// truncating, and the derivation needs widening.
@(private = "file")
DECIMAL_DIGITS :: "0123456789"

#assert(
	VERSION_MAJOR_N < 10 && VERSION_MINOR_N < 10 && VERSION_RELEASE_N < 10,
	"a version component reached two digits; widen the string derivation below",
)

VERSION_MAJOR :: DECIMAL_DIGITS[VERSION_MAJOR_N:VERSION_MAJOR_N + 1]
VERSION_MINOR :: DECIMAL_DIGITS[VERSION_MINOR_N:VERSION_MINOR_N + 1]
VERSION_RELEASE :: DECIMAL_DIGITS[VERSION_RELEASE_N:VERSION_RELEASE_N + 1]

// Human-facing strings derived from these numbers -- `VERSION` (the `_VERSION`
// global), `RELEASE`, `COPYRIGHT`, `AUTHORS` and the bytecode `SIGNATURE` --
// live in brand.odin, because they carry the configurable brand name.

// What follows are the `luaconf.h` tunables this port actually needs: the numeric
// formats at the float/string boundary, buffer sizes, stack limits, the GC
// parameters, and the path separators. The bytecode ABI configuration
// (little-endian, 32-bit Instruction and int, 64-bit integer, IEEE-754 binary64)
// lives with the dump and undump code that depends on it.

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
IDSIZE :: 60

// The initial size the lexer gives its token-accumulation buffer. Reference Lua's
// `LUA_MINBUFFER`.
MINBUFFER :: 32

// The name of the upvalue that holds the global environment. Reference Lua's
// `LUA_ENV`.
ENV_NAME :: "_ENV"

// Whether `global` is treated as a plain identifier rather than a reserved word.
// Reference luaconf.h defines `LUA_COMPAT_GLOBAL` unconditionally in 5.5, so the
// default build does NOT reserve `global`; we match that here. Flip to `false`
// to enable the 5.5 `global` declaration keyword.
COMPAT_GLOBAL :: true

// The "give me all results" sentinel for calls and varargs -- reference Lua's
// `LUA_MULTRET` (lua.h). A call or vararg asked for `LUA_MULTRET` results returns
// as many as it produces, adjusting the stack top rather than a fixed count.
MULTRET :: -1

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
REGISTRYINDEX :: -(2147483647 / 2 + 1000)

// The pseudo-index of the `i`-th upvalue of the running C function -- reference
// Lua's `lua_upvalueindex` macro. Upvalue 1 is `LUA_REGISTRYINDEX - 1`, and so on
// downward, so `index2value` recognizes any `idx < LUA_REGISTRYINDEX` as an upvalue.
upvalueindex :: #force_inline proc "contextless" (i: int) -> int {
	return REGISTRYINDEX - i
}

// The magic prefix of a precompiled (binary) chunk is brand-derived; see
// `SIGNATURE` in brand.odin.

// The arithmetic operator selectors accepted by `lua_arith` -- reference Lua's
// `LUA_OPADD` .. `LUA_OPBNOT`. Their integer values deliberately match our internal
// `Arith_Op` enum (0..13) *and* the `TM_ADD`-relative metamethod order, so the API
// can pass them straight through.
OPADD :: 0
OPSUB :: 1
OPMUL :: 2
OPMOD :: 3
OPPOW :: 4
OPDIV :: 5
OPIDIV :: 6
OPBAND :: 7
OPBOR :: 8
OPBXOR :: 9
OPSHL :: 10
OPSHR :: 11
OPUNM :: 12
OPBNOT :: 13

// The comparison selectors accepted by `lua_compare` -- reference Lua's `LUA_OPEQ`
// / `LUA_OPLT` / `LUA_OPLE`.
OPEQ :: 0
OPLT :: 1
OPLE :: 2

// The `what` selectors for `lua_gc` -- reference Lua's `LUA_GC*`. Phase 6 wires the
// ones the current (deterministic, Phase-3-foundation) collector can honor; the
// incremental/generational knobs land with the full collector in Phase 7.
GCSTOP :: 0
GCRESTART :: 1
GCCOLLECT :: 2
GCCOUNT :: 3
GCCOUNTB :: 4
GCSTEP :: 5
GCISRUNNING :: 6
GCGEN :: 7
GCINC :: 8
GCPARAM :: 9 // adjust a GC parameter (reference LUA_GCPARAM)

// The tunable GC parameters, indices into `Global_State.gcparams` -- reference
// Lua's `LUA_GCP*` (lua.h). Each is stored float-coded (see luaO_codeparam).
GCPMINORMUL :: 0 // % new bytes that triggers a minor collection
GCPMAJORMINOR :: 1 // % that shifts a major cycle back to minor
GCPMINORMAJOR :: 2 // % old bytes that shifts minor -> major
GCPPAUSE :: 3 // % heap growth before the next incremental cycle
GCPSTEPMUL :: 4 // GC "speed": work units per allocated word
GCPSTEPSIZE :: 5 // GC granularity, in bytes per step
GCPN :: 6 // number of GC parameters

// The reference default values for those parameters (lgc.h). Percentages are
// fed through `luaO_codeparam`; STEPSIZE is a byte count recovered by applying
// the coded value to 100.
GCPAUSE :: 250
GCMUL :: 200
GCSTEPSIZE_PCT :: 200 * size_of(Table)
GENMINORMUL :: 20
MINORMAJOR :: 70
MAJORMINOR :: 50
// The public type selectors returned by `lua_type` and passed to `lua_typename`
// -- reference Lua's `LUA_TNONE` / `LUA_T*` (lua.h). The kernel's own base tags
// (`TNONE`, `TNIL`, ... in object.odin) *are* those selectors: they share one
// package namespace, so the standard library (a separate package) names them
// directly as `kernel.TNIL` and no aliasing layer is needed.
