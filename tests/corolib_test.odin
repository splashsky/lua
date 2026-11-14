package tests

// corolib_test.odin -- honest end-to-end tests for the coroutine *library*
// (src/stdlib/coro.odin), driven through real Lua chunks. The Phase 5 coro_test.odin
// exercises the raw kernel resume/yield protocol; this file exercises the Lua-level
// coroutine.* surface built on top of it: the full suspend/resume value hand-off,
// the status lifecycle, resume's true/false + error convention, the re-raising
// wrapper from coroutine.wrap, running()/isyieldable() on the main thread, close().

import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

corolib_state :: proc() -> ^kernel.State {
	L := kernel.new_state(kernel.default_allocator())
	kernel.api_pushcfunction(L, stdlib.open_base)
	kernel.api_call(L, 0, 0)
	kernel.api_pushcfunction(L, stdlib.open_coroutine)
	kernel.api_call(L, 0, 1)
	kernel.api_setglobal(L, "coroutine")
	return L
}

corolib_run :: proc(L: ^kernel.State, src: string) -> kernel.Thread_Status {
	if st := stdlib.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return kernel.api_pcall(L, 0, kernel.MULTRET, 0)
}

@(test)
corolib_resume_yield_handoff :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	// Values flow both ways across yield: arguments into resume become the yield's
	// results, and the values passed to resume become the yield expression's value.
	st := corolib_run(
		L,
		"local co = coroutine.create(function(a, b)\n" +
		"  local c = coroutine.yield(a + b)\n" +
		"  local d = coroutine.yield(c * 2)\n" +
		"  return d + 1\n" +
		"end)\n" +
		"local ok, v1 = coroutine.resume(co, 2, 3)\n" +
		"assert(ok and v1 == 5, 'first yield returns a+b')\n" +
		"local ok2, v2 = coroutine.resume(co, 10)\n" +
		"assert(ok2 and v2 == 20, 'second yield returns c*2')\n" +
		"local ok3, v3 = coroutine.resume(co, 100)\n" +
		"assert(ok3 and v3 == 101, 'final return is d+1')\n" +
		"assert(coroutine.status(co) == 'dead', 'dead after return')\n" +
		"local ok4 = coroutine.resume(co)\n" +
		"assert(not ok4, 'resuming a dead coroutine fails')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "full bidirectional resume/yield value hand-off")
}

@(test)
corolib_status_lifecycle :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	st := corolib_run(
		L,
		"local co = coroutine.create(function() coroutine.yield() end)\n" +
		"assert(coroutine.status(co) == 'suspended', 'suspended when fresh')\n" +
		"coroutine.resume(co)\n" +
		"assert(coroutine.status(co) == 'suspended', 'suspended after yield')\n" +
		"coroutine.resume(co)\n" +
		"assert(coroutine.status(co) == 'dead', 'dead after completion')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "status walks suspended -> suspended -> dead")
}

@(test)
corolib_wrap_iterator :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	st := corolib_run(
		L,
		"local gen = coroutine.wrap(function()\n" +
		"  for i = 1, 3 do coroutine.yield(i * i) end\n" +
		"end)\n" +
		"assert(gen() == 1, 'first square')\n" +
		"assert(gen() == 4, 'second square')\n" +
		"assert(gen() == 9, 'third square')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "wrap yields a plain generator function")
}

@(test)
corolib_error_propagation :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	// resume must catch the error and report (false, message); wrap must re-raise
	// it, so pcall around the wrapper observes a failure.
	st := corolib_run(
		L,
		"local co = coroutine.create(function() error('boom') end)\n" +
		"local ok, err = coroutine.resume(co)\n" +
		"assert(not ok, 'resume reports the error as false')\n" +
		"assert(type(err) == 'string', 'error object is the message')\n" +
		"assert(coroutine.status(co) == 'dead', 'errored coroutine is dead')\n" +
		"local gen = coroutine.wrap(function() error('kaboom') end)\n" +
		"local wok = pcall(gen)\n" +
		"assert(not wok, 'wrap re-raises into the caller')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "resume returns errors; wrap propagates them")
}

