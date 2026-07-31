-- General micro-benchmark suite: a measuring stick for lua-odin vs reference
-- PUC Lua. A single "op" is defined per benchmark, so ops/sec is comparable
-- only between interpreters on the same line, never across benchmark names.

-- The runner enters bench/ before invoking us, but deriving the script directory
-- as well keeps direct invocations from the repository root working.
local script_dir = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
local harness = dofile(script_dir .. "harness.lua")
local bench = harness.bench

-- Recursive Fibonacci is dominated by Lua function call/return overhead.
local function fib(n)
	if n < 2 then return n end
	return fib(n - 1) + fib(n - 2)
end
do
	if harness.selected("fib(32)") then
		local N = 32
		-- The number of calls made by fib(N) is 2*fib(N+1)-1.
		local function calls(n)
			local a, b = 1, 1
			for _ = 1, n do a, b = b, a + b end
			return 2 * b - 1
		end
		bench("fib(32)", calls(N), function() return fib(N) end)
	end
end

-- A tight numeric-for loop with integer arithmetic.
do
	if harness.selected("intloop") then
		local N = 20000000
		bench("intloop", N, function()
			local s = 0
			for i = 1, N do
				s = s + i * 3 - (i // 2) + (i % 7)
			end
			return s
		end)
	end
end

-- Float arithmetic exercises the numeric tower and math library calls.
do
	if harness.selected("floatloop") then
		local N = 10000000
		local sin, sqrt = math.sin, math.sqrt
		bench("floatloop", N, function()
			local s = 0.0
			for i = 1, N do
				s = s + sqrt(i) * sin(i) - (i * 0.5)
			end
			return s
		end)
	end
end

-- Build many strings in a table, then concatenate them into one large string.
do
	if harness.selected("strconcat") then
		local N = 200000
		bench("strconcat", N, function()
			local t = {}
			for i = 1, N do
				t[i] = "item" .. i .. ":" .. (i * i)
			end
			return #table.concat(t, ",")
		end)
	end
end

-- Scan a large text repeatedly with Lua patterns.
do
	if harness.selected("strpattern") then
		local base = string.rep("the quick brown fox 123 jumps over 456 lazy dogs. ", 2000)
		local N = 200
		bench("strpattern", N, function()
			local total = 0
			for _ = 1, N do
				local n = 0
				for w in base:gmatch("%a+") do n = n + #w end
				total = total + n
			end
			return total
		end)
	end
end

-- Exercise dense arrays and string-keyed hash tables in one large workload.
do
	if harness.selected("tablechurn") then
		local N = 3000000
		bench("tablechurn", N, function()
			local a = {}
			for i = 1, N do a[i] = i end
			local s = 0
			for i = 1, N do s = s + a[i] end
			local h = {}
			for i = 1, N // 3 do h["k" .. i] = i end
			for i = 1, N // 3 do s = s + (h["k" .. i] or 0) end
			return s
		end)
	end
end

-- Sort deterministic random data so both interpreters receive the same work.
do
	if harness.selected("tablesort") then
		local N = 1000000
		math.randomseed(12345)
		local a = {}
		for i = 1, N do a[i] = math.random() end
		bench("tablesort", N, function()
			table.sort(a)
			return a[1]
		end)
	end
end

-- Allocate and invoke many small closures with captured upvalues.
do
	if harness.selected("closures") then
		local N = 2000000
		bench("closures", N, function()
			local s = 0
			local function make(x)
				return function(y) return x + y end
			end
			for i = 1, N do
				local f = make(i)
				s = s + f(1)
			end
			return s
		end)
	end
end

harness.report_heap()
