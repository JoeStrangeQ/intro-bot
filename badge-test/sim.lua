-- Headless test for the Intro Bot badge app. Stubs the Solana OS Lua API (ui, rpc, http,
-- mesh, storage, timer, sys, led, solana) with a pretend chain, drives every screen and key
-- path, decodes the transactions the app builds, and enforces the badge limits: 128 UI
-- objects, 200-byte labels, 256-byte QR, 16 KB storage, 30 rpc calls a minute, 3.5 KB
-- answers, 2 KB http bodies, 200k instructions per callback (pda/base58 costs included).
-- Run from the repo root:  lua badge-test/sim.lua   (needs python3 for pda.py)
local HERE = arg[0]:match("^(.*)/") or "."
local APP = HERE .. "/../badge/"
package.path = APP .. "?.lua;" .. package.path

local fails, passes = 0, 0
local function check(cond, what)
  if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. what) end
end

-- Minimal JSON (enough for the API answers and to size storage) ------------
local json = {}
do
  local function enc(v)
    local t = type(v)
    if t == "table" then
      if #v > 0 or next(v) == nil then
        local o = {}
        for i = 1, #v do o[i] = enc(v[i]) end
        return "[" .. table.concat(o, ",") .. "]"
      end
      local o = {}
      for k, x in pairs(v) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(x) end
      return "{" .. table.concat(o, ",") .. "}"
    elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    else return tostring(v) end
  end
  json.encode = enc
  function json.decode_lua(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local val
    local function str()
      local j, out = i + 1, {}
      while true do
        local c = s:sub(j, j)
        if c == "" then error("eof") end
        if c == '"' then i = j + 1; return table.concat(out) end
        if c == "\\" then
          local e = s:sub(j + 1, j + 1)
          if e == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)); j = j + 6
          else out[#out + 1] = ({n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"})[e] or e; j = j + 2 end
        else out[#out + 1] = c; j = j + 1 end
      end
    end
    function val()
      ws()
      local c = s:sub(i, i)
      if c == "{" then
        local t = {}; i = i + 1; ws()
        if s:sub(i, i) == "}" then i = i + 1 return t end
        while true do
          ws(); local k = str(); ws(); assert(s:sub(i, i) == ":"); i = i + 1
          t[k] = val(); ws()
          local d = s:sub(i, i); i = i + 1
          if d == "}" then return t end
          assert(d == ",")
        end
      elseif c == "[" then
        local t = {}; i = i + 1; ws()
        if s:sub(i, i) == "]" then i = i + 1 return t end
        while true do
          t[#t + 1] = val(); ws()
          local d = s:sub(i, i); i = i + 1
          if d == "]" then return t end
          assert(d == ",")
        end
      elseif c == '"' then return str()
      elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
      elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
      elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
      else
        local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not n or n == "" then error("bad json") end
        i = i + #n
        return math.tointeger(tonumber(n)) or tonumber(n)
      end
    end
    local ok, r = pcall(val)
    if not ok then return nil, r end
    return r
  end
end

-- The badge's json is C: don't count the stub's instructions.
local paused = false
local function native(f) return function(...) paused = true; local r = table.pack(f(...)); paused = false; return table.unpack(r, 1, r.n) end end
json.decode = native(json.decode_lua)
json.encode = native(json.encode)

local paused, extra = false, 0
local function native(f) return function(...) paused = true; local r = table.pack(f(...)); paused = false; return table.unpack(r, 1, r.n) end end
json.decode = native(json.decode_lua)
json.encode = native(json.encode)

-- base58 (test side) ---------------------------------------------------------
local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local function b58d(s)
  local b = {}
  for i = 1, #s do
    local p = B58:find(s:sub(i, i), 1, true)
    if not p then return nil, "not base58" end
    local carry = p - 1
    for j = 1, #b do carry = carry + b[j] * 58; b[j] = carry & 0xFF; carry = carry >> 8 end
    while carry > 0 do b[#b + 1] = carry & 0xFF; carry = carry >> 8 end
  end
  for i = 1, #s do if s:sub(i, i) ~= "1" then break end b[#b + 1] = 0 end
  local out = {}
  for i = #b, 1, -1 do out[#out + 1] = string.char(b[i]) end
  return table.concat(out)
end
local function b58e(bytes)
  local d = {}
  for i = 1, #bytes do
    local carry = bytes:byte(i)
    for j = 1, #d do carry = carry + d[j] * 256; d[j] = carry % 58; carry = carry // 58 end
    while carry > 0 do d[#d + 1] = carry % 58; carry = carry // 58 end
  end
  local out = {}
  for i = 1, #bytes do if bytes:byte(i) ~= 0 then break end out[#out + 1] = "1" end
  for i = #d, 1, -1 do out[#out + 1] = B58:sub(d[i] + 1, d[i] + 1) end
  return table.concat(out)
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function b64(s)
  local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  return ((s:gsub(".", function(x)
    local r, b = "", x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return A:sub(c + 1, c + 1)
  end) .. ({"", "==", "="})[#s % 3 + 1])
end

local pda_cache = {}
local function pda(seeds, program)
  local args = {}
  for _, s in ipairs(seeds) do
    assert(type(s) == "string" and #s <= 32, "pda seed <= 32 bytes")
    args[#args + 1] = hex(s)
  end
  assert(#program == 32 and #seeds <= 15, "pda args")
  local key = b58e(program) .. " " .. table.concat(args, " ")
  if not pda_cache[key] then
    local p = io.popen("python3 " .. HERE .. "/pda.py " .. key)
    local out = p:read("a")
    p:close()
    local a, bump = out:match("(%w+) (%d+)")
    pda_cache[key] = {b58d(a), tonumber(bump)}
  end
  local r = pda_cache[key]
  extra = extra + (256 - r[2]) * 5000
  return r[1], r[2]
end

local function sha256(s)
  local p = io.popen("printf '%s' '" .. s .. "' | shasum -a 256")
  local out = p:read("a")
  p:close()
  return out:sub(1, 64)
end

-- Pretend chain ----------------------------------------------------------------
local PROGRAM = "GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC"
local NOW = 1790000000
local function u64(n) return string.pack("<I8", math.tointeger(tonumber(n))) end
local function fixed(s, n) return s .. string.rep("\0", n - #s) end
local function disc(name) return require("lib.bytes").unhex(sha256("account:" .. name):sub(1, 16)) end

-- open [5 x {id, bid}]: t.slots, or made-up ones for t.open entries.
local function slots(t)
  local out = {}
  for k = 1, 5 do
    local sl = t.slots and t.slots[k] or (not t.slots and k <= t.open and {100 + k, 10000000})
    out[k] = sl and (u64(sl[1]) .. u64(sl[2])) or string.rep("\0", 16)
  end
  return table.concat(out)
end
local function enc_introer(t)
  return disc("Introer") .. t.wallet .. u64(t.min_bid) .. u64(t.next_id) .. string.pack("<I4", t.jobs)
    .. u64(t.earned) .. string.pack("<i8", t.created_at) .. string.char(t.open, 254)
    .. fixed(t.badge_id or "", 8) .. fixed(t.offer, 64) .. slots(t)
end
local function enc_request(t)
  return disc("Request") .. t.introer .. t.requester .. u64(t.id) .. u64(t.bid) .. string.char(t.status)
    .. string.pack("<i8i8i8", t.created_at or NOW, t.accepted_at or 0, t.made_at or 0) .. string.char(253)
    .. fixed(t.target, 64) .. fixed(t.telegram, 32)
end

-- Decode a legacy message the app built.
local function read_msg(m)
  local i = 1
  local function byte() local b = m:byte(i); i = i + 1; return b end
  local function len() local n, s = 0, 0; repeat local b = byte(); n = n | ((b & 0x7F) << s); s = s + 7 until b < 0x80; return n end
  local h = {byte(), byte(), byte()}
  local keys = {}
  for k = 1, len() do keys[k] = m:sub(i, i + 31); i = i + 32 end
  local blockhash = m:sub(i, i + 31); i = i + 32
  local ixs = {}
  for k = 1, len() do
    local ix = {program = keys[byte() + 1], accounts = {}}
    for a = 1, len() do ix.accounts[a] = keys[byte() + 1] end
    local n = len()
    ix.data = m:sub(i, i + n - 1); i = i + n
    ixs[k] = ix
  end
  local writable = {}
  local nk = #keys
  for k = 1, nk do
    local signed = k <= h[1]
    writable[keys[k]] = signed and k <= h[1] - h[2] or (not signed and k <= nk - h[3])
  end
  return {header = h, keys = keys, blockhash = blockhash, ixs = ixs, w = writable, done = i == #m + 1}
end

-- World ------------------------------------------------------------------------
local W
local MAX_INSTR = 200000
local worst = 0

local function callback(fn, ...)
  local n = 0
  extra = 0
  debug.sethook(function() if not paused then n = n + 100 end end, "", 100)
  local r = table.pack(pcall(fn, ...))
  debug.sethook()
  n = n + extra
  if n > worst then worst = n end
  check(n < MAX_INSTR, "callback over 200k instructions (" .. n .. ")")
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
end

local function new_world(opts)
  opts = opts or {}
  W = {ms = 0, objs = 0, labels = {}, lists = {}, qr = nil, timers = {}, toasts = {}, store = opts.store or {},
    accounts = opts.accounts or {}, rpcq = {}, rpc_times = {}, posts = {}, led = {}, hint = "", input = nil,
    confirm = nil, id = 0, mesh_sent = {}, offline = false, relay_fail = nil}
  local function obj(kind, o)
    W.objs = W.objs + 1
    check(W.objs <= 128, "more than 128 UI objects")
    o = o or {}
    o.kind, o.shown = kind, true
    function o:pos(x, y) self.x, self.y = x, y end
    function o:size() end
    function o:color() end
    function o:show(b) self.shown = b end
    function o:scale() end
    function o:remove() W.objs = W.objs - 1; self.removed = true end
    return o
  end
  _G.ui = {
    W = 320, H = 218,
    bg = function() end,
    label = function(_, _, text, o)
      check(type(text) == "string", "label text is a string")
      check(o == nil or o.size == nil or o.size == 12 or o.size == 14 or o.size == 20 or o.size == 32, "label size")
      local l = obj("label", {})
      function l:text(s) check(type(s) == "string" and #s <= 200, "label text <= 200 bytes"); self.t = s end
      l:text(text)
      W.labels[#W.labels + 1] = l
      return l
    end,
    rect = function(_, _, w, h) check(w > 0 and h > 0, "rect size") return obj("rect") end,
    image = function(_, _, rows, o)
      for _, r in ipairs(rows) do
        for c in r:gmatch(".") do check(c == "." or (o.palette and o.palette[c]), "pixel in palette: " .. c) end
      end
      return obj("image")
    end,
    list = function(_, _, _, h, items, o)
      check(h >= 36, "list height")
      local l = obj("list", {rows = items, sel = 1, on_select = o and o.on_select})
      function l:items(i) self.rows = i end
      function l:selected() return self.sel end
      function l:select(i) self.sel = i end
      W.lists[#W.lists + 1] = l
      return l
    end,
    qr = function(_, _, size, text)
      check(size >= 25 and size <= 218, "qr size")
      check(#text <= 256, "qr text <= 256 bytes")
      check(W.qr == nil, "one QR at a time")
      W.qr = obj("qr", {t = text})
      return W.qr
    end,
    hint = function(t) W.hint = t end,
    toast = function(s) W.toasts[#W.toasts + 1] = s end,
    confirm = function(msg, cb) W.confirm = cb end,
    input = function(p, n, cb) W.input = {max = n, cb = cb, prompt = p} end,
    clear = function() W.objs, W.labels, W.lists, W.qr = 0, {}, {}, nil end,
  }
  _G.led = {fill = function(r, g, b) W.led[#W.led + 1] = {r, g, b} end, off = function() W.led_off = true end}
  _G.timer = {
    after = function(ms, fn) W.id = W.id + 1; W.timers[W.id] = {at = W.ms + ms, fn = fn} return W.id end,
    every = function(ms, fn) W.id = W.id + 1; W.timers[W.id] = {at = W.ms + ms, fn = fn, every = ms} return W.id end,
    cancel = function(id) W.timers[id] = nil end,
  }
  _G.sys = {millis = function() return W.ms end, time = function() return NOW + W.ms // 1000 end}
  _G.badge = {id = function() return "7K2Q9M" end}
  _G.storage = {
    get = function(k) local v = W.store[k]; return v and json.decode(v) end,
    set = function(k, v)
      W.store[k] = json.encode(v)
      local total = 0
      for kk, vv in pairs(W.store) do total = total + #kk + #vv end
      check(total <= 16384, "storage <= 16 KB")
    end,
    remove = function(k) W.store[k] = nil end,
  }
  _G.solana = {
    encode = function(b) assert(#b <= 128); extra = extra + 20 + #b * #b // 16; return b58e(b) end,
    decode = function(s) extra = extra + 20 + #s * #s // 16; return b58d(s) end,
    pda = pda,
  }
  _G.rpc = {call = function(method, params, opts, cb)
    check(type(opts) == "table" and opts.cluster == "devnet", "rpc on devnet")
    local t = W.ms
    local n = 0
    W.rpc_times[#W.rpc_times + 1] = t
    for _, x in ipairs(W.rpc_times) do if t - x < 60000 then n = n + 1 end end
    check(n <= 30, "<= 30 rpc calls a minute")
    check(#json.encode(params) <= 2048, "rpc params <= 2 KB")
    check(params[2] and params[2].commitment == "confirmed" and params[2].encoding == "base64", "rpc confirmed base64")
    W.rpcq[#W.rpcq + 1] = {method = method, params = params, cb = cb}
  end}
  _G.http = {post = function(url, body, cb)
    check(url == "https://relay.botbotcap.com/tx", "relay url")
    check(#json.encode(body) <= 2048, "http body <= 2 KB")
    W.posts[#W.posts + 1] = {body = body, cb = cb}
  end}
  _G.mesh = {
    send = function(to, msg) check(#json.encode(msg) <= 200, "mesh msg <= 200 bytes"); W.mesh_sent[#W.mesh_sent + 1] = msg end,
    nearby = function() return {{id = "BADGE2", name = "@ana"}} end,
    info = function() return {online = true} end,
    pause = function() W.mesh_paused = true end, resume = function() W.mesh_paused = false end,
  }
  _G.json = json
  for _, m in ipairs({"lib.sol", "lib.bytes", "lib.tx", "lib.escrow", "lib.chain", "lib.demo", "lib.art"}) do
    package.loaded[m] = nil
  end
  _G.on_key, _G.on_tick, _G.on_exit, _G.on_mesh = nil, nil, nil, nil
  callback(function() dofile(APP .. "main.lua") end)
end

-- Answer every waiting rpc call from the pretend chain.
local function answer_one(q)
  local function acct(addr)
    local b = W.accounts[addr]
    return b and {data = {b64(b), "base64"}, lamports = 1, owner = PROGRAM, executable = false}
  end
  if W.offline then return callback(q.cb, false, "offline") end
  local r
  if q.method == "getAccountInfo" then
    r = {context = {slot = 1}, value = acct(q.params[1])}
  elseif q.method == "getMultipleAccounts" then
    check(#q.params[1] <= 5, "getMultipleAccounts <= 5")
    local v, parts = {}, {}
    for i, a in ipairs(q.params[1]) do v[i] = acct(a); parts[i] = v[i] and json.encode(v[i]) or "null" end
    check(#table.concat(parts, ",") <= 3500, "rpc answer <= 3.5 KB")
    r = {context = {slot = 1}, value = v}
  else
    check(false, "rpc method allowed: " .. q.method)
  end
  callback(q.cb, true, r)
end
local function flush()
  for _ = 1, 50 do
    if #W.rpcq == 0 then return end
    answer_one(table.remove(W.rpcq, 1))
  end
end
local function advance(ms)
  local stop = W.ms + ms
  while W.ms < stop do
    W.ms = W.ms + 30
    callback(on_tick, 30)
    local due = {}
    for id, t in pairs(W.timers) do if W.ms >= t.at then due[#due + 1] = id end end
    table.sort(due)
    for _, id in ipairs(due) do
      local t = W.timers[id]
      if t then
        if t.every then t.at = t.at + t.every else W.timers[id] = nil end
        callback(t.fn)
      end
    end
    flush()
  end
end
local function relay_reply(ok, res)
  for _ = 1, 20 do
    if #W.posts > 0 then break end
    advance(30)
  end
  local p = table.remove(W.posts, 1)
  assert(p, "no relay post")
  local m = require("lib.bytes").unhex(p.body.message)
  if os.getenv("DUMP") then io.open(os.getenv("DUMP"), "a"):write(p.body.message, "\n"):close() end
  callback(p.cb, ok, res or {status = 200, body = json.encode({url = "solana:https://relay.botbotcap.com/tx/abc123"})})
  return read_msg(m)
end
local function has(text)
  for _, l in ipairs(W.labels) do if l.t and l.t:find(text, 1, true) then return true end end
  return false
end
local function key(k) return callback(on_key, k) end
local function list_select(i, which)
  local l = W.lists[which or #W.lists]
  assert(l, "no list on screen")
  assert(l.rows[i], "no row " .. i)
  l.sel = i
  callback(l.on_select, i, l.rows[i])
end
local function type_in(text)
  local inp = W.input
  assert(inp, "no input open")
  W.input = nil
  callback(inp.cb, text and text:sub(1, inp.max))
end
local function go(title)
  for _ = 1, 7 do
    if has("JOB DONE!") then advance(3000) end
    if W.labels[1] and W.labels[1].t == title then return end
    key("right")
  end
  error("no tab " .. title)
end
local function last_toast() return W.toasts[#W.toasts] end

-- Units ------------------------------------------------------------------------
local sol = dofile(APP .. "lib/sol.lua")
local bytes = dofile(APP .. "lib/bytes.lua")
check(sol.format("1500000000") == "1.5" and sol.format("1") == "0", "format")
check(sol.format("123456789012345678901234567890") == "123,456,789,012,345,678,901.2345", "format huge")
check(sol.format("999999999999999999", 3) == "999,999,999.999", "format no float rounding")
check(sol.format("x") == "?" and sol.format(nil) == "?", "format junk")
check(sol.to_lamports("12.5") == "12500000000" and sol.to_lamports(".5") == "500000000", "to_lamports")
check(sol.to_lamports("0") == nil and sol.to_lamports("1.0000000001") == nil and sol.to_lamports("a") == nil, "to_lamports junk")
check(sol.add("999999999999999999999", "1") == "1000000000000000000000", "add")
check(sol.mul_div("10000000000", 800, 1000) == "8000000000", "mul_div")
check(sol.machine_value("10000000000", NOW - 86400 * 10, NOW) == "7200000000", "machine value 10 days")
check(sol.machine_value("10000000000", NOW - 86400 * 400, NOW) == "4000000000", "machine value wear floor")
check(sol.cmp("100", "99") == 1 and sol.cmp("05", "5") == 0 and sol.cmp("1", "2") == -1, "cmp")
check(bytes.u64(bytes.pack_u64("18446744073709551615"), 1) == "18446744073709551615", "u64 max round trip")
check(bytes.pack_u64("18446744073709551616") == nil, "u64 overflow refused")
check(bytes.pack_u64("12500000000") == string.pack("<I8", 12500000000), "pack_u64 matches")
check(bytes.u64(string.pack("<I8", 0), 1) == "0", "u64 zero")
for _, s in ipairs({"", "a", "ab", "abc", "abcd", "hello world!", "\0\255\1"}) do
  check(bytes.unbase64(b64(s)) == s, "base64 " .. #s)
end
check(bytes.unbase64("a") == nil and bytes.unbase64("@@@@") == nil, "base64 junk")

-- Discriminators against sha256, pdas against @solana/web3.js.
_G.solana = {decode = b58d, encode = b58e, pda = pda}
package.loaded["lib.escrow"], package.loaded["lib.bytes"] = nil, nil
local escrow = require("lib.escrow")
for _, n in ipairs({"register_introer", "update_introer", "bid", "withdraw", "accept", "decline",
  "mark_made", "confirm", "refund_unconfirmed", "refund_expired"}) do
  check(hex(escrow.DISC[n]) == sha256("global:" .. n):sub(1, 16), "discriminator " .. n)
end
check(hex(escrow.DISC.Introer) == sha256("account:Introer"):sub(1, 16), "account discriminator")
local WALLET = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
local MYI = escrow.introer_pda(b58d(WALLET))
check(b58e(MYI) == "8Q9ZeQgFAF2KrcRexhkXFUbQnwvXLzMxEKTwsTccy9L3", "introer pda (web3.js)")
check(b58e(escrow.request_pda(MYI, "3")) == "9gKzhq1KL7decnAjAj7TdM6y2rC3jmWmhr8bJxcLsc9o", "request pda (web3.js)")
local ib = enc_introer({wallet = b58d(WALLET), min_bid = "50000000", next_id = 3, jobs = 2, earned = "12345678901",
  created_at = NOW, open = 2, badge_id = "7K2Q9M", offer = "Solana devs"})
check(#ib == escrow.INTROER.size, "introer size")
local di = escrow.decode_introer(ib)
check(di and di.earned == "12345678901" and di.next_id == "3" and di.offer == "Solana devs" and di.open == 2
  and di.jobs == 2 and di.badge_id == "7K2Q9M" and di.created_at == NOW, "decode introer")
check(escrow.decode_introer(ib:sub(1, 100)) == nil and escrow.decode_introer("x" .. ib:sub(2)) == nil, "bad introer refused")
local rb = enc_request({introer = MYI, requester = string.rep("R", 32), id = 7, bid = "100000000000", status = 2,
  made_at = NOW - 5, target = "Toly", telegram = "@joe"})
check(#rb == escrow.REQUEST.size, "request size")
local dr = escrow.decode_request(rb)
check(dr and dr.bid == "100000000000" and dr.status == 2 and dr.target == "Toly" and dr.telegram == "@joe"
  and dr.id == "7" and dr.made_at == NOW - 5, "decode request")

-- The program's own instruction and account bytes (intro-bot-program tests/fixtures).
local FIX = os.getenv("FIXTURES") or (HERE .. "/../../intro-bot-program/tests/fixtures")
local function fixture(name)
  local f = io.open(FIX .. "/" .. name .. ".json")
  if not f then return nil end
  local t = json.decode(f:read("a"))
  f:close()
  return t
end
if not fixture("bid") then
  print("SKIP: no program fixtures at " .. FIX .. " (set FIXTURES)")
else
  _G.tx_lib = require("lib.tx")
  local function same(name, built)
    local f = fixture(name)
    local signer = b58d(f.accounts[1].pubkey)
    local ok = hex(built.data) == f.data_hex and b58e(built.program) == f.program_id and #built.accounts == #f.accounts
    for k, a in ipairs(f.accounts) do
      local mine = built.accounts[k]
      local key = mine and (mine[1] == _G.tx_lib.WALLET and signer or mine[1])
      ok = ok and mine and b58e(key) == a.pubkey and (a.signer == (mine[1] == _G.tx_lib.WALLET))
        and (a.signer or (mine.w == true) == a.writable)
    end
    check(ok, "fixture " .. name)
  end
  local function acc(name, k) return b58d(fixture(name).accounts[k].pubkey) end
  local function data(name) return require("lib.bytes").unhex(fixture(name).data_hex) end
  local bytes2 = require("lib.bytes")
  local wallet, requester = acc("register_introer", 1), acc("bid", 1)
  local intro = acc("register_introer", 2)
  check(escrow.introer_pda(wallet) == intro, "fixture introer pda")
  check(escrow.config_pda() == acc("bid", 2) and escrow.directory_pda() == acc("register_introer", 3), "fixture config, directory pdas")
  local d = data("register_introer")
  same("register_introer", escrow.ix_register(wallet, bytes2.text(d, 9, 8), bytes2.text(d, 17, 64), bytes2.u64(d, 81)))
  d = data("update_introer")
  same("update_introer", escrow.ix_update(wallet, bytes2.text(d, 9, 64), bytes2.u64(d, 73)))
  d = data("bid")
  check(escrow.request_pda(intro, "0") == acc("bid", 4), "fixture request pda")
  same("bid", escrow.ix_bid(intro, acc("bid", 4), bytes2.text(d, 9, 64), bytes2.text(d, 73, 32), bytes2.u64(d, 105)))
  d = data("bid_outbid")
  local ob = fixture("bid_outbid").accounts
  same("bid_outbid", escrow.ix_bid(intro, acc("bid_outbid", 4), bytes2.text(d, 9, 64), bytes2.text(d, 73, 32),
    bytes2.u64(d, 105), {pda = acc("bid_outbid", 6), requester = acc("bid_outbid", 7)}))
  check(#ob == 7, "fixture outbid: lowest and its requester only")
  same("accept", escrow.ix_accept(intro, acc("accept", 3)))
  same("mark_made", escrow.ix_made(intro, acc("mark_made", 3)))
  same("decline", escrow.ix_decline(intro, acc("decline", 3), requester))
  same("withdraw", escrow.ix_withdraw(intro, acc("withdraw", 3)))
  same("confirm", escrow.ix_confirm(intro, acc("confirm", 3), wallet))
  same("refund_unconfirmed", escrow.ix_refund("refund_unconfirmed", intro, acc("refund_unconfirmed", 3), requester))
  same("refund_expired", escrow.ix_refund("refund_expired", intro, acc("refund_expired", 3), requester))
  -- Account dumps.
  local f = io.open(FIX .. "/accounts.json")
  local dumps = json.decode(f:read("a"))
  f:close()
  local di2 = escrow.decode_introer(bytes2.unhex(dumps.introer.data_hex))
  check(di2 and di2.wallet == wallet and di2.badge_id == "BP26-001" and di2.offer ~= "", "fixture introer decodes")
  check(#di2.slots == di2.open, "fixture introer open slots")
  local dr2 = escrow.decode_request(bytes2.unhex(dumps.request.data_hex))
  check(dr2 and dr2.introer == intro and escrow.STATUS[dr2.status] and dr2.target ~= "", "fixture request decodes")
  local dd = escrow.decode_directory(bytes2.unhex(dumps.directory.data_hex))
  check(dd and dd[1] == wallet, "fixture directory decodes")
end

local acc_r = {status = 1, accepted_at = NOW - escrow.WORK_WINDOW - 1, created_at = NOW, made_at = 0}
check(#escrow.actions(acc_r, "introer", NOW) == 0 and escrow.note(acc_r, "introer", NOW):find("Too late"), "mark made deadline")
check(escrow.actions(acc_r, "requester", NOW)[2] == "refund_expired", "refund after the work window")
local lo, need = escrow.lowest({slots = {{id = "4", bid = "100"}, {id = "2", bid = "100"}, {id = "1", bid = "900"}}})
check(lo.id == "2" and need == "110", "lowest: oldest on a tie, +10%")
check(escrow.lowest({slots = {}}) == nil, "no lowest when empty")
check(select(2, escrow.lowest({slots = {{id = "1", bid = "95000000000"}}})) == "100000000000", "outbid capped at 100 SOL")
check(select(2, escrow.lowest({slots = {{id = "1", bid = "99999999999"}}})) == "100000000000", "outbid above the lowest")
check(select(2, escrow.lowest({slots = {{id = "1", bid = "100000000000"}}})) == nil, "no outbid when every bid is at the max")

-- App: introer --------------------------------------------------------------------
local ME = b58d(WALLET)
local CHAIN = {}
new_world({accounts = CHAIN})
check(W.hint:find("SELECT change"), "first launch opens Setup")
check(#W.rpcq == 0, "no rpc without a wallet")
list_select(1); type_in("bad")
check(last_toast() == "Not a Solana address", "bad wallet refused")
list_select(1); type_in(WALLET)
check(has("Intro Bot") and W.store.wallet, "wallet saved, Home")
flush()
check(has("Not an introer yet"), "not registered yet")
go("Setup")
list_select(2); type_in("Solana devs"); type_in("0.001")
check(last_toast() == "At least 0.01 SOL", "min bid floor")
list_select(2); type_in("Solana devs"); type_in("0.05")
check(has("Preparing..."), "sign: preparing")
advance(30)
local m = relay_reply(true)
check(m.done and m.header[1] == 1 and m.header[2] == 0, "message: one signer")
check(m.keys[1] == string.rep("\1", 32), "fee payer placeholder")
check(m.blockhash == string.rep("\0", 32), "blockhash left for the relay")
local ix = m.ixs[1]
check(b58e(ix.program) == PROGRAM, "register: program")
check(ix.accounts[1] == m.keys[1] and ix.accounts[2] == MYI and ix.accounts[3] == escrow.directory_pda()
  and ix.accounts[4] == string.rep("\0", 32), "register: accounts")
check(m.w[MYI] and m.w[m.keys[1]] and not m.w[string.rep("\0", 32)], "register: writable flags")
check(ix.data == escrow.DISC.register_introer .. fixed("7K2Q9M", 8) .. fixed("Solana devs", 64) .. u64(50000000), "register: data")
check(W.qr and W.qr.t == "solana:https://relay.botbotcap.com/tx/abc123", "register QR")
advance(6000)
check(has("Waiting for the"), "still waiting")
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 0, jobs = 0, earned = "0",
  created_at = NOW, open = 0, offer = "Solana devs"})
advance(6000)
check(last_toast() == "Register: done", "register landed")
check(W.hint:find("SELECT change"), "back to Setup")

-- Requests arrive.
local REQ = {}
local function put_req(id, t)
  t.introer, t.id = t.introer or MYI, id
  local addr = escrow.request_pda(t.introer, tostring(id))
  CHAIN[b58e(addr)] = enc_request(t)
  REQ[id] = addr
  return addr
end
local RQ = string.rep("\7", 32)
put_req(0, {requester = RQ, bid = "200000000", status = 0, target = "Mert", telegram = "@a"})
put_req(1, {requester = RQ, bid = "12500000000", status = 1, accepted_at = NOW, target = "Anza", telegram = "@b"})
put_req(2, {requester = RQ, bid = "100000000", status = 2, made_at = NOW, target = "Done", telegram = ""})
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 3, jobs = 4, earned = "30000000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
advance(20000)
go("Intro Bot")
check(has("23.52 SOL") and has("demo value"), "machine value from earned and wear")
check(has("Ask me about BotBot") and has("botbotcap.com"), "BotBot footer")
go("My queue")
local q = W.lists[1]
check(q and #q.rows == 3 and q.rows[1].right == "Open" and q.rows[2].right == "Accepted"
  and q.rows[3].right == "Waiting for confirm", "queue rows and status words")
check(q.rows[2].sub == "@b  12.5 SOL", "queue bid over 2^31 lamports")
list_select(1)
check(#W.lists[1].rows == 2, "open: accept, decline")
list_select(1); advance(30)
m = relay_reply(true)
ix = m.ixs[1]
check(ix.data == escrow.DISC.accept and ix.accounts[1] == m.keys[1] and ix.accounts[2] == MYI
  and ix.accounts[3] == REQ[0], "accept: accounts")
check(m.w[MYI] and m.w[REQ[0]], "accept: writable")
put_req(0, {requester = RQ, bid = "200000000", status = 1, accepted_at = NOW, target = "Mert", telegram = "@a"})
advance(6000)
check(last_toast() == "Accept: done", "accept landed")
put_req(3, {requester = RQ, bid = "70000000", status = 0, target = "Vitalik", telegram = "@v"})
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 4, jobs = 4, earned = "30000000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
advance(20000)
go("My queue")
check(W.lists[1].rows[1].title == "Vitalik" and W.lists[1].rows[2].title == "Anza"
  and W.lists[1].rows[3].title == "Mert" and W.lists[1].rows[4].title == "Done", "queue order: open first, newest")
W.lists[1].sel = 2
put_req(5, {requester = RQ, bid = "90000000", status = 0, target = "Newer", telegram = ""})
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 6, jobs = 4, earned = "30000000000",
  created_at = NOW - 86400 * 2, open = 2, offer = "Solana devs"})
advance(20000)
check(W.lists[1].rows[W.lists[1].sel].title == "Anza" and W.lists[1].rows[1].title == "Newer", "selection follows the request, not the row")
CHAIN[b58e(REQ[5])] = nil
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 4, jobs = 4, earned = "30000000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
advance(20000)
list_select(1); list_select(2); advance(30)
m = relay_reply(true)
check(m.ixs[1].data == escrow.DISC.decline and m.ixs[1].accounts[4] == RQ and m.w[RQ], "decline: requester refunded")
key("back")
list_select(2); list_select(1); advance(30)
m = relay_reply(true)
check(m.ixs[1].data == escrow.DISC.mark_made, "made")
key("back")
list_select(4)
check(has("The requester confirms to pay you."), "made: nothing to sign for the introer")
key("back")

-- Relay failure, offline.
list_select(1); list_select(1)
relay_reply(true, {status = 200, body = json.encode({url = "solana:https://relay.botbotcap.com/tx?id=a&b=1"})})
check(W.qr and W.qr.t == "solana:https%3A%2F%2Frelay.botbotcap.com%2Ftx%3Fid%3Da%26b%3D1", "query link percent-encoded")
key("back"); key("back")
list_select(1); list_select(1)
relay_reply(true, {status = 200, body = json.encode({url = "solana:https://relay.botbotcap.com.evil.io/tx/1"})})
check(has("bad relay answer"), "relay host checked")
key("back"); key("back")
list_select(1); list_select(1); advance(30)
relay_reply(true, {status = 500, body = ""})
check(has("Could not sign:") and has("relay error 500"), "relay error shown")
key("back"); key("back")
W.offline = true
advance(20000)
go("Intro Bot")
check(has("offline - showing last data"), "offline handled")
W.offline = false

-- Job done when a requester confirms.
CHAIN[b58e(REQ[2])] = nil
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 4, jobs = 5, earned = "30100000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
local function wait_for(text, ms)
  for _ = 1, ms // 30 do
    if has(text) then return true end
    advance(30)
  end
  return has(text)
end
check(wait_for("JOB DONE!", 21000), "job done animation")
check(key("right") == true and has("JOB DONE!"), "keys wait during the animation")
advance(3000)
check(#W.led > 0 and W.led_off and has("Ask me about BotBot"), "LEDs, back to Home")

-- Hire me.
go("Hire me")
check(has("Paid only when you confirm.") and has("We trust you to keep your word."), "hire me copy")
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 4, jobs = 6, earned = "30200000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
advance(21000)
check(not has("JOB DONE!") and has("Paid only when you confirm."), "job done waits off Home")
key("left"); key("left")
check(has("JOB DONE!"), "job done plays on Home")
advance(3000)
go("Setup"); list_select(2); type_in("Solana devs"); local n_t = #W.toasts; type_in(nil)
check(#W.toasts == n_t and not has("Sign on phone"), "cancelled min bid: no toast")
go("Hire me")

-- Mesh: a nearby introer, and a beacon on request.
callback(on_mesh, "BADGE2", {k = "ib", w = "Demo1ntroer1111111111111111111111111111111"})
callback(on_mesh, "BADGE3", {k = "ib", w = "nope"})
callback(on_mesh, "BADGE3", "junk")
go("Find an introer")
check(W.lists[1].rows[4] and W.lists[1].rows[4].title == "@ana" and not W.lists[1].rows[5], "nearby introer listed")
local sent = #W.mesh_sent
callback(on_mesh, "BADGE3", {k = "ib?"})
check(#W.mesh_sent == sent + 1 and W.mesh_sent[#W.mesh_sent].w == WALLET, "beacon answers a scan")

-- App: requester -------------------------------------------------------------------
local OTHER = "9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM"
local OB = b58d(OTHER)
local OI = escrow.introer_pda(OB)
CHAIN[b58e(OI)] = enc_introer({wallet = OB, min_bid = "100000000", next_id = 9, jobs = 1, earned = "0",
  created_at = NOW, open = 1, offer = "Asia VCs"})
list_select(1); type_in(OTHER)
check(has("Reading the chain..."), "introer: reading")
flush()
check(has("Asia VCs") and has("min 0.1 SOL"), "introer shown")
list_select(1); type_in("Toly"); type_in("joe"); type_in("0.05")
check(last_toast() == "Below the min bid", "below min refused")
list_select(1); type_in("Toly"); type_in("joe"); type_in("101")
check(last_toast() == "Max bid is 100 SOL", "max bid")
list_select(1); type_in("Toly"); type_in("joe"); type_in("12.5")
advance(30)
m = relay_reply(true)
ix = m.ixs[1]
local NEWR = escrow.request_pda(OI, "9")
local P = b58d(PROGRAM)
check(ix.data == escrow.DISC.bid .. fixed("Toly", 64) .. fixed("@joe", 32) .. u64(12500000000), "bid: data (12.5 SOL)")
check(ix.accounts[1] == m.keys[1] and ix.accounts[2] == escrow.config_pda() and ix.accounts[3] == OI
  and ix.accounts[4] == NEWR and ix.accounts[5] == string.rep("\0", 32) and ix.accounts[6] == P
  and ix.accounts[7] == P and #ix.accounts == 7, "bid: accounts, None as program id")
check(not m.w[escrow.config_pda()] and m.w[OI] and m.w[NEWR] and not m.w[P], "bid: writable, config read-only")
CHAIN[b58e(NEWR)] = enc_request({introer = OI, requester = string.rep("\9", 32), id = 9, bid = "12500000000",
  status = 0, target = "Toly", telegram = "@joe"})
advance(6000)
check(last_toast() == "Bid: done" and has("My requests"), "bid landed, My requests")
flush()
check(W.lists[1] and W.lists[1].rows[1].right == "Open", "my request listed")
list_select(1)
check(not W.lists[1] and has("Withdraw available in 24h"), "open: withdraw after 24h")
key("back")
advance(20000)
CHAIN[b58e(NEWR)] = enc_request({introer = OI, requester = string.rep("\9", 32), id = 9, bid = "12500000000",
  status = 0, created_at = NOW - 86400, target = "Toly", telegram = "@joe"})
advance(20000)
list_select(1)
check(W.lists[1] and W.lists[1].rows[1] == "Withdraw", "open: withdraw once 24h passed")
key("back")
-- Introer accepts and marks made long ago: confirm or refund.
CHAIN[b58e(NEWR)] = enc_request({introer = OI, requester = string.rep("\9", 32), id = 9, bid = "12500000000",
  status = 2, made_at = NOW - 73 * 3600, target = "Toly", telegram = "@joe"})
advance(20000)
list_select(1)
check(W.lists[1].rows[1] == "Confirm + pay" and W.lists[1].rows[2] == "Refund (72h passed)", "made: confirm, refund")
list_select(1); advance(30)
m = relay_reply(true)
ix = m.ixs[1]
check(ix.data == escrow.DISC.confirm and ix.accounts[1] == m.keys[1] and ix.accounts[4] == OB and m.w[OB], "confirm: pays introer wallet")
CHAIN[b58e(NEWR)] = nil
advance(6000)
check(last_toast() == "Confirm + pay: done", "confirm landed")
advance(20000)
check(has("No requests yet") and json.decode(W.store.mine)[1] == nil, "closed request dropped")

-- Someone else takes the request id first.
go("Find an introer")
list_select(1); type_in(OTHER); flush()
list_select(1); type_in("Vitalik"); type_in("me"); type_in("0.2")
advance(30); relay_reply(true)
CHAIN[b58e(escrow.request_pda(OI, "9"))] = enc_request({introer = OI, requester = RQ, id = 9, bid = "500000000",
  status = 0, target = "Someone else", telegram = ""})
CHAIN[b58e(NEWR)] = CHAIN[b58e(escrow.request_pda(OI, "9"))]
advance(6000)
check(has("Someone bid first") and has("SELECT to retry"), "someone bid first: not ours, retry offered")
check(#json.decode(W.store.mine) == 0, "their request not saved as mine")
CHAIN[b58e(OI)] = enc_introer({wallet = OB, min_bid = "100000000", next_id = 10, jobs = 1, earned = "0",
  created_at = NOW, open = 2, offer = "Asia VCs"})
key("select")
m = relay_reply(true)
check(m.ixs[1].accounts[4] == escrow.request_pda(OI, "10") and m.ixs[1].data:find("Vitalik", 1, true),
  "retry re-reads next_id and rebuilds")
key("back")
CHAIN[b58e(NEWR)] = nil

-- The on-chain list of introers.
local DIR = escrow.directory_pda()
local ring = {}
for k = 1, 32 do ring[k] = string.rep("\0", 32) end
ring[1], ring[2], ring[3] = string.rep("\5", 32), OB, ME
CHAIN[b58e(DIR)] = disc("Directory") .. string.char(3, 254) .. table.concat(ring)
go("Find an introer")
list_select(3); flush()
local found = {}
for _, r in ipairs(W.lists[1].rows) do found[r.sub] = (found[r.sub] or 0) + 1 end
check(found["on-chain list"] == 1, "directory: new introers listed, me and seen ones not twice")
local dl = escrow.decode_directory(CHAIN[b58e(DIR)])
check(#dl == 3 and dl[1] == ME and dl[2] == OB, "directory newest first")

-- No bids on yourself.
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, min_bid = "50000000", next_id = 4, jobs = 6, earned = "30200000000",
  created_at = NOW - 86400 * 2, open = 1, offer = "Solana devs"})
go("Find an introer")
list_select(1); type_in(WALLET); flush()
list_select(1)
check(last_toast() == "You can't bid on yourself" and not W.input, "no self-bid")
key("back")

-- Full queue: name the lowest open one (oldest on a tie) and beat it by 10%.
local FULL = "4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T"
local FB = b58d(FULL)
local FI = escrow.introer_pda(FB)
CHAIN[b58e(FI)] = enc_introer({wallet = FB, min_bid = "10000000", next_id = 9, jobs = 0, earned = "0",
  created_at = NOW, open = 5, offer = "Full",
  slots = {{8, 300000000}, {7, 55555555}, {3, 55555555}, {6, 400000000}, {5, 500000000}}})
put_req(3, {introer = FI, requester = string.rep("\3", 32), bid = "55555555", status = 0, target = "x", telegram = ""})
go("Find an introer")
list_select(1); type_in(FULL)
flush(); advance(100)
check(has("Full: bid at least 0.0611 SOL"), "full queue: lowest + 10%, rounded up")
list_select(1); type_in("Toly"); type_in("")
check(last_toast() == "Telegram is required" and not W.input, "telegram required")
list_select(1); type_in("Toly"); type_in("@t"); type_in("0.06111111")
check(last_toast() == "Bid at least 0.0611 SOL", "must beat lowest by 10%")
list_select(1); type_in("Toly"); type_in("t"); type_in("0.061111111")
m = relay_reply(true)
ix = m.ixs[1]
check(ix.accounts[6] == REQ[3] and ix.accounts[7] == string.rep("\3", 32) and #ix.accounts == 7, "bid: lowest (oldest on tie) and its requester")
check(m.w[REQ[3]] and m.w[string.rep("\3", 32)], "bid: lowest writable")
check(#m.ixs == 1 and #m.keys == 8, "one intro_escrow instruction only")
check(ix.data:sub(-8) == u64(61111111) and ix.data:sub(9 + 64, 9 + 66) == "@t\0", "bid: telegram gets its @")
key("back")
check(has("My requests") or has("Find an introer"), "back from signing")

-- Budget.
local calls = 0
for _, t in ipairs(W.rpc_times) do if W.ms - t < 60000 then calls = calls + 1 end end
check(calls <= 30, "rpc budget")

-- Relaunch keeps wallet and requests; bad storage is ignored.
new_world({store = {wallet = W.store.wallet, mine = W.store.mine}, accounts = CHAIN})
check(has("Intro Bot"), "relaunch opens Home")
new_world({store = {wallet = '"bad"', spark = '["x"]', mine = '[{"w":"x"}]', jobs = '"x"', recent = '[1]'}})
check(W.hint:find("SELECT change"), "bad storage ignored")

-- Demo mode: no network, every role.
new_world({store = {mock = "true"}})
check(#W.rpcq == 0 and #W.posts == 0, "demo: no network")
check(has("demo value"), "demo home")
go("My queue")
local n0 = #W.lists[1].rows
list_select(1); list_select(1)
check(W.qr and W.qr.t:find("^solana:https://relay.botbotcap.com/tx/"), "demo QR")
advance(4100)
check(last_toast() == "Accept: done", "demo accept")
go("Find an introer")
check(W.lists[1].rows[4].title == "@ana", "demo nearby")
list_select(5)
check(has("Full: bid at least 0.165 SOL"), "demo full introer")
list_select(1); type_in("Toly"); type_in("joe"); type_in("0.2")
advance(4100)
check(last_toast() == "Bid: done", "demo bid")
check(#W.lists[1].rows == 3, "demo bid listed")
list_select(1)
check(W.lists[1].rows[2] == "Refund (72h passed)", "demo refund offered")
list_select(2); advance(4100)
check(#W.lists[1].rows == 2, "demo refund")
go("Intro Bot")
local anims = 0
for _ = 1, 30 do advance(20000); if has("JOB DONE!") then anims = anims + 1; advance(3000) end end
check(#W.rpcq == 0 and #W.posts == 0, "demo: still no network")
check(n0 > 0, "demo queue")
go("Setup"); list_select(3)
check(W.store.mock == "false", "demo off")

print(string.format("%d passed, %d failed, worst callback %d instructions", passes, fails, worst))
os.exit(fails == 0 and 0 or 1)