@(test)
corolib_running_and_close :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	st := corolib_run(
		L,
		"local _, ismain = coroutine.running()\n" +
		"assert(ismain == true, 'main thread reports ismain')\n" +
		"assert(coroutine.isyieldable() == false, 'main thread cannot yield')\n" +
		"local co = coroutine.create(function() coroutine.yield() end)\n" +
		"coroutine.resume(co)\n" +
		"assert(coroutine.close(co) == true, 'close a suspended coroutine')\n" +
		"assert(coroutine.status(co) == 'dead', 'closed coroutine is dead')\n" +
		"return 1",
	)
	testing.expect(t, st == .Ok, "running()/isyieldable() on main and close()")
}

// Upstream 15b2a78: self-close from an error handler overrides the original
// error, and the wrapped call returns no values. Also exercise explicit close,
// regular close errors, and a nested protected call that self-close must bypass.
@(test)
corolib_close_while_closing_after_error :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	st := corolib_run(L, `
		local function func2close(f) return setmetatable({}, {__close = f}) end
		local co = coroutine.wrap(function()
			local a <close> = func2close(function() coroutine.close() end)
			error('y')
		end)
		assert(select('#', co()) == 0)

		local after = false
		local wrapped = coroutine.wrap(function()
			local a <close> = func2close(function()
				pcall(function() coroutine.close(coroutine.running()) end)
				after = true
			end)
			error('original')
		end)
		assert(select('#', wrapped()) == 0 and not after)

		local thread = coroutine.create(function()
			local a <close> = func2close(function() coroutine.close() end)
			error('original')
		end)
		local ok, err = coroutine.resume(thread)
		assert(not ok and err ~= nil)
		assert(coroutine.close(thread))
		assert(coroutine.close(thread))

		local bad = coroutine.wrap(function()
			local a <close> = func2close(function() error('closing', 0) end)
			error('original', 0)
		end)
		local ok2, err2 = pcall(bad)
		assert(not ok2 and err2 == 'closing')
	`)
	testing.expect(t, st == .Ok, "self-close overrides a prior error without losing other close errors")
}

// The embedding API must leave exactly one error object after a failing close,
// preserving its type, and an empty stack after a subsequent close.
@(test)
corolib_closethread_stack_invariant :: proc(t: ^testing.T) {
	L := corolib_state()
	defer kernel.close_state(L)
	sources := []string{"error('original', 0)", "error(42, 0)"}
	for source in sources {
		co := kernel.api_newthread(L) // anchored on L's stack
		testing.expect_value(t, stdlib.aux_loadstring(L, source), kernel.Thread_Status.Ok)
		kernel.api_xmove(L, co, 1)
		status, _ := kernel.api_resume(co, L, 0)
		testing.expect_value(t, status, kernel.Thread_Status.Err_Run)
		testing.expect_value(t, kernel.api_closethread(co, L), kernel.Thread_Status.Err_Run)
		testing.expect_value(t, co.top, 2)
		testing.expect_value(t, kernel.api_gettop(co), 1)
		if source == "error(42, 0)" {
			testing.expect_value(t, kernel.api_type(co, 1), kernel.TNUMBER)
			testing.expect_value(t, kernel.api_tointeger(co, 1), 42)
		} else {
			msg, ok := kernel.api_tolstring(co, 1)
			testing.expect(t, ok)
			testing.expect_value(t, msg, "original")
		}
		testing.expect_value(t, kernel.api_closethread(co, L), kernel.Thread_Status.Ok)
		testing.expect_value(t, co.top, 1)
		testing.expect_value(t, kernel.api_gettop(co), 0)
		kernel.api_pop(L, 1)
	}
}
