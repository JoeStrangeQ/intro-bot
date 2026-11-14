-- Intro Bot: get paid for intros at Breakpoint, or bid for one. Both sides on the badge.
-- Reads the chain with `rpc`, builds each transaction here, and the phone wallet signs it
-- through a Solana Pay QR from the relay. The badge never makes or stores keys.
local sol = require("lib.sol")
local escrow = require("lib.escrow")
local tx = require("lib.tx")
local chain = require("lib.chain")
local demo = require("lib.demo")
local art = require("lib.art")

local POLL_MS, WATCH_MS, WATCH_FOR = 20000, 6000, 600000
local BEACON_MS, NEARBY_FOR, SCAN_MS = 10000, 120000, 12000
local SPARK_N, MAX_MINE, QUEUE_SCAN = 24, 10, 10
local C = {
  desk = 0xC9BFF2, brand = 0x6A50D8, ink = 0x241A52, paper = 0xF6F3FD,
  orange = 0xA8521A, white = 0xFFFFFF, dim = 0x6E6496, line = 0xDCD5F7,
}
local TABS = {"home", "queue", "hire", "find", "mine", "setup"}
local TITLE = {
  home = "Intro Bot", queue = "My queue", hire = "Hire me", find = "Find an introer",
  mine = "My requests", setup = "Setup", action = "Request", sign = "Sign on phone",
  introer = "Introer",
}
local TABHINT = "LEFT/RIGHT screens   CANCEL exit"

-- State ------------------------------------------------------------------

