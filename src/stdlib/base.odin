package stdlib

// base.odin -- our analogue of reference Lua's `lbaselib.c`.
//
// The basic library: the globals that are always present without a table prefix
// -- print, type, tostring/tonumber, pairs/ipairs/next, pcall/xpcall/error/
// assert, select, rawget/rawset/rawequal/rawlen, setmetatable/getmetatable,
// collectgarbage, load, and the `_G`/`_VERSION` globals.
//
// TODO(phase-9): implement the base functions against the public API.
