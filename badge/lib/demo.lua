-- lib/demo.lua: a pretend chain for demo mode, no network. Same shapes as the real reads.
local escrow = require("lib.escrow")
local sol = require("lib.sol")

local M = {}

M.ME = "demo-me"  -- stands in for my wallet
M.PEOPLE = {
  ["demo-ana"] = {name = "Ana (Solana devs)", jobs = 7, earned = "2400000000"},
  ["demo-kai"] = {name = "Kai (Asia VCs)", jobs = 12, earned = "5100000000"},
  ["demo-lea"] = {name = "Lea (market makers)", jobs = 2, earned = "300000000"},
  [M.ME] = {name = "You", jobs = 3, earned = "1560000000"},
}
local ASKS = {
  {"Mert", "Helius"}, {"Toly", "Solana Labs"}, {"Lily", "Solana Foundation"}, {"Meow", "Jupiter"},
  {"Armani", "Backpack"}, {"Akshay", "Superteam"},
}

local function job(d, who, company, bid, requester, status)
  d.n = d.n + 1
  return {pda = "demo-job" .. d.n, nonce = tostring(d.n), who = who, company = company, bid = bid,
    telegram = "@" .. who:lower(), requester = requester or "demo-someone", status = status or escrow.OPEN,
    created_at = d.now, approved_at = d.now, made_at = d.now, offers = {}, offer_count = 0}
end

function M.new(now)
  local d = {n = 0, step = 0, now = now or 1790000000, offered = {}}
  d.me = {wallet = M.ME, badge_id = "DEMO", name = "You", jobs = 3, earned = "1560000000",
    created_at = d.now - 86400 * 4}
  d.board = {}
  for k = 1, 4 do
    d.board[k] = job(d, ASKS[k][1], ASKS[k][2], tostring(k * 50000000))
  end
  d.board[2].offers, d.board[2].offer_count = {"demo-ana"}, 1
  -- One I offered on and got approved for.
  local mine = d.board[3]
  mine.status, mine.approved, mine.offers, mine.offer_count = escrow.APPROVED, M.ME, {M.ME, "demo-lea"}, 2
  d.offered[mine.pda] = true
  -- My own job, with offers to pick from.
  local own = job(d, "Vitalik", "Ethereum", "300000000", M.ME)
  own.offers, own.offer_count = {"demo-kai", "demo-ana"}, 2
  d.board[#d.board + 1] = own
  return d
end

function M.mine(d)
  local out = {}
  for _, j in ipairs(d.board) do if j.requester == M.ME then out[#out + 1] = j end end
  return out
end

function M.my_offers(d)
  local out = {}
  for _, j in ipairs(d.board) do if d.offered[j.pda] then out[#out + 1] = j end end
  return out
end

function M.introer(wallet) return M.PEOPLE[wallet] end

local function find(d, pda)
  for i, j in ipairs(d.board) do if j.pda == pda then return i, j end end
end

-- One poll: new jobs and offers arrive; a job I made gets confirmed (a receipt).
function M.tick(d)
  d.step = d.step + 1
  d.now = d.now + 20
  if d.step % 3 == 0 and #d.board < 12 then
    local a = ASKS[d.n % #ASKS + 1]
    table.insert(d.board, 1, job(d, a[1], a[2], tostring(math.random(2, 30) * 10000000)))
  end
  for _, j in ipairs(d.board) do
    if j.requester == M.ME and j.status == escrow.OPEN and d.step % 4 == 0 and #j.offers < 3 then
      table.insert(j.offers, 1, "demo-lea")
      j.offer_count = j.offer_count + 1
      break
    end
  end
  for i, j in ipairs(d.board) do
    if j.approved == M.ME and j.status == escrow.MADE and d.step % 2 == 0 then
      table.remove(d.board, i)
      d.offered[j.pda] = nil
      d.me.jobs = d.me.jobs + 1
      d.me.earned = sol.add(d.me.earned, j.bid)
      break
    end
  end
end

-- Apply a signed step as if the wallet had sent it.
function M.apply(d, action, r)
  local i, j = find(d, r and r.pda)
  if action == "post_job" then
    local n = job(d, r.who, r.company, r.bid, M.ME)
    n.telegram = r.telegram
    table.insert(d.board, 1, n)
  elseif action == "offer" and j then
    d.offered[j.pda] = true
    table.insert(j.offers, 1, M.ME)
    j.offer_count = j.offer_count + 1
  elseif action == "withdraw_offer" or action == "close_offer" then
    d.offered[r.pda] = nil
  elseif action == "approve" and j then
    j.status, j.approved, j.approved_at = escrow.APPROVED, r.introer, d.now
  elseif action == "mark_made" and j then
    j.status, j.made_at = escrow.MADE, d.now
  elseif j and (action == "cancel_job" or action == "confirm" or action:find("^refund")) then
    table.remove(d.board, i)
  elseif action == "register_introer" or action == "update_introer" then
    d.me.name = r.name
  end
end

return M
