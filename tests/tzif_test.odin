package tests

// These are deliberately byte-buffer tests, not host-zone tests. They exercise
// the risky TZif layout and rule arithmetic on Windows, where /etc/localtime and
// the POSIX loader cannot be exercised. Real Linux/macOS end-to-end behavior
// therefore remains compile-checked but unverified on this machine.

import "core:testing"
import stdlib "lang:stdlib"

tzif_put_u32 :: proc(b: ^[dynamic]u8, value: u32) {
	append(b, u8(value >> 24), u8(value >> 16), u8(value >> 8), u8(value))
}

tzif_put_i64 :: proc(b: ^[dynamic]u8, value: i64) {
	v := u64(value)
	append(b,
		u8(v >> 56), u8(v >> 48), u8(v >> 40), u8(v >> 32),
		u8(v >> 24), u8(v >> 16), u8(v >> 8), u8(v))
}

tzif_put_header :: proc(
	b: ^[dynamic]u8,
	version: u8,
	time_count, type_count, char_count: int,
) {
	append(b, 'T', 'Z', 'i', 'f', version)
	for _ in 0 ..< 15 do append(b, 0)
	values := [6]int{0, 0, 0, time_count, type_count, char_count}
	for value in values {
		tzif_put_u32(b, u32(value))
	}
}

tzif_put_type :: proc(b: ^[dynamic]u8, offset: i32, dst: bool, abbreviation: u8) {
	tzif_put_u32(b, u32(offset))
	append(b, dst ? 1 : 0, abbreviation)
}

tzif_put_string :: proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
}

tzif_put_v1_fixed_block :: proc(b: ^[dynamic]u8) {
	tzif_put_type(b, 0, false, 0)
	tzif_put_string(b, "UTC\x00")
}

@(test)
tzif_fixed_offset_v1 :: proc(t: ^testing.T) {
	image: [dynamic]u8
	defer delete(image)
	tzif_put_header(&image, 0, 0, 1, 4)
	tzif_put_type(&image, 19800, false, 0)
	tzif_put_string(&image, "IST\x00")

	zone, ok := stdlib.TZif_Parse(image[:])
	testing.expect(t, ok, "a fixed-offset version-1 TZif parses")
	kind, found := stdlib.TZif_At(zone, 0)
	testing.expect(t, found && kind.offset == 19800 && !kind.is_dst &&
		kind.abbreviation == "IST", "fixed type supplies offset, DST flag, and abbreviation")
}

@(test)
tzif_dst_transition_search :: proc(t: ^testing.T) {
	image: [dynamic]u8
	defer delete(image)
	tzif_put_header(&image, 0, 2, 2, 8)
	tzif_put_u32(&image, 1000)
	tzif_put_u32(&image, 2000)
	append(&image, 1, 0)
	tzif_put_type(&image, 0, false, 0)
	tzif_put_type(&image, 3600, true, 4)
	tzif_put_string(&image, "STD\x00DST\x00")

	zone, ok := stdlib.TZif_Parse(image[:])
	testing.expect(t, ok, "a transition-bearing TZif parses")
	before, _ := stdlib.TZif_At(zone, 999)
	during, _ := stdlib.TZif_At(zone, 1000)
	after, _ := stdlib.TZif_At(zone, 2000)
	testing.expect(t, before.offset == 0 && !before.is_dst && before.abbreviation == "STD",
		"type zero applies before the first transition")
	testing.expect(t, during.offset == 3600 && during.is_dst && during.abbreviation == "DST",
		"binary search selects the daylight type at its transition")
	testing.expect(t, after.offset == 0 && !after.is_dst,
		"binary search selects the standard type at fall-back")
}

@(test)
tzif_version2_uses_64_bit_block :: proc(t: ^testing.T) {
	image: [dynamic]u8
	defer delete(image)
	tzif_put_header(&image, '2', 0, 1, 4)
	tzif_put_v1_fixed_block(&image)
	tzif_put_header(&image, '2', 1, 2, 8)
	tzif_put_i64(&image, 4_000_000_000)
	append(&image, 1)
	tzif_put_type(&image, 0, false, 0)
	tzif_put_type(&image, 7200, true, 4)
	tzif_put_string(&image, "STD\x00DST\x00")
	tzif_put_string(&image, "\nUTC0\n")

	zone, ok := stdlib.TZif_Parse(image[:])
	testing.expect(t, ok, "a version-2 image with both blocks parses")
	kind, found := stdlib.TZif_At(zone, 4_000_000_000)
	testing.expect(t, found && kind.offset == 7200 && kind.is_dst &&
		kind.abbreviation == "DST", "the 64-bit block, not the compatibility block, is used")
}

@(test)
tzif_footer_posix_rule_after_last_transition :: proc(t: ^testing.T) {
	image: [dynamic]u8
	defer delete(image)
	tzif_put_header(&image, '3', 0, 1, 4)
	tzif_put_v1_fixed_block(&image)
	tzif_put_header(&image, '3', 1, 1, 4)
	tzif_put_i64(&image, 0)
	append(&image, 0)
	tzif_put_type(&image, -18000, false, 0)
	tzif_put_string(&image, "EST\x00")
	tzif_put_string(&image, "\nEST5EDT,M3.2.0,M11.1.0\n")

	zone, ok := stdlib.TZif_Parse(image[:])
	testing.expect(t, ok, "a version-3 image with a POSIX footer parses")
	winter, winter_ok := stdlib.TZif_At(zone, 1705320000) // 2024-01-15 12:00 UTC
	summer, summer_ok := stdlib.TZif_At(zone, 1719835200) // 2024-07-01 12:00 UTC
	testing.expect(t, winter_ok && winter.offset == -18000 && !winter.is_dst &&
		winter.abbreviation == "EST", "the footer supplies standard time in winter")
	testing.expect(t, summer_ok && summer.offset == -14400 && summer.is_dst &&
		summer.abbreviation == "EDT", "the footer supplies daylight time in summer")
}

@(test)
tzif_rejects_malformed_images :: proc(t: ^testing.T) {
	short := []u8{'T', 'Z', 'i', 'f'}
	_, short_ok := stdlib.TZif_Parse(short)
	testing.expect(t, !short_ok, "a truncated header is rejected")

	image: [dynamic]u8
	defer delete(image)
	tzif_put_header(&image, 0, 1, 1, 4)
	tzif_put_u32(&image, 1000)
	append(&image, 7) // transition references a nonexistent type
	tzif_put_type(&image, 0, false, 0)
	tzif_put_string(&image, "UTC\x00")
	_, bad_index_ok := stdlib.TZif_Parse(image[:])
	testing.expect(t, !bad_index_ok, "an out-of-range transition type is rejected")
}
