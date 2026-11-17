-- Intro Bot: the intro board, paid in !LAMPs (docs/spec-lamps.md). Post a job ("introduce me
-- to..."), people offer, you pick one after talking on Telegram, then pay in person (the
-- badges meet: full bid) or over Telegram (half). The bid waits in the app's !LAMP escrow;
-- our server (lib/api.lua) keeps the board and pays out. The badge holds no keys: the badge server signs who is asking.
local api = require("lib.api")
local art = require("lib.art")
local list = require("lib.list")

local ESCROW = "ESC-GQD4T2WC"
local MIN_BID, MAX_BID, TEXT = 10, 500, 31
local BONUS = 50  -- !LAMPs the app awards an introer per in-person intro (lamps.award); half over Telegram
local POLL_MS, SPARK_N = 20000, 24
local C = {
  desk = 0xC9BFF2, brand = 0x6A50D8, ink = 0x000000, paper = 0xF6F3FD,
  orange = 0x8A3A0A, white = 0xFFFFFF, dim = 0x000000, line = 0xDCD5F7,
}
local TABS = {"board", "fleet", "request", "myjobs", "myoffers", "profile"}
local IS_TAB = {request = true, board = true, fleet = true, myjobs = true, myoffers = true, profile = true}
local TITLE = {
  request = "Request an intro", board = "Intro board", fleet = "Badge Fleet", myjobs = "My jobs",
  myoffers = "My offers", profile = "Profile", job = "Job", inperson = "Pay in person",
  getpaid = "Get paid in person",
}
local LABEL = {
  offer = "Offer to make this intro", withdraw = "Withdraw my offer", cancel = "Remove: bid back",
  edit = "Edit who, company, Telegram", remove = "Remove (not paid)",
  inperson = "Pay in person: full bid", telegram = "Pay over Telegram: half",
  getpaid = "Get paid in person", refund = "Refund my bid", pay = "Pay the bid", raise = "Raise the bid",
}
local STATUS = {open = "Open", approved = "Picked", closed = "Closed"}

-- A job's status in a word. Every bid is paid into escrow when posted; a post waits
-- off the board ("Paying") until its deposit lands.
local function status(j)
  if j.st == "pending" then return "Paying" end
  return STATUS[j.st] or j.st or ""
end
local TABHINT = "LEFT/RIGHT screens   CANCEL home"
-- LEDs while the app is open: the logo's rainbow bands across the top (1..6, same
-- order), lavender on the right edge (7..8). LEFT runs a flicker left to right,
-- RIGHT right to left; the home screen keeps it running.
local BANDS = {0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC}
local SIDE = 0xC9BFF2
local STEP_MS = 70
local sweep = nil   -- {dir = 1 | -1, t = ms, loop = bool}

local function led_set(i, c)
  led.set(i, c >> 16, (c >> 8) & 0xFF, c & 0xFF)
end

-- `dark`: the top light (1..6) shown off for this frame of a flicker.
local function brand_led(dark)
  if not led then return end
  for i = 1, led.count or 8 do
    led_set(i, i == dark and 0 or (BANDS[i] or SIDE))
  end
end

