-- lib/escrow.lua: the intro_escrow program (v2, docs/spec-v2.md): account layouts,
-- addresses, instructions. Fixed-size fields first, text as zero-padded byte arrays.
local bytes = require("lib.bytes")
local tx = require("lib.tx")

local M = {}

M.PROGRAM_ID = "GgViYsZgeTfkEh67JTK8MYmWegnsvNcsR6GJCF5EeMcC"
M.CLUSTER = "mainnet"

M.WORK_WINDOW = 7 * 24 * 3600     -- approved -> mark made
M.CONFIRM_WINDOW = 72 * 3600      -- made -> confirm
M.CANCEL_DELAY = 3600             -- posted -> cancel
M.WHO, M.COMPANY, M.TELEGRAM, M.NAME = 32, 32, 32, 32
M.OFFERS, M.BOARD = 16, 64
M.MIN_BID = "10000000"
M.MAX_BID = "100000000000"

M.OPEN, M.APPROVED, M.MADE = 0, 1, 2
M.STATUS = {[0] = "Open", [1] = "Approved", [2] = "Waiting for confirm"}

-- Anchor discriminators: sha256("account:<Name>") / sha256("global:<ix>"), first 8 bytes.
local D = {
  Introer = "3e179abd0466ce44", Job = "4b7c50cba1b4ca50", Offer = "d7583c47aaa249e5",
  Board = "4f30a03f9984f038", Stats = "be7d333fa9c524ee",
  register_introer = "7bdef1c58acb8cf2", update_introer = "69fe06de8958fa50",
  post_job = "22d03af881eab3d3", cancel_job = "7ef19bf132ec5376", offer = "35cc245a970636e7",
  withdraw_offer = "cb2683eacc7a3596", close_offer = "bf484323efd16184", approve = "454ad9247375614c",
  mark_made = "8aacbff25a16c159", confirm = "ae010fd503be8300",
  refund_expired = "7699a4f42880f2fa", refund_unconfirmed = "f3e95327b0f588d8",
}
M.DISC = {}
for k, v in pairs(D) do M.DISC[k] = bytes.unhex(v) end

-- Byte offsets (1-based for string.sub/byte), after the 8-byte discriminator.
-- (docs/spec-v2.md, "Program details")
-- Job: requester 32 | nonce u64 | serial u64 | bid u64 | status u8 | created_at, approved_at,
--      made_at i64 | approved 32 | offer_count u16 | who [32] | company [32] | telegram [32] |
--      bump | offers_head u8 | offers [16 x 32]. The ring is last: LIST bytes skip it.
M.JOB = {requester = 9, nonce = 41, serial = 49, bid = 57, status = 65, created_at = 66, approved_at = 74,
  made_at = 82, approved = 90, offer_count = 122, who = 124, company = 156, telegram = 188,
  offers_head = 221, offers = 222, size = 733, LIST = 220}
-- Introer: wallet 32 | badge_id [8] | name [32] | jobs_done u32 | earned u64 | created_at i64 | bump
M.INTROER = {wallet = 9, badge_id = 41, name = 49, jobs_done = 81, earned = 85, created_at = 93, size = 101}
-- Offer: job 32 | introer 32 | job_serial u64 | created_at i64 | bump
M.OFFER = {job = 9, introer = 41, job_serial = 73, created_at = 81, size = 89}
-- Board (zero-copy): head u8 | bump u8 | 6 padding | posted u64 | jobs [64 x 32], a ring of the newest
M.BOARD_L = {head = 9, posted = 17, jobs = 25, size = 2072}
-- Stats (fleet totals): paid u64 | jobs u64 | bump | spare [64]
M.STATS = {paid = 9, jobs = 17, size = 89}

local ZERO = ("\0"):rep(32)

local function key(b, at) return b:sub(at, at + 31) end

