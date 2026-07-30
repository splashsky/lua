package stdlib

// mathlib.odin -- our analogue of reference Lua's `lmathlib.c`.
//
// The math library: the usual floating-point functions (sin/cos/exp/log/sqrt/
// ...), the integer/float-aware helpers (floor/ceil/abs/fmod/modf/tointeger/
// type), min/max, the mathematical constants, and the pseudo-random generator
// (math.random / math.randomseed).
//
// A note on faithfulness: operations with pure-Odin or hardware-backed
// `core:math` implementations use those directly. sin/cos/exp remain on libc
// because Odin currently lowers those particular intrinsics to libm calls; they
// are handled by the dedicated libc-removal math task.
//
// The PRNG is a straight port of reference 5.5's `xoshiro256**`, using the
// 64-bit-integer branch (our `lua.Integer` is 64-bit). The generator state lives
// in a full userdata that is shared -- as upvalue #1 -- by both `math.random`
// and `math.randomseed`, exactly as reference does.

import "base:runtime"
import "core:c/libc"
import "core:math"
import lua "luao:lua"

// Narrow alias so the ported bodies read like their C originals.
@(private = "file")
state :: #force_inline proc "contextless" (Lp: rawptr) -> ^lua.Lua_State {
	return (^lua.Lua_State)(Lp)
}

// PI to reference precision (extra digits are harmless; the compiler rounds to
// the nearest f64, which is the same value reference's literal produces).
@(private = "file")
PI :: 3.141592653589793238462643383279502884

// --------------------------------------------------------------------------------
// Basic floating-point functions (thin wrappers over libc)
// --------------------------------------------------------------------------------

// `math.abs` -- integer stays integer (with two's-complement-safe negation so
// abs(mininteger) wraps exactly as reference does); floats go through `fabs`.
math_abs :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isinteger(L, 1) {
		n := lua.lua_tointeger(L, 1)
		if n < 0 {
			n = lua.Integer(0 - lua.Unsigned(n)) // avoid UB on mininteger
		}
		lua.lua_pushinteger(L, n)
	} else {
		lua.lua_pushnumber(L, lua.Number(math.abs(f64(luaL_checknumber(L, 1)))))
	}
	return 1
}

math_sin :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(libc.sin(f64(luaL_checknumber(L, 1)))))
	return 1
}

math_cos :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(libc.cos(f64(luaL_checknumber(L, 1)))))
	return 1
}

math_tan :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(math.tan(f64(luaL_checknumber(L, 1)))))
	return 1
}

math_asin :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(math.asin(f64(luaL_checknumber(L, 1)))))
	return 1
}

math_acos :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(math.acos(f64(luaL_checknumber(L, 1)))))
	return 1
}

// `math.atan(y [, x])` -- two-argument form is `atan2(y, x)`; x defaults to 1,
// which makes the one-argument call the ordinary arctangent.
math_atan :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	y := luaL_checknumber(L, 1)
	x := luaL_optnumber(L, 2, 1)
	lua.lua_pushnumber(L, lua.Number(math.atan2(f64(y), f64(x))))
	return 1
}

math_exp :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(libc.exp(f64(luaL_checknumber(L, 1)))))
	return 1
}

math_sqrt :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, lua.Number(math.sqrt(f64(luaL_checknumber(L, 1)))))
	return 1
}

// `math.log(x [, base])` -- special-cases base 2 and base 10 to their dedicated
// libc entry points (more accurate than a division), else `log(x)/log(base)`.
math_log :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	x := f64(luaL_checknumber(L, 1))
	res: f64
	if lua.lua_isnoneornil(L, 2) {
		res = math.ln(x)
	} else {
		base := f64(luaL_checknumber(L, 2))
		if base == 2.0 {
			res = math.log2(x)
		} else if base == 10.0 {
			res = math.log10(x)
		} else {
			res = math.ln(x) / math.ln(base)
		}
	}
	lua.lua_pushnumber(L, lua.Number(res))
	return 1
}

// `math.deg` / `math.rad` -- degree/radian conversion by the exact constant
// factor reference uses (grouped identically so rounding matches).
math_deg :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, luaL_checknumber(L, 1) * (180.0 / PI))
	return 1
}

math_rad :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	lua.lua_pushnumber(L, luaL_checknumber(L, 1) * (PI / 180.0))
	return 1
}

