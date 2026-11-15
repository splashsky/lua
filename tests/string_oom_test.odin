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

// Exercise OP_CONCAT itself: api_concat above does not enter the VM handler.
@(test)
vm_concat_allocation_failure :: proc(t: ^testing.T) {
	cases := [3]struct {source: string, result_len: uint}{
		{`local a,b = 'unique_short_', 'concat_result'; return a .. b`, uint(len("unique_short_concat_result"))},
		{`local a,b = 'a long left operand, longer than forty characters!', ' and a long right operand as well!'; return a .. b`, uint(len("a long left operand, longer than forty characters! and a long right operand as well!"))},
		{`local a,b = 'prefix', 918273645; return a .. b`, 9},
	}
	for c in cases {
		a: String_OOM_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = string_oom_alloc, ud = &a})
		if !testing.expect(t, L != nil) do return
		rd: Src_Reader
		testing.expect_value(t, api_load(L, c.source, &rd), kernel.Thread_Status.Ok)
		a.bytes = kernel.sizelstring(c.result_len)
		status := kernel.api_pcall(L, 0, 1, 0)
		a.bytes = 0
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect(t, a.failures >= 2, "target allocation and emergency retry must fail")
		kernel.api_settop(L, 0)
		testing.expect_value(t, api_load(L, "return 42", &rd), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_tointeger(L, -1), 42)
		kernel.close_state(L)
		testing.expect_value(t, a.count.outstanding, 0)
	}
}

String_Retry_Allocator :: struct {
	count: Counting_Allocator,
	bytes: uint,
	remaining, attempts: int,
	enabled: bool,
}

string_retry_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	a := (^String_Retry_Allocator)(ud)
	if a.enabled && ptr == nil && osize == uint(kernel.TSTRING) && nsize == a.bytes {
		a.attempts += 1
		if a.remaining > 0 {
			a.remaining -= 1
			return nil
		}
	}
	return counting_alloc(&a.count, ptr, osize, nsize)
}

@(test)
vm_concat_survives_emergency_retry :: proc(t: ^testing.T) {
	a: String_Retry_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = string_retry_alloc, ud = &a})
	if !testing.expect(t, L != nil) do return
	rd: Src_Reader
	source := `local a, x, y = 'retry:', 918273645, 728394615; return a .. x .. ':' .. y`
	testing.expect_value(t, api_load(L, source, &rd), kernel.Thread_Status.Ok)
	a.bytes = kernel.sizelstring(9)
	a.remaining = 1
	a.enabled = true
	status := kernel.api_pcall(L, 0, 1, 0)
	a.enabled = false
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, a.attempts >= 2, "numeric conversion retried after emergency collection")
	if status == .Ok {
		value, ok := kernel.api_tolstring(L, -1)
		testing.expect(t, ok && value == "retry:918273645:728394615")
	}
	kernel.close_state(L)
	testing.expect_value(t, a.count.outstanding, 0)
}

String_Trace_Allocator :: struct {
	count: Counting_Allocator,
	active: bool,
	n: int,
	sizes: [16]uint,
}

string_trace_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	a := (^String_Trace_Allocator)(ud)
	if a.active && ptr == nil && osize == uint(kernel.TSTRING) && nsize != 0 {
		if a.n < len(a.sizes) do a.sizes[a.n] = nsize
		a.n += 1
	}
	return counting_alloc(&a.count, ptr, osize, nsize)
}

// Number coercions are allocated right-to-left, followed by the result.
// The threaded shortcut must not combine them or change allocator accounting.
@(test)
vm_concat_allocation_order :: proc(t: ^testing.T) {
	a: String_Trace_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = string_trace_alloc, ud = &a})
	if !testing.expect(t, L != nil) do return
	rd: Src_Reader
	source := `local a, x, y = 'retry:', 91827364, 728394615; return a .. x .. ':' .. y`
	testing.expect_value(t, api_load(L, source, &rd), kernel.Thread_Status.Ok)
	a.active = true
	status := kernel.api_pcall(L, 0, 1, 0)
	a.active = false
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, a.n, 3)
	if a.n == 3 {
		testing.expect_value(t, a.sizes[0], kernel.sizelstring(9))
		testing.expect_value(t, a.sizes[1], kernel.sizelstring(8))
		testing.expect_value(t, a.sizes[2], kernel.sizelstring(24))
	}
	kernel.close_state(L)
	testing.expect_value(t, a.count.outstanding, 0)
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
