-- Lua 5.5 local-time differential corpus. See correctness-tz.md for invocation.
-- Usage: REFLUA=... OURS=... TMPDIR=... "$REFLUA" this-file driver
-- The driver discovers transitions with reference Lua, then feeds IDENTICAL
-- timestamps and wall tables to separate processes of both implementations.
local mode = arg[1]
local unpack = table.unpack
local function days(y, m, d)
  if m <= 2 then y = y - 1 end
  local era = y // 400
  local yoe = y - era * 400
  local mp = m + (m > 2 and -3 or 9)
  return era * 146097 + yoe*365 + yoe//4 - yoe//100 + (153*mp+2)//5 + d-1 - 719468
end
local function nominal(d)
  return days(d.year,d.month,d.day)*86400+d.hour*3600+d.min*60+d.sec
end
local function quote(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
local function escaped(s)
  return (tostring(s):gsub('[\\%c]', function(c) return string.format('\\x%02x', string.byte(c)) end))
end
local fields = {'year','month','day','hour','min','sec','yday','wday','isdst'}
local function serialize(d)
  local out = {}
  for _, k in ipairs(fields) do out[#out+1] = k .. '=' .. tostring(d[k]) end
  return table.concat(out, ',')
end
local function emit(id, ok, x)
  if type(x) == 'table' then x = serialize(x) end
  print(id .. '\t' .. (ok and 'ok:' or 'error:') .. escaped(x))
end
if mode == 'discover' then
  local ranges = {{1900,1972},{2000,2031},{2399,2403}}
  local transitions, seen = {}, {}
  local function sig(t)
    local d = os.date('*t', t)
    return os.date('%z|%Z', t) .. '|' .. tostring(d.isdst)
  end
  for _, r in ipairs(ranges) do
    local first, last = days(r[1],1,1)*86400, days(r[2],1,1)*86400
    local a, sa = first, sig(first)
    while a < last do
      local b = math.min(a+86400,last)
      local sb = sig(b)
      if sa ~= sb then
        local lo, hi = a, b
        while hi-lo > 1 do
          local mid = (lo+hi)//2
          if sig(mid) == sa then lo = mid else hi = mid end
        end
        if not seen[hi] then transitions[#transitions+1], seen[hi] = hi, true end
      end
      a, sa = b, sb
    end
  end
  for _, t in ipairs(transitions) do
    print('T', t)
    local lo, hi = nominal(os.date('*t',t-1))+1, nominal(os.date('*t',t))
    local mid = (lo+hi)//2
    for _, dt in ipairs({-300,0,300}) do
      local d = os.date('!*t',mid+dt)
      print('W', d.year,d.month,d.day,d.hour,d.min,d.sec)
    end
  end
  return
end
if mode == 'worker' then
  local ts = {-0x7fffffffffffffff-1, -67768040609913601, -67768040609740801,
    -67768040609740800,-67768040609740799,-62198755200,-62167219200,
    -2208988800,-1577923200,-314366400,-299851200,-86401,-86400,-2,-1,0,1,
    86400,78796799,78796800,78796801,946684800,1483228825,1483228826,1483228827,
    1704067200,1710054000,1719835200,1730613600,
    2147483647,253402300800,13569465600,67768036191676798,
    67768036191676799,67768036191676800,67768036191849600,0x7fffffffffffffff}
  local walls = {
    {1969,12,31,23,59,59},{1969,12,31,23,59,58},{1970,1,1,0,0,0},
    {2024,1,15,12,0,0},{2024,7,15,12,0,0},{2024,3,10,2,30,0},
    {2024,11,3,1,30,0},{2024,4,7,1,45,0},{2024,10,6,2,15,0},
    {2024,13,1,0,0,0},{2024,1,0,0,0,0},{2024,-12,1,25,-61,90},
    {2000,2,29,-1,0,-1},{2030,7,1,1,-120,0},
    {1972,6,30,23,59,60},{2016,12,31,23,59,60},
    {2147485547,13,1,12,0,0},{-2147481748,1,0,12,0,0},
    {2147485547,12,31,23,59,59},{-2147481748,1,1,0,0,0},
  }
  for line in assert(io.open(arg[2])):lines() do
    local a = {}; for n in line:gmatch('%-?%d+') do a[#a+1] = math.tointeger(n) end
    if line:sub(1,1) == 'T' then
      for _, offset in ipairs({-3601,-1,0,1,3601}) do ts[#ts+1] = a[1]+offset end
    else walls[#walls+1] = a end
  end
  local options = 'a A b B c C d D e F g G h H I j m M n p r R S t T u U V w W x X y Y z Z % Ec EC Ex EX Ey EY Od Oe OH OI Om OM OS Ou OU OV Ow OW Oy'
  local fmt = {}; for op in options:gmatch('%S+') do fmt[#fmt+1] = '%' .. op end
  fmt = table.concat(fmt,'|')
  for i,t in ipairs(ts) do
    for _, u in ipairs({'','!'}) do
      emit('date:'..i..':'..t..':'..u..'format',pcall(os.date,u..fmt,t))
      emit('date:'..i..':'..t..':'..u..'table',pcall(os.date,u..'*t',t))
    end
  end
  for i,w in ipairs(walls) do
    for _,hint in ipairs({'nil','false','true'}) do
      local d = {year=w[1],month=w[2],day=w[3],hour=w[4],min=w[5],sec=w[6]}
      if hint ~= 'nil' then d.isdst = hint == 'true' end
      local ok, x = pcall(os.time,d)
      local id = ('time:%d:%s:%s'):format(i,table.concat(w,','),hint)
      -- On mktime overflow Lua exposes uninitialized tm members; do not compare
      -- their indeterminate values. -1, however, has a fully normalized table.
      emit(id,ok,(ok or x == -1) and (tostring(x)..'|'..serialize(d)) or x)
    end
  end
  for i,f in ipairs({'%Q','%','%E','%Oq','%EYx%Q','%\0z','*t\0tail','!%Q'}) do
    emit('invalid:'..i,pcall(os.date,f,0))
  end
  local cases = {
    {},{year=2024},{year=2024,month=1},{year=2024,month=1,day='x'},
    {year=2024,month=1,day=1.5},{year=2024,month=1,day=2147483648},
    {year=2024,month=2147483649,day=1},{year=2147485548,month=1,day=1},
    {year=-2147481749,month=1,day=1},{year=2024,month=1,day=1,min={}},
  }
  for i,d in ipairs(cases) do emit('field:'..i,pcall(os.time,d)) end
  return
end
assert(mode == 'driver', 'expected driver, discover, or worker')
local ref, ours, tmp = assert(os.getenv('REFLUA')), assert(os.getenv('OURS')), assert(os.getenv('TMPDIR'))
local self = assert(arg[0])
local zones = {
  false, '', ':', 'UTC', 'America/New_York', 'America/Chicago',
  'Australia/Lord_Howe', 'America/Santiago', 'Europe/Dublin', 'Asia/Kolkata',
  'Pacific/Chatham', 'Europe/Amsterdam', 'Pacific/Apia', 'Africa/Casablanca',
  'Asia/Kathmandu', 'Europe/Moscow', 'EST5EDT', 'EST5EDT,M3.2.0,M11.1.0',
  '<+0330>-3:30', 'AAA0BBB,J60/1,J300/3', 'AAA0BBB,59/1,300/3',
  'AAA0BBB,M3.2.0/-2,M11.1.0/26', 'AAA0BBB,M1.1.0/-167,M12.5.0/167',
  'AAA0BBB,M10.1.0,M3.1.0', ':UTC', 'garbage', 'Foo/Bar', 'PSTgarbage',
  '12garbage','ABC12garbage','XYZ3BAD/suffix', '/usr/share/zoneinfo/Asia/Kolkata',
  ':/usr/share/zoneinfo/Australia/Lord_Howe', '/nonexistent/zone', ':No/Such/Zone',
  'AAA0BBB', 'TZDIR_EMPTY|America/New_York', 'TZDIR_EMPTY|EST5EDT',
  'TZDIR_EMPTY|AAA0BBB', 'right/UTC', 'right/America/New_York',
  'AAA0BBB,M1.1.0/-2,M10.1.0', 'AAA0BBB,M3.1.0,M12.5.0/26',
  '<X>1', 'ABC65536', 'ABC25:65536:1'
}
local function run(cmd)
  local ok, why, code = os.execute(cmd)
  assert(ok, cmd .. ' failed: ' .. tostring(why) .. ' ' .. tostring(code))
end
local totals, nlines, ntrans, zones_changed = 0, 0, 0, 0
run('mkdir -p ' .. quote(tmp .. '/empty-tzdir'))
for i,zone in ipairs(zones) do
  local base = tmp .. '/tz-corpus-' .. i
  local tzdir = zone and zone:match('^TZDIR_EMPTY|(.+)$')
  local value = tzdir or zone
  local env = 'env -u TZ -u TZDIR LC_ALL=C ' .. (value == false and '' or ('TZ=' .. quote(value) .. ' ')) ..
    (tzdir and ('TZDIR=' .. quote(tmp .. '/empty-tzdir') .. ' ') or '')
  for _,pair in ipairs({{ref,'ref'},{ours,'ours'}}) do
    run(env .. quote(pair[1]) .. ' ' .. quote(self) .. ' discover > ' .. quote(base..'.'..pair[2]..'.discovered'))
  end
  -- Union includes transitions only one implementation observes, especially
  -- pre-1970 POSIX rules. Both workers still consume precisely the same input.
  local input, seen = assert(io.open(base..'.input','w')), {}
  for _,kind in ipairs({'ref','ours'}) do
    for line in assert(io.open(base..'.'..kind..'.discovered')):lines() do
      if not seen[line] then seen[line]=true; input:write(line,'\n') end
    end
  end
  input:close()
  for line in assert(io.open(base..'.input')):lines() do if line:sub(1,1) == 'T' then ntrans=ntrans+1 end end
  run(env..quote(ref)..' '..quote(self)..' worker '..quote(base..'.input')..' > '..quote(base..'.ref'))
  run(env..quote(ours)..' '..quote(self)..' worker '..quote(base..'.input')..' > '..quote(base..'.ours'))
  local same_bytes = os.execute('cmp -s '..quote(base..'.ref')..' '..quote(base..'.ours')) == true
  local f, g = assert(io.open(base..'.ref','rb')), assert(io.open(base..'.ours','rb'))
  local count, samples = 0, {}
  while true do
    local a,b = f:read('*l'), g:read('*l')
    assert((a == nil) == (b == nil), 'different line counts for '..tostring(zone))
    if not a then break end
    nlines = nlines + 1
    if a ~= b then
      assert(a:match('^[^\t]*') == b:match('^[^\t]*'), 'different case IDs')
      count = count+1
      if #samples < 4 then samples[#samples+1] = '  REF '..a..'\n  OUR '..b end
    end
  end
  f:close(); g:close()
  assert((count == 0) == same_bytes, 'line comparison missed a byte difference')
  if count > 0 then zones_changed = zones_changed+1 end
  totals = totals+count
  print(('zone %02d %s: %d mismatching lines'):format(i,zone == false and '<unset>' or string.format('%q',zone),count))
  for _,s in ipairs(samples) do print(s) end
end
print(('TOTAL zones=%d transitions=%d lines=%d mismatches=%d affected-zones=%d'):format(#zones,ntrans,nlines,totals,zones_changed))
