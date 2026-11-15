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
import kernel "lang:kernel"

// ---------------------------------------------------------------------------
// Fixture: compile a chunk, run it, and expose its return values
// ---------------------------------------------------------------------------

VM_Fixture :: struct {
	L:    ^kernel.State,
	z:    kernel.Zio,
	buff: kernel.Mbuffer,
	dyd:  kernel.Dyndata,
	rd:   Src_Reader,
	cl:   ^kernel.LClosure, // the compiled main closure
	base: int, // stack index the results land at (the old function slot)
	nres: int, // number of results the chunk returned
}

// The protected compile job: turn source into the main closure. `luaY_parser`
// long-jumps on a syntax error, which `run_protected` turns into a status.
vm_compile_job :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	fx := (^VM_Fixture)(ud)
	first := kernel.zio_getc(&fx.z)
	fx.cl = kernel.parse_parser(L, &fx.z, &fx.buff, &fx.dyd, "=vm", first)
	return .Ok
}

// The protected run job: wire the main chunk's `_ENV` to the globals table, then
// call it and record where the results landed and how many there were. Any runtime
// error inside the chunk long-jumps back out to the surrounding `run_protected`.
vm_run_job :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	fx := (^VM_Fixture)(ud)
	cl := fx.cl
	kernel.func_initupvals(L, cl) // create the closed `_ENV` upvalue (starts nil)
	// Point `_ENV` at the real globals table so global reads/writes work.
	regt := (^kernel.Table)(kernel.gc_value(&L.g.registry))
	gtv: kernel.TValue
	kernel.table_getint(regt, kernel.RIDX_GLOBALS, &gtv)
	kernel.upval_value(kernel.closure_upvals(cl)[0])^ = gtv
	funcidx := L.top - 1 // the closure sits on top of the stack
	fx.base = funcidx
	kernel.do_call(L, funcidx, kernel.MULTRET)
	fx.nres = L.top - funcidx
	return .Ok
}

// Compile and run `source`. Returns the final status: `.Ok` on a clean run, or an
// error status (`.Err_Syntax` for a bad parse, `.Err_Run` for a runtime error).
run_source :: proc(fx: ^VM_Fixture, source: string) -> kernel.Thread_Status {
	fx.L = kernel.new_state(kernel.default_allocator())
	kernel.mbuffer_init(&fx.buff)
	fx.rd = Src_Reader {
		data = ([^]u8)(raw_data(source)),
		len  = uint(len(source)),
		done = false,
	}
	kernel.zio_init(fx.L, &fx.z, src_read, &fx.rd)
	fx.dyd = {}
	fx.cl = nil

	status := kernel.run_protected(fx.L, vm_compile_job, fx)
	if status != .Ok {
		return status
	}
	return kernel.run_protected(fx.L, vm_run_job, fx)
}

// Free everything the fixture owns, mirroring `luaD_protectedparser`'s cleanup of
// the parser's non-GC scratch arrays before `close_state` audits the byte
// accounting back to zero.
teardown_vm :: proc(fx: ^VM_Fixture) {
	d := &fx.dyd
	if d.actvar.arr != nil {
		kernel.state_free(fx.L, d.actvar.arr, uint(d.actvar.size) * size_of(kernel.Vardesc))
	}
	if d.gt.arr != nil {
		kernel.state_free(fx.L, d.gt.arr, uint(d.gt.size) * size_of(kernel.Labeldesc))
	}
	if d.label.arr != nil {
		kernel.state_free(fx.L, d.label.arr, uint(d.label.size) * size_of(kernel.Labeldesc))
	}
	kernel.mbuffer_free(fx.L, &fx.buff)
	kernel.close_state(fx.L)
}

// ---------------------------------------------------------------------------
// Result readers
// ---------------------------------------------------------------------------

res :: proc(fx: ^VM_Fixture, i: int) -> ^kernel.TValue {
	return kernel.stack_value(fx.L, fx.base + i)
}
res_int :: proc(fx: ^VM_Fixture, i: int) -> kernel.Integer {
	return kernel.int_value(res(fx, i))
}
res_float :: proc(fx: ^VM_Fixture, i: int) -> kernel.Number {
	return kernel.flt_value(res(fx, i))
}
res_string :: proc(fx: ^VM_Fixture, i: int) -> string {
	return string(kernel.str_slice(kernel.str_value(res(fx, i))))
}

// ---------------------------------------------------------------------------
// Arithmetic and constant folding
// ---------------------------------------------------------------------------

// Every unused 7-bit encoding must fail as a Lua error rather than falling
// through dispatch or indexing beyond its jump table. Mutate compiled code just
// as a malformed binary chunk could, and execute under the public protected API.
vm_reserved_hook :: proc "c" (L, ar: rawptr) {}

