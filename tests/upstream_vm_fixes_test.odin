package tests

import "core:testing"
import kernel "lang:kernel"

// NaN limits and initial values are unordered; a NaN step is not negative,
// so it chooses the ascending initial check and then stops after one iteration.
@(test)
upstream_numeric_for_nan :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	src := `
		local nan = 0/0
		local n = 0
		for i = 1, nan, 1 do n = n + 1; break end
		for i = 1, nan, -1 do n = n + 1; break end
		for i = 1.0, nan do n = n + 1; break end
		for i = 1.0, nan, -1 do n = n + 1; break end
		for i = nan, 1 do n = n + 1; break end
		for i = nan, 1, -1 do n = n + 1; break end
		for i = 2, 1, nan do n = n + 1; break end
		local count = 0
		for i = 1, 5, nan do count = count + 1; if count > 2 then break end end
		return n, count
	`
	status := pkg_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect_value(t, kernel.api_tointeger(L, -2), 0)
	testing.expect_value(t, kernel.api_tointeger(L, -1), 1)
}

// The constant and variable zero must produce the same negative zero. Also
// exercise the __sub fallback on the new K-operand instruction.
@(test)
upstream_subtract_zero_sign_and_metamethod :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	src := `
		local mz, zi = -0.0, 0
		local negative = 1/(mz - 0) < 0
		local same = 1/(mz - 0) == 1/(mz - zi)
		local obj = setmetatable({}, {__sub = function(a, b) return b == 0 and 42 end})
		return negative, same, obj - 0
	`
	status := pkg_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -3), "negative zero must retain its sign")
	testing.expect(t, kernel.api_toboolean(L, -2), "constant and variable zero must agree")
	testing.expect_value(t, kernel.api_tointeger(L, -1), 42)
}

@(test)
upstream_subtract_zero_bytecode :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	status := compile(&fx, `
		local function zero(a) return a - 0 end
		local function one(a) return a - 1 end
		local function shift(a) return a << 0 end
		return zero, one, shift
	`)
	defer teardown_parser(&fx)
	if status != .Ok {
		testing.expect_value(t, status, kernel.Thread_Status.Ok)
		return
	}
	p := main_proto(&fx)
	testing.expect_value(t, p.sizep, 3)
	if p.sizep != 3 {
		return
	}
	testing.expect(t, has_op(p.p[0], .SUBK), "subtracting constant zero uses SUBK")
	testing.expect(t, has_op(p.p[0], .MMBINK), "SUBK uses the K metamethod fallback")
	testing.expect(t, !has_op(p.p[0], .ADDI), "subtracting zero must not become ADDI")
	testing.expect(t, has_op(p.p[1], .ADDI), "subtracting nonzero still uses ADDI")
	testing.expect(t, has_op(p.p[2], .SHRI), "shifting by zero still uses SHRI")
}

@(test)
upstream_vararg_field_error :: proc(t: ^testing.T) {
	L := api_new()
	defer kernel.close_state(L)
	rd: Src_Reader
	status := api_load(L, "local function foo (...t) return t.xx + 1 end; foo()", &rd)
	if status != .Ok {
		testing.expect_value(t, status, kernel.Thread_Status.Ok)
		return
	}
	status = kernel.api_pcall(L, 0, 0, 0)
	testing.expect_value(t, status, kernel.Thread_Status.Err_Run)
	msg, ok := kernel.api_tolstring(L, -1)
	testing.expect(t, ok && contains(msg, "field 'xx'"), "error must name the vararg field")
}

// Both the repetition CLOSE and the normal-exit CLOSE execute while loop locals
// are in scope. This is the upstream locals.lua regression, including both paths.
@(test)
upstream_repeat_close_local_scope :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	src := `
		local res = {}
		local function foo(a)
		  repeat
		    local x
		    local i <close> = setmetatable({}, {__close = function()
		      res[#res + 1] = debug.getlocal(2, 2)
		      res[#res + 1] = debug.getlocal(2, 3)
		      a = true
		    end})
		  until a
		end
		foo(false)
		return res[1], res[2], res[3], res[4]
	`
	status := pkg_run(L, src)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	for want, i in ([]string{"x", "i", "x", "i"}) {
		got, ok := kernel.api_tolstring(L, i - 4)
		testing.expectf(t, ok && got == want, "close local %d: want %s, got %s", i, want, got)
	}
}

// Match the 5.5.1 compiler's instruction order, branch displacements, and
// debug ranges for a repeat loop with a captured local, a close variable, and
// a break. In particular, both loop-closing instructions precede local endpc.
@(test)
upstream_repeat_close_bytecode_and_ranges :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	status := compile(&fx, `
		local function foo(a)
		  local outer = 1
		  repeat
		    local x = outer
		    local y <close> = resource()
		    local function capture() return x end
		    if a == 2 then break end
		    a = a + 1
		  until a > 3
		  return outer
		end
		return foo
	`)
	defer teardown_parser(&fx)
	if status != .Ok {
		testing.expect_value(t, status, kernel.Thread_Status.Ok)
		return
	}
	main := main_proto(&fx)
	testing.expect_value(t, main.sizep, 1)
	if main.sizep != 1 {
		return
	}
	p := main.p[0]
	ops := []kernel.Op_Code {
		.LOADI, .MOVE, .GETTABUP, .CALL, .TBC, .CLOSURE, .EQI, .JMP,
		.CLOSE, .JMP, .ADDI, .MMBINI, .GTI, .JMP, .JMP, .CLOSE, .JMP,
		.CLOSE, .RETURN, .RETURN,
	}
	testing.expect_value(t, p.sizecode, len(ops))
	if p.sizecode != len(ops) {
		return
	}
	for op, pc in ops {
		testing.expectf(t, kernel.get_opcode(p.code[pc]) == op, "instruction %d", pc)
	}
	for pc in ([]int{8, 15, 17}) {
		if kernel.get_opcode(p.code[pc]) == .CLOSE {
			testing.expect_value(t, kernel.getarg_A(p.code[pc]), 2)
		}
	}
	jump_pcs := []int{7, 9, 13, 14, 16}
	for displacement, i in ([]int{2, 8, 1, 2, -16}) {
		pc := jump_pcs[i]
		if kernel.get_opcode(p.code[pc]) == .JMP {
			testing.expect_value(t, kernel.getarg_sJ(p.code[pc]), displacement)
		}
	}
	testing.expect_value(t, p.sizelocvars, 5)
	if p.sizelocvars != 5 {
		return
	}
	starts := []int{0, 1, 2, 4, 6}
	ends := []int{20, 20, 18, 18, 18}
	for name, i in ([]string{"a", "outer", "x", "y", "capture"}) {
		local := p.locvars[i]
		testing.expect_value(t, string(kernel.str_slice(local.varname)), name)
		testing.expect_value(t, local.startpc, starts[i])
		testing.expect_value(t, local.endpc, ends[i])
	}
}
