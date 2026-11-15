package tests

import "core:testing"
import kernel "lang:kernel"

Closure_Failure_Allocator :: struct {
	count:     Counting_Allocator,
	tag:       uint,
	skip:      int,
	failures:  int, // negative fails every matching request
	attempts:  int,
	enabled:   bool,
}

closure_failure_alloc :: proc "c" (ud: rawptr, ptr: rawptr, osize, nsize: uint) -> rawptr {
	a := (^Closure_Failure_Allocator)(ud)
	if a.enabled && ptr == nil && nsize != 0 && osize == a.tag {
		a.attempts += 1
		if a.skip > 0 {
			a.skip -= 1
		} else if a.failures != 0 {
			if a.failures > 0 {
				a.failures -= 1
			}
			return nil
		}
	}
	return counting_alloc(&a.count, ptr, osize, nsize)
}

closure_oom_native :: proc "c" (Lp: rawptr) -> i32 {
	return 0
}

closure_oom_push_native :: proc(L: ^kernel.State, _: rawptr) -> kernel.Thread_Status {
	kernel.api_pushinteger(L, 42)
	kernel.api_pushcclosure(L, closure_oom_native, 1)
	return .Ok
}

@(test)
native_closure_allocation_failure_is_catchable :: proc(t: ^testing.T) {
	a: Closure_Failure_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = closure_failure_alloc, ud = &a})
	testing.expect(t, L != nil)
	if L == nil {
		return
	}
	a.tag = kernel.TFUNCTION
	a.failures = -1
	a.enabled = true
	status := kernel.run_protected(L, closure_oom_push_native, nil)
	a.enabled = false
	testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
	testing.expect(t, a.attempts >= 2)
	kernel.close_state(L)
	testing.expect_value(t, a.count.outstanding, 0)
}

// Fail both the closure itself and the second captured upvalue, including the
// emergency retry. A protected call must return Err_Mem and leave a usable state.
@(test)
closure_allocation_failure_is_catchable :: proc(t: ^testing.T) {
	tags := [2]uint{kernel.TFUNCTION, kernel.TUPVAL}
	for tag in tags {
		a: Closure_Failure_Allocator
		L := kernel.new_state(kernel.Allocator{alloc = closure_failure_alloc, ud = &a})
		testing.expect(t, L != nil)
		if L == nil {
			continue
		}
		rd: Src_Reader
		source := "local a,b=21,22; return function() return a,b end"
		testing.expect_value(t, api_load(L, source, &rd), kernel.Thread_Status.Ok)
		a.tag = tag
		a.skip = 1 if tag == kernel.TUPVAL else 0
		a.failures = -1
		a.enabled = true
		status := kernel.api_pcall(L, 0, 1, 0)
		a.enabled = false
		testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
		testing.expect(t, a.attempts >= 2, "allocation and emergency retry both failed")
		kernel.api_settop(L, 0)
		testing.expect_value(t, api_load(L, "return 42", &rd), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_pcall(L, 0, 1, 0), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_tointeger(L, -1), 42)
		kernel.close_state(L)
		testing.expect_value(t, a.count.outstanding, 0)
	}
}

// A transient failure while filling a closure triggers an emergency GC. The
// closure and the first captured upvalue must remain rooted during that retry.
@(test)
closure_survives_emergency_retry :: proc(t: ^testing.T) {
	a: Closure_Failure_Allocator
	L := kernel.new_state(kernel.Allocator{alloc = closure_failure_alloc, ud = &a})
	testing.expect(t, L != nil)
	if L == nil {
		return
	}
	rd: Src_Reader
	testing.expect_value(t, api_load(L, "local a,b=21,22; return function() return a,b end", &rd), kernel.Thread_Status.Ok)
	a.tag = kernel.TUPVAL
	a.skip = 1
	a.failures = 1
	a.enabled = true
	status := kernel.api_pcall(L, 0, 1, 0)
	a.enabled = false
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, a.attempts >= 3, "second upvalue was retried after an emergency collection")
	if status == .Ok {
		testing.expect_value(t, kernel.api_pcall(L, 0, 2, 0), kernel.Thread_Status.Ok)
		testing.expect_value(t, kernel.api_tointeger(L, -2), 21)
		testing.expect_value(t, kernel.api_tointeger(L, -1), 22)
	}
	kernel.close_state(L)
	testing.expect_value(t, a.count.outstanding, 0)
}

// Text and binary loading construct a closure and prototypes before returning
// to the caller. Fail the main closure, its closed upvalue, and both prototype
// allocation sites.
@(test)
closure_loader_allocation_failure_is_catchable :: proc(t: ^testing.T) {
	cases := [4]struct{tag: uint, skip: int}{
		{kernel.TFUNCTION, 0}, {kernel.TUPVAL, 0}, {kernel.TPROTO, 0}, {kernel.TPROTO, 1},
	}
	modes := [2]bool{false, true}
	for binary in modes {
		for c in cases {
			a: Closure_Failure_Allocator
			L := kernel.new_state(kernel.Allocator{alloc = closure_failure_alloc, ud = &a})
			testing.expect(t, L != nil)
			if L == nil {
				continue
			}
			rd: Src_Reader
			source := "local function f() return 1 end; return f"
			bytes: [dynamic]u8
			if binary {
				testing.expect_value(t, api_load(L, source, &rd), kernel.Thread_Status.Ok)
				bytes = dump_top(L, false)
				kernel.api_settop(L, 0)
			}
			a.tag = c.tag
			a.skip = c.skip
			a.failures = -1
			a.enabled = true
			status: kernel.Thread_Status
			if binary {
				status = dump_load_binary(L, bytes[:], &rd)
			} else {
				status = api_load(L, source, &rd)
			}
			a.enabled = false
			testing.expect_value(t, status, kernel.Thread_Status.Err_Mem)
			testing.expect(t, a.attempts >= c.skip + 2)
			delete(bytes)
			kernel.close_state(L)
			testing.expect_value(t, a.count.outstanding, 0)
		}
	}
}
