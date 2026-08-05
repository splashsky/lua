#+build !freestanding

package stdlib

// tzif.odin -- the data-only half of POSIX local-time support.
//
// A TZif file starts with a 44-byte header, then four parallel pieces we care
// about: transition instants, one-byte type indexes for those instants, six-byte
// local-time-type records, and a NUL-separated abbreviation table. There are
// leap-second and indicator tables after those, which we bounds-check and skip.
//
// Version 2 and 3 files look wasteful because they carry that whole arrangement
// twice. The first block has 32-bit transition times for old readers; a second
// header and block repeat it with 64-bit times. We deliberately parse and use the
// second block. Its final newline-delimited POSIX rule describes years beyond
// the last explicit transition. Version 1 is also accepted, using its sole
// 32-bit block and no footer.
//
// The parser keeps offsets into the caller's byte slice rather than allocating.
// That makes malformed-input tests honest and lets the hosted loader use a
// temporary file buffer. Callers must keep `data` alive while using TZif_Zone.
// The byte parser and rule evaluator are covered by constructed-image tests on
// Windows. The file discovery and real POSIX OS path are only cross-compiled
// here; they still need end-to-end confirmation on an actual Linux/macOS host.

import "core:fmt"
import "core:os"

TZif_Local_Type :: struct {
	offset:       i64,
	is_dst:       bool,
	abbreviation: string,
}

TZif_Zone :: struct {
	data:              []u8,
	transition_offset: int,
	index_offset:      int,
	type_offset:       int,
	abbreviation_offset: int,
	transition_count:  int,
	type_count:        int,
	abbreviation_count: int,
	time_size:         int,
	footer:            string,
}

POSIX_Rule_Kind :: enum {
	Julian_No_Leap,
	Julian,
	Month_Week_Day,
}

POSIX_Transition_Rule :: struct {
	kind:    POSIX_Rule_Kind,
	day:     int,
	month:   int,
	week:    int,
	weekday: int,
	seconds: i64,
}

POSIX_TZ_Rule :: struct {
	standard_name:   string,
	standard_offset: i64,
	has_dst:         bool,
	daylight_name:   string,
	daylight_offset: i64,
	start:           POSIX_Transition_Rule,
	end:             POSIX_Transition_Rule,
}

@(private = "file")
tzif_u32 :: proc(data: []u8, at: int) -> (u32, bool) {
	if at < 0 || at > len(data) - 4 {
		return 0, false
	}
	return u32(data[at]) << 24 | u32(data[at + 1]) << 16 |
		u32(data[at + 2]) << 8 | u32(data[at + 3]), true
}

@(private = "file")
tzif_i32 :: proc(data: []u8, at: int) -> (i32, bool) {
	v, ok := tzif_u32(data, at)
	return i32(v), ok
}

@(private = "file")
tzif_i64 :: proc(data: []u8, at: int) -> (i64, bool) {
	if at < 0 || at > len(data) - 8 {
		return 0, false
	}
	v := u64(data[at]) << 56 | u64(data[at + 1]) << 48 |
		u64(data[at + 2]) << 40 | u64(data[at + 3]) << 32 |
		u64(data[at + 4]) << 24 | u64(data[at + 5]) << 16 |
		u64(data[at + 6]) << 8 | u64(data[at + 7])
	return i64(v), true
}

@(private = "file")
TZif_Header :: struct {
	version:  u8,
	isut:     int,
	isstd:    int,
	leap:     int,
	time:     int,
	types:    int,
	chars:    int,
}

@(private = "file")
tzif_header :: proc(data: []u8, at: int) -> (TZif_Header, bool) {
	if at < 0 || at > len(data) - 44 ||
	   data[at] != 'T' || data[at + 1] != 'Z' ||
	   data[at + 2] != 'i' || data[at + 3] != 'f' {
		return {}, false
	}
	h := TZif_Header{version = data[at + 4]}
	values := [6]^int{&h.isut, &h.isstd, &h.leap, &h.time, &h.types, &h.chars}
	for ptr, i in values {
		v, ok := tzif_u32(data, at + 20 + i * 4)
		if !ok || u64(v) > u64(max(int)) {
			return {}, false
		}
		ptr^ = int(v)
	}
	if h.types < 1 || h.types > 256 || h.chars < 1 ||
	   (h.isut != 0 && h.isut != h.types) ||
	   (h.isstd != 0 && h.isstd != h.types) {
		return {}, false
	}
	return h, true
}

