#+build !freestanding

package stdlib

// oslib.odin -- the operating-system library without a C-runtime dependency.
//
// The calendar code below deliberately does not lean on a hidden libc date
// parser. Unix time is split into whole days and seconds-within-the-day, then
// converted with the proleptic Gregorian calendar. Local civil time is the one
// place where arithmetic alone is not enough: on Windows we ask the OS to map a
// UTC SYSTEMTIME through the machine's configured time-zone rules. On hosted
// POSIX targets tzif.odin reads TZ or /etc/localtime and applies the TZif
// transition table. Both routes give us the historical offset at the instant,
// including both sides of a DST transition, while normalization stays in Odin.
//
// There are three intentional, visible locale deviations. We have no libc locale
// database, so date names and the composite %c/%x/%X forms are always the fixed
// C-locale English forms; os.setlocale supports only "C", "POSIX", and "" (our
// default is C); and OS error wording comes from core:os rather than strerror.

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:time"
import win32 "core:sys/windows"
import host "lang:host"
import kernel "lang:kernel"
import shellproc "lang:shellproc"

when ODIN_OS == .Windows {
	foreign import oslib_kernel32 "system:Kernel32.lib"
	foreign oslib_kernel32 {
		GetTimeZoneInformation :: proc(lpTimeZoneInformation: ^win32.TIME_ZONE_INFORMATION) -> win32.DWORD ---
	}
}

@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^kernel.State {
	return (^kernel.State)(Lp)
}

// This is the exact option set selected by the vendored loslib.c on each host.
// Windows strftime spells its alternate form with '#'; C99 hosts use E/O.
@(private = "file")
STRFTIME_OPTIONS :: (
	"aAbBcdHIjmMpSUwWxXyYzZ%||#c#x#d#H#I#j#m#M#S#U#w#W#y#Y" when ODIN_OS == .Windows else
	"aAbBcCdDeFgGhHIjmMnprRStTuUVwWxXyYzZ%||EcECExEXEyEYOdOeOHOIOmOMOSOuOUOVOwOWOy"
)

@(private = "file")
Civil_Time :: struct {
	year:   i64,
	month:  int,
	day:    int,
	hour:   int,
	minute: int,
	second: int,
	yday:   int, // zero based, like struct tm
	wday:   int, // Sunday == 0, like struct tm
	isdst:  int, // -1 unknown, 0 standard, 1 daylight
	offset: i64, // local seconds east of UTC
	zone:   string,
}

@(private)
floor_div :: proc(a, b: i64) -> i64 {
	q := a / b
	if a % b < 0 {
		q -= 1
	}
	return q
}

@(private = "file")
floor_mod :: proc(a, b: i64) -> i64 {
	return a - floor_div(a, b) * b
}

@(private)
is_leap :: proc(y: i64) -> bool {
	return y % 4 == 0 && (y % 100 != 0 || y % 400 == 0)
}

// Howard Hinnant's days-from-civil transform, shifted to Unix day zero. The
// March-based year makes February the last month, so leap-day handling becomes a
// single era correction instead of a nest of month special cases.
@(private)
days_from_civil :: proc(y: i64, m, d: int) -> i64 {
	y := y
	if m <= 2 {
		y -= 1
	}
	era := floor_div(y, 400)
	yoe := y - era * 400
	mp := i64(m + (m > 2 ? -3 : 9))
	doy := (153 * mp + 2) / 5 + i64(d) - 1
	doe := yoe * 365 + yoe / 4 - yoe / 100 + doy
	return era * 146097 + doe - 719468
}

// The inverse transform peels a Unix day back into a 400-year era, a year
// within that era, and finally a March-based month. Both procedures use floor
// division, which is the important detail that keeps dates before 1970 correct.
@(private)
civil_from_days :: proc(z: i64) -> (y: i64, m, d: int) {
	z0 := z + 719468
	era := floor_div(z0, 146097)
	doe := z0 - era * 146097
	yoe := (doe - doe / 1460 + doe / 36524 - doe / 146096) / 365
	y = yoe + era * 400
	doy := doe - (365 * yoe + yoe / 4 - yoe / 100)
	mp := (5 * doy + 2) / 153
	d = int(doy - (153 * mp + 2) / 5 + 1)
	m = int(mp + (mp < 10 ? 3 : -9))
	if m <= 2 {
		y += 1
	}
	return
}

