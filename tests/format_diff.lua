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
-- corpus. The earlier Windows comparison accidentally treated the entire a/A
-- conversion group as unsupported because its C89 fallback rejects modifiers;
-- Linux accepts them. Listing both bare and modified forms makes either outcome
-- visible and prevents filtering out the supported bare forms.
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
-- Additional independent sweeps cover every allowed width and precision without
-- requiring the enormous Cartesian product of both dimensions. Flags include
-- invalid combinations: the error text is just as important as successful bytes.
local function emit(fmt, valueindex, value)
	count = count + 1
	local ok, result = pcall(string.format, fmt, value)
	if ok then
		result = "OK:" .. hex(result)
	else
		result = "ERR:" .. tostring(result):gsub("^.-:%d+: ", "")
	end
	print(count, hex(fmt), valueindex, result)
end

local frombits = function(bits)
	return (string.unpack("<d", string.pack("<I8", bits)))
end
local special = {
	frombits(0x0000000000000000), frombits(0x8000000000000000),
	frombits(0x7ff0000000000000), frombits(0xfff0000000000000),
	frombits(0x7ff8000000000000), frombits(0xfff8000000000000),
	frombits(0x0000000000000001), frombits(0x000fffffffffffff),
	frombits(0x0010000000000000), frombits(0x7fefffffffffffff),
	0.1, 0.01, 0.001, 0.0001, 0.00001,
	1.0, 1.25, 1.5, 1.75, 2.5, 9.999999999999998,
	1e-300, 1e-99, 1e99, 1e300,
}
local sweep_groups = {
	{"d", intvalues}, {"i", intvalues}, {"u", intvalues},
	{"o", intvalues}, {"x", intvalues}, {"X", intvalues},
	{"a", special}, {"A", special}, {"e", special}, {"E", special},
	{"f", special}, {"F", special}, {"g", special}, {"G", special},
	{"c", charvalues}, {"s", stringvalues}, {"q", special},
}
for gi, group in ipairs(sweep_groups) do
	local spec, values = group[1], group[2]
	for fi, flag in ipairs(flags) do
		for width = 0, 30 do
			local index = (gi * 31 + fi * 17 + width) % #values + 1
			emit("%" .. flag .. width .. spec, index, values[index])
		end
		for precision = 0, 99 do
			local index = (gi * 13 + fi * 19 + precision) % #values + 1
			emit("%" .. flag .. "." .. precision .. spec, index, values[index])
		end
	end
end
for _, spec in ipairs({"a", "A", "e", "E", "f", "g", "G"}) do
	for precision = 0, 99 do
		for i, value in ipairs(special) do
			emit("%#." .. precision .. spec, i, value)
		end
	end
end

-- Exact binary neighbours around powers of two, plus reproducible bit patterns
-- spanning normal/subnormal magnitudes and both signs. Generate values from bits
-- rather than decimal text to avoid depending on either interpreter's parser.
local state = 0x123456789abcdef0
for i = 1, 12000 do
	local bits
	if i <= 4096 then
		local exponent = (i - 1) % 2046 + 1
		local delta = ((i - 1) // 2046) - 1
		bits = (exponent << 52) + delta
		if i % 2 == 0 then bits = bits | 0x8000000000000000 end
	else
		state = state ~ (state << 13)
		state = state ~ (state >> 7)
		state = state ~ (state << 17)
		bits = state
		if (bits & 0x7ff0000000000000) == 0x7ff0000000000000 then
			bits = bits ~ 0x0010000000000000
		end
	end
	local value = frombits(bits)
	local spec = ({"a", "A", "e", "E", "f", "g", "G"})[i % 7 + 1]
	local flag = flags[i % #flags + 1]
	emit("%" .. flag .. (i % 31) .. "." .. (i % 100) .. spec, i, value)
	emit("%q", i, value)
	count = count + 1
	print(count, "tostring", i, hex(tostring(value)), hex("" .. value))
end

for i, fmt in ipairs({
	"%", "%.", "%1.2.3f", "%100d", "%1.100f", "%#d", "%+u",
	"%03s", "%1.2c", "%3q", "%F", "%n", "%z", "%*d", "%ld",
	"%----------------------d", "%\0d", "%%%", "%..a", "%9-9d",
}) do
	emit(fmt, i, 1)
end
for i, value in ipairs({false, setmetatable({}, {__tostring = function() return "table" end}),
                       "12", "1.5", "not a number", "a\0b"}) do
	for _, spec in ipairs({"d", "c", "a", "g", "q", "s", "5s"}) do
		emit("%" .. spec, i, value)
	end
end
for i, value in ipairs({true, false, 0, -1, math.mininteger, math.maxinteger,
                        "", "a\0b", "\1" .. "2", 'a"b\\c\n'}) do
	emit("%q", i, value)
end
emit("%q", 11, nil)
for _, fmt in ipairs({"%s", "%99s", "%-99s", "%.99s", "%1s"}) do
	emit(fmt, 1, string.rep("a", 120))
end
for _, fmt in ipairs({"%", "%d", "%a", "%q", "%s", "%999d"}) do
	count = count + 1
	local ok, result = pcall(string.format, fmt)
	if ok then result = "OK:" .. hex(result)
	else result = "ERR:" .. tostring(result):gsub("^.-:%d+: ", "") end
	print(count, hex(fmt), "missing", result)
end
io.stderr:write("CASES=", count, "\n")