@(private = "file")
tzif_block_size :: proc(h: TZif_Header, time_size: int) -> (int, bool) {
	n := i64(h.time) * i64(time_size) + i64(h.time) +
		i64(h.types) * 6 + i64(h.chars) +
		i64(h.leap) * i64(time_size + 4) + i64(h.isstd) + i64(h.isut)
	if n < 0 || n > i64(max(int)) {
		return 0, false
	}
	return int(n), true
}

@(private = "file")
tzif_transition :: proc(z: TZif_Zone, index: int) -> (i64, bool) {
	if index < 0 || index >= z.transition_count {
		return 0, false
	}
	at := z.transition_offset + index * z.time_size
	if z.time_size == 8 {
		return tzif_i64(z.data, at)
	}
	v, ok := tzif_i32(z.data, at)
	return i64(v), ok
}

@(private = "file")
tzif_abbreviation :: proc(z: TZif_Zone, index: int) -> (string, bool) {
	if index < 0 || index >= z.abbreviation_count {
		return "", false
	}
	start := z.abbreviation_offset + index
	limit := z.abbreviation_offset + z.abbreviation_count
	for end := start; end < limit; end += 1 {
		if z.data[end] == 0 {
			return string(z.data[start:end]), true
		}
	}
	return "", false
}

TZif_Type :: proc(z: TZif_Zone, index: int) -> (TZif_Local_Type, bool) {
	if index < 0 || index >= z.type_count {
		return {}, false
	}
	at := z.type_offset + index * 6
	off, ok := tzif_i32(z.data, at)
	if !ok || off < -89999 || off > 93599 ||
	   (z.data[at + 4] != 0 && z.data[at + 4] != 1) {
		return {}, false
	}
	abbr, abbr_ok := tzif_abbreviation(z, int(z.data[at + 5]))
	if !abbr_ok {
		return {}, false
	}
	return TZif_Local_Type{
		offset = i64(off),
		is_dst = z.data[at + 4] == 1,
		abbreviation = abbr,
	}, true
}

TZif_Parse :: proc(data: []u8) -> (TZif_Zone, bool) {
	first, ok := tzif_header(data, 0)
	if !ok || (first.version != 0 && first.version != '2' && first.version != '3') {
		return {}, false
	}

	header_at := 0
	h := first
	time_size := 4
	if first.version == '2' || first.version == '3' {
		first_size, valid := tzif_block_size(first, 4)
		if !valid || first_size > len(data) - 44 {
			return {}, false
		}
		header_at = 44 + first_size
		h, valid = tzif_header(data, header_at)
		if !valid || h.version != first.version {
			return {}, false
		}
		time_size = 8
	}

	block_size, valid := tzif_block_size(h, time_size)
	block_at := header_at + 44
	if !valid || block_at > len(data) || block_size > len(data) - block_at {
		return {}, false
	}

	z := TZif_Zone{
		data = data,
		transition_offset = block_at,
		index_offset = block_at + h.time * time_size,
		type_offset = block_at + h.time * time_size + h.time,
		abbreviation_offset = block_at + h.time * time_size + h.time + h.types * 6,
		transition_count = h.time,
		type_count = h.types,
		abbreviation_count = h.chars,
		time_size = time_size,
	}

	previous: i64
	for i in 0 ..< z.transition_count {
		t, good := tzif_transition(z, i)
		if !good || (i > 0 && t <= previous) ||
		   int(data[z.index_offset + i]) >= z.type_count {
			return {}, false
		}
		previous = t
	}
	for i in 0 ..< z.type_count {
		if _, good := TZif_Type(z, i); !good {
			return {}, false
		}
	}

	indicators := z.abbreviation_offset + z.abbreviation_count +
		h.leap * (time_size + 4)
	if indicators > block_at + block_size {
		return {}, false
	}
	for i in 0 ..< h.isstd + h.isut {
		if data[indicators + i] > 1 {
			return {}, false
		}
	}

	if time_size == 8 {
		footer_at := block_at + block_size
		if footer_at >= len(data) || data[footer_at] != '\n' {
			return {}, false
		}
		footer_at += 1
		footer_end := footer_at
		for footer_end < len(data) && data[footer_end] != '\n' {
			if data[footer_end] == 0 {
				return {}, false
			}
			footer_end += 1
		}
		if footer_end >= len(data) {
			return {}, false
		}
		z.footer = string(data[footer_at:footer_end])
	}
	return z, true
}

