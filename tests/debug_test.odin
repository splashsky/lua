package tests

// debug_test.odin -- Phase 6 tests for the debug/introspection API and the hook
// dispatch wired into the VM (debug.odin + the VM trap check).
//
// As with api_test.odin these are black-box: we install real hooks and query real
// activation records through the public API, and assert only on what an embedder
// would actually observe. The line-hook test proves the VM genuinely calls back
// on line changes; the getinfo test proves we report a function's honest static
// facts (what/source/linedefined/nparams). We never assert on name-guessing --
// the 'n' fields are intentionally empty in this phase, so claiming a name here
// would be a dishonest ("fitted") test.

import "core:testing"
import "base:runtime"
import kernel "lang:kernel"

// ---------------------------------------------------------------------------
// Line hook: shared capture buffer (C hooks cannot close over locals).
// ---------------------------------------------------------------------------

dbg_line_count: int
dbg_lines: [64]i32

dbg_reset :: proc() {
	dbg_line_count = 0
	dbg_lines = {}
}

// A line hook that records every line the VM reports. It reads the `currentline`
// that luaD_hook filled into the activation record it hands us.
dbg_line_hook :: proc "c" (Lp: rawptr, arp: rawptr) {
	context = runtime.default_context()
	ar := (^kernel.Debug_Info)(arp)
	if ar.event == kernel.HOOKLINE && dbg_line_count < len(dbg_lines) {
		dbg_lines[dbg_line_count] = ar.currentline
		dbg_line_count += 1
	}
}

@(test)
test_debug_line_hook_fires :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	dbg_reset()
	rd: Src_Reader

	// Three statements on three distinct lines. A faithful line hook must fire on
	// each new source line as execution reaches it.
	src := "a = 1\nb = 2\nc = a + b\n"
	testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)

	kernel.api_sethook(L, dbg_line_hook, kernel.MASKLINE, 0)
	testing.expect_value(t, kernel.api_pcall(L, 0, 0, 0), kernel.Thread_Status.Ok)
	kernel.api_sethook(L, nil, 0, 0) // uninstall

	// We should have seen at least the three assignment lines.
	testing.expect(t, dbg_line_count >= 3)

	// And every recorded line must fall inside the chunk (1..3) -- proving the
	// numbers are real line info, not noise.
	seen1, seen2, seen3 := false, false, false
	for i in 0 ..< dbg_line_count {
		ln := dbg_lines[i]
		testing.expect(t, ln >= 1 && ln <= 3)
		switch ln {
		case 1:
			seen1 = true
		case 2:
			seen2 = true
		case 3:
			seen3 = true
		}
	}
	testing.expect(t, seen1 && seen2 && seen3)

	// The observable hook state round-trips through the getters.
	dbg_reset()
	kernel.api_sethook(L, dbg_line_hook, kernel.MASKLINE, 0)
	testing.expect(t, kernel.api_gethook(L) != nil)
	testing.expect_value(t, kernel.api_gethookmask(L), kernel.MASKLINE)
	kernel.api_sethook(L, nil, 0, 0)
	testing.expect(t, kernel.api_gethook(L) == nil)
}

// ---------------------------------------------------------------------------
// Count hook: fires every `count` instructions.
// ---------------------------------------------------------------------------

dbg_count_hits: int

dbg_count_hook :: proc "c" (Lp: rawptr, arp: rawptr) {
	context = runtime.default_context()
	ar := (^kernel.Debug_Info)(arp)
	if ar.event == kernel.HOOKCOUNT {
		dbg_count_hits += 1
	}
}

@(test)
test_debug_count_hook_fires :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	dbg_count_hits = 0
	rd: Src_Reader

	// A loop that executes many instructions, so a per-instruction count hook is
	// guaranteed to trip repeatedly.
	src := "local s = 0\nfor i = 1, 50 do s = s + i end\nreturn s"
	testing.expect_value(t, api_load(L, src, &rd), kernel.Thread_Status.Ok)

	kernel.api_sethook(L, dbg_count_hook, kernel.MASKCOUNT, 1)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	kernel.api_sethook(L, nil, 0, 0)

	testing.expect(t, dbg_count_hits > 0)
	// The chunk still produced the right answer: 1+2+...+50 == 1275.
	testing.expect_value(t, kernel.api_tointeger(L, -1), 1275)
}

// ---------------------------------------------------------------------------
// lua_getinfo on a function value (the ">" selector).
// ---------------------------------------------------------------------------

@(test)
test_debug_getinfo_function :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader

	// Load a chunk (leaves the main function on the stack) and interrogate it.
	testing.expect_value(t, api_load(L, "return 1", &rd), kernel.Thread_Status.Ok)

	ar: kernel.Debug_Info
	// ">" consumes the function on top of the stack, then fills the record.
	ok := kernel.api_getinfo(L, ">Slu", &ar)
	testing.expect(t, ok)
	testing.expect_value(t, ar.what, "main") // the main chunk of a loaded file
	testing.expect_value(t, ar.linedefined, 0) // main chunks define at line 0
	testing.expect_value(t, ar.nparams, u8(0)) // main chunk takes no fixed params
	testing.expect_value(t, ar.isvararg, u8(1)) // ... but is vararg
	testing.expect(t, len(ar.source) > 0) // the source name was recorded
}

// ---------------------------------------------------------------------------
// lua_getstack + lua_getinfo("l") from inside a running frame, via a hook.
// ---------------------------------------------------------------------------

dbg_stack_currentline: i32
dbg_stack_ok: bool
dbg_stack_what: string

// A line hook that, on its first invocation, walks its own stack and records the
// current line and function kind of the running frame -- proving lua_getstack and
// lua_getinfo work mid-execution.
dbg_stack_hook :: proc "c" (Lp: rawptr, arp: rawptr) {
	context = runtime.default_context()
	if dbg_stack_ok {
		return // only sample once
	}
	L := (^kernel.State)(Lp)
	frame: kernel.Debug_Info
	if kernel.api_getstack(L, 0, &frame) {
		if kernel.api_getinfo(L, "Sl", &frame) {
			dbg_stack_currentline = frame.currentline
			dbg_stack_what = frame.what
			dbg_stack_ok = true
		}
	}
}

@(test)
test_debug_getstack_currentline :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	dbg_stack_ok = false
	dbg_stack_currentline = 0
	dbg_stack_what = ""
	rd: Src_Reader

	testing.expect_value(t, api_load(L, "local x = 10\nreturn x", &rd), kernel.Thread_Status.Ok)
	kernel.api_sethook(L, dbg_stack_hook, kernel.MASKLINE, 0)
	testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
	kernel.api_sethook(L, nil, 0, 0)

	testing.expect(t, dbg_stack_ok)
	testing.expect_value(t, dbg_stack_what, "main")
	testing.expect(t, dbg_stack_currentline >= 1 && dbg_stack_currentline <= 2)
}
