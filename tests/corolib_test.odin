package tests

// corolib_test.odin -- honest end-to-end tests for the coroutine *library*
// (src/stdlib/coro.odin), driven through real Lua chunks. The Phase 5 coro_test.odin
// exercises the raw kernel resume/yield protocol; this file exercises the Lua-level
// coroutine.* surface built on top of it: the full suspend/resume value hand-off,
// the status lifecycle, resume's true/false + error convention, the re-raising
// wrapper from coroutine.wrap, running()/isyieldable() on the main thread, close().

import "core:testing"
import lua "luao:lua"
import aux "luao:stdlib"

corolib_state :: proc() -> ^lua.State {
	L := lua.new_state(lua.default_allocator())
	lua.api_pushcfunction(L, aux.open_base)
	lua.api_call(L, 0, 0)
	lua.api_pushcfunction(L, aux.open_coroutine)
	lua.api_call(L, 0, 1)
	lua.api_setglobal(L, "coroutine")
	return L
}

corolib_run :: proc(L: ^lua.State, src: string) -> lua.Thread_Status {
	if st := aux.aux_loadstring(L, src); st != .Ok {
		return st
	}
	return lua.api_pcall(L, 0, lua.MULTRET, 0)
}

@(test)
corolib_resume_yield_handoff :: proc(t: ^testing.T) {
	L := corolib_state()
	defer lua.close_state(L)
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
	defer lua.close_state(L)
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
	defer lua.close_state(L)
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
	defer lua.close_state(L)
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
	defer lua.close_state(L)
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
