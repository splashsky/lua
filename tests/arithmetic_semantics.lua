-- This is a black-box arithmetic conformance test. It deliberately checks Lua's
-- observable rules rather than any detail of the Odin implementation, so the
-- same file can run unchanged against PUC Lua as a differential oracle.

local function check(condition, label)
	if not condition then
		error("arithmetic conformance failed: " .. label, 2)
	end
end

local function error_ends_with(fn, suffix, label)
	local ok, message = pcall(fn)
	check(not ok, label .. " did not fail")
	check(type(message) == "string" and message:sub(-#suffix) == suffix,
		label .. " produced the wrong error: " .. tostring(message))
end

local max, min = math.maxinteger, math.mininteger
check(max + 1 == min, "maximum integer addition wraps")
check(min - 1 == max, "minimum integer subtraction wraps")
check(min * -1 == min, "integer multiplication wraps")
check(-min == min, "integer unary minus wraps")

error_ends_with(function() return 7 // 0 end,
	"attempt to divide by zero", "integer floor division by zero")
error_ends_with(function() return 7 % 0 end,
	"attempt to perform 'n%0'", "integer modulo by zero")

local floor_cases = {
	{7, 3, 2, 1},
	{-7, 3, -3, 2},
	{7, -3, -3, -2},
	{-7, -3, 2, -1},
}
for _, case in ipairs(floor_cases) do
	local a, b, quotient, remainder = table.unpack(case)
	check(a // b == quotient, ("mixed-sign floor division: %d // %d"):format(a, b))
	check(a % b == remainder, ("mixed-sign modulo: %d %% %d"):format(a, b))
end
check(min // -1 == min, "minimum integer floor division wraps")
check(min % -1 == 0, "minimum integer modulo avoids overflow")

check(-5.5 % 2.0 == 0.5, "negative float modulo")
check(5.5 % -2.0 == -0.5, "float modulo follows divisor sign")

-- An infinite divisor is not an fmod domain error: a finite dividend is already
-- a remainder. Lua's subsequent sign correction can still add that infinity,
-- which is why the two mixed-sign cases below deliberately become infinities.
check(0.0 % math.huge == 0.0, "zero modulo positive infinity")
check(1.0 % math.huge == 1.0, "positive finite modulo positive infinity")
check(-1.0 % math.huge == math.huge,
	"negative finite modulo positive infinity applies Lua sign correction")
check(1.0 % -math.huge == -math.huge,
	"positive finite modulo negative infinity applies Lua sign correction")
check(-1.0 % -math.huge == -1.0, "negative finite modulo negative infinity")
check(1.0 / (-0.0 % math.huge) == -math.huge,
	"modulo by infinity preserves a negative-zero dividend")
check((math.huge % 2.0) ~= (math.huge % 2.0),
	"infinite dividend modulo finite divisor is NaN")
check((1.0 % 0.0) ~= (1.0 % 0.0), "float modulo by zero is NaN")

-- These values exercise both ends of binary64 without relying on a gradual
-- subtraction implementation: the smallest subnormal must survive intact, and
-- a huge exact power of two has a simple mathematically exact remainder.
local min_subnormal = 0x0.0000000000001p-1022
check(min_subnormal % (2.0 * min_subnormal) == min_subnormal,
	"subnormal float modulo")
check(0x1p-1022 % (3.0 * min_subnormal) == min_subnormal,
	"normal dividend modulo subnormal divisor")
check(0x1p500 % 3.0 == 1.0, "very large finite float modulo")

check((12.0 & 10.0) == 8, "bitwise and accepts integral floats")
check((12.0 | 3.0) == 15, "bitwise or accepts integral floats")
check((12.0 ~ 10.0) == 6, "bitwise xor accepts integral floats")
check((1.0 << 5.0) == 32, "shift accepts integral floats")
check((32.0 >> 4.0) == 2, "right shift accepts integral floats")
check(~5.0 == -6, "bitwise not accepts an integral float")
error_ends_with(function() return 4.5 & 1 end,
	"number has no integer representation", "bitwise and rejects fractions")
error_ends_with(function() return 1 << 2.5 end,
	"number has no integer representation", "shift rejects fractions")

-- Keep these as upvalues rather than literals in the operator expression. The
-- observable contract under test is not merely that an error occurs, but that
-- Lua identifies whichever source operand actually failed integer conversion.
local bit_a, bit_b = -0.5, 0
error_ends_with(function() return bit_a & bit_b end,
	"number (upvalue 'bit_a') has no integer representation",
	"bitwise error names a bad first operand")
bit_a, bit_b = 0, -0.5
error_ends_with(function() return bit_a & bit_b end,
	"number (upvalue 'bit_b') has no integer representation",
	"bitwise error names a bad second operand")

-- Arithmetic type errors share the lower-level operand-selection helper. Check
-- both shapes so a repair to bitwise diagnostics cannot accidentally reverse
-- the already-correct arithmetic attribution.
local arith_a, arith_b = {}, 1
error_ends_with(function() return arith_a + arith_b end,
	"attempt to perform arithmetic on a table value (upvalue 'arith_a')",
	"arithmetic error names a bad first operand")
arith_a, arith_b = 1, {}
error_ends_with(function() return arith_a + arith_b end,
	"attempt to perform arithmetic on a table value (upvalue 'arith_b')",
	"arithmetic error names a bad second operand")
arith_a, arith_b = "abc", 1
error_ends_with(function() return arith_a + arith_b end,
	"attempt to add a 'string' with a 'number'",
	"string arithmetic reports a bad first operand")
arith_a, arith_b = 1, "abc"
error_ends_with(function() return arith_a + arith_b end,
	"attempt to add a 'number' with a 'string'",
	"string arithmetic reports a bad second operand")

local negative_zero = -0.0
check(negative_zero == 0.0 and 1.0 / negative_zero == -math.huge,
	"negative zero retains its sign")
check(1.0 / (-negative_zero) == math.huge, "unary minus flips negative zero")

local nan = 0.0 / 0.0
check(nan ~= nan, "division produces NaN")
check((nan + 1.0) ~= (nan + 1.0), "addition propagates NaN")
check(math.huge + 1.0 == math.huge, "addition propagates positive infinity")
check(-math.huge * 2.0 == -math.huge, "multiplication propagates negative infinity")
check(1.0 / math.huge == 0.0, "division by infinity reaches zero")

local calls = {}
local mt = {
	__add = function(a, b)
		calls[#calls + 1] = "add"
		return a.tag .. "+" .. b.tag
	end,
	__unm = function(a)
		calls[#calls + 1] = "unm"
		return "neg:" .. a.tag
	end,
	__bnot = function(a)
		calls[#calls + 1] = "bnot"
		return "not:" .. a.tag
	end,
}
local left = setmetatable({tag = "left"}, mt)
local right = setmetatable({tag = "right"}, mt)
check(left + right == "left+right", "binary arithmetic metamethod dispatch")
check(-left == "neg:left", "unary minus metamethod dispatch")
check(~left == "not:left", "bitwise-not metamethod dispatch")
check(table.concat(calls, ",") == "add,unm,bnot", "metamethods run exactly once")

print("arithmetic semantics: ok")