// `math.frexp(x)` -> (mantissa, exponent).
math_frexp :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	x := f64(luaL_checknumber(L, 1))
	m, ep := math.frexp(x)
	lua.lua_pushnumber(L, lua.Number(m))
	lua.lua_pushinteger(L, lua.Integer(ep))
	return 2
}

// `math.ldexp(x, e)` -- reference narrows the exponent to a C `int`, so we cast
// to i32 to reproduce its overflow behavior for extreme exponents.
math_ldexp :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	x := f64(luaL_checknumber(L, 1))
	ep := int(i32(luaL_checkinteger(L, 2)))
	lua.lua_pushnumber(L, lua.Number(math.ldexp(x, ep)))
	return 1
}

// --------------------------------------------------------------------------------
// Integer/float-aware helpers
// --------------------------------------------------------------------------------

// Push `d` as an integer if it fits exactly in `lua.Integer`, else as a float --
// reference `pushnumint`.
@(private = "file")
pushnumint :: proc(L: ^lua.Lua_State, d: lua.Number) {
	if n, ok := lua.number_to_integer_range(d); ok {
		lua.lua_pushinteger(L, n)
	} else {
		lua.lua_pushnumber(L, d)
	}
}

// `math.tointeger(x)` -- convert to integer if possible, else fail (nil).
math_toint :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n, valid := lua.lua_tointegerx(L, 1)
	if valid {
		lua.lua_pushinteger(L, n)
	} else {
		luaL_checkany(L, 1)
		luaL_pushfail(L)
	}
	return 1
}

// `math.floor(x)` -- an integer is its own floor; otherwise floor then narrow.
math_floor :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isinteger(L, 1) {
		lua.lua_settop(L, 1)
	} else {
		d := math.floor(f64(luaL_checknumber(L, 1)))
		pushnumint(L, lua.Number(d))
	}
	return 1
}

// `math.ceil(x)` -- symmetric to floor.
math_ceil :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isinteger(L, 1) {
		lua.lua_settop(L, 1)
	} else {
		d := math.ceil(f64(luaL_checknumber(L, 1)))
		pushnumint(L, lua.Number(d))
	}
	return 1
}

// `math.fmod(a, b)` -- integer operands use `%` with the reference's guard
// against the `mininteger % -1` overflow and the `% 0` error; else libc `fmod`.
math_fmod :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isinteger(L, 1) && lua.lua_isinteger(L, 2) {
		d := lua.lua_tointeger(L, 2)
		if lua.Unsigned(d) + 1 <= 1 { // d is -1 or 0
			luaL_argcheck(L, d != 0, 2, "zero")
			lua.lua_pushinteger(L, 0) // avoid overflow of mininteger / -1
		} else {
			lua.lua_pushinteger(L, lua.lua_tointeger(L, 1) % d)
		}
	} else {
		a := f64(luaL_checknumber(L, 1))
		b := f64(luaL_checknumber(L, 2))
		lua.lua_pushnumber(L, lua.Number(lua.num_fmod(a, b)))
	}
	return 1
}

// `math.modf(x)` -> (integer-part, fractional-part). Integer part rounds toward
// zero; the explicit `n == ip` test keeps the fractional part 0.0 for +/-inf.
math_modf :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_isinteger(L, 1) {
		lua.lua_settop(L, 1) // number is its own integer part
		lua.lua_pushnumber(L, 0) // no fractional part
	} else {
		n := f64(luaL_checknumber(L, 1))
		ip := n < 0 ? math.ceil(n) : math.floor(n)
		pushnumint(L, lua.Number(ip))
		lua.lua_pushnumber(L, lua.Number(n == ip ? 0.0 : n - ip))
	}
	return 2
}

// `math.ult(a, b)` -- unsigned less-than over the integer bit patterns.
math_ult :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	a := luaL_checkinteger(L, 1)
	b := luaL_checkinteger(L, 2)
	lua.lua_pushboolean(L, lua.Unsigned(a) < lua.Unsigned(b))
	return 1
}

// `math.min` / `math.max` -- compare with the language's own `<` (so metamethods
// and mixed int/float rules apply), returning the winning *original* value.
math_min :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	luaL_argcheck(L, n >= 1, 1, "value expected")
	imin := 1
	for i := 2; i <= n; i += 1 {
		if lua.lua_compare(L, i, imin, lua.LUA_OPLT) {
			imin = i
		}
	}
	lua.lua_pushvalue(L, imin)
	return 1
}

