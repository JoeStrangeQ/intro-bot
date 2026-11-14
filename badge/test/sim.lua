-- Headless test for the badge app: stubs the Solana OS Lua API closely enough to drive
-- every screen and key path, and enforces the limits that bite (128 UI objects, 200-byte
-- labels, 256-byte QR, 16 KB storage, 200k instructions per callback).
-- Run from badge/:  lua test/sim.lua   (not part of the app: leave test/ out of the upload)
package.path = "./?.lua;" .. package.path

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

-- World --------------------------------------------------------------------
local W
local MAX_INSTR = 200000
local worst = 0

-- Run fn as one badge callback and count its VM instructions.
local function callback(fn, ...)
  local n = 0
  debug.sethook(function() if not paused then n = n + 100 end end, "", 100)
  local r = table.pack(pcall(fn, ...))
  debug.sethook()
  if n > worst then worst = n end
  check(n < MAX_INSTR, "callback over 200k instructions (" .. n .. ")")
  if not r[1] then error(r[2], 0) end
  return table.unpack(r, 2, r.n)
end

local function new_world(opts)
  opts = opts or {}
  W = {ms = 0, objs = 0, labels = {}, lists = {}, qr = nil, timers = {}, toasts = {}, store = opts.store or {},
    reqs = {}, led = {}, hint = "", input = nil, confirm = nil, id = 0}
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
    list = function(_, _, _, _, items, o)
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
    input = function(p, n, cb) W.input = {max = n, cb = cb} end,
    clear = function() W.objs, W.labels, W.lists, W.qr = 0, {}, {}, nil end,
  }
  _G.led = {fill = function(r, g, b) W.led[#W.led + 1] = {r, g, b} end, off = function() W.led_off = true end}
  _G.timer = {
    after = function(ms, fn) W.id = W.id + 1; W.timers[W.id] = {at = W.ms + ms, fn = fn} return W.id end,
    every = function(ms, fn) W.id = W.id + 1; W.timers[W.id] = {at = W.ms + ms, fn = fn, every = ms} return W.id end,
    cancel = function(id) W.timers[id] = nil end,
  }
  local n = 0
  for _ in pairs(W.timers) do n = n + 1 end
  _G.sys = {millis = function() return W.ms end, time = function() return 1790000000 end}
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
  _G.http = {get = function(url, headers, cb)
    if cb == nil then cb = headers end
    check(url:sub(1, 8) == "https://" and #url <= 512 and not url:find(" "), "http url ok")
    check(url:match("^https://([^/]+)") == "intro.botbotcap.com", "http host allowed")
    W.reqs[#W.reqs + 1] = {url = url, cb = cb}
  end}
  _G.json = json
  for _, m in ipairs({"lib.sol", "lib.feed", "lib.art"}) do package.loaded[m] = nil end
  _G.on_key, _G.on_tick, _G.on_exit = nil, nil, nil
  callback(function() dofile("main.lua") end)
end

local function key(k) return callback(on_key, k) end
local function advance(ms)
  local stop = W.ms + ms
  while W.ms < stop do
    W.ms = W.ms + 30
    callback(on_tick, 30)
    for id, t in pairs(W.timers) do
      if W.ms >= t.at then
        if t.every then t.at = t.at + t.every else W.timers[id] = nil end
        callback(t.fn)
      end
    end
  end
end
local function answer(ok, res)
  local r = table.remove(W.reqs, 1)
  assert(r, "no pending request")
  callback(r.cb, ok, res)
end
local function body(t) return {status = 200, body = json.encode(t), type = "application/json"} end
local function has(text)
  for _, l in ipairs(W.labels) do if l.t and l.t:find(text, 1, true) then return true end end
  return false
end
local function list_select(i)
  local l = W.lists[#W.lists]
  assert(l, "no list on screen")
  l.sel = i
  callback(l.on_select, i, l.rows[i])
end
local function type_in(text)
  local inp = W.input
  assert(inp, "no input open")
  W.input = nil
  callback(inp.cb, text and text:sub(1, inp.max))
end

-- sol ----------------------------------------------------------------------
package.path = "./?.lua;" .. package.path
local sol = dofile("lib/sol.lua")
check(sol.format("0") == "0", "format 0")
check(sol.format("1") == "0", "format 1 lamport truncates to 0")
check(sol.format("1500000000") == "1.5", "format 1.5 SOL")
check(sol.format("000050000000", 3) == "0.05", "format leading zeros")
check(sol.format("123456789012345678901234567890") == "123,456,789,012,345,678,901.2345", "format huge string")
check(sol.format("999999999999999999", 3) == "999,999,999.999", "format no float rounding")
check(sol.format(-5) == "?" and sol.format("12a") == "?" and sol.format(nil) == "?" and sol.format("") == "?", "format rejects junk")
check(sol.format(string.rep("9", 31)) == "?", "format rejects > 30 digits")
check(sol.to_lamports("0.05") == "50000000", "to_lamports 0.05")
check(sol.to_lamports("2") == "2000000000" and sol.to_lamports(".5") == "500000000", "to_lamports int and .5")
check(sol.to_lamports("0") == nil and sol.to_lamports("abc") == nil and sol.to_lamports("1.0000000001") == nil
  and sol.to_lamports("") == nil and sol.to_lamports(".") == nil, "to_lamports rejects junk")
check(sol.add("999999999999999999999", "1") == "1000000000000000000000", "add carries past 2^64")
check(sol.milli("12345678901234567890") > 0, "milli of a big value")
check(sol.is_wallet("7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"), "valid wallet")
check(not sol.is_wallet("0OIl" .. string.rep("1", 40)) and not sol.is_wallet("abc") and not sol.is_wallet(nil), "invalid wallets")
check(sol.urlencode("a b&c/é") == "a%20b%26c%2F%C3%A9", "urlencode")

-- App ----------------------------------------------------------------------
local WALLET = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
local DATA = {v = "1234567890123", j = 2, e = "3000000000", n = "50000000", q = {
  {i = "Req1", t = "Mert @ Helius", g = "mert", b = "250000000", s = "open"},
  {i = "Req2", t = "Anza", g = "@anza", b = "100000000", s = "active"},
  {i = "Req3", t = "Done one", g = "", b = "1", s = "made"},
  {i = "bad id/../x", t = "Dropped", g = "", b = "1", s = "open"},
}}

-- First launch: Setup, wallet entry.
new_world()
check(W.hint:find("SELECT change"), "first launch opens Setup")
check(#W.reqs == 0, "no request without a wallet")
list_select(1); type_in("not a wallet")
check(W.toasts[#W.toasts] == "Not a Solana address", "bad wallet refused")
list_select(1); type_in(nil)
list_select(1); type_in(WALLET)
check(W.store.wallet ~= nil and W.hint:find("LEFT/RIGHT"), "wallet saved, Home shown")
check(#W.reqs == 1 and W.reqs[1].url == "https://intro.botbotcap.com/api/badge/" .. WALLET, "polls the badge API")
check(has("loading"), "loading shown")
answer(true, body(DATA))
check(has("1,234.567 SOL"), "machine value shown")
check(has("demo value"), "labelled demo value")
check(has("0.05 SOL"), "next min bid shown")
check(has("Ask me about BotBot") and has("botbotcap.com"), "BotBot footer")
advance(3000)
check(has("updated 3s ago"), "updated time ticks")

-- Errors keep the last data.
advance(17000)
check(#W.reqs == 1, "polls every 20 s")
answer(false, "offline")
check(has("offline - showing last data") and has("1,234.567 SOL"), "offline handled")
advance(20000); answer(true, {status = 500, body = "oops"})
check(has("server error 500"), "server error handled")
advance(20000); answer(true, {status = 200, body = "{bad", truncated = false})
check(has("bad answer"), "bad JSON handled")
advance(20000); answer(true, {status = 200, body = "{}", truncated = true})
check(has("answer too big"), "truncated handled")
advance(20000); answer(true, {status = 200, body = ""})
check(has("empty answer"), "empty body handled")
advance(20000); answer(true, body({v = {}, j = "x", q = {}}))
check(has("bad answer"), "answer without jobs refused")
advance(20000); answer(true, body({v = {}, j = 2, q = {"no", {i = {}}, 5}}))
check(has("0 SOL") and not has("JOB DONE!"), "junk fields become zero")

-- Hire me QR.
key("right")
check(W.qr and W.qr.t == "https://intro.botbotcap.com/b/" .. WALLET, "hire QR")
-- Queue, actions, QR.
advance(20000); answer(true, body(DATA))
key("right")
local q = W.lists[1]
check(q and #q.rows == 3 and q.rows[1].sub == "@mert  0.25 SOL" and q.rows[1].right == "open", "queue rows")
list_select(1)
check(#W.lists[1].rows == 2, "open request: accept, decline")
list_select(1)
check(W.qr and W.qr.t == "solana:https://intro.botbotcap.com/api/tx/accept?request=Req1", "accept QR")
check(key("back") == true and #W.lists == 1, "back to actions")
list_select(2)
check(W.qr.t:find("/api/tx/decline%?request=Req1"), "decline QR")
key("back"); key("back")
list_select(2); list_select(1)
check(W.qr.t:find("/api/tx/made%?request=Req2"), "made QR")
key("back"); key("back")
list_select(3)
check(has("Nothing to sign here."), "made request has no actions")
key("back")
check(W.hint:find("SELECT open"), "back to queue")
-- Queue updates in place.
advance(20000)
local more = {v = DATA.v, j = 2, n = DATA.n, q = {DATA.q[1]}}
answer(true, body(more))
check(#W.lists[1].rows == 1, "queue refreshes")
advance(20000); answer(true, body({v = "1", j = 2, n = "1", q = {}}))
check(has("No requests yet"), "empty queue")

-- Job done.
key("left"); key("left")
advance(20000); answer(true, body({v = "2000000000", j = 3, n = "1", q = {}}))
check(has("JOB DONE!") and has("+1 intro made"), "job done animation")
check(key("right") == true and has("JOB DONE!"), "keys wait during the animation")
advance(3000)
check(#W.led > 0 and W.led_off, "LEDs flash and turn off")
check(not has("JOB DONE!") and has("2 SOL"), "back to Home after the animation")
check(not has("JOB DONE!"), "no repeat on same jobs")

-- A job landing while typing waits for the keyboard to close.
key("left"); list_select(1)
advance(20000); answer(true, body({v = "2000000000", j = 4, n = "1", q = {}}))
check(not has("JOB DONE!"), "no animation behind the keyboard")
type_in(nil)
check(has("JOB DONE!"), "animation after the keyboard closes")
advance(3000); key("right")

-- Tabs wrap; CANCEL on a tab exits.
key("left"); check(W.hint:find("SELECT change"), "left from Home is Setup")
key("right"); key("select"); check(W.qr ~= nil, "SELECT on Home opens Hire me")
check(key("back") == false, "CANCEL on a tab exits")

-- Register QR.
key("right"); key("right")
list_select(2); type_in("Solana core devs & VCs"); type_in("abc")
check(W.toasts[#W.toasts] == "Use a number like 0.05", "bad min bid refused")
list_select(2); type_in(nil)
list_select(2); type_in("Solana core devs & VCs"); type_in("0.05")
check(W.qr and W.qr.t == "solana:https://intro.botbotcap.com/api/tx/register?badge=7K2Q9M&offer=Solana%20core%20devs%20%26%20VCs&min=50000000", "register QR")
key("back")
check(W.hint:find("SELECT change"), "back to Setup")

-- Clear wallet.
list_select(4); callback(W.confirm, false)
check(W.store.wallet ~= nil, "clear cancelled")
list_select(4); callback(W.confirm, true)
check(W.store.wallet == nil and W.store.last == nil, "wallet cleared")
check(W.lists[1].rows[1].right == "not set", "Setup shows no wallet")

-- Relaunch keeps data; stale answers after a wallet change are dropped.
local store = W.store
store.wallet = json.encode(WALLET)
new_world({store = store})
check(W.hint:find("LEFT/RIGHT"), "relaunch with wallet opens Home")
key("left"); list_select(3)  -- demo on, while a real request is pending
check(W.store.mock == "true", "demo saved")
local stale = W.reqs[1]
callback(stale.cb, true, body({v = "1", j = 99, n = "1", q = {}}))
check(not has("JOB DONE!"), "stale answer ignored")

-- Demo mode runs without the API, with job-done animations.
key("right")
local before = #W.reqs
advance(6000)
local jobs0 = json.decode(W.store.jobs)
advance(240000)
local anims = json.decode(W.store.jobs) - jobs0
check(#W.reqs == before, "demo mode makes no requests")
check(anims >= 3, "demo jobs finish (" .. anims .. ")")
check(has("SOL") and not has("-- SOL"), "demo value shown")
local sp = json.decode(W.store.spark)
check(#sp == 24, "sparkline keeps 24 points")
key("right"); check(W.qr.t == "https://intro.botbotcap.com/b/" .. WALLET, "demo hire QR")
key("right"); check(W.lists[1] and #W.lists[1].rows >= 1, "demo queue")

-- Fresh demo launch without a wallet.
new_world({store = {mock = "true"}})
check(W.hint:find("LEFT/RIGHT") and #W.reqs == 0, "demo without wallet opens Home")
key("right"); check(W.qr.t == "https://intro.botbotcap.com", "hire QR without wallet is the board")

-- Bad stored data is ignored.
new_world({store = {wallet = '"bad"', spark = '["x"]', last = '"junk"', jobs = '"x"'}})
check(W.hint:find("SELECT change"), "bad stored wallet ignored")

-- Worst case answer: 5 long rows, max-size body.
new_world({store = {wallet = json.encode(WALLET)}})
local big = {v = string.rep("9", 30), j = 2147483647, e = string.rep("9", 30), n = string.rep("9", 30), q = {}}
for k = 1, 50 do
  big.q[k] = {i = string.rep("i", 64), t = string.rep("é", 200), g = string.rep("g", 300), b = string.rep("9", 30), s = "OPEN"}
end
local b = body(big)
answer(true, b)
key("right"); key("right")
check(#W.lists[1].rows == 5, "queue capped at 5")
list_select(1); list_select(1)
check(W.qr ~= nil, "long ids still fit in a QR")

print(string.format("%d passed, %d failed, worst callback %d instructions", passes, fails, worst))
os.exit(fails == 0 and 0 or 1)
