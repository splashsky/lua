package tests

// parse_test.odin -- Phase 4 tests for the recursive-descent parser (parse.odin).
//
// These prove the parser honestly by compiling real Lua source through the same
// entry point the interpreter uses (`luaY_parser`) and then asserting on the
// *observable* shape of the `Proto` it produces: the number of parameters, the
// vararg flag, the upvalue names, the constant table, and the emitted opcode
// stream. Every expectation here is a fact about the Lua 5.5 bytecode the
// language spec requires for these snippets -- e.g. that the main chunk is a
// vararg function whose sole upvalue is `_ENV`, that a global write compiles to a
// SETTABUP on `_ENV`, that `1 + 2` folds to a single immediate load, that a
// nested `function(a, b)` prototype reports two parameters -- not an assertion
// wired to any private detail of our implementation.
//
// The `Src_Reader`, `src_read`, and `contains` helpers are shared with
// lex_test.odin (same `tests` package).

import "core:testing"
import kernel "lang:kernel"

// ---------------------------------------------------------------------------
// Fixture: stand up a state, stream a chunk, and drive the parser under the
// protected boundary so a syntax error is caught instead of aborting.
// ---------------------------------------------------------------------------

Parse_Fixture :: struct {
	L:    ^kernel.State,
	z:    kernel.Zio,
	buff: kernel.Mbuffer,
	dyd:  kernel.Dyndata,
	rd:   Src_Reader,
	cl:   ^kernel.LClosure, // the compiled main closure (nil on error)
}

// The protected job: compile the whole chunk. `luaY_parser` may longjmp on a
// syntax error; `run_protected` turns that into a returned status.
Parse_Job :: struct {
	fx:    ^Parse_Fixture,
	name:  string,
	first: int,
}

parse_job_run :: proc(L: ^kernel.State, ud: rawptr) -> kernel.Thread_Status {
	job := (^Parse_Job)(ud)
	fx := job.fx
	fx.cl = kernel.parse_parser(L, &fx.z, &fx.buff, &fx.dyd, job.name, job.first)
	return .Ok
}

// Bring up a fresh fixture pointed at `source`.
setup_parser :: proc(fx: ^Parse_Fixture, source: string) {
	L := kernel.new_state(kernel.default_allocator())
	fx.L = L
	kernel.mbuffer_init(&fx.buff)
	fx.rd = Src_Reader {
		data = ([^]u8)(raw_data(source)),
		len  = uint(len(source)),
		done = false,
	}
	kernel.zio_init(L, &fx.z, src_read, &fx.rd)
	fx.dyd = {}
	fx.cl = nil
}

// Compile `source`, returning the protected status. On success `fx.cl` holds the
// main closure (which stays anchored on the Lua stack for the duration of the
// fixture, so its Proto is safe to inspect).
compile :: proc(fx: ^Parse_Fixture, source: string) -> kernel.Thread_Status {
	setup_parser(fx, source)
	first := kernel.zio_getc(&fx.z)
	job := Parse_Job {
		fx    = fx,
		name  = "=t",
		first = first,
	}
	return kernel.run_protected(fx.L, parse_job_run, &job)
}