@(private = "file")
civil_at_timestamp :: proc(t: i64) -> Civil_Time {
	days := floor_div(t, 86400)
	sod := floor_mod(t, 86400)
	y, m, d := civil_from_days(days)
	jan1 := days_from_civil(y, 1, 1)
	return Civil_Time {
		year = y,
		month = m,
		day = d,
		hour = int(sod / 3600),
		minute = int((sod % 3600) / 60),
		second = int(sod % 60),
		yday = int(days - jan1),
		wday = int(floor_mod(days + 4, 7)), // 1970-01-01 was Thursday
		isdst = 0,
	}
}

// Normalize all fields exactly as mktime does: months may spill across years,
// and day/hour/minute/second may spill in either direction. Converting the first
// of the normalized month to a day number makes even values such as day=0 or
// month=14 fall out naturally.
@(private = "file")
normalize_civil :: proc(year: i64, month, day, hour, minute, second: int) -> (Civil_Time, i64) {
	mi := i64(month) - 1
	y := year + floor_div(mi, 12)
	m := int(floor_mod(mi, 12)) + 1
	total := i64(hour) * 3600 + i64(minute) * 60 + i64(second)
	days := days_from_civil(y, m, 1) + i64(day) - 1 + floor_div(total, 86400)
	nominal := days * 86400 + floor_mod(total, 86400)
	return civil_at_timestamp(nominal), nominal
}

@(private = "file")
tzi_info :: proc() -> (standard, daylight: i64, tzi: win32.TIME_ZONE_INFORMATION, ok: bool) {
	when ODIN_OS == .Windows {
		id := GetTimeZoneInformation(&tzi)
		if id == 0xffffffff {
			return
		}
		standard = -i64(tzi.Bias + tzi.StandardBias) * 60
		daylight = -i64(tzi.Bias + tzi.DaylightBias) * 60
		ok = true
		return
	} else {
		// POSIX conversions do not use this Windows-oriented pair. Keep zeroes
		// here for UTC formatting and for unsupported hosted targets.
		standard, daylight, ok = 0, 0, true
		return
	}
}

@(private = "file")
transition_day :: proc(year: i64, rule: win32.SYSTEMTIME) -> int {
	if rule.year != 0 {
		return int(rule.day)
	}

	// A zero year is Windows' compact recurring-rule form: `day` is the
	// occurrence (1st through 4th, or 5th meaning last) of `day_of_week` in the
	// named month. Work from civil day numbers so leap years need no separate
	// table.
	month := int(rule.month)
	first_wday := int(floor_mod(days_from_civil(year, month, 1) + 4, 7))
	wanted_wday := int(rule.day_of_week)
	first := 1 + int(floor_mod(i64(wanted_wday - first_wday), 7))
	if rule.day < 5 {
		return first + 7 * (int(rule.day) - 1)
	}
	next_year, next_month := year, month + 1
	if next_month == 13 {
		next_year += 1
		next_month = 1
	}
	days_in_month := int(days_from_civil(next_year, next_month, 1) -
		days_from_civil(year, month, 1))
	return first + 7 * ((days_in_month - first) / 7)
}

@(private = "file")
transition_timestamp :: proc(year: i64, rule: win32.SYSTEMTIME, prior_offset: i64) -> i64 {
	day := transition_day(year, rule)
	local_nominal := days_from_civil(year, int(rule.month), day) * 86400 +
		i64(rule.hour) * 3600 + i64(rule.minute) * 60 + i64(rule.second)
	return local_nominal - prior_offset
}

