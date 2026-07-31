-- Standard-library benchmarks aimed at the machinery we reimplemented when the
-- project dropped its C-library dependency.
--
-- The other bench files exercise the VM and the table representation. None of
-- them touch the pieces that were rewritten in pure Odin: float rendering and
-- parsing (which replaced snprintf's %g and strtod), the string.format printf
-- engine, the transcendental maths (which replaced libm's sin/cos/exp/pow), the
-- buffered stream layer (which replaced FILE*), and date formatting (which
-- replaced strftime). Those are precisely where a regression against reference
-- would hide, so they get their own file.

local script_dir = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
local harness = dofile(script_dir .. "harness.lua")
local bench = harness.bench

-- Rendering floats to text: one tostring per op. Deliberately uses values that
-- do not round-trip at 15 digits as well as ones that do, so both the fast path
-- and the %.17g fallback are represented.
do
	local N = 400000
	local vals = {}
	math.randomseed(4242)
	for i = 1, 64 do
		vals[i] = (math.random() - 0.5) * 2 ^ math.random(-60, 60)
	end
	bench("tostring_float", N, function()
		local acc = 0
		for i = 1, N do
			acc = acc + #tostring(vals[(i & 63) + 1])
		end
		return acc
	end)
end

-- Parsing floats from text: one tonumber per op, exercising correct rounding.
do
	local N = 400000
	local strs = {}
	math.randomseed(4242)
	for i = 1, 64 do
		strs[i] = string.format("%.17g", (math.random() - 0.5) * 2 ^ math.random(-60, 60))
	end
	bench("tonumber_float", N, function()
		local acc = 0.0
		for i = 1, N do
			acc = acc + tonumber(strs[(i & 63) + 1])
		end
		return acc
	end)
end

-- The printf engine: a spread of conversions, widths and precisions per op.
do
	local N = 200000
	bench("string_format", N, function()
		local acc = 0
		for i = 1, N do
			local s = string.format("%d|%8.3f|%-10s|%x|%g|%e", i, i * 1.5, "abc", i, i * 0.001, i * 1.0)
			acc = acc + #s
		end
		return acc
	end)
end

-- Integer formatting on its own, since it shares none of the float paths.
do
	local N = 400000
	bench("format_int", N, function()
		local acc = 0
		for i = 1, N do
			acc = acc + #string.format("%d", i)
		end
		return acc
	end)
end

-- The transcendentals we hand-wrote: sin, cos, exp and pow (via ^).
do
	local N = 1000000
	local sin, cos, exp = math.sin, math.cos, math.exp
	bench("math_transcend", N, function()
		local acc = 0.0
		for i = 1, N do
			local x = i * 0.000001
			acc = acc + sin(x) + cos(x) + exp(x % 1) + x ^ 1.5
		end
		return acc
	end)
end

-- The stream layer: write a file, then read it back a line at a time. One op is
-- one line through the buffering machinery in each direction.
do
	local N = 200000
	bench("file_lines", N * 2, function()
		local path = os.tmpname()
		local f = assert(io.open(path, "w"))
		for i = 1, N do
			f:write("line ", i, " of the buffered stream benchmark\n")
		end
		f:close()
		local count = 0
		for _ in io.lines(path) do
			count = count + 1
		end
		os.remove(path)
		return count
	end)
end

-- Date formatting, which replaced strftime plus the civil-calendar arithmetic.
do
	local N = 100000
	bench("os_date", N, function()
		local acc = 0
		for i = 1, N do
			acc = acc + #os.date("!%Y-%m-%dT%H:%M:%S", 1700000000 + i)
		end
		return acc
	end)
end

harness.report_heap()
