-- A leaner pass that separates dense arrays, string allocation, hash-table
-- operations, and sorting so a layout change can be tied to the affected path.

local script_dir = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
local harness = dofile(script_dir .. "harness.lua")
local bench = harness.bench

-- Dense integer-key insertion and summation, with no string allocation.
do
	if harness.selected("array_insert") then
		local N = 3000000
		bench("array_insert", N, function()
			local a = {}
			for i = 1, N do a[i] = i end
			local s = 0
			for i = 1, N do s = s + a[i] end
			return s
		end)
	end
end

-- String-keyed insertion and lookup. Each access constructs a fresh key string,
-- so this combines string interning with hash-part behavior.
do
	if harness.selected("hash_strkey") then
		local N = 300000
		bench("hash_strkey", N, function()
			local h = {}
			for i = 1, N do h["k" .. i] = i end
			local s = 0
			for i = 1, N do s = s + (h["k" .. i] or 0) end
			return s
		end)
	end
end

-- Reuse pre-built strings to isolate hash insertion and lookup from interning.
do
	if harness.selected("hash_prekey") then
		local N = 300000
		local keys = {}
		for i = 1, N do keys[i] = "k" .. i end
		bench("hash_prekey", N, function()
			local h = {}
			for i = 1, N do h[keys[i]] = i end
			local s = 0
			for i = 1, N do s = s + (h[keys[i]] or 0) end
			return s
		end)
	end
end

-- Sort deterministic random floats at a smaller scale than micro.lua.
do
	if harness.selected("tablesort") then
		local N = 300000
		math.randomseed(12345)
		local a = {}
		for i = 1, N do a[i] = math.random() end
		bench("tablesort", N, function()
			table.sort(a)
			return a[1]
		end)
	end
end

harness.report_heap()