@(private = "file")
local_at_timestamp :: proc(t: i64) -> (Civil_Time, bool) {
	when ODIN_OS == .Windows {
		utc := civil_at_timestamp(t)
		// Windows' CRT applies the current TIME_ZONE_INFORMATION recurrence to
		// every year. SystemTimeToTzSpecificLocalTime(nil, ...) looks tempting,
		// but it consults the registry's historical dynamic rules instead. Those
		// differ observably for old timestamps (for example, US DST in 1970), so
		// doing the small recurrence calculation here is both cheaper and the
		// byte-for-byte match for reference Lua's localtime.
		if utc.year < 1601 || utc.year > 30827 {
			return {}, false
		}
		std, dst, rules, ok := tzi_info()
		if !ok {
			return {}, false
		}
		in_dst := false
		if dst != std && rules.DaylightDate.month != 0 && rules.StandardDate.month != 0 {
			start := transition_timestamp(utc.year, rules.DaylightDate, std)
			finish := transition_timestamp(utc.year, rules.StandardDate, dst)
			in_dst = start < finish ? (t >= start && t < finish) : (t >= start || t < finish)
		}
		offset := in_dst ? dst : std
		out := civil_at_timestamp(t + offset)
		out.offset = offset
		out.isdst = in_dst ? 1 : 0
		return out, true
	} else {
		zone, loaded := load_local_zone()
		if loaded {
			// The abbreviation in Civil_Time is a slice into this temporary TZif
			// image. This helper is only retained for callers that consume the
			// result immediately; os.date keeps its own zone alive through formatting.
			kind, found := local_zone_at(zone, t)
			if found {
				out := civil_at_timestamp(t + kind.offset)
				out.offset = kind.offset
				out.isdst = kind.is_dst ? 1 : 0
				out.zone = kind.abbreviation
				return out, true
			}
		}
		// An unreadable or unsupported zone is not allowed to make os.date fail:
		// UTC is the documented, deterministic last resort.
		out := civil_at_timestamp(t)
		out.offset = 0
		out.isdst = 0
		out.zone = "UTC"
		return out, true
	}
}

@(private = "file")
same_wall :: proc(a, b: Civil_Time) -> bool {
	return a.year == b.year && a.month == b.month && a.day == b.day &&
		a.hour == b.hour && a.minute == b.minute && a.second == b.second
}

