package lua

// control.odin -- the unified execution/error outcome and protected boundaries.
//
// This file has no single reference-Lua counterpart; it exists because Odin has
// no setjmp/longjmp. Reference Lua unwinds errors and switches coroutine stacks
// with longjmp over the native C stack. We can't, so we make the control flow
// *explicit* (see docs/ARCHITECTURE.md, Decision 2).
//
// The whole VM/call machinery speaks in one tagged outcome:
//   Continue        -- keep stepping the current frame
//   Returned        -- current frame finished; pop and resume its caller
//   Yielded         -- suspend to the resuming boundary, staying resumable
//   Errored(status) -- unwind to the nearest protected (pcall) boundary
//   Out_Of_Memory   -- emergency-collect then retry, or surface as an error
//
// It lands *before* the compiler on purpose: the lexer, parser, undumper, and
// allocator all raise protected errors, so this primitive must exist first or
// they'd grow throwaway error handling we'd later rip out.
//
// TODO(phase-2): define Exec_Outcome, the thread status/error codes, and the
// protected-boundary machinery (the explicit analogue of luaD_rawrunprotected).