local function stored_list(key, ok)
  local s, out = storage.get(key), {}
  if type(s) == "table" then
    for k = 1, 32 do
      if s[k] == nil then break end
      if ok(s[k]) then out[#out + 1] = s[k] end
    end
  end
  return out
end

local function mine_ok(m)
  return type(m) == "table" and sol.is_wallet(m.w) and type(m.id) == "string" and m.id:find("^%d+$") ~= nil
    and #m.id <= 9 and type(m.at) == "number"
end

local st = {
  wallet = sol.is_wallet(storage.get("wallet")) and storage.get("wallet") or nil,
  mock = storage.get("mock") == true,
  spark = stored_list("spark", function(v) return type(v) == "number" end),
  jobs = math.tointeger(storage.get("jobs")),
  mine = stored_list("mine", mine_ok),      -- my bids: {w = introer wallet, id, at}
  recent = stored_list("recent", sol.is_wallet),
  me = nil,           -- my Introer account (decoded), false when not registered, nil unknown
  queue = nil,        -- requests to me
  rows = nil,         -- my requests, read from the chain
  live = {},          -- [id] = true: requests to me that were live last time (kept)
  nearby = {},        -- [wallet] = {id, at}
  status = "starting", updated = nil, busy = nil, gen = 0,
  screen = nil, w = {}, row = nil, role = nil, pick = nil, sign = nil, anim = nil,
  modal = nil, pending = nil, ago = 0, mockdata = nil, scan_until = nil,
}
while #st.spark > SPARK_N do table.remove(st.spark, 1) end
while #st.mine > MAX_MINE do table.remove(st.mine, 1) end
for _, id in ipairs(stored_list("live", function(v) return type(v) == "string" and v:find("^%d+$") and #v <= 9 end)) do
  st.live[id] = true
end

local function now() return sys.time() end
local function my_bytes() return st.wallet and solana.decode(st.wallet) end

-- Frame ------------------------------------------------------------------

local function frame(name)
  ui.clear()
  st.w = {}
  ui.bg(C.desk)
  ui.rect(4, 4, 312, 196, {color = C.ink})
  ui.rect(5, 5, 310, 194, {color = C.paper})
  ui.rect(5, 5, 310, 20, {color = C.brand})
  ui.label(10, 7, TITLE[name], {size = 14, color = C.white})
  local tag = st.mock and "DEMO" or (st.wallet and sol.short(st.wallet) or "")
  ui.label(160, 9, tag, {size = 12, color = C.white, w = 150, align = "right"})
end

local function center(y, text, size, color)
  return ui.label(5, y, text, {size = size or 14, color = color or C.ink, w = 310, align = "center"})
end

local function ago_text()
  if st.status ~= "ok" and st.status ~= "starting" then
    return st.status .. (st.updated and " - showing last data" or "")
  end
  if not st.updated then return "loading..." end
  local s = (sys.millis() - st.updated) // 1000
  return s < 2 and "updated now" or ("updated " .. s .. "s ago")
end

-- Modals: a job-done animation waits until they close ---------------------

local job_done  -- forward

local function modal(open, ...)
  local args = table.pack(...)
  local cb = args[args.n]
  args[args.n] = function(v)
    st.modal = nil
    cb(v)
    if st.pending and not st.modal and st.screen == "home" then
      local n = st.pending
      st.pending = nil
      job_done(n)
    elseif st.dirty and not st.modal and not st.anim then
      st.dirty = nil
      show(st.screen)
    end
  end
  st.modal = true
  open(table.unpack(args, 1, args.n))
end

local function input(prompt, max, cb) modal(ui.input, prompt, max, cb) end
local function confirm(text, cb) modal(ui.confirm, text, cb) end

-- Home -------------------------------------------------------------------

local function draw_spark()
  local bars, pts = st.w.spark, st.spark
  if not bars then return end
  local lo, hi = math.huge, -math.huge
  for k = 1, #pts do
    if pts[k] < lo then lo = pts[k] end
    if pts[k] > hi then hi = pts[k] end
  end
  local first = SPARK_N - #pts
  for k = 1, SPARK_N do
    local p = pts[k - first]
    if p then
      local h = hi > lo and math.floor(3 + (p - lo) * 31 / (hi - lo)) or 18
      bars[k]:size(3, h)
      bars[k]:pos(206 + (k - 1) * 4, 66 - h)
      bars[k]:show(true)
    else
      bars[k]:show(false)
    end
  end
end

local function value_of(me)
  return sol.machine_value(me.earned, me.created_at, now())
end

local function refresh_home()
  local w, me = st.w, st.me
  if not w.value then return end
  if me then
    w.value:text(sol.format(value_of(me), 3) .. " SOL")
    w.jobs:text(tostring(me.jobs))
    w.queue:text(me.open .. "/" .. escrow.MAX_OPEN)
    w.bid:text(sol.format(me.min_bid, 3) .. " SOL")
    w.note:text(me.offer)
  else
    w.value:text("-- SOL")
    w.jobs:text("-") w.queue:text("-") w.bid:text("-")
    w.note:text(me == false and "Not an introer yet: Setup > Register" or "")
  end
  w.status:text(ago_text())
  draw_spark()
end

local function stat(x, title)
  ui.label(x, 92, title, {size = 12, color = C.dim})
  return ui.label(x, 106, "-", {size = 20, color = C.ink})
end

local function build_home()
  frame("home")
  art.robot_at(12, 30, 3)
  ui.label(66, 32, "machine value (demo value)", {size = 12, color = C.dim})
  st.w.value = ui.label(66, 48, "", {size = 20, color = C.brand})
  ui.rect(204, 32, 100, 36, {color = C.line})
  st.w.spark = {}
  for k = 1, SPARK_N do
    st.w.spark[k] = ui.rect(206 + (k - 1) * 4, 50, 3, 2, {color = C.brand})
  end
  st.w.jobs = stat(14, "jobs")
  st.w.queue = stat(84, "open")
  ui.label(160, 92, "min bid", {size = 12, color = C.dim})
  st.w.bid = ui.label(160, 106, "", {size = 20, color = C.ink})
  st.w.note = ui.label(14, 132, "", {size = 12, color = C.ink, w = 292})
  st.w.status = ui.label(14, 146, "", {size = 12, color = C.dim, w = 292})
  ui.rect(5, 162, 310, 1, {color = C.line})
  center(168, "Ask me about BotBot")
  center(184, "botbotcap.com", 12, C.orange)
  ui.hint(TABHINT)
  refresh_home()
end

-- Request lists ----------------------------------------------------------

local function status_text(r) return escrow.STATUS[r.status] or "?" end

local function row_items(rows, role)
  local items = {}
  for k, r in ipairs(rows or {}) do
    items[k] = {
      title = r.target ~= "" and r.target or "(no target)",
      sub = (r.telegram ~= "" and r.telegram .. "  " or "") .. sol.format(r.bid, 3) .. " SOL"
        .. (role == "requester" and r.w and ("  via " .. sol.short(r.w)) or ""),
      right = status_text(r),
    }
  end
  return items
end

local show  -- forward

-- From async callbacks: wait while the animation or a dialog has the screen.
local function show_later(name)
  if st.anim or st.modal then
    st.screen, st.dirty = name, true
  else
    show(name)
  end
end

local function build_rows(name, rows, role, empty, empty2)
  frame(name)
  local items = row_items(rows, role)
  if #items == 0 then
    center(80, rows and empty or "Reading the chain...")
    if rows and empty2 then center(104, empty2, 12, C.dim) end
  else
    st.w.list = ui.list(6, 26, 308, 172, items, {on_select = function(i)
      local r = (role == "introer" and st.queue or st.rows or {})[i]  -- the rows shown now
      if r then
        st.row, st.role = r, role
        show("action")
      end
    end})
  end
  st.w.count, st.w.rows = #items, rows
  ui.hint(#items > 0 and "SELECT open   LEFT/RIGHT screens" or TABHINT)
end

local function build_queue()
  if st.me == false then
    frame("queue")
    center(80, "Not an introer yet")
    center(104, "Register in Setup to get hired", 12, C.dim)
    st.w.count = -1
    ui.hint(TABHINT)
    return
  end
  build_rows("queue", st.queue, "introer", "No requests yet", "Show Hire me so people find you")
end

local function build_mine()
  build_rows("mine", st.rows, "requester", "No requests yet", "Find an introer to bid")
end

local function refresh_rows(rows, role, rebuild)
  local items = row_items(rows, role)
  if st.w.list and #items > 0 then
    local old = st.w.rows and st.w.rows[st.w.list:selected() or 1]
    local sel = 1
    for k, r in ipairs(rows) do if old and r.pda == old.pda then sel = k end end
    st.w.list:items(items)
    st.w.list:select(sel)
    st.w.rows = rows
  elseif #items ~= st.w.count or not st.w.list then
    rebuild()
  end
end

-- Signing: build the message, get a QR from the relay, watch the chain -----

local start_sign, fresh_bid  -- forward

local function build_action()
  frame("action")
  local r = st.row
  ui.label(14, 32, r.target, {size = 14, color = C.ink, w = 292})
  ui.label(14, 52, (r.telegram ~= "" and r.telegram .. "   " or "") .. "bid " .. sol.format(r.bid) .. " SOL",
    {size = 12, color = C.dim, w = 292})
  ui.label(14, 68, "status: " .. status_text(r), {size = 12, color = C.dim, w = 292})
  local keys = escrow.actions(r, st.role, now())
  local note = escrow.note(r, st.role, now())
  if note then ui.label(14, 176, note, {size = 12, color = C.orange, w = 292}) end
  if #keys == 0 then
    ui.label(14, 110, r.status == escrow.MADE and "The requester confirms to pay you."
      or "Nothing to sign yet.", {size = 14, color = C.ink, w = 292})
    if r.status == escrow.MADE then
      ui.label(14, 130, "No confirm in 72h: they get a refund.", {size = 12, color = C.dim, w = 292})
    end
    ui.hint("CANCEL back")
    return
  end
  local items = {}
  for k, a in ipairs(keys) do items[k] = escrow.LABEL[a] end
  ui.list(6, 88, 308, 36 * #keys, items, {on_select = function(i) start_sign(keys[i], st.row) end})
  ui.hint("SELECT sign   CANCEL back")
end

-- What each step builds, which account shows it landed, and how.
local function plan(action, r)
  local me = my_bytes()
  if action == "accept" or action == "mark_made" or action == "decline" then
    local intro = escrow.introer_pda(me)
    local ix = action == "accept" and escrow.ix_accept(intro, r.pda)
      or action == "mark_made" and escrow.ix_made(intro, r.pda)
      or escrow.ix_decline(intro, r.pda, r.requester)
    local want = action == "accept" and escrow.ACCEPTED or action == "mark_made" and escrow.MADE or "gone"
    return {ix}, r.pda, want
  end
  if action == "withdraw" or action == "confirm" or action:find("^refund") then
    local iw = solana.decode(r.w)
    local intro = escrow.introer_pda(iw)
    local ix = action == "withdraw" and escrow.ix_withdraw(intro, r.pda)
      or action == "confirm" and escrow.ix_confirm(intro, r.pda, iw)
      or escrow.ix_refund(action, intro, r.pda, r.requester)
    return {ix}, r.pda, "gone"
  end
  if action == "bid" then
    local intro = escrow.introer_pda(solana.decode(r.w))
    r.pda = r.pda or escrow.request_pda(intro, r.id)
    return {escrow.ix_bid(intro, r.pda, r.target, r.telegram, r.bid, r.lowest)}, r.pda, "bid"
  end
  if action == "register_introer" then
    return {escrow.ix_register(me, r.badge_id, r.offer, r.min_bid)}, escrow.introer_pda(me), "exists"
  end
  return {escrow.ix_update(me, r.offer, r.min_bid)}, escrow.introer_pda(me), "offer"
end

-- true when it landed, false and why when it can't any more, nil to keep waiting.
local function landed(want, b, r)
  if want == "gone" then return b == nil end
  if want == "exists" then return b ~= nil end
  if want == "bid" then
    local q = b and escrow.decode_request(b)
    if not q then return nil end
    if q.target == r.target and q.telegram == r.telegram and q.bid == r.bid then return true end
    return false, "Someone bid first"
  end
  if want == "offer" then
    local i = b and escrow.decode_introer(b)
    return i and i.offer == r.offer and i.min_bid == r.min_bid
  end
  local q = b and escrow.decode_request(b)
  return q and q.status == want
end

local poll  -- forward

local function stop_sign()
  local s = st.sign
  if s and s.timer then timer.cancel(s.timer) end
  st.sign = nil
end

local function sign_done(s)
  if s.action == "bid" and not st.mock then
    st.mine[#st.mine + 1] = {w = s.row.w, id = s.row.id, at = now() or 0}  -- 0: no clock yet
    while #st.mine > MAX_MINE do table.remove(st.mine, 1) end
    storage.set("mine", st.mine)
  end
  stop_sign()
  ui.toast(escrow.LABEL[s.action] .. ": done")
  poll(true)
  show_later(s.back)
end

local function sign_text(a, b, c)
  local w = st.w
  if st.screen ~= "sign" or not w.l1 then return end
  w.l1:text(a) w.l2:text(b or "") w.l3:text(c or "")
end

local function watch()
  local s = st.sign
  if not s then return end
  if sys.millis() - s.started > WATCH_FOR then
    stop_sign()
    sign_text("Timed out.", "Nothing landed", "in 10 minutes.")
    return
  end
  chain.account(s.addr, function(ok, b)
    if st.sign ~= s or not ok then return end
    local done, why = landed(s.want, b, s.row)
    if done then sign_done(s)
    elseif why then
      stop_sign()
      st.retry = s.action == "bid" and s
      sign_text(why, "Nothing was paid.", st.retry and "SELECT to retry" or "Try again.")
      if st.retry then ui.hint("SELECT retry   CANCEL back") end
    end
  end)
end

local function build_sign()
  frame("sign")
  local s = st.sign
  if s and s.url and ui.qr then ui.qr(14, 32, 160, s.url) end
  st.w.l1 = ui.label(186, 36, "", {size = 14, color = C.brand, w = 124})
  st.w.l2 = ui.label(186, 60, "", {size = 12, color = C.ink, w = 124})
  st.w.l3 = ui.label(186, 76, "", {size = 12, color = C.dim, w = 124})
  if s and s.url then
    sign_text(escrow.LABEL[s.action], "Scan with your", "phone wallet.")
    ui.label(186, 104, "Waiting for the", {size = 12, color = C.dim})
    ui.label(186, 118, "chain...", {size = 12, color = C.dim})
    if st.mock then ui.label(186, 146, "Demo: not real", {size = 12, color = C.orange}) end
  elseif s and s.err then
    sign_text("Could not sign:", s.err, "CANCEL, then retry.")
  elseif s then
    sign_text("Preparing...", "", "")
  else
    sign_text("Timed out.", "Nothing landed", "in 10 minutes.")
  end
  ui.hint("CANCEL back")
end

-- Right before a bid: read the introer again for its next id and lowest open bid.
function fresh_bid(s, r, build)
  local wb = solana.decode(r.w)
  local intro = escrow.introer_pda(wb)
  local function fail_bid(why)
    if st.sign ~= s then return end
    s.err = why
    if st.screen == "sign" then show_later("sign") end
  end
  chain.account(intro, function(ok, b)
    if st.sign ~= s then return end
    local x = ok and b and escrow.decode_introer(b)
    if not x then return fail_bid(ok and "Not an introer." or tostring(b)) end
    if r.id ~= x.next_id then r.id, r.pda = x.next_id, nil end
    r.lowest = nil
    local lo, need = escrow.lowest(x)
    if x.open < escrow.MAX_OPEN then return timer.after(20, build) end
    if sol.cmp(r.bid, need) < 0 then return fail_bid("Bid at least " .. sol.format(need, 4) .. " SOL") end
    chain.request_pdas(intro, {lo.id}, function(pdas)
      chain.account(pdas[1], function(ok2, b2)
        if st.sign ~= s then return end
        local q = ok2 and b2 and escrow.decode_request(b2)
        if not (q and q.status == escrow.OPEN) then return fail_bid("Queue changed: try again") end
        r.lowest = {pda = pdas[1], requester = q.requester, bid = q.bid}
        timer.after(20, build)
      end)
    end)
  end)
end

function start_sign(action, r, back)
  stop_sign()
  st.retry = nil
  local s = {action = action, row = r, started = sys.millis(),
    back = back or (st.role == "introer" and "queue" or "mine")}
  st.sign = s
  if st.mock then
    s.url = "solana:" .. chain.RELAY .. "/tx/demo"
    s.timer = timer.after(4000, function()
      if st.sign ~= s then return end
      demo.apply(st.mockdata, action, r)
      sign_done(s)
    end)
    show("sign")
    return
  end
  show("sign")
  -- Addresses cost instructions: work them out over a few callbacks, then build.
  local function build()
    if st.sign ~= s then return end
    local ixs, addr, want = plan(action, r)
    s.addr, s.want = addr, want
    chain.relay(tx.message(ixs), function(ok, url)
      if st.sign ~= s then return end
      if ok then
        s.url = url
        s.timer = timer.every(WATCH_MS, watch)
      else
        s.err = tostring(url)
      end
      if st.screen == "sign" then show_later("sign") end
    end)
  end
  local warm = {
    function() escrow.config_pda() end,
    function() if st.wallet then escrow.introer_pda(my_bytes()) end end,
    function() if r.w then escrow.introer_pda(solana.decode(r.w)) end end,
    function() if action == "register_introer" then escrow.directory_pda() end end,
  }
  local k = 0
  local function step()
    if st.sign ~= s then return end
    k = k + 1
    if warm[k] then warm[k]() timer.after(20, step)
    elseif action == "bid" then fresh_bid(s, r, build)
    else build() end
  end
  timer.after(20, step)
end

-- Hire me ----------------------------------------------------------------

local function build_hire()
  frame("hire")
  art.robot_at(14, 32, 4)
  ui.label(90, 34, "Hire me for an intro", {size = 14, color = C.brand})
  local me = st.me
  if me then
    ui.label(90, 56, me.offer, {size = 12, color = C.ink, w = 216})
    ui.label(90, 72, "min " .. sol.format(me.min_bid, 3) .. " SOL   open " .. me.open .. "/" .. escrow.MAX_OPEN,
      {size = 12, color = C.ink, w = 216})
  else
    ui.label(90, 56, "Register in Setup first.", {size = 12, color = C.ink, w = 216})
  end
  ui.label(90, 90, "Bid from your badge:", {size = 12, color = C.dim})
  ui.label(90, 104, "Intro Bot > Find", {size = 12, color = C.dim})
  if st.wallet then ui.label(90, 118, "wallet " .. sol.short(st.wallet), {size = 12, color = C.dim}) end
  ui.rect(5, 138, 310, 1, {color = C.line})
  center(144, "Paid only when you confirm.", 14, C.ink)
  center(162, "We trust you to keep your word.", 12, C.dim)
  center(182, "Ask me about BotBot - botbotcap.com", 12, C.orange)
  ui.hint(TABHINT)
end

-- Find -------------------------------------------------------------------

local build_find  -- forward

local function find_entries()
  local out, seen, names = {}, {}, {}
  local t = sys.millis()
  if mesh and mesh.nearby then
    for _, b in ipairs(mesh.nearby() or {}) do
      if type(b) == "table" and b.id then names[b.id] = b.name end
    end
  end
  for w, n in pairs(st.nearby) do
    if #out >= 8 then break end
    if t - n.at < NEARBY_FOR and w ~= st.wallet then
      out[#out + 1] = {w = w, title = names[n.id] or sol.short(w), sub = "nearby"}
      seen[w] = true
    end
  end
  if st.mock then
    for _, x in ipairs(demo.INTROERS) do
      out[#out + 1] = {w = x.w, title = x.name, sub = "nearby (demo)"}
      seen[x.w] = true
    end
  end
  for k = #st.recent, 1, -1 do
    local w = st.recent[k]
    if not seen[w] then out[#out + 1] = {w = w, title = sol.short(w), sub = "seen before"}; seen[w] = true end
  end
  for _, w in ipairs(st.dir or {}) do
    if not seen[w] and w ~= st.wallet then out[#out + 1] = {w = w, title = sol.short(w), sub = "on-chain list"} end
  end
  return out
end

local function open_introer(w)
  for k = #st.recent, 1, -1 do if st.recent[k] == w then table.remove(st.recent, k) end end
  st.recent[#st.recent + 1] = w
  while #st.recent > 6 do table.remove(st.recent, 1) end
  storage.set("recent", st.recent)
  st.pick = {w = w}
  show("introer")
end

local function scan_nearby()
  if not mesh then ui.toast("No mesh on this badge") return end
  st.scan_until = sys.millis() + SCAN_MS
  if mesh.resume then mesh.resume() end
  mesh.send("*", {k = "ib?"})
  ui.toast("Looking for badges nearby...")
end

-- The program keeps the 32 latest introers in one account.
local function load_directory()
  if st.mock then
    st.dir = {}
    ui.toast("Demo: nearby list only")
    return
  end
  ui.toast("Reading the list...")
  chain.account(escrow.directory_pda(), function(ok, b)
    if not ok then ui.toast(tostring(b)) return end
    local list = escrow.decode_directory(b)
    if not list then ui.toast("No list on chain yet") return end
    st.dir = {}
    for k, w in ipairs(list) do st.dir[k] = solana.encode(w) end
    if st.screen == "find" and not st.anim and not st.modal then build_find() end
  end)
end

local FIND_TOP = 3

function build_find()
  frame("find")
  local entries = find_entries()
  local items = {{title = "Enter a wallet", sub = "an introer's address"},
    {title = "Look nearby", sub = "badges running Intro Bot"},
    {title = "On-chain list", sub = "the latest introers"}}
  for _, e in ipairs(entries) do items[#items + 1] = {title = e.title, sub = e.sub} end
  st.w.list = ui.list(6, 26, 308, 172, items, {on_select = function(i)
    if i == 1 then
      input("Introer wallet", 44, function(text)
        if not text then return end
        text = text:gsub("%s", "")
        if not sol.is_wallet(text) then ui.toast("Not a Solana address") return end
        open_introer(text)
      end)
    elseif i == 2 then
      scan_nearby()
    elseif i == 3 then
      load_directory()
    elseif entries[i - FIND_TOP] then
      open_introer(entries[i - FIND_TOP].w)
    end
  end})
  st.w.count = #items
  ui.hint("SELECT open   LEFT/RIGHT screens")
end

local function refresh_find()
  if #find_entries() + FIND_TOP ~= st.w.count then build_find() end
end

-- An introer, and bidding ---------------------------------------------------

local function ask_bid(p)
  local x = p.introer
  if p.w == st.wallet then ui.toast("You can't bid on yourself") return end
  input("Who do you want to meet?", escrow.TARGET, function(target)
    if not target or target:gsub("%s", "") == "" then return end
    input("Your Telegram @handle", escrow.TELEGRAM - 1, function(tg)
      if not tg then return end
      tg = tg:gsub("%s", "")
      if tg == "" or tg == "@" then ui.toast("Telegram is required") return end
      if tg:sub(1, 1) ~= "@" then tg = "@" .. tg end
      input("Bid in SOL (min " .. sol.format(x.min_bid, 3) .. ")", 12, function(amount)
        if not amount then return end
        local lam = sol.to_lamports(amount)
        if not lam then ui.toast("Use a number like 0.1") return end
        if sol.cmp(lam, x.min_bid) < 0 or sol.cmp(lam, escrow.MIN_BID_FLOOR) < 0 then
          ui.toast("Below the min bid") return
        end
        if sol.cmp(lam, escrow.MAX_BID) > 0 then ui.toast("Max bid is 100 SOL") return end
        if x.open >= escrow.MAX_OPEN then
          if not p.lowest then ui.toast("Queue is full: try again") return end
          if sol.cmp(lam, p.need) < 0 then
            ui.toast("Bid at least " .. sol.format(p.need, 4) .. " SOL") return
          end
        end
        local r = {w = p.w, id = x.next_id, target = target, telegram = tg, bid = lam,
          lowest = p.lowest}
        if st.mock then r.pda = "demo-bid" end
        start_sign("bid", r, "mine")
      end)
    end)
  end)
end

-- With 5 open, a bid names the lowest open one (it is refunded) and its requester.
local function load_lowest(p, intro)
  local lo, need = escrow.lowest(p.introer)
  if not lo then return end
  chain.request_pdas(intro, {lo.id}, function(pdas)
    chain.account(pdas[1], function(ok, b)
      if st.pick ~= p then return end
      local q = ok and b and escrow.decode_request(b)
      if q and q.status == escrow.OPEN then
        p.lowest, p.need = {pda = pdas[1], requester = q.requester, bid = q.bid}, need
      end
      if st.screen == "introer" and st.w.full then
        st.w.full:text(p.lowest and ("Full: bid at least " .. sol.format(need, 4) .. " SOL")
          or "Full: can't read the lowest bid")
      end
    end)
  end)
end

local function build_introer()
  frame("introer")
  local p = st.pick
  ui.label(14, 30, sol.short(p.w), {size = 14, color = C.brand})
  if not p.introer then
    ui.label(14, 56, p.err or (p.introer == false and "Not an introer." or "Reading the chain..."),
      {size = 14, color = C.ink, w = 292})
    ui.hint("CANCEL back")
    return
  end
  local x = p.introer
  ui.label(14, 50, x.offer ~= "" and x.offer or "(no offer)", {size = 14, color = C.ink, w = 292})
  ui.label(14, 72, "min " .. sol.format(x.min_bid, 3) .. " SOL   open " .. x.open .. "/" .. escrow.MAX_OPEN
    .. "   jobs " .. x.jobs, {size = 12, color = C.dim, w = 292})
  ui.label(14, 88, "machine value " .. sol.format(value_of(x), 3) .. " SOL (demo value)",
    {size = 12, color = C.dim, w = 292})
  local full = x.open >= escrow.MAX_OPEN
  st.w.full = ui.label(14, 104, not full and "" or p.lowest and ("Full: bid at least " .. sol.format(p.need, 4)
    .. " SOL") or "Full: reading the queue...", {size = 12, color = C.orange, w = 292})
  ui.list(6, 122, 308, 36, {{title = "Bid for an intro", sub = "you sign on your phone"}},
    {on_select = function() ask_bid(p) end})
  ui.label(14, 166, "You pay only when you confirm.", {size = 12, color = C.ink})
  ui.label(14, 180, "No confirm 72h after made: refund.", {size = 12, color = C.dim})
  ui.hint("SELECT bid   CANCEL back")
end

local function load_introer(p)
  if st.mock then
    p.introer = demo.introer(p.w) or false
    if p.introer and p.introer.open >= escrow.MAX_OPEN then
      p.lowest, p.need = {pda = "demo-low", requester = "", bid = "150000000"}, "165000000"
    end
    return
  end
  local intro = escrow.introer_pda(solana.decode(p.w))
  chain.account(intro, function(ok, b)
    if st.pick ~= p then return end
    if not ok then p.err = tostring(b)
    else
      p.introer = b and escrow.decode_introer(b) or false
      if p.introer and p.introer.open >= escrow.MAX_OPEN then load_lowest(p, intro) end
    end
    if st.screen == "introer" then show_later("introer") end
  end)
end

-- Setup ------------------------------------------------------------------

local restart_poll  -- forward

-- Clears what came from the chain (or the demo), in memory and in storage.
local function reset_data()
  st.me, st.queue, st.rows, st.live, st.updated, st.spark, st.jobs = nil, nil, nil, {}, nil, {}, nil
  storage.remove("spark") storage.remove("jobs") storage.remove("live")
end

local function set_wallet(w)
  st.wallet = w
  if w then storage.set("wallet", w) else storage.remove("wallet") end
  st.mine = {}
  storage.remove("mine")
  reset_data()
  restart_poll()
end

local function setup_items()
  return {
    {title = "My wallet", right = st.wallet and sol.short(st.wallet) or "not set"},
    {title = st.me and "Update my offer" or "Register as an introer", sub = "sign on your phone"},
    {title = "Demo mode", sub = "pretend chain, no network", right = st.mock and "ON" or "OFF"},
    {title = "Clear wallet"},
  }
end

local function ask_offer()
  if not st.wallet and not st.mock then ui.toast("Set your wallet first") return end
  input("What can you intro?", escrow.OFFER, function(offer)
    if not offer or offer:gsub("%s", "") == "" then return end
    input("Min bid in SOL", 12, function(min)
      if not min then return end
      local lam = sol.to_lamports(min)
      if not lam or sol.cmp(lam, escrow.MIN_BID_FLOOR) < 0 then ui.toast("At least 0.01 SOL") return end
      if sol.cmp(lam, escrow.MAX_BID) > 0 then ui.toast("At most 100 SOL") return end
      start_sign(st.me and "update_introer" or "register_introer",
        {offer = offer, min_bid = lam, badge_id = (badge.id() or ""):sub(1, 8)}, "setup")
    end)
  end)
end

local function build_setup()
  frame("setup")
  local list
  list = ui.list(6, 26, 308, 144, setup_items(), {on_select = function(i)
    if i == 1 then
      input("Your wallet address", 44, function(text)
        if not text then return end
        text = text:gsub("%s", "")
        if not sol.is_wallet(text) then ui.toast("Not a Solana address") return end
        set_wallet(text)
        ui.toast("Wallet saved")
        show("home")
      end)
    elseif i == 2 then
      ask_offer()
    elseif i == 3 then
      st.mock = not st.mock
      storage.set("mock", st.mock)
      reset_data()
      restart_poll()
      list:items(setup_items())
      list:select(3)
      ui.toast(st.mock and "Demo mode on" or "Demo mode off")
    elseif i == 4 and st.wallet then
      confirm("Clear the wallet?", function(yes)
        if yes then
          set_wallet(nil)
          list:items(setup_items())
          ui.toast("Wallet cleared")
        end
      end)
    end
  end})
  ui.label(14, 176, "Your badge never holds keys.", {size = 12, color = C.dim})
  ui.hint("SELECT change   LEFT/RIGHT screens")
end

-- Screens ----------------------------------------------------------------

local BUILD = {
  home = build_home, queue = build_queue, hire = build_hire, find = build_find,
  mine = build_mine, setup = build_setup, action = build_action, sign = build_sign,
  introer = build_introer,
}
local BACK = {
  action = function() return st.role == "introer" and "queue" or "mine" end,
  introer = function() return "find" end,
  sign = function() return st.sign and st.sign.back or (st.role == "introer" and "queue" or "mine") end,
}

function show(name)
  st.dirty = nil
  if name == "home" and st.pending and not st.modal and not st.anim then
    st.screen = name
    local n = st.pending
    st.pending = nil
    return job_done(n)
  end
  if name == "introer" and st.screen ~= "introer" and st.pick and st.pick.introer == nil then
    load_introer(st.pick)
  end
  st.screen = name
  BUILD[name]()
end

-- Job done ---------------------------------------------------------------

local ANIM_MS = 2600

function job_done(n)
  if st.anim then return end
  if st.modal or st.screen ~= "home" then st.pending = (st.pending or 0) + n return end
  ui.clear()
  st.w = {}
  ui.bg(C.brand)
  local a = {t = 0}
  a.robot = art.robot_at(136, 40, 3)
  ui.label(0, 110, "JOB DONE!", {size = 32, color = C.white, w = ui.W, align = "center"})
  ui.label(0, 150, n > 1 and ("+" .. n .. " intros confirmed") or "+1 intro confirmed",
    {size = 14, color = C.desk, w = ui.W, align = "center"})
  st.anim = a
end

local function anim_tick(ms)
  local a = st.anim
  a.t = a.t + ms
  if a.robot then
    local phase = (a.t // 10) % 60
    local hop = phase < 30 and phase or 60 - phase
    a.robot:pos(136, 40 - hop)
  end
  if led then
    if a.t >= ANIM_MS then led.off()
    elseif (a.t // 150) % 2 == 0 then led.fill(0x6A, 0x50, 0xD8)
    else led.fill(0xA8, 0x52, 0x1A) end
  end
  if a.t >= ANIM_MS then
    st.anim = nil
    show(st.screen)
  end
end

-- Reading the chain --------------------------------------------------------

local function refresh()
  if st.anim then return end
  local s = st.screen
  if s == "home" then refresh_home()
  elseif s == "queue" then
    if st.me == false then if st.w.count ~= -1 then build_queue() end
    else refresh_rows(st.queue, "introer", build_queue) end
  elseif s == "mine" then refresh_rows(st.rows, "requester", build_mine)
  elseif s == "find" then refresh_find() end
end

-- A new copy of my introer account: value, spark, jobs.
local function got_me(me)
  st.me = me
  if not me then return end
  st.spark[#st.spark + 1] = sol.milli(value_of(me))
  while #st.spark > SPARK_N do table.remove(st.spark, 1) end
  local before = st.jobs
  st.jobs = me.jobs
  storage.set("spark", st.spark)
  if before ~= me.jobs then storage.set("jobs", me.jobs) end
  if before and me.jobs > before then job_done(me.jobs - before) end
end

local function fail(why)
  st.busy = nil
  st.status = tostring(why)
  refresh()
end

local function finish()
  st.busy, st.status, st.updated = nil, "ok", sys.millis()
  refresh()
end

-- My requests: read each saved bid; drop the closed ones.
local function read_mine(gen)
  local list = st.mine
  if #list == 0 then st.rows = {} return finish() end
  local pdas, k = {}, 1
  local function step()  -- one saved bid (two addresses) per callback
    if gen ~= st.gen then return end
    if k <= #list then
      local m = list[k]
      pdas[k] = escrow.request_pda(escrow.introer_pda(solana.decode(m.w)), m.id)
      k = k + 1
    end
    if k <= #list then timer.after(20, step) return end
    chain.many(pdas, function(ok, data)
      if gen ~= st.gen then return end
      if not ok then return fail(data) end
      local rows, keep, t = {}, {}, now()
      for i, m in ipairs(list) do
        if m.at == 0 and t then m.at = t end
        local q = data[i] and escrow.decode_request(data[i])
        if q then
          q.pda, q.w = pdas[i], m.w
          rows[#rows + 1] = q
          m.seen = true
          keep[#keep + 1] = m
        elseif not m.seen and (not t or m.at == 0 or t - m.at < 900) then
          keep[#keep + 1] = m  -- not landed yet
        end
      end
      st.rows = rows
      if #keep ~= #list then st.mine = keep; storage.set("mine", keep) end
      finish()
    end)
  end
  step()
end

local function read_queue(gen, me)
  local intro = escrow.introer_pda(my_bytes())
  local next = tonumber(me.next_id) or 0
  local ids, seen = {}, {}
  for id = next - 1, math.max(0, next - QUEUE_SCAN), -1 do
    ids[#ids + 1] = tostring(id)
    seen[ids[#ids]] = true
  end
  for id in pairs(st.live) do
    if not seen[id] and #ids < QUEUE_SCAN + 10 then ids[#ids + 1] = id end
  end
  chain.request_pdas(intro, ids, function(pdas)
    if gen ~= st.gen then return end
    chain.many(pdas, function(ok, data)
      if gen ~= st.gen then return end
      if not ok then return fail(data) end
      local rows, live = {}, {}
      for i = 1, #pdas do
        local q = data[i] and escrow.decode_request(data[i])
        if q then
          q.pda = pdas[i]
          rows[#rows + 1] = q
          live[ids[i]] = true
        end
      end
      table.sort(rows, function(a, b)  -- open first, then newest
        if a.status ~= b.status then return a.status < b.status end
        return #a.id > #b.id or (#a.id == #b.id and a.id > b.id)
      end)
      st.queue, st.live = rows, live
      local keep = {}
      for id in pairs(live) do if #keep < 20 then keep[#keep + 1] = id end end
      table.sort(keep)
      local was = storage.get("live")
      if type(was) ~= "table" or table.concat(was, ",") ~= table.concat(keep, ",") then storage.set("live", keep) end
      read_mine(gen)
    end)
  end)
end

function poll(force)
  if st.mock then
    st.mockdata = st.mockdata or demo.new(now())
    local d = st.mockdata
    demo.tick(d)
    local me = {}
    for k, v in pairs(d.me) do me[k] = v end
    st.queue, st.rows = d.queue, d.mine
    got_me(me)
    return finish()
  end
  if not st.wallet then st.status = "no wallet: open Setup" refresh() return end
  if st.sign and st.sign.timer and not force then return end  -- the watch has the rpc budget
  if st.busy and sys.millis() - st.busy < 30000 and not force then return end
  if not rpc then return fail("needs the rpc permission") end
  st.gen = st.gen + 1
  st.busy = sys.millis()
  local gen = st.gen
  chain.account(escrow.introer_pda(my_bytes()), function(ok, b)
    if gen ~= st.gen then return end
    if not ok then return fail(b) end
    local me = b and escrow.decode_introer(b)
    got_me(me or false)
    if me then read_queue(gen, me) else st.queue = {} read_mine(gen) end
  end)
end

function restart_poll()
  st.gen, st.busy, st.status, st.mockdata = st.gen + 1, nil, "starting", nil
  stop_sign()
  if st.poll_id then timer.cancel(st.poll_id) end
  st.poll_id = timer.every(POLL_MS, poll)
  poll()
end

-- Nearby: introers send their wallet over the mesh -------------------------

local function beacon()
  if not mesh or not st.wallet or not st.me then return end
  mesh.send("*", {k = "ib", w = st.wallet})
end

function on_mesh(from, msg)
  if type(msg) ~= "table" then return end
  if msg.k == "ib" and sol.is_wallet(msg.w) then
    local fresh = not st.nearby[msg.w]
    local n, t = 0, sys.millis()
    for w, x in pairs(st.nearby) do
      if t - x.at >= NEARBY_FOR then st.nearby[w] = nil else n = n + 1 end
    end
    if fresh and n >= 32 then return end
    st.nearby[msg.w] = {id = tostring(from), at = sys.millis()}
    if fresh and st.screen == "find" and not st.anim then refresh_find() end
  elseif msg.k == "ib?" then
    beacon()
  end
end

-- Keys and ticks ---------------------------------------------------------

local function tab_index()
  for k, n in ipairs(TABS) do if n == st.screen then return k end end
end

function on_key(key)
  if st.anim then return true end
  if key == "back" then
    local b = BACK[st.screen]
    if not b then return false end
    if st.screen == "sign" then
      b = b()
      stop_sign()
    else
      b = b()
    end
    show(b)
    return true
  end
  if key == "select" and st.screen == "sign" and st.retry then
    local s = st.retry
    st.retry = nil
    s.row.pda, s.row.lowest = nil, nil
    start_sign("bid", s.row, s.back)
    return true
  end
  local k = tab_index()
  if k and (key == "left" or key == "right") then
    show(TABS[(k - 1 + (key == "right" and 1 or -1)) % #TABS + 1])
  end
  return true
end

function on_tick(ms)
  if st.anim then return anim_tick(ms) end
  st.ago = st.ago + ms
  if st.ago >= 1000 then
    st.ago = st.ago - 1000
    if st.screen == "home" and st.w.status then st.w.status:text(ago_text()) end
    if st.scan_until and sys.millis() > st.scan_until then
      st.scan_until = nil
      if mesh and mesh.info and mesh.pause and not mesh.info().online then mesh.pause() end
    end
  end
end

function on_exit()
  if led then led.off() end
end

-- Start ------------------------------------------------------------------

-- The mesh can take the radio from Wi-Fi: keep Wi-Fi unless the user looks nearby.
if mesh and mesh.info and mesh.pause and not mesh.info().online then mesh.pause() end
timer.every(BEACON_MS, beacon)
show((st.wallet or st.mock) and "home" or "setup")
restart_poll()
