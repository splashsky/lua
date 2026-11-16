-- Isolated named workloads. N is the number of outer calls/scans.
-- Example: perf stat -e instructions:u -- lua patterns-probes.lua gmatch_long 2
-- Run one case per process. Setup (including the shared long inputs), startup,
-- the loop and printing are included; do not subtract the `loop` case blindly.
local name, N = arg[1], tonumber(arg[2]) or 100000
local find, match, gmatch, gsub = string.find, string.match, string.gmatch, string.gsub
local short = "alpha 123 beta 456"
local words = string.rep("the quick brown fox 123 jumps over 456 lazy dogs. ", 2000)
local long = string.rep("a", 4096) .. "Z"
local repl = {alpha="A", beta="B"}
local function fun(w) return w == "alpha" and "A" or "B" end
local total = 0
if name == "loop" then
  for i=1,N do total=total+1 end
elseif name == "find_plain_short" then
  for i=1,N do local a,b=find(short,"beta",1,true); total=total+a+b end
elseif name == "find_auto_short" then
  for i=1,N do local a,b=find(short,"beta"); total=total+a+b end
elseif name == "find_plain_long_miss" then
  for i=1,N do if find(long,"zZZ",1,true) then total=total+1 end end
elseif name == "find_plain_long_candidates" then
  for i=1,N do if find(long,"aaaZ",1,true) then total=total+1 end end
elseif name == "find_auto_long_miss" then
  for i=1,N do if find(long,"zZZ") then total=total+1 end end
elseif name == "find_plain_empty" then
  for i=1,N do local a,b=find(short,"",1,true); total=total+a+b end
elseif name == "find_plain_binary" then
  local s = string.rep("a\0", 512) .. "a\0z"
  for i=1,N do local a,b=find(s,"\0z",1,true); total=total+a+b end
elseif name == "find_pattern" then
  for i=1,N do local a,b,c,d=find(short,"^(%a+)%s+(%d+)"); total=total+a+b+#c+#d end
elseif name == "match_nocap" then
  for i=1,N do local a=match(short,"^%a+%s+%d+"); total=total+#a end
elseif name == "match_capture" then
  for i=1,N do local a,b=match(short,"^(%a+)%s+(%d+)"); total=total+#a+#b end
elseif name == "match_backref" then
  for i=1,N do local a=match("abcabc", "^(%a+)%1$"); total=total+#a end
elseif name == "match_empty" then
  for i=1,N do local a=match(short, "^"); total=total+#a end
elseif name == "gmatch_short" then
  for i=1,N do for w in gmatch(short,"%a+") do total=total+#w end end
elseif name == "gmatch_long" then
  for i=1,N do for w in gmatch(words,"%a+") do total=total+#w end end
elseif name == "gsub_string" then
  for i=1,N do local s,n=gsub(short,"(%a+)","X%1"); total=total+#s+n end
elseif name == "gsub_table" then
  for i=1,N do local s,n=gsub(short,"(%a+)",repl); total=total+#s+n end
elseif name == "gsub_function" then
  for i=1,N do local s,n=gsub(short,"(%a+)",fun); total=total+#s+n end
elseif name == "gsub_copy_miss" then
  local s=string.rep("a",1024)
  for i=1,N do local v,n=gsub(s,"%d","X"); total=total+#v+n end
elseif name == "gsub_long_replacement" then
  local r=string.rep("replacement", 30)
  for i=1,N do local s,n=gsub("a", "a", r); total=total+#s+n end
elseif name == "gsub_empty" then
  for i=1,N do local s,n=gsub("abc", "", "x"); total=total+#s+n end
elseif name == "classes" then
  for i=1,N do
    local a=match("abc", "^%a+$"); local b=match("123", "^%d+$")
    local c=match(" \t\n", "^%s+$"); local d=match("a12", "^%w+$")
    total=total+#a+#b+#c+#d
  end
elseif name == "sets" then
  for i=1,N do local a=match("aZ09_", "^[%a%d_]+$"); total=total+#a end
elseif name == "quantifiers" then
  for i=1,N do local a=match("abbbcccd", "^ab*c+.-d?$"); total=total+#a end
elseif name == "backtrack" then
  for i=1,N do local a=match("aaaaaaaaaaaaab", "^a*a*a*b$"); total=total+#a end
elseif name == "balance_frontier" then
  for i=1,N do local a=match("x (a(b)c) end", "%f[%a]end"); local b=match("(a(b)c)", "^%b()$"); total=total+#a+#b end
elseif name == "class_long" then
  for i=1,N do local a=match(long,"^%a+"); total=total+#a end
elseif name == "class_long_fail" then
  for i=1,N do if match(long,"%d") then total=total+1 end end
else error("unknown probe " .. tostring(name)) end
print(name, N, total)
