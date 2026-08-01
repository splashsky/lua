-- Differential corpus for lua-odin and a reference PUC Lua 5.5 executable.
-- Each process generates the same deterministic inputs, parses them with its
-- own tonumber, and hashes the resulting binary64 bytes. Equal category counts
-- and hashes mean every parsed bit pattern agreed without writing a huge file.

local random = 0x6a09e667f3bcc909
local hash = 2166136261
local total = 0
local counts = {
	random_roundtrip = 0,
	digit_exponent = 0,
	neighbour = 0,
	subnormal_extreme = 0,
}

local function next_random()
	local x = random
	x = x ~ (x << 13)
	x = x ~ (x >> 7)
	x = x ~ (x << 17)
	random = x
	return x
end

local function finite(bits)
	return (bits & 0x7ff0000000000000) ~= 0x7ff0000000000000
end

local function from_bits(bits)
	return string.unpack("<d", string.pack("<i8", bits))
end

local function record(text, category)
	local value = assert(tonumber(text), text)
	local packed = string.pack("<d", value)
	for i = 1, 8 do
		hash = ((hash ~ packed:byte(i)) * 16777619) & 0xffffffff
	end
	total = total + 1
	counts[category] = counts[category] + 1
end

while counts.random_roundtrip < 1000000 do
	local bits = next_random()
	if finite(bits) then
		record(string.format("%.17g", from_bits(bits)), "random_roundtrip")
	end
end

for length = 1, 25 do
	for exponent = -348, 347 do
		for _ = 1, 64 do
			local digits = {string.char(49 + ((next_random() & 0x7fffffffffffffff) % 9))}
			for i = 2, length do
				digits[i] = string.char(48 + ((next_random() & 0x7fffffffffffffff) % 10))
			end
			record(table.concat(digits) .. string.format("e%+d", exponent), "digit_exponent")
		end
	end
end

local bases = 0
while bases < 350000 do
	local bits = next_random()
	if finite(bits) then
		bases = bases + 1
		for delta = -1, 1 do
			local candidate = bits + delta
			if finite(candidate) then
				record(string.format("%.17g", from_bits(candidate)), "neighbour")
			end
		end
	end
end

for bits = 0, 50000 do
	record(string.format("%.17g", from_bits(bits)), "subnormal_extreme")
	record(string.format("%.17g", from_bits(bits | 0x8000000000000000)), "subnormal_extreme")
end
for _ = 1, 100000 do
	local bits = next_random() & 0x000fffffffffffff
	record(string.format("%.17g", from_bits(bits)), "subnormal_extreme")
end
for _, bits in ipairs {
	0x0010000000000000,
	0x8010000000000000,
	0x7fefffffffffffff,
	0xffefffffffffffff,
} do
	record(string.format("%.17g", from_bits(bits)), "subnormal_extreme")
end
for _, text in ipairs {
	"1e309",
	"-1e309",
	"1e-400",
	"-1e-400",
	"5e-324",
	"2.2250738585072014e-308",
} do
	record(text, "subnormal_extreme")
end

io.write(string.format(
	"PASS total=%d hash=%08x random-roundtrip=%d digit-exponent=%d neighbour=%d subnormal-extreme=%d\n",
	total,
	hash,
	counts.random_roundtrip,
	counts.digit_exponent,
	counts.neighbour,
	counts.subnormal_extreme
))