@(private = "file")
posix_alpha :: proc(c: u8) -> bool {
	return c >= 'A' && c <= 'Z' || c >= 'a' && c <= 'z'
}

@(private = "file")
posix_digit :: proc(c: u8) -> bool {
	return c >= '0' && c <= '9'
}

@(private = "file")
posix_name :: proc(s: string, at: int) -> (string, int, bool) {
	at := at
	if at >= len(s) {
		return "", at, false
	}
	if s[at] == '<' {
		start := at + 1
		at = start
		for at < len(s) && s[at] != '>' {
			c := s[at]
			if !(posix_alpha(c) || posix_digit(c) || c == '+' || c == '-') {
				return "", at, false
			}
			at += 1
		}
		if at >= len(s) || at == start {
			return "", at, false
		}
		return s[start:at], at + 1, true
	}
	start := at
	for at < len(s) && posix_alpha(s[at]) {
		at += 1
	}
	if at - start < 3 {
		return "", at, false
	}
	return s[start:at], at, true
}

@(private = "file")
posix_number :: proc(s: string, at: int, min_value, max_value: int) -> (int, int, bool) {
	at := at
	start := at
	value := 0
	for at < len(s) && posix_digit(s[at]) {
		if value > (max_value - int(s[at] - '0')) / 10 {
			return 0, at, false
		}
		value = value * 10 + int(s[at] - '0')
		at += 1
	}
	if at == start || value < min_value || value > max_value {
		return 0, at, false
	}
	return value, at, true
}

// POSIX offsets have the opposite sign from TZif's gmtoff: EST5 means local
// time is UTC-5. Transition clock values use the same number syntax but their
// sign is ordinary, so `reverse` selects which interpretation is wanted.
@(private = "file")
posix_hms :: proc(s: string, at: int, reverse: bool, max_hour: int = 167) -> (i64, int, bool) {
	at := at
	sign: i64 = 1
	if at < len(s) && (s[at] == '+' || s[at] == '-') {
		if s[at] == '-' {
			sign = -1
		}
		at += 1
	}
	hour, next, ok := posix_number(s, at, 0, max_hour)
	if !ok {
		return 0, at, false
	}
	at = next
	minute, second := 0, 0
	if at < len(s) && s[at] == ':' {
		minute, at, ok = posix_number(s, at + 1, 0, 59)
		if !ok {
			return 0, at, false
		}
		if at < len(s) && s[at] == ':' {
			second, at, ok = posix_number(s, at + 1, 0, 59)
			if !ok {
				return 0, at, false
			}
		}
	}
	value := sign * i64(hour * 3600 + minute * 60 + second)
	if reverse {
		value = -value
	}
	return value, at, true
}

@(private = "file")
posix_transition_rule :: proc(s: string, at: int) -> (POSIX_Transition_Rule, int, bool) {
	at := at
	r := POSIX_Transition_Rule{seconds = 2 * 3600}
	if at >= len(s) {
		return {}, at, false
	}
	if s[at] == 'M' {
		r.kind = .Month_Week_Day
		value, next, ok := posix_number(s, at + 1, 1, 12)
		if !ok do return {}, at, false
		r.month, at = value, next
		if at >= len(s) || s[at] != '.' {
			return {}, at, false
		}
		value, next, ok = posix_number(s, at + 1, 1, 5)
		if !ok do return {}, at, false
		r.week, at = value, next
		if at >= len(s) || s[at] != '.' {
			return {}, at, false
		}
		value, next, ok = posix_number(s, at + 1, 0, 6)
		if !ok do return {}, at, false
		r.weekday, at = value, next
	} else if s[at] == 'J' {
		r.kind = .Julian_No_Leap
		value, next, ok := posix_number(s, at + 1, 1, 365)
		if !ok do return {}, at, false
		r.day, at = value, next
	} else {
		r.kind = .Julian
		value, next, ok := posix_number(s, at, 0, 365)
		if !ok do return {}, at, false
		r.day, at = value, next
	}
	if at < len(s) && s[at] == '/' {
		value, next, ok := posix_hms(s, at + 1, false)
		if !ok do return {}, at, false
		r.seconds, at = value, next
	}
	return r, at, true
}

