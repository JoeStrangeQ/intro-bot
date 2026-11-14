-- lib/demo.lua: a pretend chain for demo mode, no network. Same shapes as the real reads.
local escrow = require("lib.escrow")
local sol = require("lib.sol")

local M = {}

local PEOPLE = {
  {"Mert at Helius", "@mert"}, {"An Anza core dev", "@sol_dev"}, {"Jupiter BD", "@jup_bd"},
  {"Breakpoint MC", "@bp_mc"}, {"Phantom PM", "@ph_pm"}, {"Superteam lead", "@st_lead"},
}
M.INTROERS = {
  {w = "Demo1ntroer1111111111111111111111111111111", name = "@ana", offer = "Solana core devs, infra",
    min = "50000000", jobs = 7, earned = "2400000000", open = 2},
  {w = "Demo2ntroer2222222222222222222222222222222", name = "@kai", offer = "Asia VCs and market makers",
    min = "100000000", jobs = 12, earned = "5100000000", open = 5},
}

local function row(d, who, bid, status)
  d.next = d.next + 1
  return {pda = "demo" .. d.next, id = tostring(d.next), target = who[1], telegram = who[2],
    bid = bid, status = status, created_at = d.now, accepted_at = d.now, made_at = d.now}
end

function M.new(now)
  local d = {next = 0, step = 0, now = now or 1790000000}
  d.me = {wallet = "", min_bid = "50000000", next_id = "3", jobs = 3, earned = "1560000000",
    created_at = d.now - 86400 * 4, open = 2, badge_id = "DEMO", offer = "Founders and devs at BP"}
  d.queue = {row(d, PEOPLE[1], "200000000", 0), row(d, PEOPLE[2], "120000000", 1), row(d, PEOPLE[3], "80000000", 0)}
  local m = row(d, {"Toly", "@me"}, "300000000", 2)
  m.w, m.made_at = M.INTROERS[1].w, d.now - 80 * 3600
  local m2 = row(d, {"A Firedancer dev", "@me"}, "150000000", 0)
  m2.w = M.INTROERS[2].w
  d.mine = {m, m2}
  return d
end

-- One poll: new bids arrive, some requesters confirm.
function M.tick(d)
  d.step = d.step + 1
  d.now = d.now + 20
  if d.step % 3 == 0 and #d.queue < 6 then
    d.queue[#d.queue + 1] = row(d, PEOPLE[d.next % #PEOPLE + 1], tostring(math.random(5, 40) * 10000000), 0)
    d.me.open = d.me.open + 1
  end
  if d.step % 4 == 0 then
    for i, r in ipairs(d.queue) do
      if r.status == escrow.MADE then
        table.remove(d.queue, i)
        d.me.jobs = d.me.jobs + 1
        d.me.earned = sol.add(d.me.earned, r.bid)
        break
      end
    end
  end
end

function M.introer(wallet)
  for _, x in ipairs(M.INTROERS) do
    if x.w == wallet then
      return {min_bid = x.min, next_id = "9", jobs = x.jobs, earned = x.earned,
        created_at = 1790000000 - 86400, open = x.open, badge_id = "", offer = x.offer}
    end
  end
end

local function find(list, pda)
  for i, r in ipairs(list) do if r.pda == pda then return i, r end end
end

-- Apply a signed step as if the wallet had sent it.
function M.apply(d, action, r)
  local qi, q = find(d.queue, r and r.pda)
  local mi = find(d.mine, r and r.pda)
  if action == "accept" and q then q.status = escrow.ACCEPTED; q.accepted_at = d.now; d.me.open = d.me.open - 1
  elseif action == "mark_made" and q then q.status = escrow.MADE; q.made_at = d.now
  elseif action == "decline" and q then table.remove(d.queue, qi); d.me.open = d.me.open - 1
  elseif mi and (action == "withdraw" or action == "confirm" or action:find("^refund")) then
    table.remove(d.mine, mi)
  elseif action == "bid" then
    local n = row(d, {r.target, r.telegram}, r.bid, 0)
    n.w = r.w
    d.mine[#d.mine + 1] = n
  elseif action == "register_introer" or action == "update_introer" then
    d.me.offer, d.me.min_bid = r.offer, r.min_bid
  end
end

return M