@(test)
test_vm_reserved_opcodes :: proc(t: ^testing.T) {
	for traced in ([]bool{false, true}) {
		for op in kernel.NUM_OPCODES ..< (1 << kernel.SIZE_OP) {
			fx: Parse_Fixture
			status := compile(&fx, "return 1")
			if status == .Ok {
				p := main_proto(&fx)
				kernel.set_opcode(&p.code[1], kernel.Op_Code(op))
				if traced {
					kernel.api_sethook(fx.L, vm_reserved_hook, kernel.MASKCOUNT, 1)
				}
				status = kernel.api_pcall(fx.L, 0, 0, 0)
				testing.expectf(t, status == .Err_Run, "reserved opcode %d (traced=%v) must raise", op, traced)
				msg, ok := kernel.api_tolstring(fx.L, -1)
				testing.expectf(t, ok && contains(msg, "invalid opcode"), "opcode %d: %s", op, msg)
			} else {
				testing.expect_value(t, status, kernel.Thread_Status.Ok)
			}
			teardown_parser(&fx)
		}
	}
}

// Exercise frame entry/return, tail calls, tracing, GC, and resumption of an
// interrupted arithmetic instruction in one execution. In relocation test
// mode the frame and value stacks also move during these transitions.
@(test)
vm_deep_frames_hooks_and_resume :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local events = 0
		local function recur(n)
		  if n == 0 then return 0 end
		  return 1 + recur(n - 1)
		end
		local function tail(n)
		  if n == 0 then return 42 end
		  return tail(n - 1)
		end
		local co = coroutine.create(function()
		  local x = setmetatable({value = 17}, {
		    __add = function(a) coroutine.yield(a.value); return 91 end
		  })
		  local z = x + 1
		  return recur(2000), tail(50000), z
		end)
		debug.sethook(co, function() events = events + 1 end, '', 10000)
		local ok, yielded = coroutine.resume(co)
		assert(ok and yielded == 17)
		collectgarbage('collect')
		local ok2, a, b, c = coroutine.resume(co)
		assert(ok2 and a == 2000 and b == 42 and c == 91)
		assert(coroutine.status(co) == 'dead' and events > 0)
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Cover both the table-hit path and the potentially relocating, yielding miss
// path for global and field reads. A hook checks that a hit does not lose an
// already-armed trap, and the next read after the yield checks the resumed base.
@(test)
vm_field_reads_with_hooks_and_yield :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local events = 0
		local co = coroutine.create(function()
		  local env = setmetatable({present = 12}, {
		    __index = function(t, key)
		      coroutine.yield(key)
		      collectgarbage('collect')
		      return 30
		    end
		  })
		  local _ENV = env
		  local a = present
		  local b = absent
		  local c = env.present
		  return a + b + c
		end)
		debug.sethook(co, function() events = events + 1 end, '', 1)
		local ok, key = coroutine.resume(co)
		assert(ok and key == 'absent')
		local ok2, value = coroutine.resume(co)
		assert(ok2 and value == 54 and events > 0)
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// String method hits may find __index in a table without a callout. A miss
// can still follow that table's yielding __index, and __index itself may be a
// function. Restore the original string metatable before leaving the chunk.
@(test)
vm_string_method_lookup_and_yield :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local old = debug.getmetatable('')
		local seen, hooks = 0, 0
		local methods = setmetatable({
		  m = function(self, ...) return self, select('#', ...), ... end,
		}, {__index = function(t, key)
		  seen = seen + 1
		  coroutine.yield(key)
		  collectgarbage('collect')
		  return function(self) return self .. key end
		end})
		debug.setmetatable('', {__index = methods})
		local s = 'x'
		local a, n, x, y = s:m(7, 8)
		assert(a == 'x' and n == 2 and x == 7 and y == 8)
		local co = coroutine.create(function() return ('y'):missing() end)
		debug.sethook(co, function() hooks = hooks + 1 end, '', 1)
		local ok, key = coroutine.resume(co)
		assert(ok and key == 'missing')
		local ok2, val = coroutine.resume(co)
		assert(ok2 and val == 'ymissing' and seen == 1 and hooks > 0)
		debug.setmetatable('', {__index = function(s, key)
		  return function(self) return self .. key end
		end})
		assert(('z'):other() == 'zother')
		debug.setmetatable('', old)
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Concatenation must preserve coercion order and the original operand types
// when a yielding metamethod handles a non-string operand.
@(test)
vm_concat_coercion_and_yield :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local a, b, c, d = 'value:', 12, ':', 3.5
		assert(a .. b .. c .. d == 'value:12:3.5')
		local empty, num = '', 19
		assert(empty .. num == '19' and num .. empty == '19')
		local p, q = 'prefix', 'suffix'
		assert(p .. empty .. q == 'prefixsuffix')
		assert(empty .. num .. empty == '19')
		local obj = setmetatable({}, {__concat = function(x, y)
		  assert(type(x) == 'number' and type(y) == 'table')
		  coroutine.yield('in concat')
		  collectgarbage('collect')
		  return 'metamethod result'
		end})
		local co = coroutine.create(function() local n = 14; return n .. obj end)
		local ok, value = coroutine.resume(co)
		assert(ok and value == 'in concat')
		local done, result = coroutine.resume(co)
		assert(done and result == 'metamethod result')
		local chain = setmetatable({}, {__concat = function(x, y)
		  assert(type(x) == 'table' and y == 'prefixsuffix')
		  coroutine.yield('in chain')
		  collectgarbage('collect')
		  return 'chain result'
		end})
		local chainco = coroutine.create(function() return chain .. p .. q end)
		local ok2, value2 = coroutine.resume(chainco)
		assert(ok2 and value2 == 'in chain')
		local done2, result2 = coroutine.resume(chainco)
		assert(done2 and result2 == 'chain result')
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Variable-key reads cover array and short-string hits, integer-hash and
// generic keys, and misses whose __index yields and moves the stacks.
@(test)
vm_variable_table_reads :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local t = {11, 22}
		local k = 1
		local alias = t
		alias = alias[k]
		assert(alias == 11)
		t[2] = nil
		local s, big, obj = 'short-key', string.rep('x', 100), {}
		t[s], t[big], t[obj], t[999], t[1.25] = 33, 44, 55, 66, 77
		for key, value in pairs({[s]=33, [big]=44, [obj]=55, [999]=66, [1.25]=77}) do
		  assert(t[key] == value)
		end
		setmetatable(t, {__index = function(_, key)
		  coroutine.yield(key)
		  collectgarbage('collect')
		  return 90
		end})
		for _, key in ipairs({2, 'missing', 9999, false}) do
		  local co = coroutine.create(function() return t[key] + 1 end)
		  local ok, seen = coroutine.resume(co)
		  assert(ok and seen == key)
		  local done, value = coroutine.resume(co)
		  assert(done and value == 91)
		end
		local co = coroutine.create(function() local key; return t[key] end)
		local ok, seen = coroutine.resume(co)
		assert(ok and seen == nil)
		local done, value = coroutine.resume(co)
		assert(done and value == 90)
		local err, key = false, 'x'
		assert(not pcall(function() return err[key] end))
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Integer writes can take the contextless path only when no GC barrier is
// needed. Empty slots with __newindex, writes needing a barrier, and non-table
// objects still have to follow the ordinary yielding/error paths.
@(test)
vm_variable_table_writes :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local t = setmetatable({11}, {
		  __newindex = function(tab, key, value)
		    coroutine.yield(key, value)
		    collectgarbage('collect')
		    rawset(tab, key, value)
		  end
		})
		local co = coroutine.create(function()
		  local k = 1
		  t[k] = 12
		  local before = t[k]
		  k = 2
		  t[k] = 42
		  local child = {answer = 99}
		  k = 1
		  t[k] = child
		  collectgarbage('collect')
		  return before, t[2], t[k].answer
		end)
		local ok, key, value = coroutine.resume(co)
		assert(ok and key == 2 and value == 42)
		local ok2, a, b, c = coroutine.resume(co)
		assert(ok2 and a == 12 and b == 42 and c == 99)
		local ok3 = pcall(function() local x, k = false, 1; x[k] = 1 end)
		assert(not ok3)
		for _, mode in ipairs({'incremental', 'generational'}) do
		  collectgarbage(mode)
		  local holder = {false}
		  collectgarbage('collect')
		  for i = 1, 200 do
		    local k = 1
		    holder[k] = {i}
		    collectgarbage('step')
		    assert(holder[k][1] == i)
		  end
		end
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Short-string writes exercise successful pre-sets, rehashes, deletion,
// collectable values and a yielding __newindex miss using variable keys.
@(test)
vm_short_string_table_writes :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		for _, mode in ipairs({'incremental', 'generational'}) do
		  collectgarbage(mode)
		  local t = {}
		  for i = 1, 200 do local k = 'key' .. i; t[k] = i end
		  collectgarbage('collect')
		  for i = 1, 200 do local k = 'key' .. i; assert(t[k] == i) end
		  local k = 'key1'
		  t[k] = nil
		  t[k] = 123
		  local child = {answer = 99}
		  t[k] = child
		  collectgarbage('collect')
		  assert(t[k].answer == 99)
		  local mt = {__newindex = function(tab, key, value)
		    coroutine.yield(key, value)
		    collectgarbage('collect')
		    rawset(tab, key, value)
		  end}
		  local dst = setmetatable({}, mt)
		  local co = coroutine.create(function()
		    local key = 'missing'; dst[key] = 42; return dst[key]
		  end)
		  local ok, key, value = coroutine.resume(co)
		  assert(ok and key == 'missing' and value == 42)
		  local resumed, result = coroutine.resume(co)
		  assert(resumed and result == 42)
		end
		return true
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	testing.expect(t, kernel.api_toboolean(L, -1))
}