POSIX_TZ_Parse :: proc(s: string) -> (POSIX_TZ_Rule, bool) {
	r: POSIX_TZ_Rule
	at := 0
	name, next, ok := posix_name(s, at)
	if !ok do return {}, false
	r.standard_name, at = name, next
	offset: i64
	offset, next, ok = posix_hms(s, at, true)
	if !ok do return {}, false
	r.standard_offset, at = offset, next
	if at == len(s) {
		return r, true
	}
	name, next, ok = posix_name(s, at)
	if !ok do return {}, false
	r.daylight_name, at = name, next
	r.has_dst = true
	r.daylight_offset = r.standard_offset + 3600
	if at < len(s) && s[at] != ',' {
		offset, next, ok = posix_hms(s, at, true)
		if !ok do return {}, false
		r.daylight_offset, at = offset, next
	}
	// We intentionally require explicit rules for a DST string. POSIX permits an
	// implementation-defined default when they are absent; silently choosing one
	// would be worse than rejecting the zone and taking the documented UTC fallback.
	if at >= len(s) || s[at] != ',' {
		return {}, false
	}
	transition: POSIX_Transition_Rule
	transition, next, ok = posix_transition_rule(s, at + 1)
	if !ok do return {}, false
	r.start, at = transition, next
	if at >= len(s) || s[at] != ',' {
		return {}, false
	}
	transition, next, ok = posix_transition_rule(s, at + 1)
	if !ok do return {}, false
	r.end, at = transition, next
	return r, at == len(s)
}

// The Gregorian calendar transforms these rules need are the same ones `oslib.odin`
// already implements for `os.date`/`os.time` -- `is_leap`, `floor_div`,
// `days_from_civil`, and `civil_from_days`. They live in the same `stdlib` package,
// so this file calls them directly rather than keeping a second copy: two
// independent implementations of the same calendar are exactly the kind of pair
// that drifts apart silently.


@(private = "file")
posix_rule_day :: proc(year: i64, r: POSIX_Transition_Rule) -> i64 {
	switch r.kind {
	case .Julian_No_Leap:
		day := i64(r.day - 1)
		if is_leap(year) && r.day >= 60 {
			day += 1
		}
		return day
	case .Julian:
		return i64(r.day)
	case .Month_Week_Day:
		first := days_from_civil(year, r.month, 1)
		first_weekday := int((first + 4) % 7)
		if first_weekday < 0 {
			first_weekday += 7
		}
		day := 1 + (r.weekday - first_weekday + 7) % 7 + (r.week - 1) * 7
		next_month := r.month == 12 ? days_from_civil(year + 1, 1, 1) :
			days_from_civil(year, r.month + 1, 1)
		if days_from_civil(year, r.month, day) >= next_month {
			day -= 7
		}
		return days_from_civil(year, r.month, day) - days_from_civil(year, 1, 1)
	}
	return 0
}

@(private = "file")
posix_transition_utc :: proc(year: i64, r: POSIX_Transition_Rule, before_offset: i64) -> i64 {
	return days_from_civil(year, 1, 1) * 86400 +
		posix_rule_day(year, r) * 86400 + r.seconds - before_offset
}

POSIX_TZ_At :: proc(r: POSIX_TZ_Rule, timestamp: i64) -> TZif_Local_Type {
	if !r.has_dst {
		return TZif_Local_Type{offset = r.standard_offset, abbreviation = r.standard_name}
	}
	// The rule's year is a local-calendar concept. Standard local time gives a
	// stable year even while the daylight offset is active.
	local_days := floor_div(timestamp + r.standard_offset, 86400)
	year, _, _ := civil_from_days(local_days)
	start := posix_transition_utc(year, r.start, r.standard_offset)
	end := posix_transition_utc(year, r.end, r.daylight_offset)
	dst := start < end ? timestamp >= start && timestamp < end :
		timestamp >= start || timestamp < end
	if dst {
		return TZif_Local_Type{
			offset = r.daylight_offset,
			is_dst = true,
			abbreviation = r.daylight_name,
		}
	}
	return TZif_Local_Type{offset = r.standard_offset, abbreviation = r.standard_name}
}

