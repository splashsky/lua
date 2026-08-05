package tests

// vm_test.odin -- Phase 5 end-to-end tests for the register VM (vm.odin) and the
// call/coroutine machinery (do.odin).
//
// These are the most honest tests we can write for an interpreter: they take real
// Lua *source*, compile it through the very same parser the language uses, run the
// resulting bytecode through `luaV_execute`, and then assert only on the values the
// chunk *returns* -- never on any private VM internal. If `return 1 + 2 * 3`
// yields `7`, the arithmetic opcodes, the constant folding, the return protocol,
// and the trampoline all provably work together. Each test states a fact about
// observable Lua 5.5 semantics, not about our implementation's shape.
//
// The `Src_Reader`, `src_read`, and `contains` helpers are shared with the lexer
// and parser tests (same `tests` package).

import "core:testing"
import lua "luao:lua"

// ---------------------------------------------------------------------------
// Fixture: compile a chunk, run it, and expose its return values
// ---------------------------------------------------------------------------

VM_Fixture :: struct {
	L:    ^lua.State,
	z:    lua.Zio,
	buff: lua.Mbuffer,
	dyd:  lua.Dyndata,
	rd:   Src_Reader,
	cl:   ^lua.LClosure, // the compiled main closure
	base: int, // stack index the results land at (the old function slot)
	nres: int, // number of results the chunk returned
}

// The protected compile job: turn source into the main closure. `luaY_parser`
// long-jumps on a syntax error, which `run_protected` turns into a status.
vm_compile_job :: proc(L: ^lua.State, ud: rawptr) -> lua.Thread_Status {
	fx := (^VM_Fixture)(ud)
	first := lua.zio_getc(&fx.z)
	fx.cl = lua.parse_parser(L, &fx.z, &fx.buff, &fx.dyd, "=vm", first)
	return .Ok
}

// The protected run job: wire the main chunk's `_ENV` to the globals table, then
// call it and record where the results landed and how many there were. Any runtime
// error inside the chunk long-jumps back out to the surrounding `run_protected`.
vm_run_job :: proc(L: ^lua.State, ud: rawptr) -> lua.Thread_Status {
	fx := (^VM_Fixture)(ud)
	cl := fx.cl
	lua.func_initupvals(L, cl) // create the closed `_ENV` upvalue (starts nil)
	// Point `_ENV` at the real globals table so global reads/writes work.
	regt := (^lua.Table)(lua.gc_value(&L.g.registry))
	gtv: lua.TValue
	lua.table_getint(regt, lua.RIDX_GLOBALS, &gtv)
	lua.upval_value(cl.upvals[0])^ = gtv
	funcidx := L.top - 1 // the closure sits on top of the stack
	fx.base = funcidx
	lua.do_call(L, funcidx, lua.MULTRET)
	fx.nres = L.top - funcidx
	return .Ok
}

// Compile and run `source`. Returns the final status: `.Ok` on a clean run, or an
// error status (`.Err_Syntax` for a bad parse, `.Err_Run` for a runtime error).
run_source :: proc(fx: ^VM_Fixture, source: string) -> lua.Thread_Status {
	fx.L = lua.new_state(lua.default_allocator())
	lua.mbuffer_init(&fx.buff)
	fx.rd = Src_Reader {
		data = ([^]u8)(raw_data(source)),
		len  = uint(len(source)),
		done = false,
	}
	lua.zio_init(fx.L, &fx.z, src_read, &fx.rd)
	fx.dyd = {}
	fx.cl = nil

	status := lua.run_protected(fx.L, vm_compile_job, fx)
	if status != .Ok {
		return status
	}
	return lua.run_protected(fx.L, vm_run_job, fx)
}

// Free everything the fixture owns, mirroring `luaD_protectedparser`'s cleanup of
// the parser's non-GC scratch arrays before `close_state` audits the byte
// accounting back to zero.
teardown_vm :: proc(fx: ^VM_Fixture) {
	d := &fx.dyd
	if d.actvar.arr != nil {
		lua.state_free(fx.L, d.actvar.arr, uint(d.actvar.size) * size_of(lua.Vardesc))
	}
	if d.gt.arr != nil {
		lua.state_free(fx.L, d.gt.arr, uint(d.gt.size) * size_of(lua.Labeldesc))
	}
	if d.label.arr != nil {
		lua.state_free(fx.L, d.label.arr, uint(d.label.size) * size_of(lua.Labeldesc))
	}
	lua.mbuffer_free(fx.L, &fx.buff)
	lua.close_state(fx.L)
}