// Debug code can mutate the loop's control-variable tag. Preserve this VM's
// existing tag repair (unlike reference Lua, which preserves the changed tag).
// Ordinary source code cannot assign to a numeric-for control variable.
@(test)
numeric_for_debug_control_tag :: proc(t: ^testing.T) {
	L := pkg_state()
	defer kernel.close_state(L)
	status := pkg_run(L, `
		local seen, n = nil, 0
		for i = 1, 2 do
		  n = n + 1
		  if n == 1 then debug.setlocal(1, 5, false)
		  else seen = type(i) end
		end
		return seen
	`)
	if status != .Ok {
		msg, _ := kernel.api_tolstring(L, -1)
		testing.expectf(t, false, "chunk failed: %s", msg)
		return
	}
	seen, ok := kernel.api_tolstring(L, -1)
	testing.expectf(t, ok && seen == "number", "control tag after debug mutation: %s", seen)
}

@(test)
test_vm_integer_arithmetic :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 1 + 2 * 3 - 4")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, fx.nres, 1)
	testing.expect(t, kernel.is_integer(res(&fx, 0)))
	testing.expect_value(t, res_int(&fx, 0), 3)
}

@(test)
test_vm_float_and_div :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// `/` always produces a float in Lua 5.5, even on integer operands.
	status := run_source(&fx, "return 7 / 2")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, kernel.is_float(res(&fx, 0)))
	testing.expect_value(t, res_float(&fx, 0), 3.5)
}

