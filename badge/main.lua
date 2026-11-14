-- Intro Bot v2: the intro board (docs/spec-v2.md). Post a job ("introduce me to..."), people
-- offer, you pick one after talking on Telegram, they make the intro, you confirm and pay.
-- Reads the chain with `rpc`, builds each transaction here, and the phone wallet signs it
-- through a Solana Pay QR from the relay. The badge never makes or stores keys.
local sol = require("lib.sol")
local escrow = require("lib.escrow")
local tx = require("lib.tx")
local chain = require("lib.chain")
local demo = require("lib.demo")
local art = require("lib.art")

local POLL_MS, WATCH_MS, WATCH_FOR = 20000, 6000, 600000
local SPARK_N, MAX_MINE, MAX_OFFERED, BOARD_SHOW = 24, 6, 6, 10
local C = {
  desk = 0xC9BFF2, brand = 0x6A50D8, ink = 0x241A52, paper = 0xF6F3FD,
  orange = 0xA8521A, white = 0xFFFFFF, dim = 0x6E6496, line = 0xDCD5F7,
}
local TABS = {"request", "board", "myjobs", "myoffers", "profile"}
local IS_TAB = {request = true, board = true, myjobs = true, myoffers = true, profile = true}
local TITLE = {
  request = "Request an intro", board = "Intro board", myjobs = "My jobs", myoffers = "My offers",
  profile = "Profile", job = "Job", myjob = "My job", offerjob = "My offer", sign = "Sign on phone", connect = "Connect",
}
local TABHINT = "LEFT/RIGHT screens   CANCEL exit"
local CTA = "Robots that earn: botbotcap.com"
local CTA_EARNED = "This badge just earned. Your robots can too: botbotcap.com"
local CTA_PAID = "Paid! Robots that earn: botbotcap.com"
local SITE = "https://botbotcap.com"

-- State ------------------------------------------------------------------

