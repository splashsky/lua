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
