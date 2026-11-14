-- Local end-to-end test: the badge's own encoders and decoders (badge/lib) against a local
-- validator, the relay under `wrangler dev`, and wallet.mjs as the phone wallet.
-- Started by e2e.sh:  lua badge-test/e2e.lua <keys dir> <rpc url> <relay url> [time]
-- With "time", the chain can move its clock (surfpool): the 24h / 72h / 7 day paths run too.
local HERE = arg[0]:match("^(.*)/") or "."
local KEYS, RPC_URL, RELAY_URL, CAN_TIME = arg[1], arg[2], arg[3], arg[4] == "time"
assert(KEYS and RPC_URL and RELAY_URL, "usage: e2e.lua <keys dir> <rpc url> <relay url> [time]")
package.path = HERE .. "/../badge/?.lua;" .. package.path
local host = assert(loadfile(HERE .. "/host.lua"))(HERE)
local b58e, b58d = host.b58e, host.b58d

local fails, passes, skipped = 0, 0, {}
local function check(cond, what)
  if cond then passes = passes + 1; print("ok    " .. what)
  else fails = fails + 1; print("FAIL  " .. what) end
end

-- Shell helpers --------------------------------------------------------------------
local function sh(cmd)
  local p = io.popen(cmd)
  local out = p:read("a")
  local ok = p:close()
  return out, ok
end
local function quote(s) return "'" .. tostring(s):gsub("'", "'\\''") .. "'" end

