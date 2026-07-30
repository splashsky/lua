-- Systematic string.format differential corpus. This file intentionally prints
-- every case, including errors: dropping an inconvenient result would make the
-- comparison much less useful than the PUC interpreter used as its oracle.

local flagchars = {"-", "+", " ", "#", "0"}
local flags = {}
for mask = 0, 31 do
	local s = ""
	for bit = 0, 4 do
		if mask & (1 << bit) ~= 0 then s = s .. flagchars[bit + 1] end
	end
	flags[#flags + 1] = s
end

local widths = {"", "0", "1", "5", "20"}
local precisions = {"", ".0", ".1", ".6", ".17"}

local intvalues = {
	0, 1, -1, 7, 8, 255, -255, math.maxinteger, math.mininteger,
}
local floatvalues = {
	0.0, -0.0, 1.0, -1.0, 1.5, 2.5, 1.25, 1e-9, 1e20,
	5e-324, 2.2250738585072014e-308, math.maxinteger + 0.0,
	math.huge, -math.huge, 0/0, -(0/0),
}
local charvalues = {0, 1, 65, 127, 255, -1}
local stringvalues = {"", "a", "hello", "abcdefghijklmnopqrstuv", "a b"}
local pointervalues = {nil}

local groups = {
	{"d", intvalues}, {"i", intvalues}, {"u", intvalues},
	{"o", intvalues}, {"x", intvalues}, {"X", intvalues},
	{"f", floatvalues}, {"F", floatvalues}, {"e", floatvalues},
	{"E", floatvalues}, {"g", floatvalues}, {"G", floatvalues},
	{"a", floatvalues}, {"A", floatvalues},
	{"c", charvalues}, {"s", stringvalues}, {"p", pointervalues},
}

local function hex(s)
	return (s:gsub(".", function(c) return string.format("%02X", string.byte(c)) end))
end

local count = 0
for _, group in ipairs(groups) do
	local conversion, values = group[1], group[2]
	for _, flag in ipairs(flags) do
		for _, width in ipairs(widths) do
			for _, precision in ipairs(precisions) do
				local fmt = "%" .. flag .. width .. precision .. conversion
				for valueindex, value in ipairs(values) do
					count = count + 1
					local ok, result = pcall(string.format, fmt, value)
					if ok then
						result = "OK:" .. hex(result)
					else
						result = "ERR:" .. tostring(result):gsub("^.-:%d+: ", "")
					end
					print(count, hex(fmt), valueindex, result)
				end
			end
		end
	end
end

-- Keep a small, explicit hexadecimal-float gate outside the broad Cartesian
-- corpus. The earlier comparison accidentally treated the entire a/A conversion
-- group as unsupported because modified a/A forms error in the reference; that
-- also hid mismatches in the supported bare forms. Listing both bare forms and
-- representative rejected modifiers here makes that filtering mistake obvious.
local hexformats = {
	"%a", "%A", "%5.2a", "%-10a", "%#a", "%5.2A", "%-10A", "%#A",
}
local hexvalues = {
	1.5, 1.0, 0.0, -0.0, 2^-1074, 2^1023, 0.1,
	math.huge, -math.huge, 0/0, -(0/0),
}
for _, fmt in ipairs(hexformats) do
	for valueindex, value in ipairs(hexvalues) do
		count = count + 1
		local ok, result = pcall(string.format, fmt, value)
		if ok then
			result = "OK:" .. hex(result)
		else
			result = "ERR:" .. tostring(result):gsub("^.-:%d+: ", "")
		end
		print(count, hex(fmt), valueindex, result)
	end
end
io.stderr:write("CASES=", count, "\n")
