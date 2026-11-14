-- lib/chain.lua: reads the chain with `rpc` within its budget, and posts messages to the relay.
local bytes = require("lib.bytes")
local escrow = require("lib.escrow")
local sol = require("lib.sol")

local M = {}

M.RELAY = "https://relay.botbotcap.com"
M.BUDGET = 27  -- of the badge's 30 rpc calls a minute
local sent = {}

local function budget_left()
  local now = sys.millis()
  while sent[1] and now - sent[1] >= 60000 do table.remove(sent, 1) end
  return M.BUDGET - #sent
end
M.budget_left = budget_left

local function call(method, params, cb)
  if budget_left() <= 0 then return cb(false, "busy: try again soon") end
  sent[#sent + 1] = sys.millis()
  rpc.call(method, params, {cluster = escrow.CLUSTER}, cb)
end

local OPTS = {encoding = "base64", commitment = "confirmed"}

local function data_of(v)
  if type(v) ~= "table" or type(v.data) ~= "table" then return nil end
  return bytes.unbase64(v.data[1])
end

-- cb(ok, bytes or nil when missing, or error)
function M.account(addr, cb)
  call("getAccountInfo", {solana.encode(addr), OPTS}, function(ok, r)
    if not ok then return cb(false, r) end
    if type(r) ~= "table" then return cb(false, "bad answer") end
    cb(true, data_of(r.value))
  end)
end

-- Up to 5 addresses: cb(ok, {[i] = bytes or nil}). `len`: only the first len bytes.
function M.accounts(addrs, cb, len)
  local list = {}
  for i = 1, math.min(#addrs, 5) do list[i] = solana.encode(addrs[i]) end
  local opts = OPTS
  if len then opts = {encoding = "base64", commitment = "confirmed", dataSlice = {offset = 0, length = len}} end
  call("getMultipleAccounts", {list, opts}, function(ok, r)
    if not ok then return cb(false, r) end
    if type(r) ~= "table" or type(r.value) ~= "table" then return cb(false, "bad answer") end
    local out = {}
    for i = 1, #list do out[i] = data_of(r.value[i]) end
    cb(true, out)
  end)
end

-- Many addresses, `per` (default 5) per call, one call after the other:
-- cb(ok, {[i] = bytes or nil}). A Job is ~700 bytes: 3 fit one 3.5 KB answer.
function M.many(addrs, cb, per, len)
  per = per or 5
  local out, at = {}, 1
  local function step()
    if at > #addrs then return cb(true, out) end
    local chunk = {}
    for i = at, math.min(at + per - 1, #addrs) do chunk[#chunk + 1] = addrs[i] end
    M.accounts(chunk, function(ok, r)
      if not ok then return cb(false, r) end
      for i = 1, #chunk do out[at + i - 1] = r[i] end
      at = at + #chunk
      step()
    end, len)
  end
  step()
end

-- Addresses are pdas (~10k instructions each): work out 2 per callback.
-- make(item) returns the address; cb(addresses).
function M.pdas(items, make, cb)
  local out, k = {}, 1
  local function step()
    for _ = 1, 2 do
      if k > #items then break end
      out[k] = make(items[k])
      k = k + 1
    end
    if k > #items then cb(out) else timer.after(20, step) end
  end
  step()
end

-- Post a message; cb(ok, "solana:..." link or error).
function M.relay(message, cb)
  http.post(M.RELAY .. "/tx", {message = bytes.hex(message)}, function(ok, res)
    if not ok then return cb(false, res) end
    if res.status ~= 200 then return cb(false, "relay error " .. tostring(res.status)) end
    local t = json.decode(res.body or "")
    local url = type(t) == "table" and t.url
    if type(url) ~= "string" or #url > 256 or url:sub(1, #M.RELAY + 8) ~= "solana:" .. M.RELAY .. "/" then
      return cb(false, "bad relay answer")
    end
    -- Solana Pay: a link with a query must be percent-encoded after "solana:".
    if url:find("?", 1, true) then url = "solana:" .. sol.urlencode(url:sub(8)) end
    cb(true, url)
  end)
end

-- Ask for a "connect" link: the phone wallet that scans it tells the relay its address.
-- cb(ok, id, "solana:..." link) or cb(false, error).
function M.connect(cb)
  http.post(M.RELAY .. "/connect", {}, function(ok, res)
    if not ok then return cb(false, res) end
    if res.status ~= 200 then return cb(false, "relay error " .. tostring(res.status)) end
    local t = json.decode(res.body or "")
    local id, url = type(t) == "table" and t.id, type(t) == "table" and t.url
    if type(id) ~= "string" or not id:match("^%x+$") or #id ~= 32
      or url ~= "solana:" .. M.RELAY .. "/tx/" .. id then
      return cb(false, "bad relay answer")
    end
    cb(true, id, url)
  end)
end

-- Who scanned the connect link: cb(wallet) once a wallet has, cb(nil) before, cb(false) if gone.
function M.who(id, cb)
  http.get(M.RELAY .. "/tx/" .. id .. "/who", function(ok, res)
    if not ok then return cb(nil) end
    if res.status == 404 then return cb(false) end
    local t = res.status == 200 and json.decode(res.body or "")
    local w = type(t) == "table" and t.wallet
    cb(type(w) == "string" and sol.is_wallet(w) and w or nil)
  end)
end

return M
