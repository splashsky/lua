package lua

// debug.odin -- our analogue of reference Lua's `ldebug.h` / `ldebug.c`.
//
// The reflection and diagnostics layer: mapping instructions back to source
// lines, producing the runtime error messages (with variable-name guessing),
// building tracebacks, and driving the debug hooks (call/return/line/count) that
// the debug library and profilers rely on.
//
// TODO(phase-5): line-info lookup, error message construction, symbolic
// execution for names, traceback building, and hook dispatch.