TZif_At :: proc(z: TZif_Zone, timestamp: i64) -> (TZif_Local_Type, bool) {
	if z.transition_count == 0 {
		if z.footer != "" {
			if rule, ok := POSIX_TZ_Parse(z.footer); ok {
				return POSIX_TZ_At(rule, timestamp), true
			}
		}
		return TZif_Type(z, 0)
	}
	last, _ := tzif_transition(z, z.transition_count - 1)
	if timestamp > last && z.footer != "" {
		if rule, ok := POSIX_TZ_Parse(z.footer); ok {
			return POSIX_TZ_At(rule, timestamp), true
		}
	}
	lo, hi := 0, z.transition_count
	for lo < hi {
		mid := lo + (hi - lo) / 2
		t, _ := tzif_transition(z, mid)
		if t <= timestamp {
			lo = mid + 1
		} else {
			hi = mid
		}
	}
	type_index := 0
	if lo > 0 {
		type_index = int(z.data[z.index_offset + lo - 1])
	}
	return TZif_Type(z, type_index)
}

Local_Zone :: struct {
	data:  []u8,
	tzif:  TZif_Zone,
	posix: POSIX_TZ_Rule,
	is_posix: bool,
}

@(private = "file")
local_zone_file :: proc(path: string) -> (Local_Zone, bool) {
	data, err := os.read_entire_file(path, context.temp_allocator)
	if err != nil {
		return {}, false
	}
	z, ok := TZif_Parse(data)
	if !ok {
		delete(data, context.temp_allocator)
		return {}, false
	}
	return Local_Zone{data = data, tzif = z}, true
}

@(private = "file")
local_zone_path :: proc(name: string) -> (Local_Zone, bool) {
	if len(name) > 0 && name[0] == '/' {
		return local_zone_file(name)
	}
	if dir, found := os.lookup_env("TZDIR", context.temp_allocator); found {
		defer delete(dir, context.temp_allocator)
		if zone, ok := local_zone_file(fmt.tprintf("%s/%s", dir, name)); ok {
			return zone, true
		}
	}
	dirs := [4]string{
		"/usr/share/zoneinfo",
		"/usr/share/lib/zoneinfo",
		"/var/db/timezone/zoneinfo",
		"/etc/zoneinfo",
	}
	for dir in dirs {
		if zone, ok := local_zone_file(fmt.tprintf("%s/%s", dir, name)); ok {
			return zone, true
		}
	}
	return {}, false
}

load_local_zone :: proc() -> (Local_Zone, bool) {
	if value, found := os.lookup_env("TZ", context.temp_allocator); found {
		defer delete(value, context.temp_allocator)
		if value == "" {
			rule, _ := POSIX_TZ_Parse("UTC0")
			return Local_Zone{posix = rule, is_posix = true}, true
		}
		name := value
		if name[0] == ':' {
			name = name[1:]
			// The colon form explicitly requests implementation-defined file
			// handling. Try it verbatim first, so both :/absolute/path and
			// :relative/path work, then retain zone-name lookup as a convenience.
			if zone, ok := local_zone_file(name); ok {
				return zone, true
			}
		}
		if zone, ok := local_zone_path(name); ok {
			return zone, true
		}
		if rule, ok := POSIX_TZ_Parse(name); ok {
			return Local_Zone{posix = rule, is_posix = true}, true
		}
		return {}, false
	}
	return local_zone_file("/etc/localtime")
}

free_local_zone :: proc(z: ^Local_Zone) {
	if len(z.data) > 0 {
		delete(z.data, context.temp_allocator)
		z.data = nil
	}
}

local_zone_at :: proc(z: Local_Zone, timestamp: i64) -> (TZif_Local_Type, bool) {
	if z.is_posix {
		return POSIX_TZ_At(z.posix, timestamp), true
	}
	return TZif_At(z.tzif, timestamp)
}
