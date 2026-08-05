package tests

// coro_test.odin -- Phase 5 tests for the coroutine layer (do.odin: luaE_newthread,
// lua_resume, lua_yieldk, resume/unroll/precover).
//
// Coroutines are the reason the whole VM is a trampoline over an explicit heap
// frame-stack rather than a recursive native interpreter: a suspended coroutine
// must be resumable *after* control has already returned to whoever resumed it,
// which native-stack recursion (and plain longjmp) cannot express. These tests
// prove that round-trip honestly, driving a real second thread through a genuine
// yield and back via a continuation, and asserting only on the observable values
// that cross the resume/yield boundary.
//
// We use a light C (Odin) function as the coroutine body because the Lua-level
// `coroutine.yield` global belongs to the standard library (Phase 9); the raw
// `lua_yieldk`/`lua_resume` kernel protocol is exactly what that library will wrap,
// so testing it directly is the faithful thing to do now.

import "core:testing"
import "base:runtime"
import lua "luao:lua"

// A resumable coroutine body: it pushes one value (111), then yields it with a
// continuation to run when the coroutine is next resumed. `lua_yieldk` long-jumps
// out to the resuming `lua_resume`, so this call never returns here.
coro_body :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	lua.set_int(lua.stack_value(L, L.top), 111)
	L.top += 1
	return lua.api_yieldk(L, 1, lua.K_Context(0), coro_cont)
}

// The continuation: it runs on the *second* resume, pushes the final result (222),
// and returns 1 to say "one result". `luaD_poscall` then finishes the original
// call, so this value becomes the coroutine's final return value.
coro_cont :: proc "c" (Lp: rawptr, status: i32, ctx: lua.K_Context) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	lua.set_int(lua.stack_value(L, L.top), 222)
	L.top += 1
	return 1
}

@(test)
test_coroutine_yield_and_resume :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	defer lua.close_state(L)

	// Create the coroutine and push its body function onto *its* stack.
	co := lua.state_newthread(L)
	lua.set_c_function(lua.stack_value(co, co.top), coro_body)
	co.top += 1

	// First resume: run the body until it yields. We expect a YIELD status and the
	// single yielded value (111) on the coroutine's stack.
	status1, nres1 := lua.api_resume(co, L, 0)
	testing.expect_value(t, status1, lua.Thread_Status.Yield)
	testing.expect_value(t, nres1, 1)
	yielded := lua.int_value(lua.stack_value(co, co.top - 1))
	testing.expect_value(t, yielded, 111)

	// Second resume: run the continuation to completion. We expect a clean OK
	// status and the final result (222).
	status2, nres2 := lua.api_resume(co, L, 0)
	testing.expect_value(t, status2, lua.Thread_Status.Ok)
	testing.expect_value(t, nres2, 1)
	base := co.frames[co.ci].func
	final := lua.int_value(lua.stack_value(co, base + 1))
	testing.expect_value(t, final, 222)
}

// A body that errors instead of yielding, to prove `lua_resume` reports an
// unrecoverable error as a dead-thread status with the error object in place
// rather than crashing the resuming thread.
coro_error_body :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^lua.State)(Lp)
	lua.debug_runerror(L, "boom")
	return 0
}

@(test)
test_coroutine_error_is_isolated :: proc(t: ^testing.T) {
	L := lua.new_state(lua.default_allocator())
	defer lua.close_state(L)

	co := lua.state_newthread(L)
	lua.set_c_function(lua.stack_value(co, co.top), coro_error_body)
	co.top += 1

	status, _ := lua.api_resume(co, L, 0)
	testing.expect_value(t, status, lua.Thread_Status.Err_Run)
	// The error object (a string containing our message) is left on top.
	msg := string(lua.str_slice(lua.str_value(lua.stack_value(co, co.top - 1))))
	testing.expect(t, contains(msg, "boom"))
	// The resuming thread itself is unharmed.
	testing.expect_value(t, L.status, lua.Thread_Status.Ok)
}