math_max :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	n := lua.lua_gettop(L)
	luaL_argcheck(L, n >= 1, 1, "value expected")
	imax := 1
	for i := 2; i <= n; i += 1 {
		if lua.lua_compare(L, imax, i, lua.LUA_OPLT) {
			imax = i
		}
	}
	lua.lua_pushvalue(L, imax)
	return 1
}

// `math.type(x)` -- "integer"/"float" for numbers, fail for anything else.
math_type :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	if lua.lua_type(L, 1) == lua.LUA_TNUMBER {
		lua.lua_pushstring(L, lua.lua_isinteger(L, 1) ? "integer" : "float")
	} else {
		luaL_checkany(L, 1)
		luaL_pushfail(L)
	}
	return 1
}

// --------------------------------------------------------------------------------
// Pseudo-random number generator: xoshiro256** (64-bit-integer branch)
// --------------------------------------------------------------------------------

// The number of mantissa bits in an f64. Reference derives this from
// `l_floatatt(MANT_DIG)`; for IEEE-754 binary64 it is 53.
@(private = "file")
FIGS :: 53

// Four 64-bit words of generator state -- reference `RanState`.
@(private = "file")
Rand_State :: struct {
	s: [4]u64,
}

// Rotate-left by `n` bits. Reference only ever calls this with n=7 and n=45, so
// `64 - n` is always in a valid, non-zero shift range.
@(private = "file")
rotl :: #force_inline proc "contextless" (x: u64, n: uint) -> u64 {
	return (x << n) | (x >> (64 - n))
}

// One step of xoshiro256** -- reference `nextrand`. All arithmetic is u64, which
// wraps modulo 2^64 in Odin exactly like C's unsigned arithmetic.
@(private = "file")
nextrand :: proc "contextless" (st: ^[4]u64) -> u64 {
	state0 := st[0]
	state1 := st[1]
	state2 := st[2] ~ state0
	state3 := st[3] ~ state1
	res := rotl(state1 * 5, 7) * 9
	st[0] = state0 ~ state3
	st[1] = state1 ~ state2
	st[2] = state2 ~ (state1 << 17)
	st[3] = rotl(state3, 45)
	return res
}

// Convert a random 64-bit value to a float in [0, 1) -- reference `I2d`. We take
// the top FIGS bits; after the shift the value fits in 53 bits so it is always a
// non-negative i64, which lets us drop reference's two's-complement correction.
@(private = "file")
I2d :: #force_inline proc "contextless" (x: u64) -> lua.Number {
	shift64_FIG :: 64 - FIGS
	scaleFIG :: 0.5 / lua.Number(u64(1) << (FIGS - 1))
	sx := i64(x >> shift64_FIG)
	return lua.Number(sx) * scaleFIG
}

// Project a random value uniformly into [0, n] -- reference `project`. It builds
// the smallest Mersenne mask >= n, masks the value into [0, lim], and rejects
// (redrawing) until the result lands in [0, n].
@(private = "file")
project :: proc "contextless" (ran0: u64, n: u64, st: ^Rand_State) -> u64 {
	lim := n
	for sh: uint = 1; (lim & (lim + 1)) != 0; sh *= 2 {
		lim |= (lim >> sh) // spread 1-bits to the right
	}
	ran := ran0 & lim
	for ran > n {
		ran = nextrand(&st.s) & lim
	}
	return ran
}

// `math.random([m [, n]])` -- reference `math_random`.
math_random :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st := (^Rand_State)(lua.lua_touserdata(L, lua.lua_upvalueindex(1)))
	rv := nextrand(&st.s)
	low, up: lua.Integer
	switch lua.lua_gettop(L) {
	case 0:
		lua.lua_pushnumber(L, I2d(rv)) // float in [0, 1)
		return 1
	case 1:
		low = 1
		up = luaL_checkinteger(L, 1)
		if up == 0 { // random(0): a full-width random integer
			lua.lua_pushinteger(L, lua.Integer(rv))
			return 1
		}
	case 2:
		low = luaL_checkinteger(L, 1)
		up = luaL_checkinteger(L, 2)
	case:
		luaL_error(L, "wrong number of arguments")
	}
	luaL_argcheck(L, low <= up, 1, "interval is empty")
	p := project(rv, lua.Unsigned(up) - lua.Unsigned(low), st)
	lua.lua_pushinteger(L, lua.Integer(p + lua.Unsigned(low)))
	return 1
}