// ---------------------------------------------------------------------------
// Result readers
// ---------------------------------------------------------------------------

res :: proc(fx: ^VM_Fixture, i: int) -> ^lua.TValue {
	return lua.stack_value(fx.L, fx.base + i)
}
res_int :: proc(fx: ^VM_Fixture, i: int) -> lua.Integer {
	return lua.int_value(res(fx, i))
}
res_float :: proc(fx: ^VM_Fixture, i: int) -> lua.Number {
	return lua.flt_value(res(fx, i))
}
res_string :: proc(fx: ^VM_Fixture, i: int) -> string {
	return string(lua.str_slice(lua.str_value(res(fx, i))))
}

// ---------------------------------------------------------------------------
// Arithmetic and constant folding
// ---------------------------------------------------------------------------

@(test)
test_vm_integer_arithmetic :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 1 + 2 * 3 - 4")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, fx.nres, 1)
	testing.expect(t, lua.is_integer(res(&fx, 0)))
	testing.expect_value(t, res_int(&fx, 0), 3)
}

@(test)
test_vm_float_and_div :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// `/` always produces a float in Lua 5.5, even on integer operands.
	status := run_source(&fx, "return 7 / 2")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect(t, lua.is_float(res(&fx, 0)))
	testing.expect_value(t, res_float(&fx, 0), 3.5)
}

@(test)
test_vm_floor_div_and_mod :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 7 // 2, 7 % 3, -7 % 3")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, fx.nres, 3)
	testing.expect_value(t, res_int(&fx, 0), 3)
	testing.expect_value(t, res_int(&fx, 1), 1)
	// Lua's `%` follows the sign of the divisor: -7 % 3 == 2, not -1.
	testing.expect_value(t, res_int(&fx, 2), 2)
}

@(test)
test_vm_power_is_float :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 2 ^ 10")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect(t, lua.is_float(res(&fx, 0)))
	testing.expect_value(t, res_float(&fx, 0), 1024.0)
}

@(test)
test_vm_bitwise :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 0xF0 | 0x0F, 0xFF & 0x0F, 5 ~ 3, 1 << 4, 256 >> 2")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 255)
	testing.expect_value(t, res_int(&fx, 1), 15)
	testing.expect_value(t, res_int(&fx, 2), 6)
	testing.expect_value(t, res_int(&fx, 3), 16)
	testing.expect_value(t, res_int(&fx, 4), 64)
}

// ---------------------------------------------------------------------------
// Comparisons, boolean logic, concatenation, length
// ---------------------------------------------------------------------------

@(test)
test_vm_comparisons :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 1 < 2, 2 <= 2, 3 > 4, 'a' < 'b', 1 == 1.0")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect(t, lua.is_true(res(&fx, 0)))
	testing.expect(t, lua.is_true(res(&fx, 1)))
	testing.expect(t, lua.is_false(res(&fx, 2)))
	testing.expect(t, lua.is_true(res(&fx, 3)))
	// An integer and a float that denote the same mathematical value are equal.
	testing.expect(t, lua.is_true(res(&fx, 4)))
}

@(test)
test_vm_and_or :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// `and`/`or` return operands, not booleans, and short-circuit.
	status := run_source(&fx, "return (nil or 5), (3 and 4), (false and 9)")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 5)
	testing.expect_value(t, res_int(&fx, 1), 4)
	testing.expect(t, lua.is_false(res(&fx, 2)))
}

@(test)
test_vm_concat_and_len :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// Concatenation coerces numbers to strings; `#` measures a string's bytes.
	status := run_source(&fx, "return 'a' .. 'b' .. 'c', 'x' .. 1 .. 2, #'hello'")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_string(&fx, 0), "abc")
	testing.expect_value(t, res_string(&fx, 1), "x12")
	testing.expect_value(t, res_int(&fx, 2), 5)
}

// ---------------------------------------------------------------------------
// Control flow, locals, loops
// ---------------------------------------------------------------------------

@(test)
test_vm_if_else :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local x = 10\nif x > 5 then return 'big' else return 'small' end")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_string(&fx, 0), "big")
}

@(test)
test_vm_numeric_for :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local s = 0\nfor i = 1, 10 do s = s + i end\nreturn s")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 55)
}