// Resolve a local civil time without libc mktime. Around a fall-back fold there
// are two real UTC instants; tm_isdst selects one and an unspecified flag follows
// the Windows CRT by preferring standard time. Around a spring-forward gap there
// is no exact instant. Windows retains its existing CRT-compatible choice below.
//
// POSIX libc leaves both cases implementation-defined, so our non-Windows policy
// is explicit: an unspecified fold prefers standard time, while an unspecified
// gap normalizes forward to the first representable wall time. An explicit
// `isdst` selects that side's offset, even when that normalizes the gap backward.
@(private = "file")
timestamp_from_local :: proc(wall: Civil_Time, nominal: i64, wanted_dst: int) -> (i64, Civil_Time, bool) {
	when ODIN_OS == .Windows {
		std, dst, _, ok := tzi_info()
		if !ok {
			return 0, {}, false
		}
		offsets := [2]i64{std, dst}
		for wanted in 0 ..< 2 {
			for off in offsets {
				if wanted_dst >= 0 && wanted != wanted_dst {
					continue
				}
				t := nominal - off
				got, valid := local_at_timestamp(t)
				if valid && same_wall(got, wall) && got.isdst == wanted {
					return t, got, true
				}
			}
		}
		if wanted_dst < 0 {
			for off in offsets {
				t := nominal - off
				got, valid := local_at_timestamp(t)
				if valid && same_wall(got, wall) {
					return t, got, true
				}
			}
		}
		chosen := wanted_dst == 0 ? std : dst // unknown (-1) deliberately chooses DST
		t := nominal - chosen
		got, valid := local_at_timestamp(t)
		return t, got, valid
	} else {
		zone, loaded := load_local_zone()
		if !loaded {
			got := civil_at_timestamp(nominal)
			got.zone = "UTC"
			return nominal, got, true
		}
		defer free_local_zone(&zone)

		standard_t, daylight_t: i64
		standard_c, daylight_c: Civil_Time
		have_standard, have_daylight := false, false
		best_after_t, best_other_t: i64
		best_after_c, best_other_c: Civil_Time
		best_requested_t: i64
		best_requested_c: Civil_Time
		best_after_delta := i64(max(i64))
		best_other_delta := i64(max(i64))
		best_requested_delta := i64(max(i64))

		// TZif type indexes are bytes, so there can be at most 256 candidate
		// offsets. POSIX-only zones contribute their standard and daylight pair.
		count := zone.is_posix ? (zone.posix.has_dst ? 2 : 1) : zone.tzif.type_count
		for i in 0 ..< count {
			candidate: TZif_Local_Type
			ok := true
			if zone.is_posix {
				if i == 0 {
					candidate = TZif_Local_Type{offset = zone.posix.standard_offset}
				} else {
					candidate = TZif_Local_Type{
						offset = zone.posix.daylight_offset,
						is_dst = true,
					}
				}
			} else {
				candidate, ok = TZif_Type(zone.tzif, i)
			}
			if !ok {
				continue
			}
			t := nominal - candidate.offset
			actual, found := local_zone_at(zone, t)
			if !found {
				continue
			}
			got_nominal := t + actual.offset
			got := civil_at_timestamp(got_nominal)
			got.offset = actual.offset
			got.isdst = actual.is_dst ? 1 : 0
			got.zone = actual.abbreviation
			if same_wall(got, wall) {
				if actual.is_dst {
					if !have_daylight {
						daylight_t, daylight_c, have_daylight = t, got, true
					}
				} else if !have_standard {
					standard_t, standard_c, have_standard = t, got, true
				}
				continue
			}
			delta := got_nominal - nominal
			if delta >= 0 && delta < best_after_delta {
				best_after_t, best_after_c = t, got
				best_after_delta = delta
			}
			absolute := delta < 0 ? -delta : delta
			if wanted_dst >= 0 && candidate.is_dst == (wanted_dst == 1) &&
			   absolute < best_requested_delta {
				best_requested_t, best_requested_c = t, got
				best_requested_delta = absolute
			}
			if absolute < best_other_delta {
				best_other_t, best_other_c = t, got
				best_other_delta = absolute
			}
		}
		if wanted_dst == 0 && have_standard {
			return standard_t, standard_c, true
		}
		if wanted_dst == 1 && have_daylight {
			return daylight_t, daylight_c, true
		}
		if wanted_dst < 0 {
			if have_standard {
				return standard_t, standard_c, true
			}
			if have_daylight {
				return daylight_t, daylight_c, true
			}
			if best_after_delta != i64(max(i64)) {
				return best_after_t, best_after_c, true
			}
		} else if best_requested_delta != i64(max(i64)) {
			return best_requested_t, best_requested_c, true
		}
		if best_other_delta != i64(max(i64)) {
			return best_other_t, best_other_c, true
		}
		return 0, {}, false
	}
}

@(private = "file")
setfield :: proc(L: ^kernel.State, key: string, value: i64) {
	kernel.api_pushinteger(L, kernel.Integer(value))
	kernel.api_setfield(L, -2, key)
}

@(private = "file")
setallfields :: proc(L: ^kernel.State, c: Civil_Time) {
	setfield(L, "year", c.year)
	setfield(L, "month", i64(c.month))
	setfield(L, "day", i64(c.day))
	setfield(L, "hour", i64(c.hour))
	setfield(L, "min", i64(c.minute))
	setfield(L, "sec", i64(c.second))
	setfield(L, "yday", i64(c.yday + 1))
	setfield(L, "wday", i64(c.wday + 1))
	if c.isdst >= 0 {
		kernel.api_pushboolean(L, c.isdst != 0)
		kernel.api_setfield(L, -2, "isdst")
	}
}

@(private = "file")
getboolfield :: proc(L: ^kernel.State, key: string) -> int {
	res := -1
	if kernel.api_getfield(L, -1, key) != kernel.TNIL {
		res = kernel.api_toboolean(L, -1) ? 1 : 0
	}
	kernel.api_pop(L, 1)
	return res
}