local function stored_list(key, ok, max)
  local s, out = storage.get(key), {}
  if type(s) == "table" then
    for k = 1, 32 do
      if s[k] == nil then break end
      if ok(s[k]) then out[#out + 1] = s[k] end
    end
  end
  while #out > max do table.remove(out, 1) end
  return out
end

local function digits(v, n) return type(v) == "string" and v:find("^%d+$") ~= nil and #v <= n end

local st = {
  wallet = sol.is_wallet(storage.get("wallet")) and storage.get("wallet") or nil,
  mock = storage.get("mock") == true,
  tg = type(storage.get("tg")) == "string" and storage.get("tg") or nil,
  spark = stored_list("spark", function(v) return type(v) == "number" end, SPARK_N),
  jobs = math.tointeger(storage.get("jobs")),
  -- My jobs, by nonce: {n = nonce, at = unix time posted, seen = landed}.
  mine = stored_list("mine", function(m)
    return type(m) == "table" and digits(m.n, 12) and type(m.at) == "number"
  end, MAX_MINE),
  -- Jobs I offered on: {j = job address (base58), at}.
  offered = stored_list("offered", function(o)
    return type(o) == "table" and sol.is_wallet(o.j) and digits(o.s, 20) and type(o.at) == "number"
  end, MAX_OFFERED),
  me = nil,            -- my Introer account, false when not registered, nil unknown
  board = nil,         -- jobs on the board, newest first
  my_jobs = nil,       -- rows for st.mine
  my_offers = nil,     -- rows for st.offered ({closed = true} once the job is gone)
  names = {},          -- [introer wallet] = Introer (or false), for offer pools
  read_at = {board = {t = -1e9}, myjobs = {t = -1e9}, myoffers = {t = -1e9}},  -- last read, per tab
  status = "starting", updated = nil, busy = nil, gen = 0,
  screen = nil, w = {}, pick = nil, sign = nil, retry = nil, anim = nil,
  modal = nil, pending = nil, dirty = nil, ago = 0, mockdata = nil,
}

local function now() return sys.time() end
-- My wallet as the chain has it (32 bytes), or the demo's stand-in.
local function me_key()
  if st.mock then return demo.ME end
  return st.wallet and solana.decode(st.wallet)
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
  local tag = st.mock and "DEMO" or (st.wallet and sol.short(st.wallet) or "")
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

local function name_of(wallet)
  local x = st.names[wallet]
  if x and x.name ~= "" then return x.name end
  if st.mock then return tostring(wallet) end
  return sol.short(solana.encode(wallet))
end

-- Modals: redraws and the receipt animation wait until they close -----------

local job_done, show  -- forward

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

-- From async callbacks: wait while the animation or a dialog has the screen.
local function show_later(name)
  if st.anim or st.modal then
    st.screen, st.dirty = name, true
  else
    show(name)
  end
end

-- Signing: build the message, get a QR from the relay, watch the chain -----

local start_sign  -- forward

-- What each step builds, which account shows it landed, and how.
local function plan(action, r)
  local me = me_key()
  if action == "post_job" then
    r.pda = r.pda or escrow.job_pda(me, r.nonce)
    return escrow.ix_post_job(r.pda, r.nonce, r.who, r.company, r.telegram, r.bid), r.pda, "exists"
  elseif action == "cancel_job" then
    return escrow.ix_cancel_job(r.pda), r.pda, "gone"
  elseif action == "offer" then
    return escrow.ix_offer(me, r.pda, r.serial), escrow.offer_pda(r.pda, r.serial, me), "exists"
  elseif action == "withdraw_offer" then
    return escrow.ix_withdraw_offer(me, r.pda, r.serial), escrow.offer_pda(r.pda, r.serial, me), "gone"
  elseif action == "close_offer" then
    return escrow.ix_close_offer(r.pda, r.serial, me), escrow.offer_pda(r.pda, r.serial, me), "gone"
  elseif action == "approve" then
    return escrow.ix_approve(r.pda, r.serial, r.introer), r.pda, escrow.APPROVED
  elseif action == "mark_made" then
    return escrow.ix_mark_made(r.pda), r.pda, escrow.MADE
  elseif action == "confirm" then
    return escrow.ix_confirm(r.pda, r.approved), r.pda, "gone"
  elseif action == "refund_expired" or action == "refund_unconfirmed" then
    return escrow.ix_refund(action, r.pda), r.pda, "gone"
  elseif action == "register_introer" then
    return escrow.ix_register(me, r.badge_id, r.name), escrow.introer_pda(me), "exists"
  end
  return escrow.ix_update(me, r.badge_id, r.name), escrow.introer_pda(me), "name"
end

-- true when it landed, nil to keep waiting.
local function landed(want, b, r)
  if want == "gone" then return b == nil end
  if want == "exists" then return b ~= nil end
  if want == "name" then
    local i = b and escrow.decode_introer(b)
    return i and i.name == r.name
  end
  local j = b and escrow.decode_job(b)
  return j and j.status == want
end

local poll  -- forward

local function stop_sign()
  local s = st.sign
  if s and s.timer then timer.cancel(s.timer) end
  st.sign = nil
end

local function forget_offer(pda)
  local b58 = st.mock and pda or solana.encode(pda)
  for k = #st.offered, 1, -1 do
    if st.offered[k].j == b58 then table.remove(st.offered, k) end
  end
  if not st.mock then storage.set("offered", st.offered) end
end

local function sign_done(s)
  local a, r = s.action, s.row
  if not st.mock then
    if a == "post_job" then
      st.mine[#st.mine + 1] = {n = r.nonce, at = now() or 0}
      while #st.mine > MAX_MINE do table.remove(st.mine, 1) end
      storage.set("mine", st.mine)
    elseif a == "offer" then
      st.offered[#st.offered + 1] = {j = solana.encode(r.pda), s = r.serial, at = now() or 0}
      while #st.offered > MAX_OFFERED do table.remove(st.offered, 1) end
      storage.set("offered", st.offered)
    end
  end
  if a == "withdraw_offer" or a == "close_offer" then forget_offer(r.pda) end
  stop_sign()
  ui.toast(a == "post_job" and "Posted!" or a == "confirm" and CTA_PAID or (escrow.LABEL[a] .. ": done"))
  poll(true)
  show_later(s.back)
end

local function sign_text(a, b, c)
  local w = st.w
  if st.screen ~= "sign" or not w.l1 then return end
  w.l1:text(a) w.l2:text(b or "") w.l3:text(c or "")
end

-- A step that didn't land: offer to build it again.
local function sign_failed(s, why)
  stop_sign()
  st.retry = s
  if st.screen == "sign" then
    sign_text(why, "SELECT to retry", "CANCEL to go back")
    ui.hint("SELECT retry   CANCEL back")
  end
end

local function watch()
  local s = st.sign
  if not s then return end
  if sys.millis() - s.started > WATCH_FOR then return sign_failed(s, "Nothing landed in 10 min.") end
  chain.account(s.addr, function(ok, b)
    if st.sign ~= s or not ok then return end
    if landed(s.want, b, s.row) then sign_done(s) end
  end)
end

local function build_sign()
  frame("sign")
  local s = st.sign or st.retry
  if st.sign and s.url and ui.qr then ui.qr(14, 32, 160, s.url) end
  st.w.l1 = ui.label(186, 36, "", {size = 14, color = C.brand, w = 124})
  st.w.l2 = ui.label(186, 60, "", {size = 12, color = C.ink, w = 124})
  st.w.l3 = ui.label(186, 76, "", {size = 12, color = C.dim, w = 124})
  ui.hint("CANCEL back")
  if st.retry then
    sign_text(st.retry.why or "Didn't land.", "SELECT to retry", "CANCEL to go back")
    ui.hint("SELECT retry   CANCEL back")
  elseif s and s.url then
    sign_text(escrow.LABEL[s.action], "Scan with your", "phone wallet.")
    ui.label(186, 104, "Waiting for the", {size = 12, color = C.dim})
    ui.label(186, 118, "chain...", {size = 12, color = C.dim})
    if st.mock then ui.label(186, 146, "Demo: not real", {size = 12, color = C.orange}) end
  elseif s then
    sign_text("Preparing...", "", "")
  end
end

function start_sign(action, r, back)
  stop_sign()
  st.retry = nil
  local s = {action = action, row = r, started = sys.millis(), back = back or st.screen}
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
  local function build()
    if st.sign ~= s then return end
    local ix, addr, want = plan(action, r)
    s.addr, s.want = addr, want
    chain.relay(tx.message({ix}), function(ok, url)
      if st.sign ~= s then return end
      if not ok then
        s.why = tostring(url)
        return sign_failed(s, s.why)
      end
      s.url = url
      s.timer = timer.every(WATCH_MS, watch)
      if st.screen == "sign" then show_later("sign") end
    end)
  end
  -- Addresses cost instructions: work out the shared ones in callbacks of their own.
  local me = me_key()
  local warm = {
    function() escrow.config_pda() end,
    function() if me then escrow.introer_pda(me) end end,
    function() if action == "post_job" then escrow.board_pda() end end,
    function() if action == "post_job" then r.pda = r.pda or escrow.job_pda(me, r.nonce) end end,
    function() if r.approved then escrow.introer_pda(r.approved) end end,
    function() if r.introer and r.pda then escrow.offer_pda(r.pda, r.serial, r.introer) end end,
  }
  local k = 0
  local function step()
    if st.sign ~= s then return end
    k = k + 1
    if warm[k] then warm[k]() timer.after(20, step) else build() end
  end
  timer.after(20, step)
end

-- Request an intro (home) ---------------------------------------------------

-- Connect: scan a QR with the phone wallet; the relay tells us its address. No typing.
local CONNECT_POLL_MS, CONNECT_FOR = 2000, 600000

local function stop_connect()
  local c = st.connect
  if c and c.timer then timer.cancel(c.timer) end
  st.connect = nil
end

local function connected(c, wallet)
  stop_connect()
  st.wallet = wallet
  storage.set("wallet", wallet)
  st.me, st.my_jobs, st.my_offers = nil, nil, nil
  ui.toast("Connected " .. sol.short(wallet))
  poll(true)
  show(c.back)
  if c.then_do then c.then_do() end
end

local function build_connect()
  frame("connect")
  local c = st.connect
  if c and c.url and ui.qr then ui.qr(14, 32, 160, c.url) end
  ui.label(186, 36, "Connect wallet", {size = 14, color = C.brand, w = 124})
  if c and c.why then
    ui.label(186, 60, c.why, {size = 12, color = C.ink, w = 124})
    ui.label(186, 76, "SELECT to retry", {size = 12, color = C.dim, w = 124})
    ui.hint("SELECT retry   CANCEL back")
    return
  end
  ui.label(186, 60, c and c.url and "Scan with your" or "Preparing...", {size = 12, color = C.ink, w = 124})
  ui.label(186, 76, c and c.url and "phone wallet." or "", {size = 12, color = C.ink, w = 124})
  if c and c.url then
    ui.label(186, 104, "Approve the note", {size = 12, color = C.dim})
    ui.label(186, 118, "to connect.", {size = 12, color = C.dim})
  end
  ui.hint("CANCEL back")
end

local function ask_wallet(then_do)
  stop_connect()
  local c = {then_do = then_do, back = st.screen == "connect" and "profile" or st.screen, started = sys.millis()}
  st.connect = c
  show("connect")
  chain.connect(function(ok, id, url)
    if st.connect ~= c then return end
    if not ok then
      c.why = "Couldn't reach the relay."
      return show("connect")
    end
    c.url = url
    c.timer = timer.every(CONNECT_POLL_MS, function()
      if st.connect ~= c then return end
      if sys.millis() - c.started > CONNECT_FOR then
        timer.cancel(c.timer)
        c.why, c.url = "QR expired.", nil
        return show("connect")
      end
      chain.who(id, function(wallet)
        if st.connect ~= c then return end
        if wallet then return connected(c, wallet) end
        if wallet == false then
          timer.cancel(c.timer)
          c.why, c.url = "QR expired.", nil
          show("connect")
        end
      end)
    end)
    show("connect")
  end)
end

local function ask_tg(then_do)
  input("Your Telegram @handle", escrow.TELEGRAM - 1, function(tg)
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
  if not st.mock and not st.wallet then return ask_wallet(ask_job) end
  input("Who do you want to meet?", escrow.WHO, function(who)
    if not who or who:gsub("%s", "") == "" then return end
    input("Their company", escrow.COMPANY, function(company)
      if not company or company:gsub("%s", "") == "" then return end
      input("Your bid in SOL", 12, function(amount)
        if not amount then return end
        local lam = sol.to_lamports(amount)
        if not lam then ui.toast("Use a number like 0.1") return end
        if sol.cmp(lam, escrow.MIN_BID) < 0 then ui.toast("At least 0.01 SOL") return end
        if sol.cmp(lam, escrow.MAX_BID) > 0 then ui.toast("At most 100 SOL") return end
        local function post(tg)
          local r = {who = who, company = company, bid = lam, telegram = tg,
            nonce = tostring(now() or sys.millis())}
          start_sign("post_job", r, "myjobs")
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
    {title = "Request an intro", sub = "who, company, bid"},
    {title = "My Telegram", right = st.tg or "not set"},
  }, {on_select = function(i) if i == 1 then ask_job() else ask_tg() end end})
  line(144, "Your Telegram is shown to people who offer.", C.ink)
  line(158, "You pay only when you confirm the intro.")
  ui.rect(5, 174, 310, 1, {color = C.line})
  center(180, CTA, 14, C.orange)
  ui.hint(TABHINT)
end

-- Lists of jobs ------------------------------------------------------------

local function offered_on(j)
  local b58 = st.mock and j.pda or solana.encode(j.pda)
  for _, o in ipairs(st.offered) do if o.j == b58 then return true end end
  return st.mock and st.mockdata and st.mockdata.offered[j.pda] or false
end

-- How a job reads in a list, for `role`: "board", "requester" or "introer".
local function job_item(j, role)
  if j.closed then return {title = "(closed job)", sub = "get your offer rent back", right = "Closed"} end
  local me = me_key()
  local right = escrow.STATUS[j.status]
  if role == "introer" then
    right = j.status == escrow.OPEN and "Waiting" or (j.approved == me and "You!" or "Not picked")
    if j.status == escrow.MADE and j.approved == me then right = "Made" end
  end
  local offers = j.offer_count == 1 and "1 offer" or (j.offer_count .. " offers")
  return {
    title = j.who .. " @ " .. j.company,
    sub = sol.format(j.bid, 3) .. " SOL   " .. offers .. (role == "introer" and ("   " .. j.telegram) or ""),
    right = right,
  }
end

local function build_jobs(name, rows, role, empty, empty2, open)
  frame(name)
  local items = {}
  for k, j in ipairs(rows or {}) do items[k] = job_item(j, role) end
  if #items == 0 then
    center(80, rows and empty or "Reading the chain...")
    if rows and empty2 then center(104, empty2, 12, C.dim) end
  else
    st.w.list = ui.list(6, 26, 308, 172, items, {on_select = function(i)
      local j = (role == "board" and st.board or role == "requester" and st.my_jobs or st.my_offers or {})[i]
      if j then st.pick = j; show(open) end
    end})
  end
  st.w.rows, st.w.count = rows, #items
  ui.hint(#items > 0 and "SELECT open   LEFT/RIGHT screens" or TABHINT)
end

local function build_board()
  build_jobs("board", st.board, "board", "No jobs yet", "Post one in Request an intro", "job")
end
local function build_myjobs()
  build_jobs("myjobs", st.my_jobs, "requester", "No jobs yet", "Request an intro to post one", "myjob")
end
local function build_myoffers()
  build_jobs("myoffers", st.my_offers, "introer", "No offers yet", "Offer on a job in the board", "offerjob")
end

-- Keep the list on the same job when rows move.
local function refresh_jobs(rows, role, rebuild)
  if not st.w.list or not rows or #rows == 0 then
    if (rows and #rows or -1) ~= st.w.count or (rows and not st.w.rows) then rebuild() end
    return
  end
  local old = st.w.rows and st.w.rows[st.w.list:selected() or 1]
  local items, sel = {}, 1
  for k, j in ipairs(rows) do
    items[k] = job_item(j, role)
    if old and j.pda == old.pda then sel = k end
  end
  st.w.list:items(items)
  st.w.list:select(sel)
  st.w.rows, st.w.count = rows, #items
end

-- One job ------------------------------------------------------------------

local function job_head(j)
  ui.label(14, 30, j.who .. " @ " .. j.company, {size = 14, color = C.ink, w = 292})
  line(50, "bid " .. sol.format(j.bid) .. " SOL   " .. j.offer_count .. " offers   " .. escrow.STATUS[j.status])
end

local function build_job()
  frame("job")
  local j = st.pick
  job_head(j)
  local me = me_key()
  if me and j.requester == me then
    line(70, "Your job: see My jobs.", C.ink, 14)
  elseif offered_on(j) then
    line(70, "You offered. Talk on Telegram:", C.ink, 14)
    ui.label(14, 92, j.telegram, {size = 20, color = C.brand})
  elseif j.status ~= escrow.OPEN then
    line(70, "Someone was picked already.", C.ink, 14)
  else
    line(68, "Telegram shown after you offer.")
    ui.list(6, 86, 308, 36, {{title = "Offer to make this intro", sub = "sign on your phone"}},
      {on_select = function()
        if not st.me then ui.toast("Register in Profile first") return end
        start_sign("offer", j, "myoffers")
      end})
  end
  line(170, "The requester picks one offer after talking.")
  ui.hint("SELECT offer   CANCEL back")
end

local function load_names(j)
  if st.names_job == j then return end  -- once per copy of the job
  st.names_job = j
  local want = {}
  -- Not registered yet (false) is asked again: they may have registered since.
  for _, w in ipairs(j.offers or {}) do if not st.names[w] then want[#want + 1] = w end end
  if #want == 0 then return end
  if st.mock then
    for _, w in ipairs(want) do st.names[w] = demo.introer(w) or false end
    return
  end
  chain.pdas(want, escrow.introer_pda, function(pdas)
    chain.many(pdas, function(ok, data)
      if not ok then return end
      for i, w in ipairs(want) do st.names[w] = data[i] and escrow.decode_introer(data[i]) or false end
      if st.screen == "myjob" and st.pick == j then show_later("myjob") end
    end)
  end)
end

local function build_myjob()
  frame("myjob")
  local j = st.pick
  job_head(j)
  local items, act = {}, {}
  if j.status == escrow.OPEN then
    line(68, j.offer_count == 0 and "No offers yet." or "Pick one after talking on Telegram:", C.ink)
    for _, w in ipairs(j.offers) do
      local x = st.names[w]
      items[#items + 1] = {title = "Approve " .. name_of(w),
        sub = x and ("jobs " .. x.jobs .. "   earned " .. sol.format(x.earned, 3) .. " SOL") or "introer"}
      act[#act + 1] = {"approve", w}
    end
  else
    line(68, "Picked: " .. name_of(j.approved), C.ink)
  end
  for _, a in ipairs(escrow.actions(j, "requester", nil, now())) do
    items[#items + 1] = {title = escrow.LABEL[a]}
    act[#act + 1] = {a}
  end
  if #items > 0 then
    ui.list(6, 86, 308, math.min(108, 36 * #items), items, {on_select = function(i)
      local a = act[i]
      if not a then return end
      if a[1] == "approve" then
        start_sign("approve", {pda = j.pda, serial = j.serial, introer = a[2]}, "myjobs")
      elseif a[1] == "cancel_job" then
        confirm("Cancel and get your bid back?", function(yes) if yes then start_sign("cancel_job", j, "myjobs") end end)
      else
        start_sign(a[1], j, "myjobs")
      end
    end})
  end
  if j.status == escrow.MADE then line(178, "Made? Confirm to pay. 72h, then refund.", C.orange) end
  local note = escrow.note(j, "requester", now())
  if note then line(178, note, C.orange) end
  ui.hint("SELECT sign   CANCEL back")
  load_names(j)
end

local function build_offerjob()
  frame("offerjob")
  local j = st.pick
  local acts
  if j.closed then
    line(32, "This job is closed.", C.ink, 14)
    acts = {"close_offer"}
  else
    job_head(j)
    line(68, "Telegram:", C.dim)
    ui.label(84, 64, j.telegram, {size = 20, color = C.brand})
    acts = escrow.actions(j, "introer", me_key(), now())
    if j.approved == me_key() and j.status == escrow.MADE then line(92, "Made. Waiting for them to confirm.", C.ink) end
  end
  local items = {}
  for k, a in ipairs(acts) do items[k] = escrow.LABEL[a] end
  if #items > 0 then
    ui.list(6, 110, 308, 36 * #items, items, {on_select = function(i) start_sign(acts[i], j, "myoffers") end})
  end
  ui.hint("SELECT sign   CANCEL back")
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
      bars[k]:show(false)
    end
  end
end

local function value_of(me) return sol.machine_value(me.earned, me.created_at, now()) end

local reset_data, restart_poll  -- forward

local function profile_items()
  return {
    {title = st.wallet and "My wallet" or "Connect wallet", sub = "scan with your phone", right = st.wallet and sol.short(st.wallet) or ""},
    {title = st.me and "Update my name" or "Register as an introer", sub = "sign on your phone"},
    {title = "Demo mode", sub = "pretend chain, no network", right = st.mock and "ON" or "OFF"},
  }
end

local function refresh_profile()
  local w, me = st.w, st.me
  if not w.value then return end
  if me then
    w.value:text(sol.format(value_of(me), 3) .. " SOL")
    w.stats:text((me.name ~= "" and me.name .. "   " or "") .. "jobs " .. me.jobs .. "   earned "
      .. sol.format(me.earned, 3) .. " SOL")
  else
    w.value:text("-- SOL")
    w.stats:text(me == false and "Not an introer yet" or ago_text())
  end
  draw_spark()
end

local function ask_name()
  if not st.mock and not st.wallet then return ask_wallet(ask_name) end
  input("Your introer name", escrow.NAME, function(name)
    if not name or name:gsub("%s", "") == "" then return end
    start_sign(st.me and "update_introer" or "register_introer",
      {name = name, badge_id = (badge.id() or ""):sub(1, 8)}, "profile")
  end)
end

local function build_profile()
  frame("profile")
  art.logo(12, 30, 2)
  ui.label(44, 30, "machine value (demo value)", {size = 12, color = C.dim})
  st.w.value = ui.label(44, 42, "", {size = 20, color = C.brand})
  ui.rect(14, 64, 100, 28, {color = C.line})
  st.w.spark = {}
  for k = 1, SPARK_N do st.w.spark[k] = ui.rect(16 + (k - 1) * 4, 74, 3, 2, {color = C.brand}) end
  if ui.qr then ui.qr(232, 28, 76, SITE) end
  ui.label(226, 106, "botbotcap.com", {size = 12, color = C.dim, w = 88, align = "center"})
  st.w.stats = line(96, "", C.ink)
  local list
  list = ui.list(6, 112, 308, 64, profile_items(), {on_select = function(i)
    if i == 1 then
      ask_wallet()
    elseif i == 2 then
      ask_name()
    else
      st.mock = not st.mock
      storage.set("mock", st.mock)
      reset_data()
      restart_poll()
      list:items(profile_items())
      list:select(3)
      ui.toast(st.mock and "Demo mode on" or "Demo mode off")
    end
  end})
  center(180, CTA, 14, C.orange)
  ui.hint("SELECT change   LEFT/RIGHT screens")
  refresh_profile()
end

-- Screens ------------------------------------------------------------------

local BUILD = {
  request = build_request, board = build_board, myjobs = build_myjobs, myoffers = build_myoffers,
  profile = build_profile, job = build_job, myjob = build_myjob, offerjob = build_offerjob,
  sign = build_sign, connect = build_connect,
}
local BACK = {job = "board", myjob = "myjobs", offerjob = "myoffers"}

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
  -- A tab's list is read when it opens, unless it was read in the last 15 s (rpc budget).
  local at = st.read_at[name]
  if fresh and at and sys.millis() - at.t > 15000 then poll(true) end
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
  -- The bands cycle: redraw the logo with the colours turned, 7 times a second.
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

-- Reading the chain ----------------------------------------------------------

local function refresh()
  if st.anim or st.modal then return end
  local s = st.screen
  if s == "profile" then refresh_profile()
  elseif s == "board" then refresh_jobs(st.board, "board", build_board)
  elseif s == "myjobs" then refresh_jobs(st.my_jobs, "requester", build_myjobs)
  elseif s == "myoffers" then refresh_jobs(st.my_offers, "introer", build_myoffers) end
end

-- A new copy of my introer account: value, spark, receipts.
local function got_me(me)
  st.me = me
  if not me then return end
  st.spark[#st.spark + 1] = sol.milli(value_of(me))
  while #st.spark > SPARK_N do table.remove(st.spark, 1) end
  storage.set("spark", st.spark)
  local before = st.jobs
  st.jobs = me.jobs
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

-- Jobs at `pdas`, 3 per call (a Job is ~700 bytes), or 5 per call without the offers ring
-- (`list`): cb(rows with pda, missing[i] = true).
local function read_jobs(gen, pdas, cb, list)
  chain.many(pdas, function(ok, data)
    if gen ~= st.gen then return end
    if not ok then return fail(data) end
    local rows, missing = {}, {}
    for i = 1, #pdas do
      local j = data[i] and escrow.decode_job(data[i])
      if j then j.pda = pdas[i]; rows[#rows + 1] = j else missing[i] = true end
    end
    cb(rows, missing)
  end, list and 5 or 3, list and escrow.JOB.LIST or nil)
end

local function read_board(gen)
  chain.account(escrow.board_pda(), function(ok, b)
    if gen ~= st.gen then return end
    if not ok then return fail(b) end
    local list = escrow.decode_board(b) or {}
    while #list > BOARD_SHOW do table.remove(list) end
    read_jobs(gen, list, function(rows)
      st.board = rows
      st.read_at.board.t = sys.millis()
      finish()
    end, true)
  end)
end

local function newest_first(rows)
  local out = {}
  for k = #rows, 1, -1 do out[#out + 1] = rows[k] end
  return out
end

-- My jobs from their nonces; drop the closed ones and posts that never landed.
local function read_mine(gen)
  local me, list = me_key(), st.mine
  chain.pdas(list, function(m) return escrow.job_pda(me, m.n) end, function(pdas)
    if gen ~= st.gen then return end
    read_jobs(gen, pdas, function(rows, missing)
      local keep, t = {}, now()
      for i, m in ipairs(list) do
        if not missing[i] then
          m.seen = true
          keep[#keep + 1] = m
        elseif not m.seen and (not t or t - m.at < 900) then
          keep[#keep + 1] = m  -- not landed yet
        end
      end
      if #keep ~= #list then st.mine = keep; storage.set("mine", keep) end
      st.my_jobs = newest_first(rows)
      st.read_at.myjobs.t = sys.millis()
      finish()
    end)
  end)
end

-- Jobs I offered on; a closed one stays until I take the offer's rent back.
local function read_offers(gen)
  local pdas = {}
  for k, o in ipairs(st.offered) do pdas[k] = solana.decode(o.j) end
  read_jobs(gen, pdas, function(rows, missing)
    rows = newest_first(rows)
    for i = 1, #pdas do
      if missing[i] then rows[#rows + 1] = {closed = true, pda = pdas[i], serial = st.offered[i].s} end
    end
    st.my_offers = rows
    st.read_at.myoffers.t = sys.millis()
    finish()
  end)
end

function poll(force)
  if st.mock then
    st.mockdata = st.mockdata or demo.new(now())
    local d = st.mockdata
    if not force then demo.tick(d) end
    local me = {}
    for k, v in pairs(d.me) do me[k] = v end
    st.board, st.my_jobs, st.my_offers = d.board, demo.mine(d), demo.my_offers(d)
    if not force then got_me(me) else st.me = me end
    return finish()
  end
  if st.sign and st.sign.timer and not force then return end  -- the watch has the rpc budget
  if st.busy and sys.millis() - st.busy < 30000 and not force then return end
  if not rpc then return fail("needs the rpc permission") end
  st.gen = st.gen + 1
  st.busy = sys.millis()
  local gen = st.gen
  local function rest()
    local s = st.screen
    if s == "board" or s == "job" then read_board(gen)
    elseif (s == "myjobs" or s == "myjob") and st.wallet then read_mine(gen)
    elseif (s == "myoffers" or s == "offerjob") and st.wallet then read_offers(gen)
    else finish() end
  end
  if not st.wallet then return rest() end
  chain.account(escrow.introer_pda(me_key()), function(ok, b)
    if gen ~= st.gen then return end
    if not ok then return fail(b) end
    got_me(b and escrow.decode_introer(b) or false)
    rest()
  end)
end

-- Clears what came from the chain (or the demo), in memory and in storage.
function reset_data()
  st.me, st.board, st.my_jobs, st.my_offers, st.names = nil, nil, nil, nil, {}
  st.updated, st.spark, st.jobs = nil, {}, nil
  storage.remove("spark") storage.remove("jobs")
end

function restart_poll()
  st.gen, st.busy, st.status, st.mockdata = st.gen + 1, nil, "starting", nil
  stop_sign()
  if st.poll_id then timer.cancel(st.poll_id) end
  st.poll_id = timer.every(POLL_MS, poll)
  poll()
end

-- Keys and ticks -------------------------------------------------------------

local function tab_index()
  for k, n in ipairs(TABS) do if n == st.screen then return k end end
end

function on_key(key)
  if st.anim then return true end
  if st.screen == "splash" and key ~= "back" then show("request") return true end
  if key == "back" then
    if st.screen == "connect" then
      local back = st.connect and st.connect.back or "request"
      stop_connect()
      show(back == "connect" and "request" or back)
      return true
    end
    if st.screen == "sign" then
      local back = (st.sign or st.retry or {}).back or "request"
      stop_sign()
      st.retry = nil
      show(back)
      return true
    end
    if BACK[st.screen] then show(BACK[st.screen]) return true end
    return false
  end
  if key == "select" and st.screen == "connect" and st.connect and st.connect.why then
    ask_wallet(st.connect.then_do)
    return true
  end
  if key == "select" and st.screen == "sign" and st.retry then
    local s = st.retry
    start_sign(s.action, s.row, s.back)
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
    if st.screen == "profile" and st.w.stats and st.me == nil then st.w.stats:text(ago_text()) end
  end
end

function on_exit()
  if led then led.off() end
end

-- Splash: the big rainbow bot, then Request an intro.
local function splash()
  st.screen = "splash"
  ui.clear()
  ui.bg(C.desk)
  art.logo(108, 30, 8)
  center(142, "Intro Bot", 20, C.ink)
  center(170, CTA, 14, C.orange)
  timer.after(1500, function()
    if st.screen == "splash" and not st.modal then show("request") end
  end)
end

splash()
restart_poll()
