local fn = os.tmpname()
local f = assert(io.open(fn, "w"))
local t0 = os.clock()
for i = 1, 2000000 do f:write("x") end
f:write("\n")
for i = 1, 200000 do f:write("line ", i, "\n") end
f:close()
local t1 = os.clock()
f = assert(io.open(fn))
local n = 0
while true do local c = f:read(1); if not c then break end; n = n + 1 end
f:close()
local t2 = os.clock()
local m = 0
for l in io.lines(fn) do m = m + 1 end
local t3 = os.clock()
os.remove(fn)
print(string.format("write %.3f  read1 %.3f  lines %.3f  (%d chars, %d lines)", t1-t0, t2-t1, t3-t2, n, m))
