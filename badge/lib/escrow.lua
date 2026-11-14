-- lib/escrow.lua: the intro_escrow program: account layouts, addresses, instructions.
-- Layouts keep fixed-size fields first and text as zero-padded byte arrays (docs/spec.md).
local bytes = require("lib.bytes")
local tx = require("lib.tx")

local M = {}

M.PROGRAM_ID = "GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC"
M.CLUSTER = "devnet"

M.MAX_OPEN = 5
M.CONFIRM_WINDOW = 72 * 3600
M.WORK_WINDOW = 7 * 24 * 3600
M.TARGET, M.TELEGRAM, M.OFFER = 64, 32, 64
M.MIN_BID_FLOOR = "10000000"
M.MAX_BID = "100000000000"

M.OPEN, M.ACCEPTED, M.MADE = 0, 1, 2
M.STATUS = {[0] = "Open", [1] = "Accepted", [2] = "Waiting for confirm"}

-- Anchor discriminators: sha256("account:<Name>") / sha256("global:<ix>"), first 8 bytes.
local D = {
  Introer = "3e179abd0466ce44", Request = "7dac96a1a2732747", Directory = "9153a590b7d107af",
  register_introer = "7bdef1c58acb8cf2", update_introer = "69fe06de8958fa50",
  bid = "c738552692f3259e", withdraw = "b712469c946da122", accept = "419646d885066b04",
  decline = "18395aa25b5ef5b1", mark_made = "8aacbff25a16c159", confirm = "ae010fd503be8300",
  refund_unconfirmed = "f3e95327b0f588d8", refund_expired = "7699a4f42880f2fa",
}
M.DISC = {}
for k, v in pairs(D) do M.DISC[k] = bytes.unhex(v) end

-- Byte offsets (1-based for string.sub/byte), after the 8-byte discriminator.
-- Introer: wallet 32 | min_bid u64 | next_id u64 | jobs_done u32 | earned u64 |
--          created_at i64 | open_count u8 | bump u8 | badge_id [8] | offer [64]
M.INTROER = {wallet = 9, min_bid = 41, next_id = 49, jobs_done = 57, earned = 61,
  created_at = 69, open_count = 77, bump = 78, badge_id = 79, offer = 87, size = 150}
-- Request: introer 32 | requester 32 | id u64 | bid u64 | status u8 | created_at i64 |
--          accepted_at i64 | made_at i64 | bump u8 | target [64] | telegram [32]
M.REQUEST = {introer = 9, requester = 41, id = 73, bid = 81, status = 89, created_at = 90,
  accepted_at = 98, made_at = 106, bump = 114, target = 115, telegram = 179, size = 210}

local PROGRAM
local function program()
  PROGRAM = PROGRAM or solana.decode(M.PROGRAM_ID)
  return PROGRAM
end

function M.decode_introer(b)
  local L = M.INTROER
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Introer then return nil end
  return {
    wallet = b:sub(L.wallet, L.wallet + 31),
    min_bid = bytes.u64(b, L.min_bid),
    next_id = bytes.u64(b, L.next_id),
    jobs = bytes.i32(b, L.jobs_done),
    earned = bytes.u64(b, L.earned),
    created_at = bytes.time(b, L.created_at),
    open = bytes.u8(b, L.open_count),
    badge_id = bytes.text(b, L.badge_id, 8),
    offer = bytes.text(b, L.offer, M.OFFER),
  }
end

function M.decode_request(b)
  local L = M.REQUEST
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Request then return nil end
  local s = bytes.u8(b, L.status)
  if not M.STATUS[s] then return nil end
  return {
    introer = b:sub(L.introer, L.introer + 31),
    requester = b:sub(L.requester, L.requester + 31),
    id = bytes.u64(b, L.id),
    bid = bytes.u64(b, L.bid),
    status = s,
    created_at = bytes.time(b, L.created_at),
    accepted_at = bytes.time(b, L.accepted_at),
    made_at = bytes.time(b, L.made_at),
    target = bytes.text(b, L.target, M.TARGET),
    telegram = bytes.text(b, L.telegram, M.TELEGRAM),
  }
end

