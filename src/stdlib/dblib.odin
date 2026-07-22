package stdlib

// dblib.odin -- our analogue of reference Lua's `ldblib.c`.
//
// The debug library: getinfo/getlocal/setlocal/getupvalue/setupvalue/upvalueid/
// upvaluejoin, get/set metatable and registry access, traceback, and the hook
// controls (sethook/gethook). This library is the toughest test of our public
// API boundary -- if it needs something the kernel doesn't expose through the
// debug-API surface, that's a gap to fix in `api`, not a reason to reach inside.
//
// TODO(phase-9): implement the debug.* functions against the debug-API surface.