local function flicker(dir, loop)
  sweep = {dir = dir, t = 0, loop = loop}
  brand_led(dir == 1 and 1 or #BANDS)
end

local function sweep_tick(ms)
  if not sweep then return end
  sweep.t = sweep.t + ms
  local k = sweep.t // STEP_MS + 1
  if k > #BANDS then
    if sweep.loop then sweep.t = 0 k = 1 else sweep = nil return brand_led() end
  end
  brand_led(sweep.dir == 1 and k or #BANDS + 1 - k)
end

local function still()
  sweep = nil
  brand_led()
end

local CTA = "Robots that earn: botbotcap.com"
local CTA_EARNED = "This badge just earned. Your robots can too: botbotcap.com"
local CTA_PAID = "Paid! Robots that earn: botbotcap.com"
local SITE = "https://botbotcap.com"
local X = "https://x.com/botbotcap"

local function lp(n) return tostring(n or 0) .. " !LAMPs" end

-- State ------------------------------------------------------------------

local function stored_spark()
  local s, out = storage.get("spark"), {}
  if type(s) == "table" then
    for k = 1, SPARK_N do
      if type(s[k]) ~= "number" then break end
      out[k] = s[k]
    end
  end
  return out
end

local st = {
  tg = type(storage.get("tg")) == "string" and storage.get("tg") or nil,
  spark = stored_spark(),
  jobs = math.tointeger(storage.get("jobs")),
  me = nil,        -- /me: {reg, name, jobs, earned, value, mine, offers}
  board = nil,     -- /board jobs
  fleet = nil,     -- /fleet: {paid, jobs}
  pick = nil,      -- /jobs/<id> of the open job
  status = "starting", updated = nil, gen = 0,
  screen = nil, w = {}, anim = nil, modal = nil, pending = nil, dirty = nil, ago = 0,
  meet = nil,
}

-- Calls to the server ------------------------------------------------------

local function call(method, path, body, cb)
  if method == "GET" then
    api.get(path, cb)
  else
    api.post(path, body, cb)
  end
end

-- Frame ------------------------------------------------------------------

local function frame(name)
  ui.clear()
  list.reset()
  st.w = {}
  ui.bg(C.desk)
  ui.rect(4, 4, 312, 196, {color = C.ink})
  ui.rect(5, 5, 310, 194, {color = C.paper})
  ui.rect(5, 5, 310, 20, {color = C.brand})
  art.logo(8, 8, 1)
  ui.label(26, 7, TITLE[name], {size = 14, color = C.white})
  local tag = st.me and st.me.reg and st.me.name or ""
  ui.label(160, 9, tag, {size = 12, color = C.white, w = 150, align = "right"})
end

local function center(y, text, size, color)
  return ui.label(5, y, text, {size = size or 14, color = color or C.ink, w = 310, align = "center"})
end

local function line(y, text, color, size)
  return ui.label(14, y, text, {size = size or 12, color = color or C.dim, w = 292})
end

local function ago_text()
  if st.status ~= "ok" and st.status ~= "starting" then
    return st.status .. (st.updated and " - showing last data" or "")
  end
  if not st.updated then return "loading..." end
  local s = (sys.millis() - st.updated) // 1000
  return s < 2 and "updated now" or ("updated " .. s .. "s ago")
end

-- Modals: redraws and the receipt animation wait until they close -----------

local job_done, show, poll, sig  -- forward

local function modal(open, ...)
  local args = table.pack(...)
  local cb = args[args.n]
  args[args.n] = function(v)
    st.modal = nil
    cb(v)
    if st.modal or st.anim then return end
    if st.pending and IS_TAB[st.screen] then
      local n = st.pending
      st.pending = nil
      job_done(n)
    elseif st.dirty then
      st.dirty = nil
      show(st.screen)
    end
  end
  st.modal = true
  open(table.unpack(args, 1, args.n))
end

local function input(prompt, max, cb) modal(ui.input, prompt, max, cb) end
local function confirm(text, cb) modal(ui.confirm, text, cb) end

local function show_later(name)
  if st.anim or st.modal then
    st.screen, st.dirty = name, true
  else
    show(name)
  end
end

-- Paying: the OS asks the owner, then the server sees it in the escrow -----

local DAY_CAP = 500  -- the badge lets a user pay at most 500 !LAMPs a day

-- `posting`: a new post; if the OS refuses, the post is removed so nothing unpaid is left.
local function pay(id, bid, memo, posting)
  if not lamps then return ui.toast("Needs the lamps permission") end
  -- JSON numbers can come back as floats (100.0); the OS wants a whole number.
  local amount = math.tointeger(tonumber(bid))
  if not amount then return ui.toast("Bad bid") end
  if st.bal and amount > st.bal then return ui.toast("You have " .. lp(st.bal)) end
  local function sent(ok, res)
    if not ok then
      local today = st.me and tonumber(st.me.dep_today) or 0
      if res == "denied" and today + amount > DAY_CAP then
        ui.toast("Badge limit: 500 !LAMPs a day, refunds don't count back")
      else
        ui.toast("Not paid: " .. tostring(res))
      end
      -- Tell the server exactly what the OS said (and the balance), for its logs.
      lamps.balance(function(okb, bal)
        call("POST", "/log", {what = "deposit", job = id, amount = amount, why = tostring(res),
          balance = okb and bal or tostring(bal)}, function() end)
      end)
      if posting then call("POST", "/jobs/" .. id .. "/remove", {}, function() poll(true) end) end
      return
    end
    call("POST", "/jobs/" .. id .. "/paid", {deposit = res and res.id}, function(ok2, j)
      if memo then ui.toast("Paid. Bid raised in a moment.")
      else ui.toast(ok2 and j.st == "open" and "Posted!" or "Paid. On the board in a moment.") end
      poll(true)
      show_later("myjobs")
    end)
  end
  lamps.deposit(tostring(ESCROW), amount, memo or ("job " .. tostring(id)), sent)
end

-- Asks for a bid, showing what the owner can pay: their balance, and what is left of the
-- badge's 500 a day (the server counts today's deposits). cb(bid, can_pay) or nothing.
local function ask_bid(title, cb)
  local function ask()
    local today = st.me and tonumber(st.me.dep_today) or 0
    local left = math.max(0, DAY_CAP - today)
    local prompt = title
    if st.bal then
      left = math.min(left, st.bal)
      prompt = title .. (left < st.bal and (" (have " .. st.bal .. ", " .. left .. " today)")
        or (" (you have " .. st.bal .. ")"))
    end
    input(prompt, 3, function(amount)
      if not amount then return end
      local bid = math.tointeger(tonumber(amount))
      if not bid then return ui.toast("Use a whole number like 50") end
      cb(bid, left)
    end)
  end
  if not lamps then return ask() end
  lamps.balance(function(ok, bal)
    st.bal = ok and math.tointeger(tonumber(bal)) or nil
    ask()
  end)
end

-- Request an intro ---------------------------------------------------------

local function ask_tg(then_do)
  input("Your Telegram @handle", TEXT, function(tg)
    if not tg then return end
    tg = tg:gsub("%s", "")
    if tg == "" or tg == "@" then ui.toast("Telegram is required") return end
    if tg:sub(1, 1) ~= "@" then tg = "@" .. tg end
    st.tg = tg
    storage.set("tg", tg)
    if then_do then then_do(tg) else show("request") end
  end)
end

local function ask_job()
  input("Who do you want to meet?", TEXT, function(who)
    if not who or who:gsub("%s", "") == "" then return end
    input("Their company", TEXT, function(co)
      if not co or co:gsub("%s", "") == "" then return end
      ask_bid("Bid in !LAMPs", function(bid, left)
        if bid < MIN_BID or bid > MAX_BID then ui.toast(MIN_BID .. " to " .. MAX_BID .. " !LAMPs") return end
        -- Every bid is paid when posted: refuse what the owner can't pay now.
        if st.bal and bid > st.bal then return ui.toast("You have " .. lp(st.bal)) end
        if bid > left then return ui.toast("You can pay " .. lp(left) .. " today (badge limit 500)") end
        local function post(tg)
          call("POST", "/jobs", {who = who, co = co, tg = tg, bid = bid}, function(ok, r)
            if not ok then return ui.toast(tostring(r)) end
            pay(r.id, bid, nil, true)
          end)
        end
        if st.tg then post(st.tg) else ask_tg(post) end
      end)
    end)
  end)
end

local function build_request()
  frame("request")
  art.logo(14, 30, 3)
  ui.label(60, 32, "Who do you want to meet?", {size = 14, color = C.brand})
  ui.label(60, 50, "Post it. Introers offer. You pick one.", {size = 12, color = C.ink})
  list.new(6, 68, 308, 72, {
    {title = "Request an intro", sub = "who, company, bid in !LAMPs"},
    {title = "My Telegram", right = st.tg or "not set"},
  }, {on_select = function(i) if i == 1 then ask_job() else ask_tg() end end})
  line(144, "Offerers see your Telegram.", C.ink)
  line(158, "Bid waits in escrow till you pay.")
  ui.rect(5, 174, 310, 1, {color = C.line})
  center(180, CTA, 14, C.ink)
  ui.hint(TABHINT)
end

-- Lists of jobs ------------------------------------------------------------

local function job_item(j, role)
  local right = status(j)
  if role == "introer" then
    right = j.st == "open" and "Waiting" or (j.me and "You!" or "Not picked")
  elseif role == "board" and j.o then
    right = "Offered"
  end
  return {
    title = j.who .. " @ " .. j.co,
    sub = lp(j.bid) .. "   " .. (j.n == 1 and "1 offer" or (j.n .. " offers")),
    right = right,
  }
end

-- What a list shows, as one string: redraw only when it changes.
function sig(rows)
  if not rows then return "-" end
  local t = {}
  for k, j in ipairs(rows) do t[k] = j.id .. j.st .. j.n .. tostring(j.o) .. tostring(j.met) .. tostring(j.me) .. tostring(j.f) end
  return table.concat(t, ",")
end

local LEAD = {title = "+ Request an intro", sub = "who, company, bid"}

local function rows_for(role)
  if role == "board" then return st.board end
  local me = st.me
  return me and (role == "requester" and me.mine or me.offers) or nil
end

local function open_job(j)
  st.pick = {id = j.id, who = j.who, co = j.co, bid = j.bid, n = j.n, st = j.st, acts = {}, loading = true}
  show("job")
  call("GET", "/jobs/" .. j.id, nil, function(ok, d)
    if not st.pick or st.pick.id ~= j.id then return end
    if not ok then st.pick.loading = tostring(d) else st.pick = d end
    if st.screen == "job" then show_later("job") end
  end)
end

local function build_jobs(name, role, empty, empty2)
  frame(name)
  local rows = rows_for(role)
  local items, off = {}, role == "board" and 1 or 0
  if off == 1 then items[1] = LEAD end
  for k, j in ipairs(rows or {}) do items[k + off] = job_item(j, role) end
  if #items == off then
    if off == 1 then list.new(6, 26, 308, 44, items, {on_select = function() ask_job() end}) end
    center(off == 1 and 100 or 80, rows and empty or "Loading...")
    if rows and empty2 then center(off == 1 and 124 or 104, empty2, 12, C.dim) end
  else
    list.new(6, 26, 308, 172, items, {on_select = function(i)
      if off == 1 and i == 1 then return ask_job() end
      local j = (rows_for(role) or {})[i - off]
      if j then open_job(j) end
    end})
  end
  st.w.sig = sig(rows)
  ui.hint(#items > off and "SELECT open   LEFT/RIGHT screens" or TABHINT)
end

local function build_board() build_jobs("board", "board", "No requests yet", "Be the first: + Request an intro") end
local function build_myjobs() build_jobs("myjobs", "requester", "No jobs yet", "Request an intro to post one") end
local function build_myoffers() build_jobs("myoffers", "introer", "No offers yet", "Offer on a job in the board") end

-- One job ------------------------------------------------------------------

local function do_act(j, a, n)
  if a == "inperson" then st.meet = {job = j.id, who = j.picked, badge = j.pbadge, bid = j.bid} return show("inperson") end
  if a == "getpaid" then st.meet = {job = j.id, who = j.who} return show("getpaid") end
  if a == "pay" then return pay(j.id, j.bid) end
  if a == "raise" then
    return ask_bid("New bid, now " .. math.tointeger(tonumber(j.bid) or 0), function(bid, left)
      if bid <= (tonumber(j.bid) or 0) or bid > MAX_BID then
        return ui.toast("More than " .. lp(j.bid) .. ", up to " .. MAX_BID)
      end
      local diff = bid - math.tointeger(tonumber(j.bid))
      if st.bal and diff > st.bal then return ui.toast("You have " .. lp(st.bal)) end
      if diff > left then return ui.toast("You can pay " .. lp(left) .. " today (badge limit 500)") end
      call("POST", "/jobs/" .. j.id .. "/raise", {bid = bid}, function(ok, d)
        if not ok then return ui.toast(tostring(d)) end
        st.pick = d
        poll(true)
        -- Pay the difference; the server adds it once it lands.
        if d.raise then return pay(j.id, d.raise.diff, d.raise.memo) end
        ui.toast(tostring(d.error or "Not raised"))
      end)
    end)
  end
  if a == "offer" and not st.tg then return ask_tg(function() do_act(j, a, n) end) end
  local function go()
    call("POST", "/jobs/" .. j.id .. "/" .. a, {n = n, name = st.tg}, function(ok, d)
      if not ok then return ui.toast(tostring(d)) end
      ui.toast(a == "telegram" and CTA_PAID or (LABEL[a] or a) .. ": done")
      st.pick = d
      poll(true)
      show_later("job")
    end)
  end
  if a == "cancel" then return confirm("Remove this job and get your bid back?", function(y) if y then go() end end) end
  if a == "remove" then
    return confirm("Remove this job? Nothing was paid.", function(y)
      if not y then return end
      call("POST", "/jobs/" .. j.id .. "/remove", {}, function(ok, d)
        if not ok then return ui.toast(tostring(d)) end
        ui.toast("Removed")
        st.pick = nil
        poll(true)
        show_later("myjobs")
      end)
    end)
  end
  if a == "edit" then
    -- Empty or cancelled keeps what was there.
    local function keep(v) return v and v:gsub("%s", "") ~= "" and v or nil end
    return input("Who (empty keeps " .. j.who .. ")", TEXT, function(who)
      input("Company (empty keeps " .. j.co .. ")", TEXT, function(co)
        input("Telegram (empty keeps it)", TEXT, function(tg)
          local body = {who = keep(who), co = keep(co), tg = keep(tg)}
          if not (body.who or body.co or body.tg) then return ui.toast("Nothing changed") end
          call("POST", "/jobs/" .. j.id .. "/edit", body, function(ok, d)
            if not ok then return ui.toast(tostring(d)) end
            ui.toast("Saved")
            st.pick = d
            poll(true)
            show_later("job")
          end)
        end)
      end)
    end)
  end
  if a == "telegram" then
    local bid = math.tointeger(tonumber(j.bid)) or 0
    local half = bid // 2
    return confirm("Paid over Telegram? " .. (j.picked or "They") .. " gets " .. lp(half) .. ", "
      .. lp(bid - half) .. " back to you.", function(y) if y then go() end end)
  end
  go()
end

local function build_job()
  frame("job")
  local j = st.pick
  ui.label(14, 30, j.who .. " @ " .. j.co, {size = 14, color = C.ink, w = 292})
  line(48, "bid " .. lp(j.bid) .. "   " .. (j.n or 0) .. " offers   " .. status(j))
  if j.loading then
    center(100, j.loading == true and "Loading..." or j.loading)
    ui.hint("CANCEL back")
    return
  end
  local y = 64
  if j.tg then
    line(y, "Telegram:", C.dim)
    ui.label(84, y - 4, j.tg, {size = 20, color = C.brand})
    y = y + 22
  elseif not j.mine and j.st == "open" then
    line(y, "Telegram shown after you offer.")
    y = y + 16
  end
  if j.picked then
    line(y, "Picked: " .. j.picked, C.ink)
    y = y + 16
  end
  local items, act = {}, {}
  -- The picked introer's side of paying in person (no server action: their badge just signs).
  local acts = j.acts or {}
  if j.me and j.st == "approved" then acts = {"getpaid"} end
  for _, a in ipairs(acts) do
    items[#items + 1] = {title = LABEL[a] or a}
    act[#act + 1] = {a}
  end
  if j.mine and j.st == "open" then
    if #(j.pool or {}) == 0 then
      line(y, "No offers yet.", C.ink)
      y = y + 16
    end
    for k, p in ipairs(j.pool or {}) do
      items[#items + 1] = {title = "Approve " .. p.name, sub = "jobs " .. p.jobs .. "   earned " .. lp(p.earned)}
      act[#act + 1] = {"approve", k - 1}
    end
  end
  if #items > 0 then
    list.new(6, y + 2, 308, math.min(196 - y - 18, 36 * #items), items, {on_select = function(i)
      local a = act[i]
      if a then do_act(j, a[1], a[2]) end
    end})
  end
  if j.mine and j.st == "pending" then
    line(178, "Not paid yet: pay or remove.", C.ink)
  elseif j.mine and j.st == "open" then
    line(178, "Raise the bid in the list.", C.dim)
  elseif j.mine and j.st == "approved" then
    line(178, "In person pays more. Meet up!", C.ink)
  elseif j.me and j.st == "approved" then
    line(178, "Open Get paid when you meet them.", C.ink)
  end
  ui.hint(#items > 0 and "SELECT choose   CANCEL back" or "CANCEL back")
end

-- Paying in person: the badges meet over the mesh ---------------------------
-- The requester's badge lists badges nearby, they pick the introer and confirm, both badges
-- sign a meet {job, pay}, and the server pays the full bid. The introer opens Get paid so
-- their badge is on the mesh and signs only for this job. Wi-Fi pauses while the mesh is on
-- (one radio), so the payment call waits for Wi-Fi to come back.

local function meet_text(a, b)
  if not st.w.m1 then return end
  st.w.m1:text(a)
  st.w.m2:text(b or "")
end

local function mesh_on()
  if not mesh or not mesh.meet then return false end
  if mesh.resume then mesh.resume() end
  return true
end

local function leave_meet()
  if mesh and mesh.pause then mesh.pause() end
  st.meet = nil
end

local function back_to_job(id)
  call("GET", "/jobs/" .. id, nil, function(ok, d)
    if ok then
      st.pick = d
      show_later("job")
    end
  end)
end

-- After a meet, Wi-Fi takes a few seconds to rejoin: retry the call until it answers.
local function call_online(method, path, body, cb, tries)
  call(method, path, body, function(ok, d)
    if not ok and d == "offline" and (tries or 0) < 20 then
      return timer.after(1500, function() call_online(method, path, body, cb, (tries or 0) + 1) end)
    end
    cb(ok, d)
  end)
end

-- Badges nearby, the picked introer's first.
local function nearby(m)
  local out = {}
  for _, p in ipairs(mesh and mesh.nearby and mesh.nearby() or {}) do
    if p.kind == "badge" then
      if p.id == m.badge then table.insert(out, 1, p) else out[#out + 1] = p end
    end
  end
  return out
end

local function paid_in_person(m, peer)
  meet_text("Met! Paying " .. lp(m.bid) .. "...", "Waiting for Wi-Fi")
  if mesh and mesh.pause then mesh.pause() end
  call_online("POST", "/jobs/" .. m.job .. "/inperson", {badge = peer.id}, function(ok, d)
    if st.meet ~= m then return end
    st.meet = nil
    if not ok then
      ui.toast(tostring(d))
      return back_to_job(m.job)
    end
    ui.toast(CTA_PAID)
    if led then
      led.fill(0x61, 0xBB, 0x46)
      timer.after(600, brand_led)
    end
    st.pick = d
    poll(true)
    show_later("job")
  end)
end

local function pick_peer(m, peer)
  local name = peer.name or peer.id
  confirm("Pay " .. name .. " " .. lp(m.bid) .. " now?", function(y)
    if not y or st.meet ~= m then return end
    meet_text("Asking " .. name .. "...", "Their badge signs too")
    local ok, err = mesh.meet(peer.id, {job = m.job, pay = 1}, function(done, res)
      if st.meet ~= m then return end
      if done then return paid_in_person(m, peer) end
      meet_text("Not met: " .. tostring(res), "Ask them to open Get paid")
    end)
    if not ok then meet_text("Not met: " .. tostring(err), "Try again") end
  end)
end

local function draw_nearby()
  local m = st.meet
  if st.screen ~= "inperson" or not m then return end
  local peers = nearby(m)
  local key = ""
  for _, p in ipairs(peers) do key = key .. p.id .. "," end
  if key == st.w.near_key then return end
  st.w.near_key = key
  if st.w.near then st.w.near:remove() st.w.near = nil end
  if #peers == 0 then return meet_text("No badges nearby yet", "Ask " .. (m.who or "them") .. " to open Get paid") end
  meet_text("", "")
  local items = {}
  for k, p in ipairs(peers) do
    items[k] = {title = p.name or p.id, right = p.id == m.badge and "picked" or p.id}
  end
  st.w.near = list.new(6, 70, 308, 108, items, {on_select = function(i)
    local p = peers[i]
    if p then pick_peer(m, p) end
  end})
end

local function build_inperson()
  frame("inperson")
  local m = st.meet
  ui.label(14, 30, "Pick " .. (m.who or "your introer") .. " from badges nearby", {size = 12, color = C.ink, w = 292})
  ui.label(14, 46, "Pays " .. lp(m.bid) .. ", plus their bonus.", {size = 12, color = C.ink, w = 292})
  st.w.m1 = center(100, "Looking for badges...", 14, C.ink)
  st.w.m2 = center(120, "", 12, C.dim)
  ui.hint("SELECT pay   CANCEL back")
  if not mesh_on() then return meet_text("This badge can't meet", "Update Solana OS") end
  st.w.near_t = 0
  draw_nearby()
end

local function build_getpaid()
  frame("getpaid")
  art.logo(14, 32, 3)
  ui.label(60, 34, "Stand near them", {size = 14, color = C.brand})
  ui.label(60, 52, "They pick you on Pay in person.", {size = 12, color = C.ink, w = 250})
  st.w.m1 = center(100, "Ready to get paid", 14, C.ink)
  st.w.m2 = center(120, "Keep this screen open", 12, C.dim)
  ui.hint("CANCEL back")
  if not mesh_on() then meet_text("This badge can't meet", "Update Solana OS") end
end

-- The requester's badge asks: sign only on Get paid, for the job open there.
function on_meet(from, data)
  local m = st.meet
  if st.screen ~= "getpaid" or not m or type(data) ~= "table" or tostring(data.job) ~= m.job then return nil end
  ui.toast("Getting paid for " .. (m.who or "this intro"))
  timer.after(10, function()
    if st.meet ~= m then return end
    leave_meet()
    -- Wi-Fi rejoins; JOB DONE plays when the payout shows in /me.
    timer.after(4000, function() poll(true) end)
    back_to_job(m.job)
  end)
  return {job = m.job, ok = 1}
end

-- Profile ------------------------------------------------------------------

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
      local h = hi > lo and math.floor(3 + (p - lo) * 21 / (hi - lo)) or 12
      bars[k]:size(3, h)
      bars[k]:pos(16 + (k - 1) * 4, 90 - h)
      bars[k]:show(true)
    else
      -- No history yet: a flat line at zero, so the box isn't empty.
      bars[k]:size(3, 2)
      bars[k]:pos(16 + (k - 1) * 4, 88)
      bars[k]:show(true)
    end
  end
end

local restart_poll  -- forward

local function profile_items()
  return {
    {title = "My Telegram", sub = "shown when you offer or request", right = st.tg or "not set"},
  }
end

local function refresh_profile()
  local w, me = st.w, st.me
  if not w.value then return end
  if me and me.reg then
    w.value:text(lp(me.value))
    w.stats:text(me.name .. "   jobs " .. me.jobs .. "   earned " .. lp(me.earned))
  else
    w.value:text(lp(0))
    w.stats:text(me and "Offer on a job to start earning" or ago_text())
  end
  if w.bal then w.bal:text(st.bal and ("balance " .. lp(st.bal)) or (st.bal_err or "balance ...")) end
  draw_spark()
end

-- The owner's own !LAMPs (lamps.balance), shown under the machine value.
local function load_balance()
  if not lamps then st.bal_err = "balance: no lamps permission" return refresh_profile() end
  lamps.balance(function(ok, bal)
    if ok then st.bal, st.bal_err = math.tointeger(tonumber(bal)) or bal, nil
    else st.bal, st.bal_err = nil, "balance: " .. tostring(bal) .. " by the badge" end
    refresh_profile()
  end)
end

-- The Telegram handle is also the introer name others see.
local function edit_tg()
  ask_tg(function(tg)
    if not (st.me and st.me.reg) then return show_later("profile") end
    call("POST", "/introer", {name = tg}, function(ok, me)
      if ok then st.me = me end
      ui.toast(ok and "Saved" or tostring(me))
      show_later("profile")
    end)
  end)
end

local function build_profile()
  frame("profile")
  art.logo(12, 30, 2)
  ui.label(44, 30, "machine value", {size = 12, color = C.dim})
  st.w.value = ui.label(44, 42, "", {size = 20, color = C.brand})
  ui.rect(14, 64, 100, 28, {color = C.line})
  st.w.spark = {}
  for k = 1, SPARK_N do st.w.spark[k] = ui.rect(16 + (k - 1) * 4, 74, 3, 2, {color = C.brand}) end
  if ui.qr then ui.qr(232, 28, 76, SITE) end
  ui.label(226, 106, "botbotcap.com", {size = 12, color = C.dim, w = 88, align = "center"})
  st.w.stats = line(96, "", C.ink)
  st.w.bal = ui.label(120, 70, "", {size = 12, color = C.dim, w = 108})
  list.new(6, 120, 308, 30, profile_items(), {on_select = function() edit_tg() end})
  center(180, CTA, 14, C.ink)
  ui.hint("SELECT change   LEFT/RIGHT screens")
  refresh_profile()
  load_balance()
end

-- Badge Fleet MAV: every !LAMP the badge fleet's introers produced ----------

local function refresh_fleet()
  local w, f = st.w, st.fleet
  if not w.mav then return end
  w.mav:text(f and lp(f.made or f.paid) or "-- !LAMPs")
  w.jobs:text(f and (f.jobs .. (f.jobs == 1 and " intro paid" or " intros paid")) or ago_text())
end

local function build_fleet()
  frame("fleet")
  art.logo(14, 32, 3)
  ui.label(60, 34, "Badge Fleet MAV", {size = 14, color = C.brand})
  ui.label(60, 52, "Total !LAMPs produced by introers", {size = 12, color = C.dim})
  st.w.mav = ui.label(14, 80, "", {size = 32, color = C.ink, w = 292, align = "center"})
  st.w.jobs = ui.label(14, 120, "", {size = 14, color = C.brand, w = 292, align = "center"})
  center(146, "Bids paid plus bonuses awarded.", 12, C.dim)
  ui.rect(5, 174, 310, 1, {color = C.line})
  center(180, CTA, 14, C.ink)
  ui.hint(TABHINT)
  refresh_fleet()
end

-- Screens ------------------------------------------------------------------

local BUILD = {
  request = build_request, board = build_board, fleet = build_fleet, myjobs = build_myjobs,
  myoffers = build_myoffers, profile = build_profile, job = build_job, inperson = build_inperson,
  getpaid = build_getpaid,
}

function show(name)
  st.dirty = nil
  if IS_TAB[name] and st.pending and not st.modal and not st.anim then
    st.screen = name
    local n = st.pending
    st.pending = nil
    return job_done(n)
  end
  local fresh = st.screen ~= name
  st.screen = name
  BUILD[name]()
  if fresh and IS_TAB[name] then poll(true) end
end

-- Receipt: JOB DONE ---------------------------------------------------------

local ANIM_MS = 2600

function job_done(n)
  if st.anim then return end
  if st.modal or not IS_TAB[st.screen] then st.pending = (st.pending or 0) + n return end
  ui.clear()
  list.reset()
  st.w = {}
  ui.bg(C.brand)
  local a = {t = 0}
  a.logo, a.shift = art.logo(127, 14, 5, 0), 0
  ui.label(0, 98, "JOB DONE!", {size = 32, color = C.white, w = ui.W, align = "center"})
  ui.label(0, 134, n > 1 and ("+" .. n .. " intros paid") or "+1 intro paid",
    {size = 14, color = C.desk, w = ui.W, align = "center"})
  local ids = st.me and st.me.claim
  if ids and #ids > 0 then
    local size = st.me.csize and math.tointeger(tonumber(st.me.csize[tostring(ids[1])])) or BONUS
    ui.label(0, 152, "+" .. size .. " !LAMPs bonus" .. (size < BONUS and " (half: Telegram)" or ""),
      {size = 14, color = C.white, w = ui.W, align = "center"})
  end
  ui.label(10, 172, CTA_EARNED, {size = 14, color = C.white, w = 300, align = "center"})
  st.anim = a
end

local function anim_tick(ms)
  local a = st.anim
  a.t = a.t + ms
  local shift = (a.t // 150) % 6
  if a.logo and shift ~= a.shift then
    a.logo:remove()
    a.logo, a.shift = art.logo(127, 14, 5, shift), shift
  end
  if led then
    if a.t >= ANIM_MS then brand_led()
    elseif (a.t // 150) % 2 == 0 then led.fill(0x6A, 0x50, 0xD8)
    else led.fill(0xA8, 0x52, 0x1A) end
  end
  if a.t >= ANIM_MS then
    st.anim = nil
    show(st.screen)
  end
end

-- Reading the server ---------------------------------------------------------

-- Redraw the open tab when its data changed.
local function refresh()
  if st.anim or st.modal then return end
  local s = st.screen
  if s == "profile" then refresh_profile()
  elseif s == "fleet" then refresh_fleet()
  elseif s == "board" or s == "myjobs" or s == "myoffers" then
    local role = s == "board" and "board" or s == "myjobs" and "requester" or "introer"
    if sig(rows_for(role)) ~= st.w.sig then show(s) end
  end
end

-- Rewards: the server lists bonuses this badge may claim (50 in person, 25 over Telegram; one
-- per pair; two a day). lamps.award pays them within the app's daily cap; the server records it.
local function claim_bonus()
  local ids = st.me and st.me.claim
  if not lamps or not lamps.award or st.claiming or not ids or #ids == 0 then return end
  if st.bonus_next and sys.millis() < st.bonus_next then return end
  local id = tostring(ids[1])
  local size = st.me.csize and math.tointeger(tonumber(st.me.csize[id])) or BONUS
  st.claiming = true
  lamps.award(size, "intro " .. id, function(ok, r)
    local got = ok and type(r) == "table" and math.tointeger(tonumber(r.awarded)) or 0
    local needs_x = ok and type(r) == "table" and r.needsX and true or false
    call("POST", "/jobs/" .. id .. "/bonus", {awarded = got, needsX = needs_x}, function(ok2, b)
      st.claiming = false
      if got > 0 then
        ui.toast("+" .. got .. " !LAMPs bonus")
        if ok2 and type(b) == "table" and st.me then st.me.claim, st.me.csize = b.claim, b.csize end
        return claim_bonus()
      end
      -- Nothing given: no X linked, or the app's cap for today. Try again in an hour.
      st.bonus_next = sys.millis() + 3600000
      if needs_x then ui.toast("Link X to get the " .. size .. " !LAMP bonus") end
    end)
  end)
end

local function got_me(me)
  st.me = me
  if not me.reg then return end
  st.spark[#st.spark + 1] = me.value
  while #st.spark > SPARK_N do table.remove(st.spark, 1) end
  storage.set("spark", st.spark)
  local before = st.jobs
  st.jobs = me.jobs
  if before ~= me.jobs then storage.set("jobs", me.jobs) end
  if before and me.jobs > before then job_done(me.jobs - before) end
  claim_bonus()
end

function poll(force)
  st.gen = st.gen + 1
  local gen = st.gen
  local function done(ok, why)
    if gen ~= st.gen then return end
    st.status = ok and "ok" or tostring(why)
    if ok then st.updated = sys.millis() end
    refresh()
  end
  call("GET", "/me", nil, function(ok, me)
    if gen ~= st.gen then return end
    if not ok then return done(false, me) end
    got_me(me)
    local s = st.screen
    if s == "board" then
      call("GET", "/board", nil, function(ok2, b)
        if gen == st.gen and ok2 then st.board = b.jobs end
        done(ok2, b)
      end)
    elseif s == "fleet" then
      call("GET", "/fleet", nil, function(ok2, f)
        if gen == st.gen and ok2 then st.fleet = f end
        done(ok2, f)
      end)
    else
      done(true)
    end
  end)
end

function restart_poll()
  st.gen, st.status = st.gen + 1, "starting"
  st.me, st.board, st.fleet, st.updated, st.spark, st.jobs = nil, nil, nil, nil, {}, nil
  storage.remove("spark")
  storage.remove("jobs")
  if st.poll_id then timer.cancel(st.poll_id) end
  st.poll_id = timer.every(POLL_MS, function() poll() end)
  poll()
end

-- Keys and ticks -------------------------------------------------------------

local function tab_index()
  for k, n in ipairs(TABS) do if n == st.screen then return k end end
end

function on_key(key)
  if st.anim then return true end
  if st.screen == "splash" then
    if key == "select" then still() show("board") return true end
    return key ~= "back"
  end
  if (key == "up" or key == "down" or key == "select") and list.key(key) then
    return true
  end
  if key == "back" then
    if st.screen == "inperson" or st.screen == "getpaid" then
      leave_meet()
      show(st.pick and "job" or "board")
      return true
    end
    if st.screen == "job" then
      local j = st.pick
      st.pick = nil
      show(j and j.mine and "myjobs" or (j and j.o and "myoffers") or "board")
      return true
    end
    if IS_TAB[st.screen] then show("splash") flicker(1, true) return true end
    return false
  end
  local k = tab_index()
  if key == "left" then flicker(1) elseif key == "right" then flicker(-1) end
  if k and (key == "left" or key == "right") then
    show(TABS[(k - 1 + (key == "right" and 1 or -1)) % #TABS + 1])
  end
  return true
end

function on_tick(ms)
  if st.anim then return anim_tick(ms) end
  sweep_tick(ms)
  if st.screen == "inperson" and st.w.near_t then
    st.w.near_t = st.w.near_t + ms
    if st.w.near_t >= 2000 then
      st.w.near_t = 0
      draw_nearby()
    end
  end
  st.ago = st.ago + ms
  if st.ago >= 1000 then
    st.ago = st.ago - 1000
    if st.screen == "profile" and st.w.stats and st.me == nil then st.w.stats:text(ago_text()) end
  end
end

function on_exit()
  if led then led.off() end
end

-- Splash: BotBot and a QR to our X, so the badge can be shown off. SELECT enters.
local function splash()
  st.dirty = nil
  st.screen = "splash"
  ui.clear()
  list.reset()
  st.w = {}
  ui.bg(C.desk)
  ui.rect(4, 4, 312, 196, {color = C.ink})
  ui.rect(5, 5, 310, 194, {color = C.paper})
  if ui.qr then ui.qr(14, 18, 166, X) end
  art.logo(212, 12, 6)                      -- 72 px, centred in the right column (184..312)
  local function side(y, text, size, color)
    ui.label(184, y, text, {size = size, color = color, w = 128, align = "center"})
  end
  side(92, "BotBot", 20, C.brand)
  side(118, "Intro Bot", 14, C.ink)
  side(144, "Scan to follow", 12, C.ink)
  side(160, "x.com/botbotcap", 14, C.ink)
  side(184, "botbotcap.com", 12, C.dim)
  ui.hint("SELECT to enter   CANCEL exit")
end
BUILD.splash = splash

-- Wi-Fi first: the mesh takes the radio only on Pay in person and Get paid.
if mesh and mesh.pause then mesh.pause() end
splash()
flicker(1, true)
restart_poll()