local TMP = KEYS .. "/body.json"
local function curl(url, body, headers)
  local args = {"curl -s -m 20 -w '\\n%{http_code}'"}
  for k, v in pairs(headers or {}) do args[#args + 1] = "-H " .. quote(k .. ": " .. v) end
  if body then
    local f = assert(io.open(TMP, "w"))
    f:write(body)
    f:close()
    args[#args + 1] = "-H 'content-type: application/json' --data-binary @" .. quote(TMP)
  end
  args[#args + 1] = quote(url)
  local out = sh(table.concat(args, " "))
  local text, code = out:match("^(.*)\n(%d+)$")
  return tonumber(code) or 0, text or ""
end

-- The badge server turns whole numbers past 32 bits into strings: do the same.
local function decode(text)
  -- A whole number after : , or [ (never inside base64 or base58 text), ended by a frontier
  -- so the next delimiter stays for the next number.
  text = text:gsub('([:,%[]%s*)(%d%d%d%d%d%d%d%d%d%d+)%f[^%d]', function(a, n)
    if tonumber(n) > 2147483647 then return a .. '"' .. n .. '"' end
  end)
  return host.json.decode_lua(text)
end

-- Badge API stubs: real network, answered at once ---------------------------------
local queue = {}
_G.json = {encode = host.json.encode, decode = decode}
_G.timer = {after = function(_, fn) queue[#queue + 1] = fn end}
_G.sys = {millis = function() return math.floor(os.clock() * 1000) end, time = function() return os.time() end}
_G.solana = {encode = b58e, decode = b58d, pda = function(seeds, program) return host.pda(seeds, program) end}
_G.rpc = {call = function(method, params, _, cb)
  local code, text = curl(RPC_URL, host.json.encode({jsonrpc = "2.0", id = 1, method = method, params = params}))
  local r = code == 200 and decode(text)
  if not r then return cb(false, "http " .. code) end
  if r.error then return cb(false, "rpc " .. tostring(r.error.code) .. ": " .. tostring(r.error.message)) end
  cb(true, r.result)
end}
_G.http = {post = function(url, body, cb)
  local code, text = curl(url, host.json.encode(body), {["CF-Connecting-IP"] = "127.0.0.1"})
  if code == 0 then return cb(false, "unreachable") end
  cb(true, {status = code, body = text})
end}
local function pump()
  while #queue > 0 do table.remove(queue, 1)() end
end

local sol = require("lib.sol")
local bytes = require("lib.bytes")
local tx = require("lib.tx")
local escrow = require("lib.escrow")
local chain = require("lib.chain")
chain.RELAY = RELAY_URL
chain.BUDGET = 1e9

-- Chain helpers -----------------------------------------------------------------------
local function wait(fn)
  local r
  fn(function(...) r = table.pack(...) end)
  pump()
  assert(r, "no answer")
  return table.unpack(r, 1, r.n)
end
local function rpc_call(method, params)
  local ok, r = wait(function(cb) rpc.call(method, params, nil, cb) end)
  assert(ok, tostring(r))
  return r
end
local function account(addr)
  local ok, b = wait(function(cb) chain.account(addr, cb) end)
  assert(ok, tostring(b))
  return b
end
local function balance(key) return tostring(rpc_call("getBalance", {b58e(key), {commitment = "confirmed"}}).value) end
local function diff(a, b) return math.tointeger(tonumber(b) - tonumber(a)) end
local function introer_of(w) return escrow.decode_introer(account(escrow.introer_pda(w))) end
local function job_at(pda) return escrow.decode_job(account(pda)) end
local function serial(pda) return job_at(pda).serial end  -- offers are per job serial

local function key(name)
  local f = assert(io.open(KEYS .. "/" .. name .. ".json"))
  local secret = host.json.decode_lua(f:read("a"))
  f:close()
  local out = {}
  for i = 33, 64 do out[#out + 1] = string.char(secret[i]) end
  return {name = name, file = KEYS .. "/" .. name .. ".json", pub = table.concat(out)}
end

-- Build on the "badge", get the QR link from the relay, pay with the "phone".
local function sign(ix, who)
  local ok, link = wait(function(cb) chain.relay(tx.message({ix}), cb) end)
  if not ok then return false, "relay: " .. tostring(link) end
  if os.getenv("E2E_DEBUG") then print("link", link) end
  local out = sh("RPC_URL=" .. quote(RPC_URL) .. " node " .. quote(HERE .. "/wallet.mjs") .. " pay " .. quote(link) .. " " .. quote(who.file) .. " 2>/dev/null")
  local r = host.json.decode_lua(out:match("([^\n]+)\n*$") or "") or {}
  if r.signature then return true, r.signature end
  return false, (r.error or out) .. (r.logs and ("\n      " .. table.concat(r.logs, "\n      ")) or "")
end
local function must(what, ix, who)
  local ok, why = sign(ix, who)
  check(ok, what .. (ok and "" or (": " .. why)))
  return ok
end
local function refused(what, ix, who, code)  -- must fail with the program's error `code`
  local ok, why = sign(ix, who)
  check(not ok and why:find(code, 1, true), what .. " (" .. code .. ")"
    .. (ok and ": it went through" or (why:find(code, 1, true) and "" or ": " .. why:sub(1, 300))))
end

-- surfpool only: move the chain clock forward from what the Clock sysvar says now.
local CLOCK = b58d("SysvarC1ock11111111111111111111111111111111")
local function time_travel(seconds)
  local now = bytes.time(account(CLOCK), 33)
  rpc_call("surfnet_timeTravel", {{absoluteTimestamp = (now + seconds) * 1000}})
  check(bytes.time(account(CLOCK), 33) >= now + seconds, "clock moved " .. seconds // 3600 .. "h")
end

-- The flow (docs/spec-v2.md) ------------------------------------------------------------
local admin, ana, kai, req1, req2 = key("admin"), key("introer"), key("other"), key("req1"), key("req2")
local SOL = 1000000000

local big = decode('{"a":[12345678901,12345678902],"b":5,"c":"x12345678901"}')
check(big.a[1] == "12345678901" and big.a[2] == "12345678902" and big.b == 5 and big.c == "x12345678901",
  "big numbers become strings, side by side too")
print("-- chain: " .. RPC_URL .. "   relay: " .. RELAY_URL .. (CAN_TIME and "   (time travel)" or ""))
check(account(escrow.config_pda()) ~= nil and account(escrow.board_pda()) ~= nil,
  "config and board made by init_config (upgrade authority " .. b58e(admin.pub):sub(1, 6) .. "..)")

-- Introers register.
must("register_introer (Ana)", escrow.ix_register(ana.pub, "E2E-0001", "Ana"), ana)
must("register_introer (Kai)", escrow.ix_register(kai.pub, "E2E-0002", "Kai"), kai)
must("update_introer", escrow.ix_update(ana.pub, "E2E-0001", "Ana (Solana devs)"), ana)
local x = introer_of(ana.pub)
check(x and x.wallet == ana.pub and x.name == "Ana (Solana devs)" and x.badge_id == "E2E-0001" and x.jobs == 0,
  "badge decodes the live introer")

-- A requester posts jobs: the bid goes into the job's escrow.
local nonce = 1000
local function post(who, company, tg, bid, by)
  nonce = nonce + 1
  local pda = escrow.job_pda(by.pub, tostring(nonce))
  return escrow.ix_post_job(pda, tostring(nonce), who, company, tg, bid), pda
end
local ix, J1 = post("Toly", "Solana Labs", "@req1", "50000000", req1)
refused("bid below 0.01 SOL refused", select(1, post("Toly", "Solana Labs", "@req1", "5000000", req1)), req1, "BidTooLow")
refused("empty Telegram refused", select(1, post("Toly", "Solana Labs", "", "50000000", req1)), req1, "BadText")
ix, J1 = post("Toly", "Solana Labs", "@req1", tostring(SOL // 2), req1)
local r1 = balance(req1.pub)
must("post_job", ix, req1)
check(diff(r1, balance(req1.pub)) < -(SOL // 2), "bid held in the job")
local j = job_at(J1)
check(j and j.requester == req1.pub and j.who == "Toly" and j.company == "Solana Labs" and j.telegram == "@req1"
  and j.bid == tostring(SOL // 2) and j.status == escrow.OPEN and j.offer_count == 0, "badge decodes the live job")
local ok, rows = wait(function(cb) chain.many({J1}, cb, 5, escrow.JOB.LIST) end)
check(ok and escrow.decode_job(rows[1]).who == "Toly", "board listing: 220-byte slice decodes")
local board = escrow.decode_board(account(escrow.board_pda()))
check(board and board[1] == J1, "badge decodes the live board: newest job first")

-- Introers offer.
refused("requester can't offer on their own job", escrow.ix_offer(req1.pub, J1, serial(J1)), req1, "AccountNotInitialized")
local S1 = serial(J1)
must("offer (Ana)", escrow.ix_offer(ana.pub, J1, serial(J1)), ana)
must("offer (Kai)", escrow.ix_offer(kai.pub, J1, serial(J1)), kai)
sh("sleep 6")  -- a new blockhash (the relay keeps one for 5 s), or it's the same transaction again
refused("offer twice refused", escrow.ix_offer(kai.pub, J1, serial(J1)), kai, "already in use")
j = job_at(J1)
check(j.offer_count == 2 and j.offers[1] == kai.pub and j.offers[2] == ana.pub, "offer pool: newest first")
local o = escrow.decode_offer(account(escrow.offer_pda(J1, S1, ana.pub)))
check(o and o.job == J1 and o.introer == ana.pub and o.job_serial == j.serial, "badge decodes the live offer")
local J0
ix, J0 = post("Raj", "Solana Labs", "@ana", "50000000", ana)
must("an introer can post a job too", ix, ana)
refused("offer on your own job refused", escrow.ix_offer(ana.pub, J0, serial(J0)), ana, "SelfOffer")
refused("cancel_job in the first hour refused", escrow.ix_cancel_job(J0), ana, "TooEarly")
must("withdraw_offer (Kai)", escrow.ix_withdraw_offer(kai.pub, J1, serial(J1)), kai)
check(account(escrow.offer_pda(J1, S1, kai.pub)) == nil, "offer withdrawn")
j = job_at(J1)
check(j.offer_count == 1 and #j.offers == 1 and j.offers[1] == ana.pub, "withdrawn offer leaves the ring")

-- The requester approves Ana; she makes the intro; they confirm and she is paid.
refused("approve by someone else refused", escrow.ix_approve(J1, serial(J1), ana.pub), req2, "ConstraintSeeds")
must("approve (Ana)", escrow.ix_approve(J1, serial(J1), ana.pub), req1)
check(job_at(J1).status == escrow.APPROVED and job_at(J1).approved == ana.pub, "approved")
refused("mark_made by an introer not picked refused", escrow.ix_mark_made(J1), kai, "Unauthorized")
refused("cancel after approving refused", escrow.ix_cancel_job(J1), req1, "BadStatus")
must("mark_made", escrow.ix_mark_made(J1), ana)
check(job_at(J1).status == escrow.MADE, "made: waiting for confirm")
local before, ab = introer_of(ana.pub), balance(ana.pub)
must("confirm", escrow.ix_confirm(J1, ana.pub), req1)
local after = introer_of(ana.pub)
check(diff(ab, balance(ana.pub)) == SOL // 2, "Ana paid exactly the bid (0.5 SOL)")
check(after.jobs == before.jobs + 1 and after.earned == sol.add(before.earned, tostring(SOL // 2)), "jobs and earned rise")
check(account(J1) == nil, "confirmed job closed")
local kb = balance(ana.pub)
must("close_offer (anyone, job closed)", escrow.ix_close_offer(J1, S1, ana.pub), req2)
check(account(escrow.offer_pda(J1, S1, ana.pub)) == nil and diff(kb, balance(ana.pub)) > 0, "offer rent back to Ana")

-- Cancel an open job: the bid comes back.
local J2
ix, J2 = post("Mert", "Helius", "@req1", "200000000", req1)
must("post_job 2", ix, req1)
refused("cancel_job before 1h refused", escrow.ix_cancel_job(J2), req1, "TooEarly")

-- Jobs for the timed paths: J3 approved (work window), J4 made (confirm window).
local J3, J4
ix, J3 = post("Lily", "Solana Foundation", "@req2", "300000000", req2)
must("post_job 3", ix, req2)
ix, J4 = post("Meow", "Jupiter", "@req2", "400000000", req2)
must("post_job 4", ix, req2)
must("offer on 3", escrow.ix_offer(kai.pub, J3, serial(J3)), kai)
must("offer on 4", escrow.ix_offer(kai.pub, J4, serial(J4)), kai)
must("approve 3", escrow.ix_approve(J3, serial(J3), kai.pub), req2)
must("approve 4", escrow.ix_approve(J4, serial(J4), kai.pub), req2)
must("mark_made 4", escrow.ix_mark_made(J4), kai)
refused("refund_unconfirmed before 72h refused", escrow.ix_refund("refund_unconfirmed", J4), req2, "NotExpired")
refused("refund_expired before 7 days refused", escrow.ix_refund("refund_expired", J3), req2, "NotExpired")

if not CAN_TIME then
  skipped[#skipped + 1] = "cancel_job after 1h, refund_unconfirmed after 72h, refund_expired after 7 days, mark_made deadline "
    .. "(this chain can't move its clock: run with surfpool)"
else
  time_travel(3600 + 60)
  r1 = balance(req1.pub)
  must("cancel_job after 1h", escrow.ix_cancel_job(J2), req1)
  check(account(J2) == nil and diff(r1, balance(req1.pub)) > 200000000, "cancelled: bid + rent back")
  must("cancel_job after 1h (Ana's)", escrow.ix_cancel_job(J0), ana)
  time_travel(71 * 3600)
  refused("refund_unconfirmed by someone else at 72h refused", escrow.ix_refund("refund_unconfirmed", J4, req2.pub), req1, "NotExpired")
  local r2 = balance(req2.pub)
  must("refund_unconfirmed by the requester after 72h", escrow.ix_refund("refund_unconfirmed", J4), req2)
  check(account(J4) == nil and diff(r2, balance(req2.pub)) > 400000000 - 10000, "unconfirmed: refunded")
  time_travel(4 * 24 * 3600)  -- 7 days after approving
  refused("mark_made after 7 days refused", escrow.ix_mark_made(J3), kai, "WorkExpired")
  refused("refund_expired by someone else at 7 days refused", escrow.ix_refund("refund_expired", J3, req2.pub), req1, "NotExpired")
  time_travel(72 * 3600 + 60)
  r2 = balance(req2.pub)
  must("refund_expired by anyone 72h later", escrow.ix_refund("refund_expired", J3, req2.pub), req1)
  check(account(J3) == nil and diff(r2, balance(req2.pub)) > 300000000, "expired: requester refunded")
end

x = introer_of(ana.pub)
check(x.jobs == 1 and x.earned == tostring(SOL // 2), "end: Ana 1 job, 0.5 SOL earned")

print(string.format("\n%d passed, %d failed", passes, fails))
for _, s in ipairs(skipped) do print("not tested here: " .. s) end
os.exit(fails == 0 and 0 or 1)
