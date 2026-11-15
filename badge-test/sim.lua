-- Headless test for the Intro Bot badge app. Stubs the Solana OS Lua API (ui, rpc, http,
-- storage, timer, sys, led, solana) with a pretend chain, drives every screen and key
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
local TX_ID = string.rep("ab", 16)
local TX_URL = "solana:https://relay.botbotcap.com/tx/" .. TX_ID
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
local ZERO = string.rep("\0", 32)

-- A ring of n keys written oldest first, as the program does: returns slots, head.
local function ring(list, n)
  local slots = {}
  for k = 1, n do slots[k] = ZERO end
  local head = 0
  for _, key in ipairs(list) do slots[head + 1] = key; head = (head + 1) % n end
  return table.concat(slots), head
end

-- t.offers oldest first.
local function enc_job(t)
  local offers, head = ring(t.offers or {}, 16)
  return disc("Job") .. t.requester .. u64(t.nonce) .. u64(t.serial or 1) .. u64(t.bid) .. string.char(t.status or 0)
    .. string.pack("<i8i8i8", t.created_at or NOW, t.approved_at or 0, t.made_at or 0)
    .. (t.approved or ZERO) .. string.pack("<I2", t.offer_count or #(t.offers or {}))
    .. fixed(t.who, 32) .. fixed(t.company, 32) .. fixed(t.telegram, 32) .. string.char(255, head) .. offers
end
local function enc_introer(t)
  return disc("Introer") .. t.wallet .. fixed(t.badge_id or "", 8) .. fixed(t.name or "", 32)
    .. string.pack("<I4", t.jobs or 0) .. u64(t.earned or 0) .. string.pack("<i8", t.created_at or NOW)
    .. string.char(254)
end
local function enc_offer(job, introer)
  return disc("Offer") .. job .. introer .. u64(1) .. string.pack("<i8", NOW) .. string.char(253)
end
-- jobs oldest first.
local function enc_board(jobs)
  local slots, head = ring(jobs, 64)
  return disc("Board") .. string.char(head, 252) .. string.rep("\0", 6) .. u64(#jobs) .. slots
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
    accounts = opts.accounts or {}, rpcq = {}, rpc_times = {}, posts = {}, whos = {}, led = {}, hint = "", input = nil,
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
    check(type(opts) == "table" and opts.cluster == "mainnet", "rpc on mainnet")
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
  end, get = function(url, cb)
    check(url == "https://relay.botbotcap.com/tx/" .. TX_ID .. "/who", "who url")
    W.whos[#W.whos + 1] = cb
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
  callback(p.cb, ok, res or {status = 200, body = json.encode({url = TX_URL})})
  return read_msg(m), p.body.pdas
end
-- The relay's "who" poll: nobody yet, then the wallet that scanned.
local function scanned_by(wallet)
  advance(2000)
  local w = table.remove(W.whos, 1)
  assert(w, "no who poll")
  callback(w, true, {status = 200, body = '{"wallet":null}'})
  advance(2000)
  w = table.remove(W.whos, 1)
  assert(w, "no second who poll")
  callback(w, true, {status = 200, body = json.encode({wallet = wallet})})
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
check(sol.format("1500000000") == "1.5" and sol.to_lamports("12.5") == "12500000000", "sol math")
check(bytes.u64(bytes.pack_u64("18446744073709551615"), 1) == "18446744073709551615", "u64 round trip")

_G.solana = {decode = b58d, encode = b58e, pda = pda}
package.loaded["lib.escrow"], package.loaded["lib.bytes"], package.loaded["lib.tx"] = nil, nil, nil
local escrow = require("lib.escrow")
local txlib = require("lib.tx")
local W8 = txlib.WALLET
for _, n in ipairs({"register_introer", "update_introer", "post_job", "cancel_job", "offer", "withdraw_offer",
  "close_offer", "approve", "mark_made", "confirm", "refund_unconfirmed", "refund_expired"}) do
  check(hex(escrow.DISC[n]) == sha256("global:" .. n):sub(1, 16), "discriminator " .. n)
end
for _, n in ipairs({"Introer", "Job", "Offer", "Board"}) do
  check(hex(escrow.DISC[n]) == sha256("account:" .. n):sub(1, 16), "account discriminator " .. n)
end

local WALLET = "7xKXtg2CW87d97TXJSDpbD5jBkheTqA83TZRuJosgAsU"
local ME = b58d(WALLET)
local OTHER = b58d("9WzDXwBbmkg8ZTbNMqUxvQRAyrZzDsGYdLVL9zYtAWWM")
local THIRD = b58d("4Nd1mBQtrMJVYVfKf2PJy9NZUZdTAsp7D4xWLs4gDB4T")
local RQ = string.rep("\7", 32)

local jb = enc_job({requester = RQ, nonce = 1790000001, bid = "12500000000", status = 1, approved = OTHER,
  approved_at = NOW - 5, offers = {OTHER, THIRD}, who = "Toly", company = "Solana Labs", telegram = "@rq"})
check(#jb == escrow.JOB.size, "job size")
local dj = escrow.decode_job(jb)
check(dj and dj.requester == RQ and dj.nonce == "1790000001" and dj.bid == "12500000000" and dj.status == 1
  and dj.approved == OTHER and dj.approved_at == NOW - 5 and dj.offer_count == 2 and dj.offers[1] == THIRD
  and dj.offers[2] == OTHER and dj.who == "Toly" and dj.company == "Solana Labs" and dj.telegram == "@rq",
  "decode job: offers newest first")
local many = {}
for k = 1, 20 do many[k] = string.char(k):rep(32) end
local dm = escrow.decode_job(enc_job({requester = RQ, nonce = 1, bid = "1", offers = many, who = "a", company = "b", telegram = "c"}))
local holes = enc_job({requester = RQ, nonce = 1, bid = "1", offers = {OTHER, THIRD, ME}, offer_count = 2, who = "a", company = "b", telegram = "c"})
holes = holes:sub(1, 221 + 32) .. string.rep("\0", 32) .. holes:sub(221 + 65)  -- THIRD withdrawn
local dh = escrow.decode_job(holes)
check(#dh.offers == 2 and dh.offers[1] == ME and dh.offers[2] == OTHER, "withdrawn offer: hole skipped")
check(#dm.offers == 16 and dm.offers[1] == many[20] and dm.offers[16] == many[5] and dm.offer_count == 20, "offer ring wraps at 16")
check(escrow.decode_job(jb:sub(1, 219)) == nil and escrow.decode_job("x" .. jb:sub(2)) == nil, "bad job refused")
local listed = escrow.decode_job(jb:sub(1, escrow.JOB.LIST))
check(listed and listed.who == "Toly" and listed.offer_count == 2 and #listed.offers == 0, "board slice: no offers ring")
local di = escrow.decode_introer(enc_introer({wallet = ME, badge_id = "7K2Q9M", name = "Joe", jobs = 3, earned = "4000000000"}))
check(di and di.wallet == ME and di.name == "Joe" and di.jobs == 3 and di.earned == "4000000000" and di.badge_id == "7K2Q9M", "decode introer")
local do_ = escrow.decode_offer(enc_offer(RQ, ME))
check(do_ and do_.job == RQ and do_.introer == ME, "decode offer")
local db = escrow.decode_board(enc_board({OTHER, THIRD}))
check(db and #db == 2 and db[1] == THIRD and db[2] == OTHER, "decode board: newest first")
check(#escrow.actions({status = 0, created_at = NOW - 3600}, "requester", nil, NOW) == 1 and #escrow.actions({status = 0, created_at = NOW - 60}, "requester", nil, NOW) == 0, "open job: cancel after 1h")
check(escrow.actions({status = 2, made_at = NOW - 73 * 3600}, "requester", nil, NOW)[2] == "refund_unconfirmed", "made 72h: refund")
check(escrow.actions({status = 1, approved_at = NOW - 8 * 86400}, "requester", nil, NOW)[2] == "refund_expired", "approved 7d: refund")
check(escrow.actions({status = 1, approved = ME, approved_at = NOW}, "introer", ME, NOW)[1] == "mark_made", "picked: mark made")
check(#escrow.actions({status = 1, approved = ME, approved_at = NOW - 8 * 86400}, "introer", ME, NOW) == 0, "mark made deadline")
check(escrow.actions({status = 1, approved = OTHER}, "introer", ME, NOW)[1] == "withdraw_offer", "not picked: withdraw offer")

-- The program's own instruction and account bytes (tests/fixtures, or FIXTURES=<dir>).
local FIX = os.getenv("FIXTURES") or (HERE .. "/../tests/fixtures")
local function fixture(name)
  local f = io.open(FIX .. "/" .. name .. ".json")
  if not f then return nil end
  local t = json.decode(f:read("a"))
  f:close()
  return t
end
if not fixture("post_job") then
  print("SKIP: no v2 program fixtures at " .. FIX .. " (set FIXTURES)")
else
  local function same_ix(name, built)
    local f = fixture(name)
    local signer = b58d(f.accounts[1].pubkey)
    local ok = hex(built.data) == f.data_hex and b58e(built.program) == f.program_id and #built.accounts == #f.accounts
    for k, a in ipairs(f.accounts) do
      local mine = built.accounts[k]
      local key = mine and (mine[1] == W8 and signer or mine[1])
      ok = ok and mine and b58e(key) == a.pubkey
        and (k ~= 1 or a.signer) and (k == 1 or a.signer or (mine.w == true) == a.writable)
    end
    check(ok, "fixture " .. name)
  end
  local function acc(name, k) return b58d(fixture(name).accounts[k].pubkey) end
  local function data(name) return bytes.unhex(fixture(name).data_hex) end
  local wallet, requester = acc("register_introer", 1), acc("post_job", 1)
  check(escrow.introer_pda(wallet) == acc("register_introer", 2), "fixture introer pda")
  check(escrow.config_pda() == acc("post_job", 2) and escrow.board_pda() == acc("post_job", 3), "fixture config, board pdas")
  local d = data("register_introer")
  same_ix("register_introer", escrow.ix_register(wallet, bytes.text(d, 9, 8), bytes.text(d, 17, 32)))
  d = data("update_introer")
  same_ix("update_introer", escrow.ix_update(wallet, bytes.text(d, 9, 8), bytes.text(d, 17, 32)))
  d = data("post_job")
  local job, nonce = acc("post_job", 4), bytes.u64(d, 9)
  check(escrow.job_pda(requester, nonce) == job, "fixture job pda")
  same_ix("post_job", escrow.ix_post_job(job, nonce, bytes.text(d, 17, 32), bytes.text(d, 49, 32),
    bytes.text(d, 81, 32), bytes.u64(d, 113)))
  same_ix("cancel_job", escrow.ix_cancel_job(acc("cancel_job", 2)))
  -- Offers are ["offer", job, serial, wallet]: find each fixture's job serial.
  local function serial_of(job, w, offer)
    for n = 0, 20 do if escrow.offer_pda(job, tostring(n), w) == offer then return tostring(n) end end
  end
  local s1 = serial_of(acc("offer", 4), wallet, acc("offer", 5))
  check(s1, "fixture offer pda: [offer, job, serial, wallet]")
  same_ix("offer", escrow.ix_offer(wallet, acc("offer", 4), s1))
  local s2 = serial_of(acc("withdraw_offer", 3), wallet, acc("withdraw_offer", 2))
  same_ix("withdraw_offer", escrow.ix_withdraw_offer(wallet, acc("withdraw_offer", 3), s2))
  local s3 = serial_of(acc("close_offer", 4), acc("close_offer", 3), acc("close_offer", 2))
  same_ix("close_offer", escrow.ix_close_offer(acc("close_offer", 4), s3, acc("close_offer", 3)))
  local s4 = serial_of(acc("approve", 2), wallet, acc("approve", 3))
  same_ix("approve", escrow.ix_approve(acc("approve", 2), s4, wallet))
  same_ix("mark_made", escrow.ix_mark_made(acc("mark_made", 2)))
  same_ix("confirm", escrow.ix_confirm(acc("confirm", 2), acc("confirm", 4)))
  same_ix("refund_expired", escrow.ix_refund("refund_expired", acc("refund_expired", 2)))
  same_ix("refund_unconfirmed", escrow.ix_refund("refund_unconfirmed", acc("refund_unconfirmed", 2)))
  local f = io.open(FIX .. "/accounts.json")
  local dumps = json.decode(f:read("a"))
  f:close()
  local x = escrow.decode_introer(bytes.unhex(dumps.introer.data_hex))
  check(x and x.wallet == wallet and x.name ~= "", "fixture introer decodes")
  local j = escrow.decode_job(bytes.unhex(dumps.job.data_hex))
  check(j and j.requester == requester and j.who ~= "" and j.telegram ~= "" and #j.offers == math.min(j.offer_count, 16)
    and j.offer_count >= 1, "fixture job decodes, with its offers")
  local o = escrow.decode_offer(bytes.unhex(dumps.offer.data_hex))
  check(o and o.job == b58d(dumps.job.pubkey) and o.job_serial == j.serial, "fixture offer decodes")
  local bd = escrow.decode_board(bytes.unhex(dumps.board.data_hex))
  check(bd and bd[1] == b58d(dumps.job.pubkey), "fixture board decodes: newest job first")
end

-- App ----------------------------------------------------------------------------
local CHAIN = {}
local P = b58d(escrow.PROGRAM_ID)
local SYS = string.rep("\0", 32)
local MYI = escrow.introer_pda(ME)
local BOARD = escrow.board_pda()
local CONFIG = escrow.config_pda()
local board_jobs = {}
local function put_job(t)
  local pda = escrow.job_pda(t.requester, tostring(t.nonce))
  CHAIN[b58e(pda)] = enc_job(t)
  return pda
end
local function on_board(pda)
  board_jobs[#board_jobs + 1] = pda
  CHAIN[b58e(BOARD)] = enc_board(board_jobs)
end
local function same(a, b)
  if #a ~= #b then return false end
  for k = 1, #a do if a[k] ~= b[k] then return false end end
  return true
end

new_world({accounts = CHAIN})
check(has("Intro Bot") and has("Robots that earn"), "splash: the B and the CTA")
advance(1600)
check(W.labels[1] and W.labels[1].t == "Intro board" and W.lists[1] and W.lists[1].rows[1].title == "+ Request an intro",
  "opens on the board, Request an intro first")
flush()
check(W.lists[1].rows[1].title == "+ Request an intro", "request row stays on top")

-- Post a job: who, company, bid, Telegram, then one QR. No wallet asked.
list_select(1)
check(W.input and W.input.prompt == "Who do you want to meet?", "asks who first, no wallet")
type_in("Toly"); type_in("Solana Labs"); type_in("0.001")
check(last_toast() == "At least 0.01 SOL", "bid floor")
list_select(1); type_in("Toly"); type_in("Solana Labs"); type_in("101")
check(last_toast() == "At most 100 SOL", "bid cap")
list_select(1); type_in("Toly"); type_in(""); 
check(not W.input, "empty company backs out")
list_select(1); type_in("Toly"); type_in("Solana Labs"); type_in("12.5")
check(W.input and W.input.prompt == "Your Telegram @handle", "asks Telegram once")
type_in("")
check(last_toast() == "Telegram is required", "Telegram required")
list_select(1); type_in("Toly"); type_in("Solana Labs"); type_in("12.5"); type_in("joe")
local m, pdas = relay_reply(true)
local ix = m.ixs[1]
local nonce = tostring(string.unpack("<I8", ix.data, 9))
check(tonumber(nonce) >= NOW, "nonce is the time")
local HOLD = txlib.PDA[1]
check(m.keys[1] == W8 and #m.ixs == 1 and b58e(ix.program) == escrow.PROGRAM_ID, "one intro_escrow instruction")
check(same(ix.accounts, {m.keys[1], CONFIG, BOARD, HOLD, SYS}), "post_job: the job is the relay's stand-in")
check(m.w[BOARD] and m.w[HOLD] and not m.w[CONFIG], "post_job: writable")
local hex = require("lib.bytes").hex
check(pdas and #pdas == 1 and m.keys[pdas[1].at + 1] == HOLD and same(pdas[1].seeds,
  {hex("job"), "wallet", hex(u64(nonce))}), "post_job: job seeds for the relay")
local MYJOB = escrow.job_pda(ME, nonce)
check(ix.data == escrow.DISC.post_job .. u64(nonce) .. fixed("Toly", 32) .. fixed("Solana Labs", 32)
  .. fixed("@joe", 32) .. u64(12500000000), "post_job: data (12.5 SOL)")
check(W.qr and W.qr.t == TX_URL, "post QR")
scanned_by(WALLET); flush()
check(W.store.wallet == json.encode(WALLET), "wallet learned from the scan")
CHAIN[b58e(MYJOB)] = enc_job({requester = ME, nonce = nonce, bid = "12500000000", who = "Toly",
  company = "Solana Labs", telegram = "@joe"})
on_board(MYJOB)
advance(6000)
check(last_toast() == "Posted!" and has("My jobs"), "posted, My jobs")
flush()
check(W.lists[1] and W.lists[1].rows[1].title == "Toly @ Solana Labs" and W.lists[1].rows[1].right == "Open", "my job listed")
check(W.store.tg == '"@joe"', "Telegram remembered")
go("Request an intro")
list_select(1); type_in("Mert"); type_in("Helius"); type_in("0.2")
check(not W.input or W.input.prompt ~= "Your Telegram @handle", "remembered Telegram not asked again")
key("back")

-- The board.
local JOB2 = put_job({requester = OTHER, nonce = 7, bid = "300000000", who = "Vitalik", company = "Ethereum",
  telegram = "@other", offers = {THIRD}})
on_board(JOB2)
go("Intro board"); advance(20000)
local rows = W.lists[1].rows
check(#rows == 3 and rows[1].title == "+ Request an intro" and rows[2].title == "Vitalik @ Ethereum"
  and rows[2].sub:find("1 offer", 1, true) and rows[3].title == "Toly @ Solana Labs", "board: newest first, offers counted")
check(not rows[2].sub:find("@other", 1, true), "board hides Telegram")
list_select(3)
check(has("Your job: see My jobs."), "own job: no offer")
key("back")
list_select(2)
check(has("Telegram shown after you offer.") and not has("@other"), "Telegram hidden before offering")
list_select(1)
check(last_toast() == "Register in Profile first", "offer needs a profile")
key("back")

-- Register as an introer.
go("Profile"); advance(20000)
check(has("Not an introer yet") and has("demo value"), "profile: not an introer")
list_select(2); type_in("Joe")
m = relay_reply(true)
ix = m.ixs[1]
check(same(ix.accounts, {m.keys[1], MYI, SYS}) and ix.data == escrow.DISC.register_introer
  .. fixed("7K2Q9M", 8) .. fixed("Joe", 32), "register_introer")
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, badge_id = "7K2Q9M", name = "Joe"})
advance(6000)
check(last_toast() == "Register: done", "registered")
flush()

-- Offer on Vitalik's job.
go("Intro board")
list_select(2); list_select(1)
m = relay_reply(true)
ix = m.ixs[1]
local MYOFFER = escrow.offer_pda(JOB2, "1", ME)
check(same(ix.accounts, {m.keys[1], CONFIG, MYI, JOB2, MYOFFER, SYS}) and ix.data == escrow.DISC.offer, "offer: accounts")
check(m.w[JOB2] and m.w[MYOFFER] and not m.w[MYI], "offer: writable")
CHAIN[b58e(MYOFFER)] = enc_offer(JOB2, ME)
put_job({requester = OTHER, nonce = 7, bid = "300000000", who = "Vitalik", company = "Ethereum",
  telegram = "@other", offers = {THIRD, ME}})
advance(6000)
check(last_toast() == "Offer: done" and has("My offers"), "offered, My offers")
flush()
check(W.lists[1].rows[1].right == "Waiting" and W.lists[1].rows[1].sub:find("@other", 1, true), "my offer shows Telegram")
go("Intro board"); list_select(2)
check(has("You offered. Talk on Telegram:") and has("@other"), "job shows Telegram after offering")
key("back")

-- Someone offers on my job; I approve them.
put_job({requester = ME, nonce = nonce, bid = "12500000000", who = "Toly", company = "Solana Labs",
  telegram = "@joe", offers = {OTHER, THIRD}})
go("My jobs"); advance(20000)
list_select(1); advance(200)
check(not W.lists[1].rows[3] and has("Cancel available in"), "cancel hidden for the first hour")
key("back")
put_job({requester = ME, nonce = nonce, bid = "12500000000", who = "Toly", company = "Solana Labs",
  telegram = "@joe", offers = {OTHER, THIRD}, created_at = NOW - 3600})
CHAIN[b58e(escrow.introer_pda(OTHER))] = enc_introer({wallet = OTHER, name = "Ana", jobs = 7, earned = "2400000000"})
go("My jobs"); advance(20000)
list_select(1); advance(200)
check(has("Pick one after talking on Telegram:"), "offer pool")
local pool = W.lists[1].rows
check(pool[1].title:find("Approve", 1, true) and pool[2].title == "Approve Ana" and pool[2].sub == "jobs 7   earned 2.4 SOL"
  and pool[3].title == "Cancel job", "pool: names, jobs, earned, then cancel")
list_select(2)
m = relay_reply(true)
ix = m.ixs[1]
check(same(ix.accounts, {m.keys[1], MYJOB, escrow.offer_pda(MYJOB, "1", OTHER)}) and ix.data == escrow.DISC.approve
  and m.w[MYJOB], "approve: accounts, no args")
put_job({requester = ME, nonce = nonce, bid = "12500000000", status = 1, approved = OTHER, approved_at = NOW,
  who = "Toly", company = "Solana Labs", telegram = "@joe", offers = {OTHER, THIRD}})
advance(6000)
check(last_toast() == "Approve: done", "approved")
flush()
list_select(1)
check(has("Picked: Ana") and W.lists[1].rows[1].title == "Confirm + pay", "approved: picked, confirm")
list_select(1)
m = relay_reply(true)
ix = m.ixs[1]
check(same(ix.accounts, {m.keys[1], MYJOB, escrow.introer_pda(OTHER), OTHER}) and m.w[OTHER]
  and m.w[escrow.introer_pda(OTHER)] and ix.data == escrow.DISC.confirm, "confirm: pays the picked introer")
key("back")
-- Made long ago: refund my own job, the signer twice as one key.
put_job({requester = ME, nonce = nonce, bid = "12500000000", status = 2, approved = OTHER, made_at = NOW - 73 * 3600,
  who = "Toly", company = "Solana Labs", telegram = "@joe", offers = {OTHER}})
go("My jobs"); advance(20000)
list_select(1)
check(has("Made? Confirm to pay.") and W.lists[1].rows[2].title == "Refund (72h passed)", "made: confirm or refund")
list_select(2)
m = relay_reply(true)
ix = m.ixs[1]
check(same(ix.accounts, {m.keys[1], MYJOB, m.keys[1]}) and #m.keys == 3, "own refund: placeholder once")
CHAIN[b58e(MYJOB)] = nil
advance(6000)
check(last_toast() == "Refund (72h passed): done", "refund landed")
advance(20000); flush()
check(has("No jobs yet") and json.decode(W.store.mine)[1] == nil, "closed job dropped")

-- I get picked on Vitalik's job: mark made, then a receipt.
put_job({requester = OTHER, nonce = 7, bid = "300000000", status = 1, approved = ME, approved_at = NOW,
  who = "Vitalik", company = "Ethereum", telegram = "@other", offers = {THIRD, ME}})
go("My offers"); advance(20000)
check(W.lists[1].rows[1].right == "You!", "picked")
list_select(1)
check(W.lists[1].rows[1] == "Intro made" and has("@other"), "picked: mark made, Telegram shown")
list_select(1)
m = relay_reply(true)
check(same(m.ixs[1].accounts, {m.keys[1], JOB2}) and m.ixs[1].data == escrow.DISC.mark_made, "mark_made")
put_job({requester = OTHER, nonce = 7, bid = "300000000", status = 2, approved = ME, made_at = NOW,
  who = "Vitalik", company = "Ethereum", telegram = "@other", offers = {THIRD, ME}})
advance(6000)
check(last_toast() == "Intro made: done", "made landed")
CHAIN[b58e(JOB2)] = nil
CHAIN[b58e(MYI)] = enc_introer({wallet = ME, badge_id = "7K2Q9M", name = "Joe", jobs = 1, earned = "300000000"})
local seen_anim = false
for _ = 1, 700 do advance(30); if has("JOB DONE!") then seen_anim = true break end end
check(seen_anim, "receipt: JOB DONE")
advance(3000)
check(#W.led > 0 and W.led_off, "LEDs flash and turn off")
go("My offers"); advance(20000)
check(W.lists[1].rows[1].right == "Closed", "closed job: offer rent")
list_select(1); list_select(1)
m = relay_reply(true)
check(same(m.ixs[1].accounts, {m.keys[1], MYOFFER, ME, JOB2}) and m.ixs[1].data == escrow.DISC.close_offer
  and m.w[ME] and m.w[MYOFFER], "close_offer: rent to me")
CHAIN[b58e(MYOFFER)] = nil
advance(6000)
check(json.decode(W.store.offered)[1] == nil, "closed offer forgotten")

-- Retry after a relay error.
go("Request an intro")
list_select(1); type_in("Mert"); type_in("Helius"); type_in("0.2")
relay_reply(true, {status = 500, body = ""})
check(has("relay error 500") and has("SELECT to retry"), "retry offered")
key("select")
m = relay_reply(true)
check(m.ixs[1].data:find("Mert", 1, true), "retry builds again")
key("back")

-- Offline.
W.offline = true
go("Profile"); advance(20000)
W.offline = false

local calls = 0
for _, t in ipairs(W.rpc_times) do if W.ms - t < 60000 then calls = calls + 1 end end
check(calls <= 30, "rpc budget")

-- Registering first, before any payment: the relay fills the introer address.
new_world({accounts = CHAIN})
advance(1600)
go("Profile")
list_select(2); type_in("Joe")
local rm, rp = relay_reply(true)
local hx = require("lib.bytes").hex
check(same(rm.ixs[1].accounts, {rm.keys[1], txlib.PDA[1], SYS}) and rp and #rp == 1
  and same(rp[1].seeds, {hx("introer"), "wallet"}), "wallet-less register: introer seeds for the relay")
scanned_by(WALLET); flush()
advance(6000)
check(last_toast() == "Register: done" and W.store.wallet == json.encode(WALLET), "registered; wallet learned")
flush()
go("Profile"); list_select(1)
check(W.confirm, "change wallet asks first")
local yes = W.confirm; W.confirm = nil; callback(yes, true); flush()
check(W.store.wallet == nil and last_toast() == "Wallet cleared", "wallet cleared; next payment sets it")

-- Demo mode: no network, every screen.
new_world({store = {mock = "true"}})
advance(1600)
check(#W.rpcq == 0, "demo: no rpc")
go("Intro board")
check(#W.lists[1].rows >= 5, "demo board")
list_select(2)
check(has("Telegram shown after you offer."), "demo job")
list_select(1); advance(4100)
check(last_toast() == "Offer: done", "demo offer")
go("My jobs"); list_select(1)
check(W.lists[1].rows[1].title:find("Approve", 1, true), "demo pool")
list_select(1); advance(4100)
check(last_toast() == "Approve: done", "demo approve")
go("My offers")
local picked
for i, r in ipairs(W.lists[1].rows) do if r.right == "You!" then picked = i end end
check(picked, "demo: picked on one")
list_select(picked); list_select(1); advance(4100)
check(last_toast() == "Intro made: done", "demo made")
go("Request an intro")
list_select(1); type_in("Mert"); type_in("Helius"); type_in("0.2"); type_in("me"); advance(4100)
check(last_toast() == "Posted!", "demo post")
go("Profile")
local jobs0, leds0 = json.decode(W.store.jobs), #W.led
advance(200000)
check(json.decode(W.store.jobs) > jobs0 and #W.led > leds0, "demo receipt: JOB DONE with LEDs")
check(#W.rpcq == 0 and #W.posts == 0, "demo: still no network")
check(has("demo value"), "demo profile")

print(string.format("%d passed, %d failed, worst callback %d instructions", passes, fails, worst))
os.exit(fails == 0 and 0 or 1)
