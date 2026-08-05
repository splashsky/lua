package main

import "core:fmt"
import "core:os"
import kernel "lang:kernel"

State :: struct {
	random_roundtrips: u64,
	digit_exponent_cross: u64,
	neighbour_boundaries: u64,
	subnormals_extremes: u64,
}

next_random :: proc(state: ^u64) -> u64 {
	x := state^
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	state^ = x
	return x
}

append_u64 :: proc(buf: []byte, at: int, value: u64, width: int = 0) -> int {
	tmp: [32]byte
	p := len(tmp)
	v := value
	for {
		p -= 1
		tmp[p] = byte(v % 10) + '0'
		v /= 10
		if v == 0 {break}
	}
	for len(tmp) - p < width {
		p -= 1
		tmp[p] = '0'
	}
	return at + copy(buf[at:], tmp[p:])
}

append_exp :: proc(buf: []byte, at: int, exponent: int) -> int {
	p := at
	e := exponent
	buf[p] = 'e'
	p += 1
	if e < 0 {
		buf[p] = '-'
		p += 1
		e = -e
	} else {
		buf[p] = '+'
		p += 1
	}
	return append_u64(buf, p, u64(e))
}

verify_case :: proc(text: []byte, category: string, index: u64) {
	fast, fast_end := kernel.parse_decimal_slice_for_verification(text)
	oracle, oracle_end := kernel.parse_decimal_slice_forced_slow(text)
	fast_bits, oracle_bits := transmute(u64)fast, transmute(u64)oracle
	if fast_end != oracle_end || fast_bits != oracle_bits {
		fmt.eprintf(
			"mismatch %s[%d] %q: fast=%016x/%d slow=%016x/%d\n",
			category,
			index,
			string(text),
			fast_bits,
			fast_end,
			oracle_bits,
			oracle_end,
		)
		os.exit(1)
	}
}

finite :: proc(bits: u64) -> bool {
	return bits & 0x7ff0_0000_0000_0000 != 0x7ff0_0000_0000_0000
}

main :: proc() {
	counts: State
	random: u64 = 0x6a09e667f3bcc909
	buf: [128]byte

	// One million arbitrary finite binary64 patterns, rendered exactly as the
	// benchmark and real Lua traffic render them: C %.17g decimal spellings.
	for counts.random_roundtrips < 1_000_000 {
		bits := next_random(&random)
		if !finite(bits) {continue}
		value := transmute(f64)bits
		n := kernel.format_float_decimal(buf[:], value, 'g', 17)
		verify_case(buf[:n], "random-roundtrip", counts.random_roundtrips)
		counts.random_roundtrips += 1
	}

	// Every length from 1 through 25, every cached decimal exponent, and 64
	// independent significands at each point. This is 25*696*64 cases and
	// deliberately exercises both exact and truncated 19-digit normalization.
	for length in 1 ..= 25 {
		for exponent in -348 ..= 347 {
			for sample in 0 ..< 64 {
				p := 0
				first := byte(next_random(&random) % 9) + '1'
				buf[p] = first
				p += 1
				for _ in 1 ..< length {
					buf[p] = byte(next_random(&random) % 10) + '0'
					p += 1
				}
				p = append_exp(buf[:], p, exponent)
				verify_case(buf[:p], "digit-exponent", counts.digit_exponent_cross)
				counts.digit_exponent_cross += 1
			}
		}
	}

	// Values deliberately aimed at rounding boundaries: choose a random finite
	// double, then render that bit pattern and both adjacent bit patterns at 17
	// digits. The parser must recover each neighbour, including ties near powers
	// of two where the ULP changes on one side.
	bases := 0
	for bases < 350_000 {
		bits := next_random(&random)
		if !finite(bits) {continue}
		bases += 1
		for delta in -1 ..= 1 {
			candidate := delta < 0 ? bits - 1 :
				(delta > 0 ? bits + 1 : bits)
			if !finite(candidate) {continue}
			value := transmute(f64)candidate
			n := kernel.format_float_decimal(buf[:], value, 'g', 17)
			verify_case(buf[:n], "neighbour", counts.neighbour_boundaries)
			counts.neighbour_boundaries += 1
		}
	}

	// Dense samples at both ends of the subnormal interval, random subnormals,
	// signed zero, the smallest normal, max finite, and explicit overflow and
	// underflow spellings cover the regions Eisel-Lemire intentionally declines.
	for bits: u64 = 0; bits <= 50_000; bits += 1 {
		signed_variants := [2]u64 {bits, bits | (u64(1) << 63)}
		for signed_bits in signed_variants {
			value := transmute(f64)signed_bits
			n := kernel.format_float_decimal(buf[:], value, 'g', 17)
			verify_case(buf[:n], "subnormal-extreme", counts.subnormals_extremes)
			counts.subnormals_extremes += 1
		}
	}
	for _ in 0 ..< 100_000 {
		bits := next_random(&random) & 0x000f_ffff_ffff_ffff
		value := transmute(f64)bits
		n := kernel.format_float_decimal(buf[:], value, 'g', 17)
		verify_case(buf[:n], "subnormal-extreme", counts.subnormals_extremes)
		counts.subnormals_extremes += 1
	}
	extreme_bits := []u64 {
		0x0010_0000_0000_0000,
		0x8010_0000_0000_0000,
		0x7fef_ffff_ffff_ffff,
		0xffef_ffff_ffff_ffff,
	}
	for bits in extreme_bits {
		value := transmute(f64)bits
		n := kernel.format_float_decimal(buf[:], value, 'g', 17)
		verify_case(buf[:n], "subnormal-extreme", counts.subnormals_extremes)
		counts.subnormals_extremes += 1
	}
	extreme_text := [6]string {
		"1e309",
		"-1e309",
		"1e-400",
		"-1e-400",
		"5e-324",
		"2.2250738585072014e-308",
	}
	for text in extreme_text {
		verify_case(transmute([]byte)text, "subnormal-extreme", counts.subnormals_extremes)
		counts.subnormals_extremes += 1
	}

	total := counts.random_roundtrips + counts.digit_exponent_cross +
		counts.neighbour_boundaries + counts.subnormals_extremes
	fmt.printf(
		"PASS total=%d random-roundtrip=%d digit-exponent=%d neighbour=%d subnormal-extreme=%d\n",
		total,
		counts.random_roundtrips,
		counts.digit_exponent_cross,
		counts.neighbour_boundaries,
		counts.subnormals_extremes,
	)
}
