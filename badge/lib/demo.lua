-- lib/demo.lua: a pretend server for demo mode, no network. Same answers as the real one.
local M = {}

local ME = "me"
local PEOPLE = {
  ana = {name = "Ana (Solana devs)", jobs = 7, earned = 240},
  kai = {name = "Kai (Asia VCs)", jobs = 12, earned = 510},
  lea = {name = "Lea (market makers)", jobs = 2, earned = 30},
}
local ASKS = {{"Mert", "Helius"}, {"Toly", "Solana Labs"}, {"Lily", "Solana Foundation"}, {"Meow", "Jupiter"}}

function M.new()
  local d = {seq = 0, jobs = {}, me = {reg = true, name = "You", jobs = 3, earned = 156}, paid = 1240, paid_jobs = 31}
  local function job(who, co, bid, req, st)
    d.seq = d.seq + 1
    local j = {id = tostring(d.seq), who = who, co = co, bid = bid, req = req or "someone", st = st or "open",
      offers = {}, tg = "@" .. who:lower(), met = false}
    d.jobs[#d.jobs + 1] = j
    return j
  end
  for k = 1, 4 do job(ASKS[k][1], ASKS[k][2], k * 25) end
  d.jobs[2].offers = {"ana"}
  local picked = d.jobs[3]
  picked.st, picked.approved, picked.offers = "approved", ME, {ME, "lea"}
  local own = job("Vitalik", "Ethereum", 300, ME)
  own.offers = {"ana", "kai"}
  return d
end

local function find(d, id)
  for _, j in ipairs(d.jobs) do if j.id == id then return j end end
end

local function has(t, v)
  for _, x in ipairs(t) do if x == v then return true end end
  return false
end

local function row(j)
  return {id = j.id, who = j.who, co = j.co, bid = j.bid, n = #j.offers, st = j.st,
    o = has(j.offers, ME), me = j.approved == ME, met = j.met}
end

local function acts(d, j)
  local a = {}
  if j.req == ME then
    if j.st == "pending" then a[#a + 1] = "pay" end
    if j.st == "open" then a[#a + 1] = "cancel" end
    if j.st == "approved" or j.st == "made" then a[#a + 1] = "confirm" a[#a + 1] = "meet" end
  elseif has(j.offers, ME) then
    if j.approved == ME then
      if j.st == "approved" then a[#a + 1] = j.met and "made" or "meet" end
    elseif j.st == "open" then a[#a + 1] = "withdraw" end
  elseif j.st == "open" and d.me.reg then a[#a + 1] = "offer" end
  return a
end

local function detail(d, j)
  local out = row(j)
  out.mine, out.acts = j.req == ME, acts(d, j)
  if has(j.offers, ME) then out.tg = j.tg end
  if j.approved then out.picked = j.approved == ME and d.me.name or PEOPLE[j.approved].name end
  if j.req == ME then
    out.pool = {}
    for k, u in ipairs(j.offers) do out.pool[k] = PEOPLE[u] or {name = "You", jobs = 0, earned = 0} end
  end
  return out
end

local function list(d, pred)
  local out = {}
  for k = #d.jobs, 1, -1 do
    local j = d.jobs[k]
    if j.st ~= "closed" and pred(j) then out[#out + 1] = row(j) end
  end
  return out
end

-- Same paths as the server: returns ok, data.
function M.call(d, method, path, body)
  body = body or {}
  if path == "/board" then return true, {jobs = list(d, function(j) return j.st == "open" end)} end
  if path == "/fleet" then return true, {paid = d.paid, jobs = d.paid_jobs} end
  if path == "/me" then
    local m = {}
    for k, v in pairs(d.me) do m[k] = v end
    m.value = d.me.earned * 8 // 10
    m.mine = list(d, function(j) return j.req == ME end)
    m.offers = list(d, function(j) return has(j.offers, ME) end)
    return true, m
  end
  if path == "/introer" then
    d.me.reg, d.me.name = true, body.name
    return M.call(d, "GET", "/me")
  end
  if path == "/jobs" then
    d.seq = d.seq + 1
    d.jobs[#d.jobs + 1] = {id = tostring(d.seq), who = body.who, co = body.co, bid = body.bid, req = ME,
      st = "pending", offers = {}, tg = body.tg}
    return true, {id = tostring(d.seq), memo = "job " .. d.seq, bid = body.bid, esc = "ESC-DEMO"}
  end
  local id, act = path:match("^/jobs/(%d+)/?(%a*)$")
  local j = id and find(d, id)
  if not j then return false, "no such job" end
  if act == "" then return true, detail(d, j) end
  if act == "paid" then j.st = "open"
  elseif act == "offer" then j.offers[#j.offers + 1] = ME
  elseif act == "withdraw" then
    for k = #j.offers, 1, -1 do if j.offers[k] == ME then table.remove(j.offers, k) end end
  elseif act == "approve" then j.st, j.approved = "approved", j.offers[(body.n or 0) + 1]
  elseif act == "meet" then j.met = true
  elseif act == "made" then j.st = "made"
  elseif act == "confirm" then
    j.st = "closed"
    d.paid, d.paid_jobs = d.paid + j.bid, d.paid_jobs + 1
  elseif act == "cancel" or act == "refund" then j.st = "closed"
  else return false, "can not " .. act .. " now" end
  return true, detail(d, j)
end

-- Every poll, the demo moves on a little: someone confirms the job I marked made.
function M.tick(d)
  for _, j in ipairs(d.jobs) do
    if j.approved == ME and j.st == "made" then
      j.st = "closed"
      d.me.jobs, d.me.earned = d.me.jobs + 1, d.me.earned + j.bid
      d.paid, d.paid_jobs = d.paid + j.bid, d.paid_jobs + 1
      return
    end
  end
end

return M