// Free everything the fixture owns. The parser allocates the `Dyndata` scratch
// arrays with the state allocator (not the GC), so they must be freed explicitly
// -- exactly as reference Lua's `luaD_protectedparser` does -- before
// `close_state` verifies the byte accounting unwinds to zero.
teardown_parser :: proc(fx: ^Parse_Fixture) {
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
// Small readers over a compiled Proto
// ---------------------------------------------------------------------------

// The main chunk's prototype.
main_proto :: proc(fx: ^Parse_Fixture) -> ^kernel.Proto {
	return fx.cl.p
}

// Does `f` contain at least one instruction with opcode `op`?
has_op :: proc(f: ^kernel.Proto, op: kernel.Op_Code) -> bool {
	for i in 0 ..< f.sizecode {
		if kernel.get_opcode(f.code[i]) == op {
			return true
		}
	}
	return false
}

// The signed immediate of the first LOADI, and whether one was found.
first_loadi :: proc(f: ^kernel.Proto) -> (val: int, found: bool) {
	for i in 0 ..< f.sizecode {
		if kernel.get_opcode(f.code[i]) == .LOADI {
			return kernel.getarg_sBx(f.code[i]), true
		}
	}
	return 0, false
}

// Does the constant table hold the string `s`?
k_has_string :: proc(f: ^kernel.Proto, s: string) -> bool {
	for i in 0 ..< f.sizek {
		v := &f.k[i]
		if kernel.base_type(v) == kernel.TSTRING {
			ts := kernel.str_value(v)
			if string(kernel.str_bytes(ts)[:ts.len]) == s {
				return true
			}
		}
	}
	return false
}

// Whether prototype `f` is a vararg function (uses hidden vararg slots or a
// vararg table). Mirrors the language-level `isvararg` predicate.
proto_is_vararg :: proc(f: ^kernel.Proto) -> bool {
	return (f.flag & u8(kernel.PF_VAHID | kernel.PF_VATAB)) != 0
}

// The interned bytes of an upvalue's name.
upval_name :: proc(f: ^kernel.Proto, idx: int) -> string {
	ts := f.upvalues[idx].name
	return string(kernel.str_bytes(ts)[:ts.len])
}

// ---------------------------------------------------------------------------
// The main chunk itself
// ---------------------------------------------------------------------------

// Every Lua chunk compiles to a vararg function taking no declared parameters,
// with a single upvalue named "_ENV", beginning with VARARGPREP and ending in a
// return. This is the bedrock the language guarantees for any top-level chunk.
@(test)
parse_empty_chunk_is_vararg_main :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(t, compile(&fx, ""), kernel.Thread_Status.Ok)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect_value(t, int(f.numparams), 0)
	testing.expect(t, proto_is_vararg(f), "main chunk must be vararg")
	testing.expect_value(t, f.sizeupvalues, 1)
	testing.expect_value(t, upval_name(f, 0), "_ENV")

	testing.expect(t, f.sizecode >= 2, "expected at least VARARGPREP + return")
	testing.expect_value(t, kernel.get_opcode(f.code[0]), kernel.Op_Code.VARARGPREP)
	last := kernel.get_opcode(f.code[f.sizecode - 1])
	is_ret := last == .RETURN0 || last == .RETURN1 || last == .RETURN
	testing.expect(t, is_ret, "main chunk must end in a return")
}

// ---------------------------------------------------------------------------
// Constant folding and literals
// ---------------------------------------------------------------------------

// `1 + 2` is a constant expression: the parser folds it to the single integer 3
// at compile time, loaded as an immediate (no separate 1 and 2 survive).
@(test)
parse_folds_constant_arithmetic :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(t, compile(&fx, "local a = 1 + 2"), kernel.Thread_Status.Ok)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	val, found := first_loadi(f)
	testing.expect(t, found, "folded constant should load as an immediate LOADI")
	testing.expect_value(t, val, 3)
}

// A string literal populates the constant table with that interned string.
@(test)
parse_string_literal_becomes_constant :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(t, compile(&fx, "local s = \"hello\""), kernel.Thread_Status.Ok)
	defer teardown_parser(&fx)

	testing.expect(t, k_has_string(main_proto(&fx), "hello"), "constant 'hello' expected")
}

// ---------------------------------------------------------------------------
// Globals go through the _ENV upvalue
// ---------------------------------------------------------------------------

// A bare assignment `x = 1` is sugar for `_ENV.x = 1`: it emits a SETTABUP on the
// _ENV upvalue and records "x" as a constant key.
@(test)
parse_global_assignment_uses_env :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(t, compile(&fx, "x = 1"), kernel.Thread_Status.Ok)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect(t, has_op(f, .SETTABUP), "global store must use SETTABUP")
	testing.expect(t, k_has_string(f, "x"), "global name 'x' must be a constant")
}

// A call statement `print(\"hi\")` reads `print` from _ENV (GETTABUP) and emits a
// CALL; both the function name and the argument string become constants.
@(test)
parse_call_statement_shape :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(t, compile(&fx, "print(\"hi\")"), kernel.Thread_Status.Ok)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect(t, has_op(f, .GETTABUP), "global read must use GETTABUP")
	testing.expect(t, has_op(f, .CALL), "call statement must emit CALL")
	testing.expect(t, k_has_string(f, "print"), "constant 'print' expected")
	testing.expect(t, k_has_string(f, "hi"), "constant 'hi' expected")
}

// ---------------------------------------------------------------------------
// Nested function prototypes
// ---------------------------------------------------------------------------

// `local function f(a, b) ... end` produces exactly one nested prototype with two
// declared parameters and no vararg. The parent emits a CLOSURE to build it.
@(test)
parse_nested_function_params :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "local function f(a, b) return a + b end"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect_value(t, f.sizep, 1)
	testing.expect(t, has_op(f, .CLOSURE), "parent must emit CLOSURE for nested fn")

	inner := f.p[0]
	testing.expect_value(t, int(inner.numparams), 2)
	testing.expect(t, !proto_is_vararg(inner), "fixed-arg function must not be vararg")
}

