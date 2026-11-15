-- Intro Bot: the intro board, paid in !LAMPs (docs/spec-lamps.md). Post a job ("introduce me
-- to..."), people offer, you pick one after talking on Telegram, meet badge to badge, and you
-- confirm to pay. The bid waits in the app's !LAMP escrow; our server (lib/api.lua) keeps the
-- board and pays out. The badge holds no keys: the badge server signs who is asking.
local api = require("lib.api")
local art = require("lib.art")

local ESCROW = "ESC-GQD4T2WC"
local MIN_BID, MAX_BID, TEXT = 10, 500, 31
local POLL_MS, SPARK_N = 20000, 24
local C = {
  desk = 0xC9BFF2, brand = 0x6A50D8, ink = 0x241A52, paper = 0xF6F3FD,
  orange = 0x8A3A0A, white = 0xFFFFFF, dim = 0x3B3266, line = 0xDCD5F7,
}
local TABS = {"board", "fleet", "request", "myjobs", "myoffers", "profile"}
local IS_TAB = {request = true, board = true, fleet = true, myjobs = true, myoffers = true, profile = true}
local TITLE = {
  request = "Request an intro", board = "Intro board", fleet = "Badge Fleet", myjobs = "My jobs",
  myoffers = "My offers", profile = "Profile", job = "Job", meet = "We met",
}
local LABEL = {
  offer = "Offer to make this intro", withdraw = "Withdraw my offer", cancel = "Remove: bid back",
  edit = "Edit who, company, Telegram", remove = "Remove (not paid)",
  confirm = "Confirm: pay the introer", refund = "Refund my bid", made = "Intro made",
  meet = "We met: verify badges", pay = "Pay the bid",
}
local STATUS = {pending = "Unpaid", open = "Open", approved = "Picked", made = "Made", closed = "Closed"}
local TABHINT = "LEFT/RIGHT screens   CANCEL home"
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

local function pay(id, bid)
  if not lamps then return ui.toast("Needs the lamps permission") end
  -- JSON numbers can come back as floats (100.0); the OS wants a whole number.
  local amount = math.tointeger(tonumber(bid))
  if not amount then return ui.toast("Bad bid") end
  local function sent(ok, res)
    if not ok then
      ui.toast("Not paid: " .. tostring(res))
      -- Tell the server exactly what the OS said (and the balance), for its logs.
      lamps.balance(function(okb, bal)
        call("POST", "/log", {what = "deposit", job = id, amount = amount, why = tostring(res),
          balance = okb and bal or tostring(bal)}, function() end)
      end)
      return
    end
    call("POST", "/jobs/" .. id .. "/paid", {deposit = res and res.id}, function(ok2, j)
      ui.toast(ok2 and j.st == "open" and "Posted!" or "Paid. On the board in a moment.")
      poll(true)
      show_later("myjobs")
    end)
  end
  lamps.deposit(tostring(ESCROW), amount, "job " .. tostring(id), sent)
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
      input("Your bid in !LAMPs", 3, function(amount)
        local bid = math.tointeger(tonumber(amount or ""))
        if not bid then ui.toast("Use a whole number like 50") return end
        if bid < MIN_BID or bid > MAX_BID then ui.toast(MIN_BID .. " to " .. MAX_BID .. " !LAMPs") return end
        local function post(tg)
          call("POST", "/jobs", {who = who, co = co, tg = tg, bid = bid}, function(ok, r)
            if not ok then return ui.toast(tostring(r)) end
            pay(r.id, bid)
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
  ui.list(6, 68, 308, 72, {
    {title = "Request an intro", sub = "who, company, bid in !LAMPs"},
    {title = "My Telegram", right = st.tg or "not set"},
  }, {on_select = function(i) if i == 1 then ask_job() else ask_tg() end end})
  line(144, "Offerers see your Telegram.", C.ink)
  line(158, "Bid waits in escrow till you confirm.")
  ui.rect(5, 174, 310, 1, {color = C.line})
  center(180, CTA, 14, C.orange)
  ui.hint(TABHINT)
end

-- Lists of jobs ------------------------------------------------------------

local function job_item(j, role)
  local right = STATUS[j.st] or j.st
  if role == "introer" then
    right = j.st == "open" and "Waiting" or (j.me and (j.st == "made" and "Made" or "You!") or "Not picked")
  elseif role == "board" and j.o then
    right = "Offered"
  end
  if j.met and (j.st == "approved" or j.st == "made") then right = right .. " +met" end
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
  for k, j in ipairs(rows) do t[k] = j.id .. j.st .. j.n .. tostring(j.o) .. tostring(j.met) .. tostring(j.me) end
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
    if off == 1 then ui.list(6, 26, 308, 44, items, {on_select = function() ask_job() end}) end
    center(off == 1 and 100 or 80, rows and empty or "Loading...")
    if rows and empty2 then center(off == 1 and 124 or 104, empty2, 12, C.dim) end
  else
    ui.list(6, 26, 308, 172, items, {on_select = function(i)
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
  if a == "meet" then st.meet = {job = j.id} return show("meet") end
  if a == "pay" then return pay(j.id, j.bid) end
  if a == "offer" and not st.tg then return ask_tg(function() do_act(j, a, n) end) end
  local function go()
    call("POST", "/jobs/" .. j.id .. "/" .. a, {n = n, name = st.tg}, function(ok, d)
      if not ok then return ui.toast(tostring(d)) end
      ui.toast(a == "confirm" and CTA_PAID or (LABEL[a] or a) .. ": done")
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
  if a == "confirm" then
    return confirm("Pay " .. lp(j.bid) .. " to " .. (j.picked or "them") .. "?", function(y) if y then go() end end)
  end
  go()
end

local function build_job()
  frame("job")
  local j = st.pick
  ui.label(14, 30, j.who .. " @ " .. j.co, {size = 14, color = C.ink, w = 292})
  line(48, "bid " .. lp(j.bid) .. "   " .. (j.n or 0) .. " offers   " .. (STATUS[j.st] or j.st or ""))
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
    line(y, "Picked: " .. j.picked .. (j.met and "   met: verified" or "   met: not yet"), C.ink)
    y = y + 16
  end
  local items, act = {}, {}
  for _, a in ipairs(j.acts or {}) do
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
    ui.list(6, y + 2, 308, math.min(196 - y - 18, 36 * #items), items, {on_select = function(i)
      local a = act[i]
      if a then do_act(j, a[1], a[2]) end
    end})
  end
  if j.mine and (j.st == "open" or j.st == "pending") then
    line(178, "New bid? Remove and post again.", C.dim)
  elseif j.me and j.st == "approved" and not j.met then
    line(178, "Meet badge to badge, then mark made.", C.orange)
  elseif j.mine and j.st == "made" then
    line(178, "Made? Confirm to pay. 72h, then refund.", C.orange)
  end
  ui.hint(#items > 0 and "SELECT choose   CANCEL back" or "CANCEL back")
end

-- We met: both badges sign a meet for this job ------------------------------

local function meet_text(a, b)
  if st.screen ~= "meet" or not st.w.m1 then return end
  st.w.m1:text(a)
  st.w.m2:text(b or "")
end

local function build_meet()
  frame("meet")
  art.logo(14, 32, 3)
  ui.label(60, 34, "Hold your badges close", {size = 14, color = C.brand})
  ui.label(60, 52, "Both open We met on this job.", {size = 12, color = C.ink})
  st.w.m1 = center(96, "SELECT to verify", 14, C.ink)
  st.w.m2 = center(118, "", 12, C.dim)
  center(150, "Signed by both badges. No Wi-Fi needed.", 12, C.dim)
  ui.hint("SELECT verify   CANCEL back")
  if not mesh or not mesh.meet then return meet_text("This badge can't meet", "Update Solana OS") end
  if mesh.resume then mesh.resume() end
end

local function leave_meet()
  if mesh and mesh.pause then mesh.pause() end
  st.meet = nil
end

local function met(id)
  ui.toast("Met! Verified in a moment.")
  if led then
    led.fill(0x61, 0xBB, 0x46)
    timer.after(600, function() led.off() end)
  end
  leave_meet()
  -- The meet uploads once Wi-Fi is back; the server marks the job met soon after.
  call("GET", "/jobs/" .. id, nil, function(ok, d)
    if ok then
      st.pick = d
      show_later("job")
    end
  end)
end

local function try_meet()
  local m = st.meet
  if not m then return end
  if not mesh or not mesh.meet then return end
  local near
  for _, p in ipairs(mesh.nearby() or {}) do
    if p.kind == "badge" then near = p break end
  end
  if not near then return meet_text("No badge nearby", "Ask them to open We met too") end
  meet_text("Asking " .. (near.name or near.id) .. "...", "")
  local ok, err = mesh.meet(near.id, {job = m.job}, function(done, res)
    if st.meet ~= m then return end
    if done then met(m.job) else meet_text("Not met: " .. tostring(res), "SELECT to try again") end
  end)
  if not ok then meet_text("Not met: " .. tostring(err), "SELECT to try again") end
end

-- The other badge asks: sign only for the job open on this screen.
function on_meet(from, data)
  local m = st.meet
  if st.screen ~= "meet" or not m or type(data) ~= "table" or tostring(data.job) ~= m.job then return nil end
  timer.after(10, function() met(m.job) end)
  return {job = m.job}
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
  ui.list(6, 120, 308, 30, profile_items(), {on_select = function() edit_tg() end})
  center(180, CTA, 14, C.orange)
  ui.hint("SELECT change   LEFT/RIGHT screens")
  refresh_profile()
  load_balance()
end

-- Badge Fleet MAV: every !LAMP the badge fleet's introers produced ----------

local function refresh_fleet()
  local w, f = st.w, st.fleet
  if not w.mav then return end
  w.mav:text(f and lp(f.paid) or "-- !LAMPs")
  w.jobs:text(f and (f.jobs .. (f.jobs == 1 and " intro paid" or " intros paid")) or ago_text())
end

local function build_fleet()
  frame("fleet")
  art.logo(14, 32, 3)
  ui.label(60, 34, "Badge Fleet MAV", {size = 14, color = C.brand})
  ui.label(60, 52, "Total !LAMPs produced by introers", {size = 12, color = C.dim})
  st.w.mav = ui.label(14, 80, "", {size = 32, color = C.ink, w = 292, align = "center"})
  st.w.jobs = ui.label(14, 120, "", {size = 14, color = C.brand, w = 292, align = "center"})
  center(146, "Every !LAMP paid to an introer.", 12, C.dim)
  ui.rect(5, 174, 310, 1, {color = C.line})
  center(180, CTA, 14, C.orange)
  ui.hint(TABHINT)
  refresh_fleet()
end

-- Screens ------------------------------------------------------------------

local BUILD = {
  request = build_request, board = build_board, fleet = build_fleet, myjobs = build_myjobs,
  myoffers = build_myoffers, profile = build_profile, job = build_job, meet = build_meet,
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
  st.w = {}
  ui.bg(C.brand)
  local a = {t = 0}
  a.logo, a.shift = art.logo(127, 14, 5, 0), 0
  ui.label(0, 98, "JOB DONE!", {size = 32, color = C.white, w = ui.W, align = "center"})
  ui.label(0, 138, n > 1 and ("+" .. n .. " intros confirmed") or "+1 intro confirmed",
    {size = 14, color = C.desk, w = ui.W, align = "center"})
  ui.label(10, 162, CTA_EARNED, {size = 14, color = C.white, w = 300, align = "center"})
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
    if a.t >= ANIM_MS then led.off()
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
    if key == "select" then show("board") return true end
    return key ~= "back"
  end
  if key == "back" then
    if st.screen == "meet" then
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
    if IS_TAB[st.screen] then show("splash") return true end
    return false
  end
  if key == "select" and st.screen == "meet" then try_meet() return true end
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
  st.w = {}
  ui.bg(C.desk)
  ui.rect(4, 4, 312, 196, {color = C.ink})
  ui.rect(5, 5, 310, 194, {color = C.paper})
  if ui.qr then ui.qr(14, 18, 166, X) end
  art.logo(212, 18, 5)
  local function side(y, text, size, color)
    ui.label(184, y, text, {size = size, color = color, w = 128, align = "center"})
  end
  side(90, "BotBot", 20, C.brand)
  side(116, "Intro Bot", 14, C.ink)
  side(144, "Scan to follow", 12, C.orange)
  side(160, "x.com/botbotcap", 14, C.orange)
  side(184, "botbotcap.com", 12, C.dim)
  ui.hint("SELECT to enter   CANCEL exit")
end
BUILD.splash = splash

-- Wi-Fi first: the mesh takes the radio only on the We met screen.
if mesh and mesh.pause then mesh.pause() end
splash()
restart_poll()
