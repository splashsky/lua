-- Shared timing and reporting for the benchmark files in this directory.
--
-- Keeping this in one place matters more than it might appear: every benchmark
-- must collect twice, sample the Lua-visible heap at the same points, and use
-- os.clock() in exactly the same way or a before/after comparison is misleading.

local harness = {}

-- A benchmark file can still be run with no arguments, which is handy when
-- poking at it by hand. The runners use the two small conventions below:
--
--     lua micro.lua --list
--     lua micro.lua strconcat
--
-- Keeping the filtering here means every suite gets exactly the same command
-- line interface, and plain old Lua builds can run the scripts without needing
-- any interpreter-specific support.
local requested = arg and arg[1] or nil
local listing = requested == "--list"
local matched = false

local function selected(name)
	if listing then
		io.write(name, "\n")
		return false
	end
	if requested ~= nil and requested ~= name then
		return false
	end
	matched = true
	return true
end

function harness.bench(name, ops, fn)
	-- Do not run skipped workloads at all. In isolated mode this is the important
	-- bit: an earlier benchmark cannot grow the heap or advance the collector
	-- before the requested benchmark reaches its usual collection boundary.
	if not selected(name) then return end
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

-- Suites call this before benchmark-specific setup as well as bench() itself.
-- That first check matters: building a large input for a skipped benchmark
-- would itself grow the heap and recreate the contamination we are avoiding.
-- scaling.lua also uses the hook because its intentionally different output
-- does not go through bench().
function harness.selected(name)
	return selected(name)
end

function harness.report_heap()
	if listing then return end
	if requested ~= nil and not matched then
		error("unknown benchmark '" .. requested .. "'", 0)
	end
	io.write(string.format("peak Lua heap: %.1f KiB\n", collectgarbage("count")))
	io.flush()
end

return harness