// Seed the generator and leave the two seed halves on the stack -- reference
// `setseed`. state[1] is forced non-zero to avoid the all-zero fixed point, and
// 16 discard steps spread the seed through all four words.
@(private = "file")
setseed :: proc(L: ^lua.Lua_State, st: ^[4]u64, n1: u64, n2: u64) {
	st[0] = n1
	st[1] = 0xff // avoid a zero state
	st[2] = n2
	st[3] = 0
	for i in 0 ..< 16 {
		nextrand(st)
	}
	lua.lua_pushinteger(L, lua.Integer(n1))
	lua.lua_pushinteger(L, lua.Integer(n2))
}

// `math.randomseed([n [, n2]])` -- reference `math_randomseed`. No argument means
// a "random" seed from `luaL_makeseed` (mixed with one draw for extra spread).
math_randomseed :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	st := (^Rand_State)(lua.lua_touserdata(L, lua.lua_upvalueindex(1)))
	n1, n2: u64
	if lua.lua_isnone(L, 1) {
		n1 = u64(luaL_makeseed(L))
		n2 = nextrand(&st.s)
	} else {
		n1 = lua.Unsigned(luaL_checkinteger(L, 1))
		n2 = lua.Unsigned(luaL_optinteger(L, 2, 0))
	}
	setseed(L, &st.s, n1, n2)
	return 2 // return the two seed halves
}

@(private = "file")
randfuncs := []Reg{{"random", math_random}, {"randomseed", math_randomseed}}

// Register `random`/`randomseed` and their shared generator-state userdata --
// reference `setrandfunc`. The userdata is created first, seeded, then handed to
// both functions as upvalue #1 via `luaL_setfuncs(..., 1)`.
@(private = "file")
setrandfunc :: proc(L: ^lua.Lua_State) {
	st := (^Rand_State)(lua.lua_newuserdatauv(L, size_of(Rand_State), 0))
	setseed(L, &st.s, u64(luaL_makeseed(L)), 0)
	lua.lua_pop(L, 2) // drop the two pushed seed halves
	luaL_setfuncs(L, randfuncs, 1)
}

// --------------------------------------------------------------------------------
// Library table and opener
// --------------------------------------------------------------------------------

// The static half of the math table. `random`/`randomseed` are added separately
// by `setrandfunc` (they need a shared upvalue), and the constants are set as
// fields in the opener. We deliberately omit the LUA_COMPAT_MATHLIB aliases
// (atan2/cosh/sinh/tanh/pow/log10) -- 5.5 builds without them by default.
@(private = "file")
mathlib := []Reg {
	{"abs", math_abs},
	{"acos", math_acos},
	{"asin", math_asin},
	{"atan", math_atan},
	{"ceil", math_ceil},
	{"cos", math_cos},
	{"deg", math_deg},
	{"exp", math_exp},
	{"tointeger", math_toint},
	{"floor", math_floor},
	{"fmod", math_fmod},
	{"frexp", math_frexp},
	{"ult", math_ult},
	{"ldexp", math_ldexp},
	{"log", math_log},
	{"max", math_max},
	{"min", math_min},
	{"modf", math_modf},
	{"rad", math_rad},
	{"sin", math_sin},
	{"sqrt", math_sqrt},
	{"tan", math_tan},
	{"type", math_type},
}

// `luaopen_math` -- build the table, set the constants, wire the RNG.
luaopen_math :: proc "c" (Lp: rawptr) -> i32 {
	context = runtime.default_context()
	L := state(Lp)
	luaL_newlib(L, mathlib)
	lua.lua_pushnumber(L, PI)
	lua.lua_setfield(L, -2, "pi")
	lua.lua_pushnumber(L, math.inf_f64(1))
	lua.lua_setfield(L, -2, "huge")
	lua.lua_pushinteger(L, lua.MAX_INTEGER)
	lua.lua_setfield(L, -2, "maxinteger")
	lua.lua_pushinteger(L, lua.MIN_INTEGER)
	lua.lua_setfield(L, -2, "mininteger")
	setrandfunc(L)
	return 1
}
