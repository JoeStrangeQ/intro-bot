-- Intro Bot: your badge shows your intro queue and takes bids by QR.
-- Never makes or stores keys: every action is signed on your phone (Solana Pay QR).
local sol = require("lib.sol")
local feed = require("lib.feed")
local art = require("lib.art")

local SITE = "https://intro.botbotcap.com"
local POLL_MS, MOCK_MS = 20000, 6000
local SPARK_N = 24
local C = {
  desk = 0xC9BFF2, brand = 0x6A50D8, ink = 0x241A52, paper = 0xF6F3FD,
  orange = 0xA8521A, white = 0xFFFFFF, dim = 0x6E6496, line = 0xDCD5F7,
}
local TABS = {"home", "hire", "queue", "setup"}
local TITLE = {
  home = "Intro Bot", hire = "Hire me", queue = "Queue", setup = "Setup",
  action = "Request", qr = "Sign on phone", reg = "Register",
}
local ACTIONS = {
  accept = "Accept", made = "Intro made", decline = "Decline",
}

-- State ------------------------------------------------------------------

local function load_spark()
  local s, out = storage.get("spark"), {}
  if type(s) == "table" then
    for k = 1, SPARK_N do
      if type(s[k]) ~= "number" then break end
      out[#out + 1] = s[k]
    end
  end
  return out
end

local st = {
  wallet = sol.is_wallet(storage.get("wallet")) and storage.get("wallet") or nil,
  mock = storage.get("mock") == true,
  spark = load_spark(),
  jobs = math.tointeger(storage.get("jobs")),
  data = feed.check(storage.get("last")),
  status = "starting",  -- "ok" or a short error
  updated = nil,        -- sys.millis() of the last good answer
  busy = nil,           -- sys.millis() when the request went out
  gen = 0,              -- bumps when the source changes; old answers are dropped
  screen = nil, w = {}, row = nil, act = nil, reg = nil, anim = nil,
  poll_id = nil, mockdata = nil, ago = 0,
}

-- Frame ------------------------------------------------------------------

local function hint(text) ui.hint(text) end

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

local function ago_text()
  if st.status ~= "ok" and st.status ~= "starting" then
    return st.status .. (st.updated and " - showing last data" or "")
  end
  if not st.updated then return "loading..." end
  local s = (sys.millis() - st.updated) // 1000
  return s < 2 and "updated now" or ("updated " .. s .. "s ago")
end

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

local function refresh_home()
  local w, d = st.w, st.data
  if not w.value then return end
  if d then
    w.value:text(sol.format(d.v, 3) .. " SOL")
    w.jobs:text(tostring(d.j))
    w.queue:text(tostring(#d.q))
    w.bid:text(sol.format(d.n, 3) .. " SOL")
  else
    w.value:text("-- SOL")
    w.jobs:text("-") w.queue:text("-") w.bid:text("-")
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
  st.w.queue = stat(84, "queue")
  ui.label(160, 92, "next min bid", {size = 12, color = C.dim})
  st.w.bid = ui.label(160, 106, "", {size = 20, color = C.ink})
  st.w.status = ui.label(14, 138, "", {size = 12, color = C.dim, w = 292})
  ui.rect(5, 162, 310, 1, {color = C.line})
  ui.label(5, 168, "Ask me about BotBot", {size = 14, color = C.ink, w = 310, align = "center"})
  ui.label(5, 184, "botbotcap.com", {size = 12, color = C.orange, w = 310, align = "center"})
  hint("LEFT/RIGHT screens   CANCEL exit")
  refresh_home()
end

-- Hire me ----------------------------------------------------------------

local function build_hire()
  frame("hire")
  local url = st.wallet and (SITE .. "/b/" .. st.wallet) or SITE
  if ui.qr then ui.qr(14, 32, 160, url) end
  ui.label(186, 36, "Hire me", {size = 20, color = C.brand})
  ui.label(186, 64, "Scan to bid", {size = 14, color = C.ink})
  ui.label(186, 82, "for an intro.", {size = 14, color = C.ink})
  if st.wallet then
    ui.label(186, 110, sol.short(st.wallet), {size = 12, color = C.dim})
  else
    ui.label(186, 110, "No wallet yet:", {size = 12, color = C.dim})
    ui.label(186, 124, "set it in Setup", {size = 12, color = C.dim})
  end
  if st.data then
    ui.label(186, 146, "min " .. sol.format(st.data.n, 3) .. " SOL", {size = 12, color = C.ink})
  end
  ui.label(186, 176, "botbotcap.com", {size = 12, color = C.orange})
  hint("LEFT/RIGHT screens   CANCEL exit")
end

-- Queue ------------------------------------------------------------------

local show  -- forward

local function queue_items()
  local items = {}
  for k, r in ipairs(st.data and st.data.q or {}) do
    items[k] = {
      title = r.t ~= "" and r.t or "(no target)",
      sub = (r.g ~= "" and r.g .. "  " or "") .. sol.format(r.b, 3) .. " SOL",
      right = r.s,
    }
  end
  return items
end

local function build_queue()
  frame("queue")
  local items = queue_items()
  if #items == 0 then
    ui.label(5, 80, st.data and "No requests yet" or "Waiting for data...",
      {size = 14, color = C.ink, w = 310, align = "center"})
    ui.label(5, 104, "Share your Hire me QR", {size = 12, color = C.dim, w = 310, align = "center"})
  else
    st.w.list = ui.list(6, 26, 308, 172, items, {on_select = function(i)
      local r = st.data and st.data.q[i]
      if r then
        st.row = r
        show("action")
      end
    end})
  end
  st.w.count = #items
  hint("SELECT open   LEFT/RIGHT screens   CANCEL exit")
end

local function refresh_queue()
  local items = queue_items()
  if st.w.list and #items > 0 then
    local sel = st.w.list:selected() or 1
    st.w.list:items(items)
    st.w.list:select(math.min(sel, #items))
  elseif #items ~= st.w.count then
    build_queue()
  end
end

-- Which signed actions fit a request's status.
local function actions_for(s)
  if s == "open" then return {"accept", "decline"} end
  if s == "active" or s == "accepted" then return {"made"} end
  return {}
end

local function build_action()
  frame("action")
  local r = st.row
  ui.label(14, 32, r.t, {size = 14, color = C.ink, w = 292})
  ui.label(14, 52, (r.g ~= "" and r.g .. "   " or "") .. "bid " .. sol.format(r.b) .. " SOL",
    {size = 12, color = C.dim, w = 292})
  ui.label(14, 68, "status: " .. r.s, {size = 12, color = C.dim, w = 292})
  local keys = actions_for(r.s)
  if #keys == 0 then
    ui.label(14, 110, "Nothing to sign here.", {size = 14, color = C.ink})
    ui.label(14, 130, "Finish it on the web page.", {size = 12, color = C.dim})
    hint("CANCEL back")
    return
  end
  local items = {}
  for k, a in ipairs(keys) do items[k] = ACTIONS[a] end
  ui.list(6, 88, 308, 36 * #keys, items, {on_select = function(i)
    st.act = keys[i]
    show("qr")
  end})
  hint("SELECT show QR   CANCEL back")
end

local function build_qr(name, url, line1, line2)
  frame(name)
  if #url > 256 then
    ui.label(14, 60, "Link too long for a QR.", {size = 14, color = C.ink})
  elseif ui.qr then
    ui.qr(14, 32, 160, url)
  end
  ui.label(186, 36, line1, {size = 14, color = C.brand, w = 124})
  ui.label(186, 60, line2, {size = 12, color = C.ink, w = 124})
  ui.label(186, 76, "Scan with your", {size = 12, color = C.dim})
  ui.label(186, 90, "phone wallet.", {size = 12, color = C.dim})
  if st.mock then ui.label(186, 120, "Demo: not real", {size = 12, color = C.orange}) end
  hint("CANCEL back")
end

-- Setup ------------------------------------------------------------------

local restart_poll  -- forward

local function set_wallet(w)
  st.wallet = w
  if w then storage.set("wallet", w) else storage.remove("wallet") end
  st.data, st.updated, st.spark, st.jobs = nil, nil, {}, nil
  storage.remove("last") storage.remove("spark") storage.remove("jobs")
  restart_poll()
end

local function setup_items()
  return {
    {title = "Wallet", right = st.wallet and sol.short(st.wallet) or "not set"},
    {title = "Register this badge", sub = "QR, sign on your phone"},
    {title = "Demo mode", sub = "fake data, no server", right = st.mock and "ON" or "OFF"},
    {title = "Clear wallet"},
  }
end

local function ask_register()
  ui.input("What can you intro?", 32, function(offer)
    if not offer or offer == "" then return end
    ui.input("Min bid in SOL", 9, function(min)
      local lam = sol.to_lamports(min)
      if not lam then ui.toast("Use a number like 0.05") return end
      st.reg = "solana:" .. SITE .. "/api/tx/register?badge=" .. sol.urlencode(badge.id() or "")
        .. "&offer=" .. sol.urlencode(offer) .. "&min=" .. lam
      show("reg")
    end)
  end)
end

local function build_setup()
  frame("setup")
  local list
  list = ui.list(6, 26, 308, 144, setup_items(), {on_select = function(i)
    if i == 1 then
      ui.input("Your wallet address", 44, function(text)
        if not text then return end
        text = text:gsub("%s", "")
        if not sol.is_wallet(text) then ui.toast("Not a Solana address") return end
        set_wallet(text)
        ui.toast("Wallet saved")
        show("home")
      end)
    elseif i == 2 then
      ask_register()
    elseif i == 3 then
      st.mock = not st.mock
      storage.set("mock", st.mock)
      st.data, st.updated, st.spark, st.jobs = nil, nil, {}, nil
      restart_poll()
      list:items(setup_items())
      list:select(3)
      ui.toast(st.mock and "Demo mode on" or "Demo mode off")
    elseif i == 4 and st.wallet then
      ui.confirm("Clear the wallet?", function(yes)
        if yes then
          set_wallet(nil)
          list:items(setup_items())
          ui.toast("Wallet cleared")
        end
      end)
    end
  end})
  ui.label(14, 176, "Your badge never holds keys.", {size = 12, color = C.dim})
  hint("SELECT change   LEFT/RIGHT screens   CANCEL exit")
end

-- Screens ----------------------------------------------------------------

local BUILD = {
  home = build_home, hire = build_hire, queue = build_queue, setup = build_setup,
  action = build_action,
  qr = function()
    build_qr("qr", "solana:" .. SITE .. "/api/tx/" .. st.act .. "?request=" .. sol.urlencode(st.row.i),
      ACTIONS[st.act], st.row.t)
  end,
  reg = function() build_qr("reg", st.reg, "Register", "as an introer") end,
}
local BACK = {action = "queue", qr = "action", reg = "setup"}

function show(name)
  st.screen = name
  BUILD[name]()
end

-- Job done ---------------------------------------------------------------

local ANIM_MS = 2600

local function job_done(n)
  if st.anim then return end
  ui.clear()
  st.w = {}
  ui.bg(C.brand)
  local a = {t = 0}
  a.robot = art.robot_at(136, 40, 3)
  ui.label(0, 110, "JOB DONE!", {size = 32, color = C.white, w = ui.W, align = "center"})
  ui.label(0, 150, n > 1 and ("+" .. n .. " intros made") or "+1 intro made",
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

-- Polling ----------------------------------------------------------------

local function refresh()
  if st.anim then return end
  if st.screen == "home" then refresh_home()
  elseif st.screen == "queue" then refresh_queue() end
end

local function apply(d)
  st.data, st.status, st.updated = d, "ok", sys.millis()
  st.spark[#st.spark + 1] = sol.milli(d.v)
  while #st.spark > SPARK_N do table.remove(st.spark, 1) end
  local before = st.jobs
  st.jobs = d.j
  storage.set("last", d) storage.set("spark", st.spark) storage.set("jobs", d.j)
  if before and d.j > before then job_done(d.j - before) else refresh() end
end

local function fail(why)
  st.status = tostring(why)
  refresh()
end

local function poll()
  if st.mock then
    st.mockdata = st.mockdata or feed.mock_new()
    apply(feed.mock_step(st.mockdata))
    return
  end
  if not st.wallet then st.status = "no wallet: open Setup" refresh() return end
  if st.busy and sys.millis() - st.busy < 15000 then return end
  st.busy = sys.millis()
  local gen = st.gen
  http.get(SITE .. "/api/badge/" .. st.wallet, {["Accept"] = "application/json"}, function(ok, res)
    if gen ~= st.gen then return end
    st.busy = nil
    if not ok then return fail(res) end
    if res.status ~= 200 then return fail("server error " .. tostring(res.status)) end
    if res.truncated then return fail("answer too big") end
    local d, err = feed.parse(res.body)
    if not d then return fail(err) end
    apply(d)
  end)
end

function restart_poll()
  st.gen, st.busy, st.status, st.mockdata = st.gen + 1, nil, "starting", nil
  if st.poll_id then timer.cancel(st.poll_id) end
  st.poll_id = timer.every(st.mock and MOCK_MS or POLL_MS, poll)
  poll()
end

-- Keys and ticks ---------------------------------------------------------

local function tab_index()
  for k, n in ipairs(TABS) do if n == st.screen then return k end end
end

function on_key(key)
  if st.anim then return true end
  local k = tab_index()
  if key == "back" then
    if BACK[st.screen] then show(BACK[st.screen]) return true end
    return false
  end
  if k and (key == "left" or key == "right") then
    show(TABS[(k - 1 + (key == "right" and 1 or -1)) % #TABS + 1])
    return true
  end
  if st.screen == "home" and key == "select" then show("hire") return true end
  return true
end

function on_tick(ms)
  if st.anim then return anim_tick(ms) end
  st.ago = st.ago + ms
  if st.ago >= 1000 then
    st.ago = st.ago - 1000
    if st.screen == "home" and st.w.status then st.w.status:text(ago_text()) end
  end
end

function on_exit()
  if led then led.off() end
end

show((st.wallet or st.mock) and "home" or "setup")
restart_poll()
