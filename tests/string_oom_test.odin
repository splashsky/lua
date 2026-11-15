package tests

import "core:testing"
import kernel "lang:kernel"

// Reject just the target string allocation, including the emergency-GC retry.
// Other allocations remain available so the test reaches the intended operation.
String_OOM_Allocator :: struct {
	count: Counting_Allocator,
	bytes: uint,
	failures: int,
}

string_oom_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	a := (^String_OOM_Allocator)(ud)
	if ptr == nil && osize == uint(kernel.TSTRING) && nsize == a.bytes {
		a.failures += 1
		return nil
	}
	return counting_alloc(&a.count, ptr, osize, nsize)
}

string_oom_concat :: proc(L: ^kernel.State, _: rawptr) -> kernel.Thread_Status {
	kernel.api_concat(L, 2)
	return .Ok
}

@(test)
string_concat_allocation_failure :: proc(t: ^testing.T) {
	// The first two cases create a short and a long result respectively; the
	// third fails while converting a numeric operand before concatenation.
	for which in 0 ..< 3 {
		a: String_OOM_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = string_oom_alloc, ud = &a})
		if !testing.expect(t, L != nil) do return
		switch which {
		case 0:
			kernel.api_pushstring(L, "unique_short_")
			kernel.api_pushstring(L, "concat_result")
			a.bytes = kernel.sizelstring(uint(len("unique_short_concat_result")))
		case 1:
			kernel.api_pushstring(L, "a long left operand, longer than forty characters!")
			kernel.api_pushstring(L, " and a long right operand as well!")
			a.bytes = kernel.sizelstring(uint(len("a long left operand, longer than forty characters! and a long right operand as well!")))
		case 2:
			kernel.api_pushstring(L, "prefix")
			kernel.api_pushinteger(L, 918273645)
			a.bytes = kernel.sizelstring(9)
		}
		status := kernel.run_protected(L, string_oom_concat, nil)
		a.bytes = 0
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect(t, a.failures >= 2, "target allocation and emergency retry must fail")
		kernel.close_state(L)
		testing.expect_value(t, a.count.outstanding, 0)
	}
}

@(test)
string_undump_allocation_failure :: proc(t: ^testing.T) {
	// Produce the chunks before enabling failures, then reject the string's
	// object allocation during binary loading, not an unrelated loader buffer.
	sources := [2]string{
		`return 'short_unique_constant_7326'`,
		`return 'long_unique_constant_7326_abcdefghijklmnopqrstuvwxyz_ABCDEFGHIJKLMNOPQRSTUVWXYZ'`,
	}
	for source in sources {
		producer := kernel.new_state(kernel.default_allocator())
		rd: Src_Reader
		if !testing.expect_value(t, dump_load_text(producer, source, &rd), kernel.Thread_Status.Ok) {
			kernel.close_state(producer)
			return
		}
		bytes := dump_top(producer, true)
		kernel.close_state(producer)

		a: String_OOM_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = string_oom_alloc, ud = &a})
		if !testing.expect(t, L != nil) {
			delete(bytes)
			return
		}
		// Exclude the `return '` prefix and final quote.
		a.bytes = kernel.sizelstring(uint(len(source) - len("return '") - 1))
		status := dump_load_binary(L, bytes[:], &rd)
		a.bytes = 0
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect(t, a.failures >= 2, "target allocation and emergency retry must fail")
		kernel.close_state(L)
		testing.expect_value(t, a.count.outstanding, 0)
		delete(bytes)
	}
}
