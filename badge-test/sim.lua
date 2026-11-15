-- End-to-end test: two simulated badges run badge/main.lua against the real Intro Bot server
-- (services/relay) and a fake badge API (fake-badge-api.mjs), through the signed-header path.
-- Checks the badge limits too: 128 UI objects, 200-byte labels, 2 KB bodies, 3.5 KB answers.
-- Run with badge-test/e2e.sh (it starts both servers).
local HERE = arg[0]:match("^(.*)/") or "."
local APP = HERE .. "/../badge/"
local FAKE = os.getenv("FAKE") or "http://127.0.0.1:8790"

local fails, passes = 0, 0
local function check(cond, what)
  if cond then passes = passes + 1 else fails = fails + 1; print("FAIL: " .. what) end
end

-- JSON ---------------------------------------------------------------------
local json = {}
local FLOATS = os.getenv("FLOATS") == "1"
do
  local function enc(v)
    local t = type(v)
    if t == "table" then
      if #v > 0 or next(v) == nil then
        local o = {}
        for i = 1, #v do o[i] = enc(v[i]) end
        return (next(v) == nil) and "{}" or "[" .. table.concat(o, ",") .. "]"
      end
      local o = {}
      for k, x in pairs(v) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(x) end
      return "{" .. table.concat(o, ",") .. "}"
    elseif t == "string" then
      return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    elseif t == "nil" then return "null"
    else return tostring(v) end
  end
  json.encode = enc
  function json.decode(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local val
    local function str()
      local j, out = i + 1, {}
      while true do
        local c = s:sub(j, j)
        if c == "" then error("eof") end
        if c == '"' then i = j + 1 return table.concat(out) end
        if c == "\\" then
          local e = s:sub(j + 1, j + 1)
          if e == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)) j = j + 6
          else out[#out + 1] = ({n = "\n", t = "\t", r = "\r"})[e] or e j = j + 2 end
        else out[#out + 1] = c j = j + 1 end
      end
    end
    function val()
      ws()
      local c = s:sub(i, i)
      if c == "{" then
        local t = {} i = i + 1 ws()
        if s:sub(i, i) == "}" then i = i + 1 return t end
        while true do
          ws() local k = str() ws() i = i + 1
          t[k] = val() ws()
          local d = s:sub(i, i) i = i + 1
          if d == "}" then return t end
        end
      elseif c == "[" then
        local t = {} i = i + 1 ws()
        if s:sub(i, i) == "]" then i = i + 1 return t end
        while true do
          t[#t + 1] = val() ws()
          local d = s:sub(i, i) i = i + 1
          if d == "]" then return t end
        end
      elseif c == '"' then return str()
      elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
      elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
      elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
      else
        local n = s:match("^-?[%d%.eE+-]+", i)
        i = i + #n
        -- The badge's JSON may hand back floats (100.0); json.floats mimics that.
        if json.floats then return tonumber(n) + 0.0 end
        return math.tointeger(tonumber(n)) or tonumber(n)
      end
    end
    local ok, v = pcall(val)
    if ok then return v end
    return nil, "bad json"
  end
end

local function sh(cmd, input)
  local tmp = os.tmpname()
  local f = io.open(tmp, "w") f:write(input or "") f:close()
  local p = io.popen(cmd .. " < " .. tmp)
  local out = p:read("a")
  p:close()
  os.remove(tmp)
  return out
end

local function q(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local function fake(path, body)
  return json.decode(sh("curl -s -X POST " .. q(FAKE .. path) .. " --data-binary @-", json.encode(body or {})))
end

-- A simulated badge ----------------------------------------------------------

local badges = {}

local function new_badge(name, id, user)
  local B = {name = name, id = id, user = user, now = 0, timers = {}, store = {}, toasts = {}, answers = {},
    objs = 0, labels = {}, list = nil, nearby = {}, tid = 0, calls = 0}
  local env = setmetatable({}, {__index = _G})
  B.env = env
  local function obj(kind, t)
    B.objs = B.objs + 1
    check(B.objs <= 128, name .. ": at most 128 UI objects")
    local o = {kind = kind, t = t}
    if kind == "label" then
      check(#t <= 200, name .. ": label under 200 bytes: " .. t)
      B.labels[#B.labels + 1] = o
    end
    function o:text(v) check(#v <= 200, name .. ": label text under 200 bytes") self.t = v end
    function o:size() end
    function o:pos() end
    function o:show() end
    function o:remove() B.objs = B.objs - 1 end
    function o:items(v) self.its = v end
    function o:select(i) self.sel = i end
    function o:selected() return self.sel or 1 end
    return o
  end
  local function schedule(ms, f, every)
    B.tid = B.tid + 1
    B.timers[B.tid] = {at = B.now + ms, f = f, every = every}
    return B.tid
  end
  env.json = FLOATS and {encode = json.encode, decode = function(t)
    json.floats = true
    local v, e = json.decode(t)
    json.floats = false
    return v, e
  end} or json
  env.ui = {
    W = 320, H = 218,
    clear = function() B.objs, B.labels, B.list, B.qr = 0, {}, nil, nil end,
    bg = function() end,
    rect = function() return obj("rect", "") end,
    label = function(_, _, t) return obj("label", t) end,
    hint = function(t) B.hint = t end,
    qr = function(_, _, size, t) B.qr, B.qr_size = t, size return obj("qr", t) end,
    list = function(_, _, _, _, items, opts)
      local o = obj("list", "")
      o.its, o.on_select = items, opts and opts.on_select
      B.list = o
      return o
    end,
    toast = function(t) B.toasts[#B.toasts + 1] = t end,
    input = function(prompt, max, cb)
      local a = table.remove(B.answers, 1)
      assert(a ~= nil, name .. ": no answer for " .. prompt)
      check(#a <= max, name .. ": answer fits " .. prompt)
      schedule(1, function() cb(a) end)
    end,
    confirm = function(_, cb) schedule(1, function() cb(true) end) end,
  }
  env.storage = {
    get = function(k) return B.store[k] end,
    set = function(k, v) B.store[k] = v end,
    remove = function(k) B.store[k] = nil end,
  }
  env.sys = {millis = function() return B.now end, time = function() return os.time() end}
  env.timer = {
    after = function(ms, f) return schedule(ms, f) end,
    every = function(ms, f) return schedule(ms, f, ms) end,
    cancel = function(t) B.timers[t] = nil end,
  }
  env.badge = {id = function() return id end, online = function() return true end}
  env.led = {fill = function() end, off = function() end}
  local function request(method, url, body, cb)
    assert(url:sub(1, 8) == "https://", "https only")
    local raw = body and json.encode(body) or ""
    check(#raw <= 2048, name .. ": body under 2 KB")
    B.calls = B.calls + 1
    local out = json.decode(sh("node " .. q(HERE .. "/call.mjs") .. " " .. method .. " " .. q(url) .. " " .. id .. " " .. user, raw))
    assert(out, name .. ": no answer from the server for " .. url)
    check(#out.body <= 3500, name .. ": answer under 3.5 KB for " .. url)
    schedule(1, function() cb(true, {status = out.status, body = out.body, type = "application/json"}) end)
  end
  env.http = {
    get = function(url, cb) request("GET", url, nil, cb) end,
    post = function(url, body, cb) request("POST", url, body, cb) end,
  }
  env.lamps = {
    balance = function(cb) schedule(1, function() cb(true, 100) end) end,
    deposit = function(addr, amount, memo, cb)
      if B.deny then B.denied = amount return schedule(1, function() cb(false, B.deny) end) end
      check(addr == "ESC-GQD4T2WC", name .. ": deposits go to the app escrow")
      check(math.type(amount) == "integer" and amount <= 500, name .. ": whole bid within 500")
      local r = fake("/test/deposit", {user = user, badge = id, amount = amount, memo = memo})
      B.deposits = (B.deposits or 0) + 1
      B.last_amount = amount
      schedule(1, function() cb(true, {balance = 1000, id = r.id}) end)
    end,
  }
  env.mesh = {
    pause = function() B.mesh = false end,
    resume = function() B.mesh = true end,
    nearby = function() return B.nearby end,
    meet = function(peer, data, cb)
      check(B.mesh, name .. ": mesh on while meeting")
      local P = badges[peer]
      if not P or not P.mesh then schedule(1, function() cb(false, "no answer") end) return true end
      local mine = P.env.on_meet(id, data)
      if type(mine) ~= "table" then schedule(1, function() cb(false, "refused") end) return true end
      fake("/test/meet", {req = {badge = id, user = user, t = os.time(), data = data},
        acc = {badge = peer, user = P.user, t = os.time(), data = mine}})
      schedule(1, function() cb(true, {peer = peer, data = mine}) end)
      return true
    end,
  }
  local loaded = {}
  env.require = function(n)
    if not loaded[n] then loaded[n] = assert(loadfile(APP .. n:gsub("%.", "/") .. ".lua", "t", env))() end
    return loaded[n]
  end
  assert(loadfile(APP .. "main.lua", "t", env))()
  badges[id] = B
  return B
end

-- Driving ------------------------------------------------------------------

local function run(B, ms)
  local stop = B.now + ms
  while true do
    local nid, nt
    for tid, t in pairs(B.timers) do
      if t.at <= stop and (not nt or t.at < nt.at or (t.at == nt.at and tid < nid)) then nid, nt = tid, t end
    end
    if not nt then break end
    if nt.at > B.now then
      if B.env.on_tick then B.env.on_tick(nt.at - B.now) end
      B.now = nt.at
    end
    if nt.every then nt.at = nt.at + nt.every else B.timers[nid] = nil end
    nt.f()
  end
  if stop > B.now and B.env.on_tick then B.env.on_tick(stop - B.now) end
  B.now = stop
end

local function key(B, k, n)
  for _ = 1, n or 1 do B.env.on_key(k) run(B, 50) end
end

local function texts(B)
  local t = {}
  for _, l in ipairs(B.labels) do t[#t + 1] = l.t end
  return table.concat(t, " | ")
end

local function has(B, s) return texts(B):find(s, 1, true) ~= nil end

local function item(B, prefix)
  if not B.list then return nil end
  for i, it in ipairs(B.list.its) do
    local title = type(it) == "table" and it.title or it
    if title:sub(1, #prefix) == prefix then return i end
  end
end

local function pick(B, prefix, answers)
  local i = item(B, prefix)
  check(i ~= nil, B.name .. ": list has " .. prefix .. " (" .. texts(B) .. ")")
  if not i then return end
  for _, a in ipairs(answers or {}) do B.answers[#B.answers + 1] = a end
  B.list.on_select(i)
  run(B, 200)
end

local function last_toast(B) return B.toasts[#B.toasts] or "" end

-- going to a tab: board, fleet, request, myjobs, myoffers, profile
local TABS = {board = 1, fleet = 2, request = 3, myjobs = 4, myoffers = 5, profile = 6}
local TITLES = {["Intro board"] = "board", ["Badge Fleet"] = "fleet", ["Request an intro"] = "request",
  ["My jobs"] = "myjobs", ["My offers"] = "myoffers", ["Profile"] = "profile"}
local function tab(B, name)
  if B.labels[1] and B.labels[1].t == "BotBot" then key(B, "select") end
  if B.labels[1] and B.labels[1].t == "JOB DONE!" then B.saw_done = true run(B, 3000) end
  for _ = 1, 3 do  -- back out of a job or We met screen first
    if TITLES[B.labels[1] and B.labels[1].t or ""] then break end
    key(B, "back")
  end
  if B.labels[1] and B.labels[1].t == "JOB DONE!" then
    B.saw_done = true
    run(B, 3000)
  end
  local cur = TABS[TITLES[B.labels[1].t]]
  key(B, "right", (TABS[name] - cur) % 6)
  run(B, 300)
  if B.labels[1] and B.labels[1].t == "JOB DONE!" then B.saw_done = true run(B, 3000) end
  check(TITLES[B.labels[1].t] == name, B.name .. ": on " .. name)
end

-- The test -----------------------------------------------------------------

local A = new_badge("requester", "REQ001", "u-req")
local I = new_badge("introer", "INT001", "u-int")
run(A, 2000) run(I, 2000)
check(A.labels[1] and A.labels[1].t == "BotBot", "splash first: " .. texts(A))
check(A.qr == "https://x.com/botbotcap" and A.qr_size >= 150, "splash QR to x.com/botbotcap, big")
check(A.hint == "SELECT to enter   CANCEL exit", "splash hint")
run(A, 5000)
check(A.labels[1].t == "BotBot", "splash stays until SELECT")
key(A, "left") key(A, "right")
check(A.labels[1].t == "BotBot", "only SELECT enters")
key(A, "select") key(I, "select")
check(A.qr == nil, "QR freed on the board")
check(has(A, "No requests yet"), "empty board at start")
check(A.env.on_key("back") == true and A.labels[1].t == "BotBot", "CANCEL on a tab goes home")
check(A.env.on_key("back") == false, "CANCEL on the splash exits")
key(A, "select")
check(TITLES[A.labels[1].t] == "board", "SELECT enters again")
check(A.mesh == false, "mesh paused at start: Wi-Fi first")

-- No sign-up: every badge can request and offer.
tab(I, "profile")
check(has(I, "Offer on a job to start earning"), "no register step")
check(not has(I, "Register"), "no register row")

-- Requester posts a job and pays the bid into the escrow.
pick(A, "+ Request an intro", {"Toly", "Solana", "5"})
check(last_toast(A) == "10 to 500 !LAMPs", "bid under 10 refused")
pick(A, "+ Request an intro", {"Toly", "Solana", "50", "reqtg"})
run(A, 500)
check(A.deposits == 1, "one deposit")
check(A.last_amount == 50 and math.type(A.last_amount) == "integer", "deposit amount is a whole number")
check(last_toast(A) == "Posted!", "posted after the deposit: " .. last_toast(A))
check(item(A, "Toly @ Solana") ~= nil, "my jobs lists the job")

-- Introer sees it on the board and offers.
tab(I, "board")
check(item(I, "Toly @ Solana") ~= nil, "board lists the job")
pick(I, "Toly @ Solana")
run(I, 300)
check(has(I, "Telegram shown after you offer."), "telegram hidden before offering")
pick(I, "Offer to make this intro", {"ana"})
run(I, 300)
check(has(I, "@reqtg"), "telegram shown after offering")

-- Requester approves.
run(A, 20000)
pick(A, "Toly @ Solana")
run(A, 300)
pick(A, "Approve @ana")
check(has(A, "Picked: @ana"), "approved @ana")
check(item(A, "Confirm") ~= nil and item(A, "We met") ~= nil, "requester can confirm or meet")

-- Introer can't mark made before meeting.
tab(I, "myoffers")
check(item(I, "Toly @ Solana") ~= nil, "my offers lists the job")
pick(I, "Toly @ Solana")
run(I, 300)
check(item(I, "Intro made") == nil and item(I, "We met") ~= nil, "meet first, then made")

-- Both open We met; the introer asks, the requester's badge signs.
pick(I, "We met")
pick(A, "We met")
check(I.mesh and A.mesh, "mesh on in We met")
I.nearby = {{id = "REQ001", name = "@req", kind = "badge", rssi = -40}}
key(I, "select")
run(I, 300) run(A, 300)
check(last_toast(I):find("Met!") ~= nil, "introer: met")
check(last_toast(A):find("Met!") ~= nil, "requester: met")
check(not I.mesh and not A.mesh, "mesh paused again after meeting")

-- The server reads the meet; then the introer marks made.
os.execute("sleep 1.5")
tab(I, "myoffers")
pick(I, "Toly @ Solana")
run(I, 300)
check(has(I, "met: verified"), "meet verified by the server")
pick(I, "Intro made")
check(last_toast(I) == "Intro made: done", "marked made")

-- Requester confirms: the introer is paid from the escrow.
tab(A, "myjobs")
pick(A, "Toly @ Solana")
run(A, 300)
pick(A, "Confirm")
check(last_toast(A):find("Paid!") ~= nil, "confirm pays")
local pays = json.decode(sh("curl -s " .. q(FAKE .. "/test/pays")))
check(pays and pays[1] and pays[1].to == "INT001" and pays[1].amount == 50, "escrow paid the introer 50")

-- The introer's badge plays JOB DONE; the Badge Fleet MAV counts it.
tab(I, "board")
run(I, 20000)
if has(I, "JOB DONE!") then I.saw_done = true run(I, 3000) end
check(I.saw_done, "introer sees JOB DONE")
tab(I, "fleet")
check(has(I, "50 !LAMPs") and has(I, "1 intro paid"), "Badge Fleet MAV: " .. texts(I))
tab(I, "profile")
check(has(I, "earned 50 !LAMPs") and has(I, "40 !LAMPs"), "machine value from earned: " .. texts(I))

-- Cancel refunds an open job.
tab(A, "board")
pick(A, "+ Request an intro", {"Mert", "Helius", "20"})
run(A, 500)
pick(A, "Mert @ Helius")
run(A, 300)
check(has(A, "To change the bid, remove and post again."), "bid change hint")
-- The introer offers, then withdraws.
tab(I, "board")
run(I, 20000)
pick(I, "Mert @ Helius")
run(I, 300)
pick(I, "Offer to make this intro")
run(I, 300)
pick(I, "Withdraw my offer")
run(I, 300)
check(item(I, "Offer to make this intro") ~= nil, "offer withdrawn")
-- Edit: an empty answer keeps the old value.
pick(A, "Edit", {"Mert", "Helius Labs", ""})
run(A, 300)
check(last_toast(A) == "Saved" and has(A, "Mert @ Helius Labs"), "edited: " .. texts(A))
pick(A, "Remove: bid back")
run(A, 300)
pays = json.decode(sh("curl -s " .. q(FAKE .. "/test/pays")))
check(pays and pays[2] and pays[2].to == "REQ001" and pays[2].amount == 20, "cancel refunded 20")

-- A refused deposit shows the OS's own words and leaves the job unpaid.
A.deny = "denied"
tab(A, "board")
run(A, 300)
pick(A, "+ Request an intro", {"Raj", "Solana", "100"})
run(A, 500)
check(A.denied == 100 and math.type(A.denied) == "integer", "denied deposit got a whole 100")
check(last_toast(A) == "Not paid: denied", "raw reason shown: " .. last_toast(A))
A.deny = nil
-- The unpaid job can be removed.
tab(A, "myjobs")
run(A, 300)
pick(A, "Raj @ Solana")
run(A, 300)
check(item(A, "Pay the bid") ~= nil and item(A, "Remove (not paid)") ~= nil, "unpaid: pay or remove")
pick(A, "Remove (not paid)")
run(A, 500)
check(last_toast(A) == "Removed" and item(A, "Raj @ Solana") == nil, "unpaid job removed: " .. texts(A))

-- Unsigned calls are refused.
local raw = sh("curl -s -o /dev/null -w '%{http_code}' " .. q((os.getenv("LOCAL") or "http://127.0.0.1:8791") .. "/api/board"))
check(raw == "401", "unsigned request refused: " .. raw)

print(string.format("%d passed, %d failed", passes, fails))
os.exit(fails == 0 and 0 or 1)
