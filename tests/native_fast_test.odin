package tests

import "base:runtime"
import "core:testing"
import kernel "lang:kernel"
import stdlib "lang:stdlib"

// Exercise the uncommon settop branches from an actual C-ABI frame. They must
// still nil-fill growth and run (or propagate errors from) a __close method.
native_trim_test :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.api_toclose(L, 2)
	kernel.api_native_trimtop(L, 1)
	return 0
}

native_grow_test :: proc "c" (Lp: rawptr) -> i32 {
	L := (^kernel.State)(Lp)
	kernel.api_native_trimtop(L, 3)
	return 3
}

native_none_test :: proc "c" (Lp: rawptr) -> i32 {
	return 0
}

// Leave the close for poscall instead of closing it inside the callback.
native_leave_tbc_test :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := (^kernel.State)(Lp)
	kernel.api_toclose(L, 1)
	return 0
}

@(test)
native_fast_paths_preserve_embedding_assertions :: proc(t: ^testing.T) {
	when kernel.API_CHECKS {
		// A regular embedding API procedure still accepts Odin's context and
		// dispatches assertion failures to the caller's handler (the test runner).
		api_type_signature: proc(^kernel.State, int) -> int = kernel.api_type
		frames: [1]kernel.Call_Info
		L: kernel.State
		L.frames = raw_data(frames[:])
		frames[0].top = 1 // no acceptable argument slots
		testing.expect_assert(t, "unacceptable index")
		api_type_signature(&L, 1)
	}
}

@(test)
native_trim_preserves_settop_semantics :: proc(t: ^testing.T) {
	L := kernel.new_state(kernel.default_allocator())
	defer kernel.close_state(L)
	stdlib.aux_openlibs(L)
	kernel.api_pushcfunction(L, native_trim_test)
	kernel.api_setglobal(L, "native_trim_test")
	kernel.api_pushcfunction(L, native_grow_test)
	kernel.api_setglobal(L, "native_grow_test")
	kernel.api_pushcfunction(L, native_none_test)
	kernel.api_setglobal(L, "native_none_test")
	kernel.api_pushcfunction(L, native_leave_tbc_test)
	kernel.api_setglobal(L, "native_leave_tbc_test")
	src := `
		local a, b, c = native_grow_test(7)
		assert(a == 7 and b == nil and c == nil)
		assert(native_grow_test(7) == 7)
		native_grow_test(7)
		assert(select('#', native_grow_test(7)) == 3)
		assert(native_none_test() == nil)
		native_none_test()
		assert(select('#', native_none_test()) == 0)
		local closed = 0
		local x = setmetatable({}, {__close = function() closed = closed + 1 end})
		native_trim_test(1, x)
		assert(closed == 1)
		native_leave_tbc_test(x)
		assert(closed == 2)
		local y = setmetatable({}, {__close = function() error('close error', 0) end})
		local ok, err = pcall(native_trim_test, 1, y)
		assert(not ok and err == 'close error')
	`
	st := stdlib.aux_loadstring(L, src)
	if st == .Ok {st = kernel.api_pcall(L, 0, 0, 0)}
	if st != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "native trim: %s", msg)
	}
}