@(private = "file")
getfield :: proc(L: ^kernel.State, key: string, d: int, delta: int) -> int {
	tp := kernel.api_getfield(L, -1, key)
	res, isnum := kernel.api_tointegerx(L, -1)
	if !isnum {
		if tp != kernel.TNIL {
			aux_error(L, "field '%s' is not an integer", key)
		} else if d < 0 {
			aux_error(L, "field '%s' missing in date table", key)
		}
		res = kernel.Integer(d)
	} else {
		ok := res >= 0 ? res - kernel.Integer(delta) <= kernel.Integer(max(i32)) :
			kernel.Integer(min(i32)) + kernel.Integer(delta) <= res
		if !ok {
			aux_error(L, "field '%s' is out-of-bound", key)
		}
		res -= kernel.Integer(delta)
	}
	kernel.api_pop(L, 1)
	return int(res)
}

@(private = "file")
checkoption :: proc(L: ^kernel.State, conv: []u8) -> int {
	option := STRFTIME_OPTIONS
	oplen := 1
	oi := 0
	for oi < len(option) && oplen <= len(conv) {
		if option[oi] == '|' {
			oplen += 1
		} else if oi + oplen <= len(option) && string(conv[:oplen]) == option[oi:oi + oplen] {
			return oplen
		}
		oi += oplen
	}
	aux_argerror(L, 1, kernel.api_pushfstring(L, "invalid conversion specifier '%%%s'", string(conv)))
}

@(private = "file")
WDAY_SHORT := [7]string{"Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"}
@(private = "file")
WDAY_LONG := [7]string{"Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"}
@(private = "file")
MONTH_SHORT := [12]string{"Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"}
@(private = "file")
MONTH_LONG := [12]string{"January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"}

@(private = "file")
zone_name :: proc(c: Civil_Time, dst: bool, buf: []u8) -> string {
	when ODIN_OS == .Windows {
		_, _, z, ok := tzi_info()
		if ok {
			src := dst ? z.DaylightName[:] : z.StandardName[:]
			n := 0
			for r in src {
				if r == 0 || n == len(buf) {
					break
				}
				// Windows time-zone display names on supported installations are
				// ASCII in practice. Non-ASCII UTF-16 code units are replaced
				// rather than accidentally emitting malformed UTF-8.
				buf[n] = r < 0x80 ? u8(r) : '?'
				n += 1
			}
			return string(buf[:n])
		}
	} else {
		if c.zone != "" {
			return c.zone
		}
	}
	return "UTC"
}

@(private = "file")
add_num :: proc(B: ^Buffer, value: i64, width: int, unpadded: bool = false) {
	if unpadded {
		aux_addstring(B, fmt.tprintf("%d", value))
	} else {
		aux_addstring(B, fmt.tprintf("%0*d", width, value))
	}
}