-- A ring of `n` keys at `at`, newest first; `head` is the next slot to write.
local function ring(b, at, n, head)
  local out = {}
  for k = 0, n - 1 do
    local slot = (head - 1 - k) % n
    local w = key(b, at + slot * 32)
    if w ~= ZERO then out[#out + 1] = w end
  end
  return out
end

-- A whole Job, or its first LIST bytes (then `offers` is empty).
function M.decode_job(b)
  local L = M.JOB
  if type(b) ~= "string" or #b < L.LIST or b:sub(1, 8) ~= M.DISC.Job then return nil end
  local full = #b >= L.size
  local s = bytes.u8(b, L.status)
  if not M.STATUS[s] then return nil end
  local count = string.unpack("<I2", b, L.offer_count)
  local approved = key(b, L.approved)
  return {
    requester = key(b, L.requester),
    nonce = bytes.u64(b, L.nonce),
    bid = bytes.u64(b, L.bid),
    status = s,
    created_at = bytes.time(b, L.created_at),
    approved_at = bytes.time(b, L.approved_at),
    made_at = bytes.time(b, L.made_at),
    approved = approved ~= ZERO and approved or nil,
    offer_count = count,
    -- Every slot, newest first: a withdrawn offer leaves a zero hole in the ring.
    offers = full and ring(b, L.offers, M.OFFERS, bytes.u8(b, L.offers_head)) or {},
    serial = bytes.u64(b, L.serial),
    who = bytes.text(b, L.who, M.WHO),
    company = bytes.text(b, L.company, M.COMPANY),
    telegram = bytes.text(b, L.telegram, M.TELEGRAM),
  }
end

function M.decode_introer(b)
  local L = M.INTROER
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Introer then return nil end
  return {
    wallet = key(b, L.wallet),
    badge_id = bytes.text(b, L.badge_id, 8),
    name = bytes.text(b, L.name, M.NAME),
    jobs = bytes.i32(b, L.jobs_done),
    earned = bytes.u64(b, L.earned),
    created_at = bytes.time(b, L.created_at),
  }
end

function M.decode_offer(b)
  local L = M.OFFER
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Offer then return nil end
  return {job = key(b, L.job), introer = key(b, L.introer), job_serial = bytes.u64(b, L.job_serial),
    created_at = bytes.time(b, L.created_at)}
end

-- Fleet totals: lamports paid to introers (as a string) and intros paid.
function M.decode_stats(b)
  local L = M.STATS
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Stats then return nil end
  return {paid = bytes.u64(b, L.paid), jobs = tonumber(bytes.u64(b, L.jobs)) or 0}
end

-- The board's job addresses, newest first.
function M.decode_board(b)
  local L = M.BOARD_L
  if type(b) ~= "string" or #b < L.size or b:sub(1, 8) ~= M.DISC.Board then return nil end
  return ring(b, L.jobs, M.BOARD, bytes.u8(b, L.head))
end

-- Addresses (32 bytes). Each pda costs ~10k instructions: they are cached.
local PROGRAM
local function program()
  PROGRAM = PROGRAM or solana.decode(M.PROGRAM_ID)
  return PROGRAM
end
local cache = {}
local function pda(...)
  local seeds = {...}
  local k = table.concat(seeds, "|")
  cache[k] = cache[k] or (solana.pda(seeds, program()))
  return cache[k]
end
function M.config_pda() return pda("config") end
function M.board_pda() return pda("board") end
function M.stats_pda() return pda("stats") end
-- With no wallet yet (nil), the relay's stand-ins: tx.PDA[1] for the job or introer, [2] for the offer.
function M.introer_pda(wallet) return wallet and pda("introer", wallet) or tx.PDA[1] end
function M.job_pda(requester, nonce) return requester and pda("job", requester, bytes.pack_u64(nonce)) or tx.PDA[1] end
-- Offers are per job serial, so offers on a closed job never count for a re-post.
function M.offer_pda(job, serial, introer_wallet)
  if not introer_wallet then return tx.PDA[2] end
  return pda("offer", job, bytes.pack_u64(serial), introer_wallet)
end

-- Instructions, signer first. W is tx.WALLET, the signer the relay fills in.
local function ix(name, accounts, args)
  return {program = program(), accounts = accounts, data = M.DISC[name] .. (args or "")}
end
local W = tx.WALLET

function M.ix_register(me, badge_id, name)
  return ix("register_introer", {{W, w = true}, {M.introer_pda(me), w = true}, {tx.SYSTEM}},
    bytes.fixed(badge_id, 8) .. bytes.fixed(name, M.NAME))
end

function M.ix_update(me, badge_id, name)
  return ix("update_introer", {{W}, {M.introer_pda(me), w = true}}, bytes.fixed(badge_id, 8) .. bytes.fixed(name, M.NAME))
end

function M.ix_post_job(job, nonce, who, company, telegram, bid)
  return ix("post_job", {{W, w = true}, {M.config_pda()}, {M.board_pda(), w = true}, {job, w = true},
    {tx.SYSTEM}}, bytes.pack_u64(nonce) .. bytes.fixed(who, M.WHO) .. bytes.fixed(company, M.COMPANY)
    .. bytes.fixed(telegram, M.TELEGRAM) .. bytes.pack_u64(bid))
end

function M.ix_cancel_job(job)
  return ix("cancel_job", {{W, w = true}, {job, w = true}})
end

function M.ix_offer(me, job, serial)
  return ix("offer", {{W, w = true}, {M.config_pda()}, {M.introer_pda(me)}, {job, w = true},
    {M.offer_pda(job, serial, me), w = true}, {tx.SYSTEM}})
end

function M.ix_withdraw_offer(me, job, serial)
  return ix("withdraw_offer", {{W, w = true}, {M.offer_pda(job, serial, me), w = true}, {job, w = true}})
end

-- Anyone, once the job is closed: the rent goes back to the introer.
function M.ix_close_offer(job, serial, introer_wallet)
  return ix("close_offer", {{W}, {M.offer_pda(job, serial, introer_wallet), w = true}, {introer_wallet, w = true},
    {job}})
end

-- Approves the offer's introer.
function M.ix_approve(job, serial, introer_wallet)
  return ix("approve", {{W}, {job, w = true}, {M.offer_pda(job, serial, introer_wallet)}})
end

function M.ix_mark_made(job)
  return ix("mark_made", {{W}, {job, w = true}})
end

function M.ix_confirm(job, introer_wallet)
  return ix("confirm", {{W, w = true}, {job, w = true}, {M.introer_pda(introer_wallet), w = true},
    {introer_wallet, w = true}, {M.stats_pda(), w = true}})
end

-- The requester refunds their own job: the same placeholder key as caller and requester,
-- since the relay can't add the wallet to the message a second time.
function M.ix_refund(name, job, requester)
  return ix(name, {{W}, {job, w = true}, {requester or W, w = true}})
end

-- A line about what can't be done yet, or nil.
function M.note(j, role, now)
  if role == "requester" and j.status == M.OPEN and now then
    local left = j.created_at + M.CANCEL_DELAY - now
    if left > 0 then return "Cancel available in " .. math.max(1, (left + 59) // 60) .. " min" end
  end
end

-- Signed steps a job allows, for its requester or for an introer `me` (32 bytes), at `now`.
function M.actions(j, role, me, now)
  local out = {}
  if role == "requester" then
    if j.status == M.OPEN and now and now >= j.created_at + M.CANCEL_DELAY then out[1] = "cancel_job" end
    if j.status == M.APPROVED or j.status == M.MADE then out[#out + 1] = "confirm" end
    if now and j.status == M.APPROVED and now > j.approved_at + M.WORK_WINDOW then
      out[#out + 1] = "refund_expired"
    end
    if now and j.status == M.MADE and now > j.made_at + M.CONFIRM_WINDOW then
      out[#out + 1] = "refund_unconfirmed"
    end
    return out
  end
  local mine = me and j.approved == me
  if mine and j.status == M.APPROVED and not (now and now > j.approved_at + M.WORK_WINDOW) then
    out[1] = "mark_made"
  end
  if not mine then out[#out + 1] = "withdraw_offer" end
  return out
end

M.LABEL = {
  register_introer = "Register", update_introer = "Update name", post_job = "Post job",
  cancel_job = "Cancel job", offer = "Offer", withdraw_offer = "Withdraw offer",
  close_offer = "Get offer rent back", approve = "Approve", mark_made = "Intro made",
  confirm = "Confirm + pay", refund_expired = "Refund (7 days passed)",
  refund_unconfirmed = "Refund (72h passed)",
}

return M