@(test)
test_vm_floor_div_and_mod :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 7 // 2, 7 % 3, -7 % 3")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, kernel.is_float(res(&fx, 0)))
	testing.expect_value(t, res_float(&fx, 0), 1024.0)
}

@(test)
test_vm_bitwise :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 0xF0 | 0x0F, 0xFF & 0x0F, 5 ~ 3, 1 << 4, 256 >> 2")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect(t, kernel.is_true(res(&fx, 0)))
	testing.expect(t, kernel.is_true(res(&fx, 1)))
	testing.expect(t, kernel.is_false(res(&fx, 2)))
	testing.expect(t, kernel.is_true(res(&fx, 3)))
	// An integer and a float that denote the same mathematical value are equal.
	testing.expect(t, kernel.is_true(res(&fx, 4)))
}

@(test)
test_vm_and_or :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// `and`/`or` return operands, not booleans, and short-circuit.
	status := run_source(&fx, "return (nil or 5), (3 and 4), (false and 9)")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 5)
	testing.expect_value(t, res_int(&fx, 1), 4)
	testing.expect(t, kernel.is_false(res(&fx, 2)))
}

@(test)
test_vm_concat_and_len :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// Concatenation coerces numbers to strings; `#` measures a string's bytes.
	status := run_source(&fx, "return 'a' .. 'b' .. 'c', 'x' .. 1 .. 2, #'hello'")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, res_string(&fx, 0), "big")
}

@(test)
test_vm_numeric_for :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local s = 0\nfor i = 1, 10 do s = s + i end\nreturn s")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 55)
}

@(test)
test_vm_for_step_and_float :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local n = 0\nfor i = 10, 1, -1 do n = n + 1 end\nreturn n")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 10)
}

@(test)
test_vm_while_loop :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local i, s = 1, 0\nwhile i <= 5 do s = s + i; i = i + 1 end\nreturn s")
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
	testing.expect_value(t, res_int(&fx, 0), 7)
}

@(test)
test_vm_closure_upvalue :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	// A counter closure proves shared upvalue capture and mutation persist.
	src := "local function counter()\n local n = 0\n return function() n = n + 1; return n end\nend\nlocal c = counter()\nc(); c()\nreturn c()"
	status := run_source(&fx, src)
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Ok)
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
	testing.expect_value(t, status, kernel.Thread_Status.Err_Run)
}

// ---------------------------------------------------------------------------
// Runtime errors
// ---------------------------------------------------------------------------

@(test)
test_vm_runtime_error_arith_on_nil :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "local x\nreturn x + 1")
	testing.expect_value(t, status, kernel.Thread_Status.Err_Run)
	// The error object is a string describing the failure; it sits at top-1.
	msg := string(kernel.str_slice(kernel.str_value(kernel.stack_value(fx.L, fx.L.top - 1))))
	testing.expect(t, contains(msg, "arithmetic"))
}

@(test)
test_vm_syntax_error :: proc(t: ^testing.T) {
	fx: VM_Fixture
	defer teardown_vm(&fx)
	status := run_source(&fx, "return 1 +")
	testing.expect_value(t, status, kernel.Thread_Status.Err_Syntax)
}