@(private = "file")
format_conversion :: proc(B: ^Buffer, op: string, c: Civil_Time, utc: bool) {
	alternate := len(op) == 2
	ch := op[len(op) - 1]
	zone_buf: [128]u8
	switch ch {
	case '%': aux_addchar(B, '%')
	case 'a': aux_addstring(B, WDAY_SHORT[c.wday])
	case 'A': aux_addstring(B, WDAY_LONG[c.wday])
	case 'b', 'h': aux_addstring(B, MONTH_SHORT[c.month - 1])
	case 'B': aux_addstring(B, MONTH_LONG[c.month - 1])
	case 'c':
		if alternate && op[0] == '#' {
			aux_addstring(B, fmt.tprintf("%s, %s %02d, %04d %02d:%02d:%02d",
				WDAY_LONG[c.wday], MONTH_LONG[c.month - 1], c.day, c.year, c.hour, c.minute, c.second))
		} else {
			aux_addstring(B, WDAY_SHORT[c.wday])
			aux_addchar(B, ' ')
			aux_addstring(B, MONTH_SHORT[c.month - 1])
			aux_addchar(B, ' ')
			if c.day < 10 do aux_addchar(B, ' ')
			aux_addstring(B, fmt.tprintf("%d %02d:%02d:%02d %04d",
				c.day, c.hour, c.minute, c.second, c.year))
		}
	case 'x':
		if alternate && op[0] == '#' {
			aux_addstring(B, fmt.tprintf("%s, %s %02d, %04d",
				WDAY_LONG[c.wday], MONTH_LONG[c.month - 1], c.day, c.year))
		} else {
			aux_addstring(B, fmt.tprintf("%02d/%02d/%02d", c.month, c.day, floor_mod(c.year, 100)))
		}
	case 'X': aux_addstring(B, fmt.tprintf("%02d:%02d:%02d", c.hour, c.minute, c.second))
	case 'd', 'e': add_num(B, i64(c.day), ch == 'e' ? 2 : 2, alternate || ch == 'e')
	case 'H': add_num(B, i64(c.hour), 2, alternate)
	case 'I':
		h := c.hour % 12
		if h == 0 do h = 12
		add_num(B, i64(h), 2, alternate)
	case 'j': add_num(B, i64(c.yday + 1), 3, alternate)
	case 'm': add_num(B, i64(c.month), 2, alternate)
	case 'M': add_num(B, i64(c.minute), 2, alternate)
	case 'p': aux_addstring(B, c.hour < 12 ? "AM" : "PM")
	case 'S': add_num(B, i64(c.second), 2, alternate)
	case 'U': add_num(B, i64((c.yday + 7 - c.wday) / 7), 2, alternate)
	case 'w': add_num(B, i64(c.wday), 1, true)
	case 'W': add_num(B, i64((c.yday + 7 - ((c.wday + 6) % 7)) / 7), 2, alternate)
	case 'y': add_num(B, floor_mod(c.year, 100), 2, alternate)
	case 'Y': add_num(B, c.year, 4, alternate)
	case 'z':
		off := c.offset
		if utc {
			// This surprising result matches Windows strftime: gmtime fills no
			// explicit zone field, so %z/%Z still use the process's standard zone.
			//
			// Keep this OS query inside the one conversion that needs it. It used
			// to run unconditionally at the top of format_conversion, meaning a
			// format such as "%Y-%m-%dT%H:%M:%S" made six separate kernel calls
			// even though it never asked for a time-zone offset.
			std, _, _, _ := tzi_info()
			off = std
		}
		sign := "+"
		if off < 0 {
			sign = "-"
			off = -off
		}
		aux_addstring(B, fmt.tprintf("%s%02d%02d", sign, off / 3600, off % 3600 / 60))
	case 'Z':
		aux_addstring(B, zone_name(c, !utc && c.isdst == 1, zone_buf[:]))
	case:
		// C99 aliases admitted on non-Windows hosts.
		switch ch {
		case 'C': add_num(B, floor_div(c.year, 100), 2)
		case 'D': aux_addstring(B, fmt.tprintf("%02d/%02d/%02d", c.month, c.day, floor_mod(c.year, 100)))
		case 'F': aux_addstring(B, fmt.tprintf("%04d-%02d-%02d", c.year, c.month, c.day))
		case 'n': aux_addchar(B, '\n')
		case 'r':
			h := c.hour % 12
			if h == 0 do h = 12
			aux_addstring(B, fmt.tprintf("%02d:%02d:%02d %s", h, c.minute, c.second, c.hour < 12 ? "AM" : "PM"))
		case 'R': aux_addstring(B, fmt.tprintf("%02d:%02d", c.hour, c.minute))
		case 't': aux_addchar(B, '\t')
		case 'T': aux_addstring(B, fmt.tprintf("%02d:%02d:%02d", c.hour, c.minute, c.second))
		case 'u': add_num(B, i64(c.wday == 0 ? 7 : c.wday), 1, true)
		case 'V': add_num(B, i64((c.yday + 10 - (c.wday == 0 ? 7 : c.wday)) / 7), 2)
		}
	}
}

@(private = "file")
l_checktime :: proc(L: ^kernel.State, arg: int) -> i64 {
	return i64(aux_checkinteger(L, arg))
}

