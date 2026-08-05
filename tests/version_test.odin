package tests

// version_test.odin -- Phase 0 sanity tests for the version identity.
//
// These are intentionally small, but they are *honest*: they check real,
// externally-meaningful facts, not implementation trivia bent to pass. The
// version numbers are part of Lua's observable identity (they appear in the
// banner, the `_VERSION` global, and the bytecode header), and reference Lua
// derives its combined numeric forms with a specific formula. We verify:
//   1. the major/minor/release match Lua 5.5.0 (as declared in reference `lua.h`),
//   2. the combined VERSION_NUM / VERSION_RELEASE_NUM are computed the same way,
//   3. the human-facing RELEASE string is assembled correctly.
// If any of these drift, something that must agree with reference Lua has broken.
//
// The human-facing strings carry the *brand*, which is a build-time choice, so
// those two assertions are written against `kernel.BRAND` rather than a literal
// "Lua" -- they still prove the string is assembled correctly, under any brand.

import "core:testing"
import kernel "lang:kernel"

@(test)
version_numbers_match_lua_5_5_0 :: proc(t: ^testing.T) {
	testing.expect_value(t, kernel.VERSION_MAJOR_N, 5)
	testing.expect_value(t, kernel.VERSION_MINOR_N, 5)
	testing.expect_value(t, kernel.VERSION_RELEASE_N, 0)
}

@(test)
combined_version_numbers_use_reference_formula :: proc(t: ^testing.T) {
	// Reference Lua: VERSION_NUM = MAJOR*100 + MINOR; RELEASE_NUM = NUM*100 + REL.
	testing.expect_value(t, kernel.VERSION_NUM, 505)
	testing.expect_value(t, kernel.VERSION_RELEASE_NUM, 50500)
}

@(test)
release_string_is_assembled_correctly :: proc(t: ^testing.T) {
	testing.expect_value(t, kernel.VERSION, kernel.BRAND + " 5.5")
	testing.expect_value(t, kernel.RELEASE, kernel.BRAND + " 5.5.0")
}
