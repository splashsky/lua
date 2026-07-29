-- Shared timing and reporting for the benchmark files in this directory.
--
-- Keeping this in one place matters more than it might appear: every benchmark
-- must collect twice, sample the Lua-visible heap at the same points, and use
-- os.clock() in exactly the same way or a before/after comparison is misleading.

local harness = {}

function harness.bench(name, ops, fn)
	collectgarbage()
	collectgarbage()
	local before = collectgarbage("count")
	local t0 = os.clock()
	fn()
	local t1 = os.clock()
	local after = collectgarbage("count")
	local secs = t1 - t0
	local rate = secs > 0 and (ops / secs) or 0
	io.write(string.format("%-16s %8.3f s   %14.0f ops/s   %10.1f KiB\n",
		name, secs, rate, after - before))
	io.flush()
end

function harness.report_heap()
	io.write(string.format("peak Lua heap: %.1f KiB\n", collectgarbage("count")))
	io.flush()
end

return harness