@(private = "file")
os_date :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	s := transmute([]u8)aux_optlstring(L, 1, "%c")
	t := kernel.api_isnoneornil(L, 2) ? time.to_unix_seconds(time.now()) : l_checktime(L, 2)
	i := 0
	utc := false
	if len(s) > 0 && s[0] == '!' {
		utc = true
		i = 1
	}
	when ODIN_OS == .Windows {
		// UCRT's localtime rejects negative time_t values on this installation;
		// gmtime accepts them. Preserve that asymmetric reference boundary.
		if !utc && t < 0 {
			aux_error(L, "date result cannot be represented in this installation")
		}
		if utc && t < -43200 {
			aux_error(L, "date result cannot be represented in this installation")
		}
	}
	c: Civil_Time
	ok := true
	if utc {
		c = civil_at_timestamp(t)
		when ODIN_OS == .Windows {
			// UCRT accepts the final twelve hours before the epoch in gmtime,
			// but computes tm_wday as though integer division truncated toward
			// zero. It is odd, but it is observable in the reference build.
			if t < 0 {
				c.wday = 4
			}
		}
	} else {
		when ODIN_OS == .Windows {
			c, ok = local_at_timestamp(t)
		} else {
			// Keep the TZif bytes alive until after %Z has consumed its
			// abbreviation slice. The pure parser intentionally borrows its input.
			zone, loaded := load_local_zone()
			if loaded {
				defer free_local_zone(&zone)
				kind, found := local_zone_at(zone, t)
				if found {
					c = civil_at_timestamp(t + kind.offset)
					c.offset = kind.offset
					c.isdst = kind.is_dst ? 1 : 0
					c.zone = kind.abbreviation
				} else {
					c = civil_at_timestamp(t)
					c.zone = "UTC"
				}
			} else {
				c = civil_at_timestamp(t)
				c.zone = "UTC"
			}
		}
	}
	if !ok {
		aux_error(L, "date result cannot be represented in this installation")
	}
	rest := s[i:]
	if string(rest) == "*t" {
		kernel.api_createtable(L, 0, 9)
		setallfields(L, c)
		return 1
	}
	b: Buffer
	aux_buffinit(L, &b)
	for p := 0; p < len(rest); {
		if rest[p] != '%' {
			aux_addchar(&b, rest[p])
			p += 1
			continue
		}
		p += 1
		n := checkoption(L, rest[p:])
		format_conversion(&b, string(rest[p:p + n]), c, utc)
		p += n
	}
	aux_pushresult(&b)
	return 1
}

@(private = "file")
os_time :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	t: i64
	if kernel.api_isnoneornil(L, 1) {
		t = time.to_unix_seconds(time.now())
	} else {
		aux_checktype(L, 1, kernel.TTABLE)
		kernel.api_settop(L, 1)
		year := i64(getfield(L, "year", -1, 1900) + 1900)
		month := getfield(L, "month", -1, 1) + 1
		day := getfield(L, "day", -1, 0)
		hour := getfield(L, "hour", 12, 0)
		minute := getfield(L, "min", 0, 0)
		second := getfield(L, "sec", 0, 0)
		wanted_dst := getboolfield(L, "isdst")
		wall, nominal := normalize_civil(year, month, day, hour, minute, second)
		normalized: Civil_Time
		ok: bool
		t, normalized, ok = timestamp_from_local(wall, nominal, wanted_dst)
		if !ok {
			aux_error(L, "time result cannot be represented in this installation")
		}
		setallfields(L, normalized)
	}
	when ODIN_OS == .Windows {
		if t < 0 {
			aux_error(L, "time result cannot be represented in this installation")
		}
	}
	kernel.api_pushinteger(L, kernel.Integer(t))
	return 1
}

@(private = "file")
os_difftime :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	kernel.api_pushnumber(L, kernel.Number(l_checktime(L, 1) - l_checktime(L, 2)))
	return 1
}