-- Directory: head u8 | wallets [32 x 32], a ring of the latest introers. Newest first.
function M.decode_directory(b)
  if type(b) ~= "string" or #b < 9 + 32 * 32 or b:sub(1, 8) ~= M.DISC.Directory then return nil end
  local head, out, zero = b:byte(9), {}, ("\0"):rep(32)
  for k = 0, 31 do
    local slot = (head - 1 - k) % 32
    local w = b:sub(10 + slot * 32, 41 + slot * 32)
    if w ~= zero then out[#out + 1] = w end
  end
  return out
end

-- Addresses (32 bytes). Each pda costs ~10k instructions: callers cache them.
local CONFIG, DIRECTORY, INTROERS = nil, nil, {}
function M.directory_pda()
  DIRECTORY = DIRECTORY or (solana.pda({"directory"}, program()))
  return DIRECTORY
end
function M.config_pda()
  CONFIG = CONFIG or (solana.pda({"config"}, program()))
  return CONFIG
end
function M.introer_pda(wallet)
  INTROERS[wallet] = INTROERS[wallet] or (solana.pda({"introer", wallet}, program()))
  return INTROERS[wallet]
end
function M.request_pda(introer, id)
  return (solana.pda({"request", introer, bytes.pack_u64(id)}, program()))
end

-- Instructions, accounts in the program's order (idl/intro_escrow.json).
-- W is tx.WALLET, the signer the relay fills in.
local function ix(name, accounts, args)
  return {program = program(), accounts = accounts, data = M.DISC[name] .. (args or "")}
end
local W = tx.WALLET

function M.ix_register(my_wallet, badge_id, offer, min_bid)
  return ix("register_introer", {
    {W, w = true}, {M.introer_pda(my_wallet), w = true}, {M.directory_pda(), w = true}, {tx.SYSTEM},
  }, bytes.fixed(badge_id, 8) .. bytes.fixed(offer, M.OFFER) .. bytes.pack_u64(min_bid))
end

function M.ix_update(my_wallet, offer, min_bid)
  return ix("update_introer", {{W}, {M.introer_pda(my_wallet), w = true}},
    bytes.fixed(offer, M.OFFER) .. bytes.pack_u64(min_bid))
end

-- lowest = {pda, requester} when the queue is full, others = the other open request pdas.
-- A missing optional account is the program id.
function M.ix_bid(introer, request, target, telegram, amount, lowest, others)
  local p = program()
  local acc = {
    {W, w = true}, {M.config_pda(), w = true}, {introer, w = true}, {request, w = true}, {tx.SYSTEM},
    lowest and {lowest.pda, w = true} or {p}, lowest and {lowest.requester, w = true} or {p},
  }
  for _, o in ipairs(others or {}) do acc[#acc + 1] = {o} end
  return ix("bid", acc, bytes.fixed(target, M.TARGET) .. bytes.fixed(telegram, M.TELEGRAM)
    .. bytes.pack_u64(amount))
end

function M.ix_withdraw(introer, request)
  return ix("withdraw", {{W, w = true}, {M.config_pda(), w = true}, {introer, w = true}, {request, w = true}})
end

function M.ix_accept(introer, request)
  return ix("accept", {{W}, {introer, w = true}, {request, w = true}})
end

function M.ix_made(introer, request)
  return ix("mark_made", {{W}, {introer, w = true}, {request, w = true}})
end

function M.ix_decline(introer, request, requester)
  return ix("decline", {{W}, {M.config_pda(), w = true}, {introer, w = true}, {request, w = true},
    {requester, w = true}})
end

function M.ix_confirm(introer, request, introer_wallet)
  return ix("confirm", {{W, w = true}, {M.config_pda(), w = true}, {introer, w = true}, {request, w = true},
    {introer_wallet, w = true}})
end

-- Anyone may send these; the signer only pays the fee.
function M.ix_refund(name, introer, request, requester)
  return ix(name, {{W}, {M.config_pda(), w = true}, {introer}, {request, w = true}, {requester, w = true}})
end

-- Which signed steps fit a request, for its introer or its requester, at unix time `now`.
function M.actions(r, role, now)
  if role == "introer" then
    if r.status == M.OPEN then return {"accept", "decline"} end
    if r.status == M.ACCEPTED then return {"mark_made"} end
    return {}
  end
  local out = {}
  if r.status == M.OPEN then out[1] = "withdraw" end
  if r.status == M.ACCEPTED or r.status == M.MADE then out[#out + 1] = "confirm" end
  if now and r.status == M.MADE and now > r.made_at + M.CONFIRM_WINDOW then
    out[#out + 1] = "refund_unconfirmed"
  end
  if now and r.status == M.ACCEPTED and now > r.accepted_at + M.WORK_WINDOW then
    out[#out + 1] = "refund_expired"
  end
  return out
end

M.LABEL = {
  accept = "Accept", decline = "Decline", mark_made = "Intro made", withdraw = "Withdraw",
  confirm = "Confirm + pay", refund_unconfirmed = "Refund (72h passed)",
  refund_expired = "Refund (7 days passed)", bid = "Bid", register_introer = "Register",
  update_introer = "Update offer",
}

return M
