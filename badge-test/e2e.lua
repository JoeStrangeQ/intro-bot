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
local function request_of(intro, id) return escrow.decode_request(account(escrow.request_pda(intro, id))) end

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

-- The flow ----------------------------------------------------------------------------
local admin, introer, req1, req2, other = key("admin"), key("introer"), key("req1"), key("req2"), key("other")
local INTRO = escrow.introer_pda(introer.pub)
local SOL = 1000000000

local big = decode('{"a":[12345678901,12345678902],"b":5,"c":"x12345678901"}')
check(big.a[1] == "12345678901" and big.a[2] == "12345678902" and big.b == 5 and big.c == "x12345678901",
  "big numbers become strings, side by side too")
print("-- chain: " .. RPC_URL .. "   relay: " .. RELAY_URL .. (CAN_TIME and "   (time travel)" or ""))
check(account(escrow.config_pda()) ~= nil, "config made by init_config (upgrade authority " .. b58e(admin.pub):sub(1, 6) .. "..)")

-- Register.
must("register_introer", escrow.ix_register(introer.pub, "E2E-0001", "Founders in Lisbon", "10000000"), introer)
local x = introer_of(introer.pub)
check(x and x.wallet == introer.pub and x.offer == "Founders in Lisbon" and x.min_bid == "10000000"
  and x.badge_id == "E2E-0001" and x.open == 0 and x.jobs == 0 and x.next_id == "0", "badge decodes the live introer")
local dir = escrow.decode_directory(account(escrow.directory_pda()))
check(dir and dir[1] == introer.pub, "badge decodes the live directory: introer listed")
must("register a second introer", escrow.ix_register(other.pub, "E2E-0002", "Someone else", "10000000"), other)
must("update_introer", escrow.ix_update(introer.pub, "Founders and VCs in Lisbon", "100000000"), introer)
check(introer_of(introer.pub).offer == "Founders and VCs in Lisbon", "offer updated")
refused("bid below the min refused", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "0"), "Toly", "@r1",
  "50000000"), req1, "BidTooLow")
refused("bid on yourself refused", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "0"), "Toly", "@me",
  "100000000"), introer, "SelfBid")
refused("bid without Telegram refused", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "0"), "Toly", "",
  "100000000"), req1, "BadText")

-- Five bids fill the queue.
local amounts = {"100000000", "200000000", "300000000", "400000000", "500000000"}
for i, amount in ipairs(amounts) do
  local id = introer_of(introer.pub).next_id
  must("bid " .. i .. " (" .. sol.format(amount) .. " SOL)",
    escrow.ix_bid(INTRO, escrow.request_pda(INTRO, id), "Target " .. i, "@req1", amount), req1)
end
x = introer_of(introer.pub)
check(x.open == 5 and #x.slots == 5 and x.next_id == "5", "queue full: 5 open slots")
local q = request_of(INTRO, "0")
check(q and q.requester == req1.pub and q.bid == "100000000" and q.status == escrow.OPEN and q.target == "Target 1"
  and q.telegram == "@req1" and q.introer == INTRO, "badge decodes the live request")

-- Outbid the lowest.
local lo, need = escrow.lowest(x)
check(lo.id == "0" and need == "110000000", "lowest is id 0, outbid needs 0.11 SOL")
local low = {pda = escrow.request_pda(INTRO, lo.id), requester = req1.pub}
refused("outbid under +10% refused", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "5"), "Vitalik", "@req2",
  "109999999", low), req2, "BidTooLow")
refused("bid on a full queue without the lowest refused", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "5"),
  "Vitalik", "@req2", "200000000"), req2, "QueueFull")
local r1 = balance(req1.pub)
must("outbid at full queue", escrow.ix_bid(INTRO, escrow.request_pda(INTRO, "5"), "Vitalik", "@req2", need, low), req2)
check(account(low.pda) == nil, "outbid request closed")
check(diff(r1, balance(req1.pub)) > 100000000, "outbid requester refunded bid + rent")
x = introer_of(introer.pub)
check(x.open == 5 and x.next_id == "6", "still 5 open, next id 6")