@(private = "file")
os_clock :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	when ODIN_OS == .Windows {
		creation, exiting, ktime, utime: win32.FILETIME
		if win32.GetProcessTimes(win32.GetCurrentProcess(), &creation, &exiting, &ktime, &utime) {
			k := transmute(u64le)ktime
			u := transmute(u64le)utime
			kernel.api_pushnumber(L, kernel.Number(f64(k + u) / 10_000_000.0))
			return 1
		}
	}
	// tick_now is elapsed rather than CPU time, but is a sane standard-library
	// fallback on targets whose OS bindings expose no process accounting.
	kernel.api_pushnumber(L, kernel.Number(f64(time.tick_now()._nsec) / 1e9))
	return 1
}

@(private = "file")
os_getenv :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	name := aux_checkstring(L, 1)
	value, found := os.lookup_env(name, context.temp_allocator)
	if found do kernel.api_pushstring(L, value)
	else do kernel.api_pushnil(L)
	return 1
}

@(private = "file")
os_remove :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	filename := aux_checkstring(L, 1)
	err := os.remove(filename)
	return aux_fileresult(L, err == nil, filename, true, err)
}

@(private = "file")
os_rename :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	err := os.rename(aux_checkstring(L, 1), aux_checkstring(L, 2))
	return aux_fileresult(L, err == nil, "", false, err)
}

@(private = "file")
os_tmpname :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	f, err := os.create_temp_file("", kernel.BRAND_LOWER + "-*")
	if err != nil {
		aux_error(L, "unable to generate a unique filename")
	}
	name := os.name(f)
	kernel.api_pushstring(L, name)
	os.close(f)
	when ODIN_OS == .Windows {
		// core:os obtains a collision-free name by creating it. Windows Lua's
		// tmpnam only returns the name, so remove the probe file before returning.
		_ = os.remove(name)
	}
	return 1
}

@(private = "file")
os_execute :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if kernel.api_isnoneornil(L, 1) {
		when ODIN_OS == .Windows {
			kernel.api_pushboolean(L, true) // cmd.exe is part of supported Windows.
		} else {
			f, err := os.open("/bin/sh")
			kernel.api_pushboolean(L, err == nil)
			if f != nil do os.close(f)
		}
		return 1
	}
	cmd := aux_checkstring(L, 1)
	args := []string{"cmd.exe", "/c", cmd} if ODIN_OS == .Windows else []string{"/bin/sh", "-c", cmd}
	desc := os.Process_Desc {
		command = args,
		stdin = os.stdin,
		stdout = os.stdout,
		stderr = os.stderr,
	}
	p, err := shellproc.start_process(desc)
	if err != nil {
		return aux_execresult(L, -1, err)
	}
	result := shellproc.wait_process(p)
	if result.err != nil {
		return aux_execresult(L, -1, result.err)
	}
	return aux_execresult(L, result.code, nil, result.signaled)
}

@(private = "file")
locale_names := []string{"all", "collate", "ctype", "monetary", "numeric", "time"}

@(private = "file")
os_setlocale :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	_ = aux_checkoption(L, 2, "all", locale_names)
	if kernel.api_isnoneornil(L, 1) {
		kernel.api_pushstring(L, "C")
		return 1
	}
	requested := aux_checkstring(L, 1)
	if requested == "" || requested == "C" || requested == "POSIX" {
		kernel.api_pushstring(L, "C")
	} else {
		kernel.api_pushnil(L)
	}
	return 1
}

@(private = "file")
os_exit :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	status := 0
	if kernel.api_isboolean(L, 1) {
		status = kernel.api_toboolean(L, 1) ? 0 : 1
	} else {
		status = int(aux_optinteger(L, 1, 0))
	}
	if kernel.api_toboolean(L, 2) {
		kernel.close_state(L)
	}
	host.process_exit(status)
}

@(private = "file")
syslib := []Reg {
	{"clock", os_clock},
	{"date", os_date},
	{"difftime", os_difftime},
	{"execute", os_execute},
	{"exit", os_exit},
	{"getenv", os_getenv},
	{"remove", os_remove},
	{"rename", os_rename},
	{"setlocale", os_setlocale},
	{"time", os_time},
	{"tmpname", os_tmpname},
}

open_os :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	aux_newlib(L, syslib)
	return 1
}
