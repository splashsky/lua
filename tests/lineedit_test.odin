package tests

// lineedit_test.odin -- direct tests for the REPL's completion machinery.
//
// The REPL completer is tested directly because the unit-test runner cannot
// drive a real raw terminal. That limitation should not make this behavior a
// black box, though: feeding completion_candidates the same text and cursor
// position lets us check the useful result without pretending to type at a
// terminal.

import "core:testing"
import lineedit "luao:lineedit"
import lua "luao:lua"
import aux "luao:stdlib"

// Completion normally runs in a fully initialized interpreter, so each test
// gets exactly that. Keeping the states separate also makes the little globals
// installed by one scenario unable to make another scenario pass by accident.
lineedit_test_state :: proc(t: ^testing.T) -> ^lua.State {
	L := lua.new_state(lua.default_allocator())
	aux.aux_openlibs(L)
	testing.expect(t, lua.api_checkstack(L, 4), "reserve completion stack")
	return L
}

lineedit_test_run :: proc(t: ^testing.T, L: ^lua.State, src: string) {
	st := aux.aux_loadstring(L, src)
	testing.expect_value(t, st, lua.Thread_Status.Ok)
	if st != .Ok {
		return
	}
	testing.expect_value(t, lua.api_pcall(L, 0, lua.MULTRET, 0), lua.Thread_Status.Ok)
}

lineedit_test_candidates :: proc(L: ^lua.State, input: string) -> lineedit.Completion {
	return lineedit.completion_candidates(L, transmute([]u8)input, len(input))
}

lineedit_test_has :: proc(c: ^lineedit.Completion, name: string) -> bool {
	for i in 0 ..< c.count {
		if c.names[i] == name {
			return true
		}
	}
	return false
}

@(test)
lineedit_completes_global_names :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// These are deliberately two different standard globals. Besides checking
	// lookup, they show that a sole match expands all the way to its full name.
	c := lineedit_test_candidates(L, "pri")
	testing.expect(t, c.count == 1 && c.names[0] == "print", "complete global pri")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), len("print"))

	c = lineedit_test_candidates(L, "str")
	testing.expect(t, c.count == 1 && c.names[0] == "string", "complete global str")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), len("string"))
}

@(test)
lineedit_completes_dotted_fields :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// An empty field fragment should enumerate the table, not merely find one
	// convenient member. The three checks are intentionally order-independent.
	c := lineedit_test_candidates(L, "string.")
	testing.expect(t, lineedit_test_has(&c, "find") && lineedit_test_has(&c, "format") && lineedit_test_has(&c, "sub"), "list string fields")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), 0)

	// A partially written field should narrow the same raw-table walk.
	c = lineedit_test_candidates(L, "os.ti")
	testing.expect(t, c.count == 1 && c.names[0] == "time", "complete os.ti")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), len("time"))
}

@(test)
lineedit_walks_chained_tables :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// This small table is clearer than relying on the shape of a standard
	// library, and proves that every completed segment is followed in turn.
	lineedit_test_run(t, L, "a = {b = {alpha = true, beta = true}}")
	c := lineedit_test_candidates(L, "a.b.")
	testing.expect(t, c.count == 2 && c.names[0] == "alpha" && c.names[1] == "beta", "walk nested raw tables")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), 0)
}

@(test)
lineedit_completes_colon_method_position :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// Lua authors naturally type a colon before a method name. Completion uses
	// the same safe field enumeration there as it does after a dot.
	c := lineedit_test_candidates(L, "string:f")
	testing.expect(t, c.count == 2 && c.names[0] == "find" && c.names[1] == "format", "colon completes fields")
}

@(test)
lineedit_non_table_step_has_no_candidates :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// Once a path reaches a number there is nowhere legitimate to continue.
	// Returning an empty completion is both more useful and safer than guessing.
	lineedit_test_run(t, L, "not_table = 42")
	c := lineedit_test_candidates(L, "not_table.x")
	testing.expect_value(t, c.count, 0)
	testing.expect_value(t, lineedit.completion_common_prefix(&c), 0)
}

@(test)
lineedit_finds_longest_common_prefix :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// "find" and "format" diverge immediately after the typed "f". Keeping the
	// candidate order check alongside the prefix check catches errors in either
	// half of the little completion contract.
	c := lineedit_test_candidates(L, "string.f")
	testing.expect(t, c.count == 2 && c.names[0] == "find" && c.names[1] == "format", "complete string.f")
	testing.expect_value(t, lineedit.completion_common_prefix(&c), len("f"))
}

@(test)
lineedit_completion_does_not_fire_index :: proc(t: ^testing.T) {
	L := lineedit_test_state(t)
	defer lua.close_state(L)

	// This proxy is tempting to walk: an ordinary Lua lookup would call
	// __index and hand back a table. Completion must use raw lookups instead.
	// The counter is the important second half of this test: an empty result
	// alone would not prove that user code stayed dormant while we inspected it.
	lineedit_test_run(
		t,
		L,
		"hits = 0\n" +
		"proxy = setmetatable({}, {__index = function()\n" +
		"  hits = hits + 1\n" +
		"  return {member = true}\n" +
		"end})",
	)
	c := lineedit_test_candidates(L, "proxy.member.")
	testing.expect_value(t, c.count, 0)
	testing.expect_value(t, lineedit.completion_common_prefix(&c), 0)
	testing.expect_value(t, lua.api_getglobal(L, "hits"), lua.TNUMBER)
	hits, ok := lua.api_tointegerx(L, -1)
	testing.expect(t, ok && hits == 0, "completion must not consult __index")
	lua.api_pop(L, 1)
}
