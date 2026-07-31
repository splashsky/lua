-- Time hash-part insertion over doubling input sizes. Linear growth suggests
-- roughly constant insertion cost; about 4x growth when N doubles exposes an
-- O(N)-per-insert rehash pathology and therefore O(N^2) total behavior.

local script_dir = (arg and arg[0] or ""):match("^(.*[\\/])") or ""
local harness = dofile(script_dir .. "harness.lua")

local function run(N)
	local keys = {}
	for i = 1, N do keys[i] = "k" .. i end
	collectgarbage()
	local t0 = os.clock()
	local h = {}
	for i = 1, N do h[keys[i]] = i end
	local t1 = os.clock()
	io.write(string.format("N=%-8d insert %8.4f s   %12.0f ins/s\n",
		N, t1 - t0, N / ((t1 - t0) > 0 and (t1 - t0) or 1)))
	io.flush()
end

-- Use simple argument-safe names for discovery while preserving the historical
-- "N=..." result lines. Each size can now get a fresh process just like the
-- regular harness.bench workloads.
for _, n in ipairs({12500, 25000, 50000, 100000}) do
	if harness.selected("scale_" .. n) then run(n) end
end
harness.report_heap()
