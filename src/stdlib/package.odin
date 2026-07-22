package stdlib

// package.odin -- our analogue of reference Lua's `loadlib.c`.
//
// The package/module system: `require`, the `package` table (loaded, preload,
// path/cpath, searchers), and the loader pipeline. Lua-source modules load
// exactly as reference Lua does.
//
// Documented deviation (see README / docs/ARCHITECTURE.md): where reference Lua
// loads native **C** modules via dlopen/LoadLibrary and a `luaopen_*` C ABI, we
// load native **Odin** dynamic modules instead -- std-lib-only Odin has no C ABI
// loader. The searcher/loader shape is preserved; only the native-module ABI
// differs.
//
// TODO(phase-9): require, the package table + searchers, the Lua-source loader,
// and the Odin-native dynamic-module loader.
