package tests

// value_test.odin -- Phase 1 tests for the tagged-value model (object.odin).
//
// These prove real, load-bearing properties of the value representation, not
// implementation trivia. If any break, the interpreter's most basic assumptions
// about how values are stored and inspected would be unsound.

import "core:testing"
import lua "luao:lua"

// Setting and reading back each scalar representation must preserve both the tag
// and the payload exactly.
@(test)
scalar_values_round_trip :: proc(t: ^testing.T) {
	v: lua.TValue

	lua.set_int(&v, 1234567890123)
	testing.expect(t, lua.is_integer(&v))
	testing.expect(t, lua.is_number(&v))
	testing.expect_value(t, lua.int_value(&v), 1234567890123)

	lua.set_float(&v, 3.5)
	testing.expect(t, lua.is_float(&v))
	testing.expect(t, lua.is_number(&v))
	testing.expect_value(t, lua.flt_value(&v), 3.5)

	lua.set_bool(&v, true)
	testing.expect(t, lua.is_boolean(&v) && lua.is_true(&v))
	lua.set_bool(&v, false)
	testing.expect(t, lua.is_boolean(&v) && lua.is_false(&v))
}

// All four nil variants read as "nil" to Lua code, but only VNIL is the strict
// nil. Falsiness covers nil and false only.
@(test)
nil_variants_behave :: proc(t: ^testing.T) {
	v: lua.TValue

	lua.set_nil(&v)
	testing.expect(t, lua.is_nil(&v))
	testing.expect(t, lua.is_strict_nil(&v))
	testing.expect(t, lua.is_falsy(&v))

	lua.set_empty(&v)
	testing.expect(t, lua.is_nil(&v)) // still "a nil"...
	testing.expect(t, !lua.is_strict_nil(&v)) // ...but not the strict nil
	testing.expect(t, lua.is_falsy(&v))

	lua.set_bool(&v, false)
	testing.expect(t, lua.is_falsy(&v)) // false is falsy
	lua.set_bool(&v, true)
	testing.expect(t, !lua.is_falsy(&v)) // true is truthy
	lua.set_int(&v, 0)
	testing.expect(t, !lua.is_falsy(&v)) // 0 is truthy in Lua
}

// Setting nil/boolean must touch ONLY the tag, leaving the payload bits intact.
// This mirrors reference Lua and is why whole-TValue memory comparisons are
// forbidden: two nils may carry different payload garbage.
@(test)
nil_and_bool_preserve_payload :: proc(t: ^testing.T) {
	v: lua.TValue
	lua.set_int(&v, 0x0BADC0DE)
	payload := v.value_.i
	lua.set_nil(&v)
	testing.expect_value(t, v.value_.i, payload) // payload untouched by set_nil
	lua.set_true(&v)
	testing.expect_value(t, v.value_.i, payload) // ...and by set_true
}

// A value pointing at a collectable object takes the object's own variant with
// the collectable bit set, and reports as collectable.
@(test)
gc_value_takes_object_tag :: proc(t: ^testing.T) {
	obj := lua.GCObject {
		tt = lua.VTABLE, // pretend this header belongs to a table
	}
	v: lua.TValue
	lua.set_gc(&v, &obj)
	testing.expect(t, lua.is_collectable(&v))
	// The raw tag carries the collectable bit; type_tag strips it back to the
	// object's own variant (this is how reference Lua's righttt check lines up).
	testing.expect_value(t, lua.raw_tag(&v), lua.ctb(lua.VTABLE))
	testing.expect_value(t, lua.type_tag(&v), lua.Byte(lua.VTABLE))
	testing.expect_value(t, lua.gc_value(&v), &obj)
	// A plain integer is never collectable.
	lua.set_int(&v, 7)
	testing.expect(t, !lua.is_collectable(&v))
}

// set_obj copies payload and tag together.
@(test)
set_obj_copies_everything :: proc(t: ^testing.T) {
	a, b: lua.TValue
	lua.set_float(&a, 2.71828)
	lua.set_obj(&b, &a)
	testing.expect(t, lua.is_float(&b))
	testing.expect_value(t, lua.flt_value(&b), 2.71828)
}
