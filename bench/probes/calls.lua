local N = 10000000
local function bench(name, f)
  local t0 = os.clock(); f(); local t1 = os.clock()
  io.write(string.format("%-28s %.3f\n", name, t1 - t0))
end
local s = "x"
local abs, rawlen, type_, select_ = math.abs, rawlen, type, select
local function lf(x) return x end
bench("empty loop", function() for i = 1, N do end end)
bench("lua fn call", function() for i = 1, N do lf(i) end end)
bench("native abs(i)", function() for i = 1, N do abs(i) end end)
bench("native type(s)", function() for i = 1, N do type_(s) end end)
bench("native rawlen(s)", function() for i = 1, N do rawlen(s) end end)
bench("native select('#')", function() for i = 1, N do select_('#') end end)
bench("method s:len()", function() for i = 1, N do s:len() end end)
bench("string.len(s)", function() local len = string.len for i = 1, N do len(s) end end)
bench("string.byte(s)", function() local b = string.byte for i = 1, N do b(s) end end)
bench("string.sub(s,1,1)", function() local sub = string.sub for i = 1, N do sub(s, 1, 1) end end)
