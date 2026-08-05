package tests

// value_test.odin -- Phase 1 tests for the tagged-value model (object.odin).
//
// These prove real, load-bearing properties of the value representation, not
// implementation trivia. If any break, the interpreter's most basic assumptions
// about how values are stored and inspected would be unsound.

import "core:testing"
import kernel "lang:kernel"

// Setting and reading back each scalar representation must preserve both the tag
// and the payload exactly.
@(test)
scalar_values_round_trip :: proc(t: ^testing.T) {
	v: kernel.TValue

	kernel.set_int(&v, 1234567890123)
	testing.expect(t, kernel.is_integer(&v))
	testing.expect(t, kernel.is_number(&v))
	testing.expect_value(t, kernel.int_value(&v), 1234567890123)

	kernel.set_float(&v, 3.5)
	testing.expect(t, kernel.is_float(&v))
	testing.expect(t, kernel.is_number(&v))
	testing.expect_value(t, kernel.flt_value(&v), 3.5)

	kernel.set_bool(&v, true)
	testing.expect(t, kernel.is_boolean(&v) && kernel.is_true(&v))
	kernel.set_bool(&v, false)
	testing.expect(t, kernel.is_boolean(&v) && kernel.is_false(&v))
}

// All four nil variants read as "nil" to Lua code, but only VNIL is the strict
// nil. Falsiness covers nil and false only.
@(test)
nil_variants_behave :: proc(t: ^testing.T) {
	v: kernel.TValue

	kernel.set_nil(&v)
	testing.expect(t, kernel.is_nil(&v))
	testing.expect(t, kernel.is_strict_nil(&v))
	testing.expect(t, kernel.is_falsy(&v))

	kernel.set_empty(&v)
	testing.expect(t, kernel.is_nil(&v)) // still "a nil"...
	testing.expect(t, !kernel.is_strict_nil(&v)) // ...but not the strict nil
	testing.expect(t, kernel.is_falsy(&v))

	kernel.set_bool(&v, false)
	testing.expect(t, kernel.is_falsy(&v)) // false is falsy
	kernel.set_bool(&v, true)
	testing.expect(t, !kernel.is_falsy(&v)) // true is truthy
	kernel.set_int(&v, 0)
	testing.expect(t, !kernel.is_falsy(&v)) // 0 is truthy in Lua
}

// Setting nil/boolean must touch ONLY the tag, leaving the payload bits intact.
// This mirrors reference Lua and is why whole-TValue memory comparisons are
// forbidden: two nils may carry different payload garbage.
@(test)
nil_and_bool_preserve_payload :: proc(t: ^testing.T) {
	v: kernel.TValue
	kernel.set_int(&v, 0x0BADC0DE)
	payload := v.value_.i
	kernel.set_nil(&v)
	testing.expect_value(t, v.value_.i, payload) // payload untouched by set_nil
	kernel.set_true(&v)
	testing.expect_value(t, v.value_.i, payload) // ...and by set_true
}

// A value pointing at a collectable object takes the object's own variant with
// the collectable bit set, and reports as collectable.
@(test)
gc_value_takes_object_tag :: proc(t: ^testing.T) {
	obj := kernel.GCObject {
		tt = kernel.VTABLE, // pretend this header belongs to a table
	}
	v: kernel.TValue
	kernel.set_gc(&v, &obj)
	testing.expect(t, kernel.is_collectable(&v))
	// The raw tag carries the collectable bit; type_tag strips it back to the
	// object's own variant (this is how reference Lua's righttt check lines up).
	testing.expect_value(t, kernel.raw_tag(&v), kernel.ctb(kernel.VTABLE))
	testing.expect_value(t, kernel.type_tag(&v), kernel.Byte(kernel.VTABLE))
	testing.expect_value(t, kernel.gc_value(&v), &obj)
	// A plain integer is never collectable.
	kernel.set_int(&v, 7)
	testing.expect(t, !kernel.is_collectable(&v))
}

// set_obj copies payload and tag together.
@(test)
set_obj_copies_everything :: proc(t: ^testing.T) {
	a, b: kernel.TValue
	kernel.set_float(&a, 2.71828)
	kernel.set_obj(&b, &a)
	testing.expect(t, kernel.is_float(&b))
	testing.expect_value(t, kernel.flt_value(&b), 2.71828)
}
