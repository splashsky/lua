local fn = os.tmpname()
local f = assert(io.open(fn, "w"))
local t0 = os.clock()
for i = 1, 5000000 do f:write("x") end
f:close()
local t1 = os.clock()
f = assert(io.open(fn))
for i = 1, 5000000 do local c = f:read(1) end
f:close()
local t2 = os.clock()
-- baseline: the same call shape into a trivial C function
local s = "x"
local t3 = os.clock()
for i = 1, 5000000 do local c = s:len() end
local t4 = os.clock()
os.remove(fn)
print(string.format("write1 %.3f  read1 %.3f  s:len %.3f", t1-t0, t2-t1, t4-t3))
