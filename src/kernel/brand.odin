package kernel

// brand.odin -- the build-time branding knobs.
//
// Nothing in this runtime hardcodes the name of the language it implements.
// Every user-visible name, path, and environment variable is derived from the
// handful of `#config` constants below, so a rebranded build is a matter of
// `-define:` flags rather than a fork:
//
//     odin build src -collection:lang=src \
//         -define:BRAND="Moon" -define:BRAND_LOWER="moon" \
//         -define:SOURCE_EXT=".moon" -define:ENV_PREFIX="MOON"
//
// The defaults reproduce Lua 5.5.1 exactly -- that is the reference profile the
// PUC-Rio test suite under tests/puc/ validates, so a plain build with no
// defines must stay byte-for-byte behaviour-compatible with reference Lua.
//
// Identifiers cannot be parameterized this way (Odin resolves names at compile
// time, and `-define:` only produces *values*), which is why the source itself
// uses neutral subsystem names -- `api_*`, `code_*`, `table_*` -- rather than a
// brand-derived prefix. Only data is configurable; names are already neutral.

// ---------------------------------------------------------------------------
// The knobs
// ---------------------------------------------------------------------------

// The display brand. Appears in the `_VERSION` global, the interpreter banner,
// `debug.getinfo().what` for a non-native function, the precompiled-chunk
// signature, and the type names in error messages.
BRAND :: #config(BRAND, "Lua")

// The lower-case brand, used where a name has to be filesystem- or command-line
// shaped: the program names, the `package.path` directory components, and the
// `os.tmpname` prefix. Odin has no compile-time `to_lower`, so this is its own
// knob rather than a transform of `BRAND`; keep the two consistent.
BRAND_LOWER :: #config(BRAND_LOWER, "lua")

// The extension of a source file, including the dot. Drives the default
// `package.path` templates.
SOURCE_EXT :: #config(SOURCE_EXT, ".lua")

// The prefix of every environment variable the runtime consults, without the
// trailing underscore: `LUA_INIT`, `LUA_PATH`, `LUA_CPATH`, `LUA_NOENV`.
ENV_PREFIX :: #config(ENV_PREFIX, "LUA")

// The copyright and authors lines the standalone prints for `-v`. These belong
// to the reference implementation, so a rebranded distribution is expected to
// replace them.
COPYRIGHT_TEXT :: #config(COPYRIGHT_TEXT, "Copyright (C) 1994-2026 Lua.org, PUC-Rio")
AUTHORS_TEXT :: #config(AUTHORS_TEXT, "R. Ierusalimschy, L. H. de Figueiredo, W. Celes")

// The symbol a native (C ABI) extension module must export, as a `%s` format.
// Reference Lua looks for `luaopen_<modname>`.
NATIVE_OPEN_FMT :: #config(NATIVE_OPEN_FMT, "luaopen_%s")

// ---------------------------------------------------------------------------
// Everything below is derived -- do not hardcode these anywhere else
// ---------------------------------------------------------------------------

// The `_VERSION` global ("Lua 5.5") and the fully-qualified release
// ("Lua 5.5.1"). The version numbers themselves live in conf.odin.
VERSION :: BRAND + " " + VERSION_MAJOR + "." + VERSION_MINOR
RELEASE :: VERSION + "." + VERSION_RELEASE

// The banner line printed by `-v`, matching the reference layout.
COPYRIGHT :: RELEASE + "  " + COPYRIGHT_TEXT
AUTHORS :: AUTHORS_TEXT

// The magic prefix of a precompiled (binary) chunk -- reference Lua's
// `LUA_SIGNATURE`, "\x1bLua". `api_load` peeks the first byte: an ESC (0x1b)
// means "binary, hand off to the undumper"; anything else means "source text,
// hand off to the parser". Rebranding changes the signature, so precompiled
// chunks are deliberately not portable across brands.
SIGNATURE :: "\x1b" + BRAND

// What `debug.getinfo(f).what` reports for a function written in this language
// (as opposed to "C" for a native function or "main" for a main chunk).
SOURCE_KIND :: BRAND

// The interpreter and compiler program names, and the compiler's default output
// file -- reference `lua`, `luac`, and `luac.out`.
PROGNAME :: BRAND_LOWER
COMPILER_PROGNAME :: BRAND_LOWER + "c"
COMPILER_OUTPUT :: COMPILER_PROGNAME + ".out"

// The prompt `debug.debug()` writes -- reference `lua_debug> `.
DEBUG_PROMPT :: BRAND_LOWER + "_debug> "

// The version suffix appended to the versioned spelling of each environment
// variable: "_5_5", giving `LUA_INIT_5_5` and `LUA_PATH_5_5`.
VERSUFFIX :: "_" + VERSION_MAJOR + "_" + VERSION_MINOR

// The environment variables consulted at start-up, in both their unversioned
// and version-suffixed spellings.
ENV_INIT :: ENV_PREFIX + "_INIT"
ENV_INIT_VERSION :: ENV_INIT + VERSUFFIX
ENV_PATH :: ENV_PREFIX + "_PATH"
ENV_CPATH :: ENV_PREFIX + "_CPATH"
ENV_NOENV :: ENV_PREFIX + "_NOENV"

// The `MAJOR.MINOR` directory component of the default search paths.
VERSION_DIR :: VERSION_MAJOR + "." + VERSION_MINOR