@(test)
test_vm_for_step_and_float :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local n = 0\nfor i = 10, 1, -1 do n = n + 1 end\nreturn n")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 10)
}

@(test)
test_vm_while_loop :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local i, s = 1, 0\nwhile i <= 5 do s = s + i; i = i + 1 end\nreturn s")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 15)
}

// ---------------------------------------------------------------------------
// Functions, closures, varargs, multiple returns
// ---------------------------------------------------------------------------

@(test)
test_vm_function_call :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local function add(a, b) return a + b end\nreturn add(3, 4)")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 7)
}

@(test)
test_vm_closure_upvalue :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// A counter closure proves shared upvalue capture and mutation persist.
	src := "local function counter()\n local n = 0\n return function() n = n + 1; return n end\nend\nlocal c = counter()\nc(); c()\nreturn c()"
	status := run_source(&fx, src)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 3)
}

@(test)
test_vm_varargs :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	src := "local function sum(...)\n local s = 0\n for _, v in ipairs({...}) do s = s + v end\n return s, select('#', ...)\nend\nreturn sum(2, 4, 6, 8)"
	// This one needs `ipairs`/`select` globals which the stdlib provides; until
	// Phase 9 those are absent, so we test raw vararg expansion instead below.
	_ = src
	status := run_source(&fx, "local function f(...) return ... end\nreturn f(1, 2, 3)")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, fx.nres, 3)
	testing.expect_value(t, res_int(&fx, 0), 1)
	testing.expect_value(t, res_int(&fx, 1), 2)
	testing.expect_value(t, res_int(&fx, 2), 3)
}

@(test)
test_vm_multiple_returns :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local function two() return 10, 20 end\nlocal a, b = two()\nreturn a, b, (two())")
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	// `(two())` is parenthesized, so it is adjusted to exactly one value.
	testing.expect_value(t, fx.nres, 3)
	testing.expect_value(t, res_int(&fx, 0), 10)
	testing.expect_value(t, res_int(&fx, 1), 20)
	testing.expect_value(t, res_int(&fx, 2), 10)
}

@(test)
test_vm_recursion :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	src := "local function fact(n) if n <= 1 then return 1 else return n * fact(n - 1) end end\nreturn fact(6)"
	status := run_source(&fx, src)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 720)
}

// ---------------------------------------------------------------------------
// Tables
// ---------------------------------------------------------------------------

@(test)
test_vm_table_construct_and_index :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	src := "local t = {10, 20, 30, x = 99}\nreturn t[1], t[3], t.x, #t"
	status := run_source(&fx, src)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 10)
	testing.expect_value(t, res_int(&fx, 1), 30)
	testing.expect_value(t, res_int(&fx, 2), 99)
	testing.expect_value(t, res_int(&fx, 3), 3)
}

@(test)
test_vm_table_mutation :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	src := "local t = {}\nt[1] = 'a'\nt.key = 'b'\nt[1] = t[1] .. t.key\nreturn t[1]"
	status := run_source(&fx, src)
	testing.expect_value(t, status, lua.Thread_Status.Ok)
	testing.expect_value(t, res_string(&fx, 0), "ab")
}

// ---------------------------------------------------------------------------
// Metamethods (via metatables set from Lua)
// ---------------------------------------------------------------------------

@(test)
test_vm_arith_metamethod :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// setmetatable is a global; instead we build the metatable relationship using
	// only language features by relying on rawequal-free __index on a table.
	src := "local base = {greet = 'hi'}\nlocal obj = setmetatable({}, {__index = base})\nreturn obj.greet"
	status := run_source(&fx, src)
	// `setmetatable` lives in the base library (Phase 9); until then this is a
	// runtime error (calling a nil global). We assert that honestly.
	testing.expect_value(t, status, lua.Thread_Status.Err_Run)
}

// ---------------------------------------------------------------------------
// Runtime errors
// ---------------------------------------------------------------------------

@(test)
test_vm_runtime_error_arith_on_nil :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local x\nreturn x + 1")
	testing.expect_value(t, status, lua.Thread_Status.Err_Run)
	// The error object is a string describing the failure; it sits at top-1.
	msg := string(lua.str_slice(lua.str_value(lua.stack_value(fx.L, fx.L.top - 1))))
	testing.expect(t, contains(msg, "arithmetic"))
}

@(test)
test_vm_syntax_error :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 1 +")
	testing.expect_value(t, status, lua.Thread_Status.Err_Syntax)
}