// A `function(...)` body reports zero declared parameters, sets the vararg flag,
// and its prototype begins with VARARGPREP.
@(test)
parse_nested_vararg_function :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "local f = function(...) return ... end"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	inner := main_proto(&fx).p[0]
	testing.expect_value(t, int(inner.numparams), 0)
	testing.expect(t, proto_is_vararg(inner), "'...' function must be vararg")
	testing.expect_value(t, kernel.get_opcode(inner.code[0]), kernel.Op_Code.VARARGPREP)
}

// A nested function that reads an enclosing local captures it as an upvalue: the
// inner prototype gains one upvalue named after that local ("x").
@(test)
parse_upvalue_capture :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "local x = 1\nlocal function f() return x end"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	inner := main_proto(&fx).p[0]
	testing.expect_value(t, inner.sizeupvalues, 1)
	testing.expect_value(t, upval_name(inner, 0), "x")
	testing.expect(t, has_op(inner, .GETUPVAL), "captured local read must use GETUPVAL")
}

// ---------------------------------------------------------------------------
// Control flow emits the expected structural opcodes
// ---------------------------------------------------------------------------

// A numeric `for` compiles to the paired FORPREP/FORLOOP bracket.
@(test)
parse_numeric_for_brackets :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "local s = 0\nfor i = 1, 10 do s = s + i end"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect(t, has_op(f, .FORPREP), "numeric for must emit FORPREP")
	testing.expect(t, has_op(f, .FORLOOP), "numeric for must emit FORLOOP")
}

// A generic `for ... in` compiles to the TFORPREP/TFORCALL/TFORLOOP trio.
@(test)
parse_generic_for_opcodes :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "for k, v in pairs(t) do end"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect(t, has_op(f, .TFORPREP), "generic for must emit TFORPREP")
	testing.expect(t, has_op(f, .TFORCALL), "generic for must emit TFORCALL")
	testing.expect(t, has_op(f, .TFORLOOP), "generic for must emit TFORLOOP")
}

// A table constructor emits NEWTABLE; a mix of list and record fields also emits
// SETLIST (for the array part) and SETFIELD (for the keyed part).
@(test)
parse_table_constructor :: proc(t: ^testing.T) {
	fx: Parse_Fixture
	testing.expect_value(
		t,
		compile(&fx, "local t = {10, 20, x = 30}"),
		kernel.Thread_Status.Ok,
	)
	defer teardown_parser(&fx)

	f := main_proto(&fx)
	testing.expect(t, has_op(f, .NEWTABLE), "constructor must emit NEWTABLE")
	testing.expect(t, has_op(f, .SETLIST), "array part must emit SETLIST")
	testing.expect(t, k_has_string(f, "x"), "record key 'x' must be a constant")
}

// ---------------------------------------------------------------------------
// Syntax errors surface through the protected boundary
// ---------------------------------------------------------------------------

// Assert that `source` fails to compile with a syntax error whose message
// contains `needle`.
expect_parse_error :: proc(t: ^testing.T, source: string, needle: string) {
	fx: Parse_Fixture
	status := compile(&fx, source)
	defer teardown_parser(&fx)

	testing.expectf(t, status == .Err_Syntax, "want Err_Syntax for %q, got %v", source, status)
	msg := kernel.str_value(kernel.stack_value(fx.L, fx.L.top - 1))
	text := string(kernel.str_bytes(msg)[:msg.len])
	testing.expectf(t, contains(text, needle), "message %q should contain %q", text, needle)
}

// An unterminated `if` reports that `end` was expected.
@(test)
parse_missing_end_errors :: proc(t: ^testing.T) {
	expect_parse_error(t, "if true then", "'end' expected")
}

// `local = 5` is missing the variable name.
@(test)
parse_missing_name_errors :: proc(t: ^testing.T) {
	expect_parse_error(t, "local = 5", "<name> expected")
}

// A `break` outside any loop is a static error.
@(test)
parse_break_outside_loop_errors :: proc(t: ^testing.T) {
	expect_parse_error(t, "break", "break outside loop")
}

// Assigning to a numeric literal is not a valid assignment target: the literal
// cannot even begin a suffixed expression, so the parser reports an unexpected
// symbol.
@(test)
parse_assign_to_literal_errors :: proc(t: ^testing.T) {
	expect_parse_error(t, "1 = 2", "unexpected symbol")
}
