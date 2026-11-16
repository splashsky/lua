-- Emit raw binary64 results for differential testing of the math entry points.
-- Run two interpreters on this file and compare their standard output bytewise.
-- The optional argument controls the number of full-range random inputs.
local iterations = tonumber(arg[1]) or 100000
local state = 0x6a09e667f3bcc909
local pack, unpack = string.pack, string.unpack
local sin, cos, tan = math.sin, math.cos, math.tan
local exp, log, sqrt = math.exp, math.log, math.sqrt
local atan, asin, acos = math.atan, math.asin, math.acos
local fmt = "<" .. string.rep("d", 15)
local count = 0

local function random_bits()
  state = state ~ (state << 13)
  state = state ~ (state >> 7)
  state = state ~ (state << 17)
  return state
end

local function number(bits)
  return (unpack("<d", pack("<i8", bits)))
end

local function record(bits, other)
  local x, y = number(bits), number(other)
  io.write(pack(fmt, sin(x), cos(x), tan(x), exp(x), log(x),
                log(x, 2), log(x, 10), sqrt(x), atan(x), asin(x), acos(x),
                atan(x, y), x ^ 1.5, x ^ 0.5, x ^ y))
  count = count + 1
end

for _ = 1, iterations do record(random_bits(), random_bits()) end

-- Signed zeros, infinities, quiet/signaling NaNs, subnormal boundaries and
-- neighbours of the argument-reduction and exponential overflow boundaries.
for _, center in ipairs {
  0, 0x0010000000000000, 0x3c90000000000000, 0x3fe921fb54442d18,
  0x3ff0000000000000, 0x3ff921fb54442d18, 0x413921fb00000000,
  0x41e921fb00000000, 0x40862e42fefa39ef, 0x40874910d52d3051,
  0x7fefffffffffffff, 0x7ff0000000000000, 0x7ff8000000000000,
} do
  for delta = -8, 8 do
    local bits = center + delta
    record(bits, 0x3ff8000000000000)
    record(bits ~ 0x8000000000000000, 0xbfe0000000000000)
  end
end
for bits = 1, 2048 do
  record(bits, 0x4000000000000000)
  record(bits | 0x8000000000000000, 0xc000000000000000)
end
io.stderr:write(string.format("inputs=%d results=%d\n", count, count * 15))