-- Accept, made, confirm: the introer is paid.
local P1 = escrow.request_pda(INTRO, "1")
must("accept", escrow.ix_accept(INTRO, P1), introer)
check(request_of(INTRO, "1").status == escrow.ACCEPTED and introer_of(introer.pub).open == 4, "accepted, open 4")
refused("accept by another registered introer refused", escrow.ix_accept(escrow.introer_pda(other.pub), P1), other, "ConstraintSeeds")
must("mark_made", escrow.ix_made(INTRO, P1), introer)
check(request_of(INTRO, "1").status == escrow.MADE, "made: waiting for confirm")
refused("confirm by another requester refused", escrow.ix_confirm(INTRO, P1, introer.pub), req2, "WrongRequester")
local before, ib = introer_of(introer.pub), balance(introer.pub)
must("confirm", escrow.ix_confirm(INTRO, P1, introer.pub), req1)
local after = introer_of(introer.pub)
check(diff(ib, balance(introer.pub)) == 200000000, "introer paid exactly the bid (0.2 SOL)")
check(after.jobs == before.jobs + 1 and after.earned == sol.add(before.earned, "200000000"), "jobs and earned rise")
check(account(P1) == nil, "confirmed request closed")
check(sol.cmp(sol.machine_value(after.earned, after.created_at, os.time()), "0") > 0, "machine value shows")

-- Decline: the requester gets the bid back.
local P2 = escrow.request_pda(INTRO, "2")
r1 = balance(req1.pub)
must("decline", escrow.ix_decline(INTRO, P2, req1.pub), introer)
check(account(P2) == nil and diff(r1, balance(req1.pub)) > 300000000, "declined: bid + rent refunded")

-- Withdraw: not before 24h.
local P3 = escrow.request_pda(INTRO, "3")
refused("withdraw before 24h refused", escrow.ix_withdraw(INTRO, P3), req1, "TooEarly")

-- Requests for the timed paths: 4 accepted (work window), 5 made (confirm window).
local P4, P5 = escrow.request_pda(INTRO, "4"), escrow.request_pda(INTRO, "5")
must("accept id 4", escrow.ix_accept(INTRO, P4), introer)
must("accept id 5", escrow.ix_accept(INTRO, P5), introer)
must("mark_made id 5", escrow.ix_made(INTRO, P5), introer)
refused("refund_unconfirmed before 72h refused", escrow.ix_refund("refund_unconfirmed", INTRO, P5, req2.pub), req1, "NotExpired")
refused("refund_expired before 7 days refused", escrow.ix_refund("refund_expired", INTRO, P4, tx.WALLET), req1, "NotExpired")

if not CAN_TIME then
  skipped[#skipped + 1] = "withdraw after 24h, refund_unconfirmed after 72h, refund_expired after 7 days "
    .. "(this chain can't move its clock: run with surfpool)"
else
  time_travel(24 * 3600 + 60)
  r1 = balance(req1.pub)
  must("withdraw after 24h", escrow.ix_withdraw(INTRO, P3), req1)
  check(account(P3) == nil and diff(r1, balance(req1.pub)) > 0, "withdrawn: refunded")

  time_travel(72 * 3600 + 60)
  local r2 = balance(req2.pub)
  must("refund_unconfirmed after 72h (anyone)", escrow.ix_refund("refund_unconfirmed", INTRO, P5, req2.pub), req1)
  check(account(P5) == nil and diff(r2, balance(req2.pub)) >= 110000000, "unconfirmed: requester refunded")

  time_travel(7 * 24 * 3600 - 72 * 3600 - 24 * 3600)  -- about 7 days after accept
  refused("mark_made after 7 days refused", escrow.ix_made(INTRO, P4), introer, "WorkExpired")
  refused("refund_expired by someone else at 7 days refused", escrow.ix_refund("refund_expired", INTRO, P4, req1.pub), req2, "NotExpired")
  r1 = balance(req1.pub)
  -- As the badge builds it: the requester is the signer, so both are the placeholder.
  must("refund_expired by the requester at 7 days", escrow.ix_refund("refund_expired", INTRO, P4, tx.WALLET), req1)
  check(account(P4) == nil and diff(r1, balance(req1.pub)) > 0, "expired: requester refunded")
end

x = introer_of(introer.pub)
check(x.open == (CAN_TIME and 0 or 1) and x.jobs == 1 and x.earned == "200000000",
  "end: open count right, 1 job, 0.2 SOL earned")

print(string.format("\n%d passed, %d failed", passes, fails))
for _, s in ipairs(skipped) do print("not tested here: " .. s) end
os.exit(fails == 0 and 0 or 1)
