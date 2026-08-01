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
