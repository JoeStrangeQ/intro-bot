-- lib/tx.lua: a legacy transaction message with one signer, the phone wallet.
-- The wallet's key is a placeholder the relay fills in; so is the blockhash.
-- (From the badge docs, "Build on the badge, sign on a phone".)
local M = {}

M.WALLET = ("\1"):rep(32)  -- not all zeros: that is the System Program
M.SYSTEM = ("\0"):rep(32)
-- Stand-ins for addresses made from the wallet; the relay derives them when it scans.
M.PDA = {("\2"):rep(32), ("\3"):rep(32)}

local function len(n)
  local s = ""
  repeat
    local b = n & 0x7F
    n = n >> 7
    s = s .. string.char(n > 0 and b | 0x80 or b)
  until n == 0
  return s
end

-- instructions: {program = 32 bytes, accounts = {{key, w = true}, {key}}, data = bytes}
function M.message(instructions)
  local keys, at, w = {M.WALLET}, {[M.WALLET] = 0}, {}
  local function add(k)
    if not at[k] then keys[#keys + 1] = k; at[k] = #keys - 1 end
  end
  for _, ix in ipairs(instructions) do
    for _, a in ipairs(ix.accounts) do if a.w then w[a[1]] = true; add(a[1]) end end
  end
  local writable = #keys
  for _, ix in ipairs(instructions) do
    for _, a in ipairs(ix.accounts) do add(a[1]) end
    add(ix.program)
  end
  local out = {string.char(1, 0, #keys - writable), len(#keys), table.concat(keys), ("\0"):rep(32),
    len(#instructions)}
  for _, ix in ipairs(instructions) do
    local idx = {}
    for i, a in ipairs(ix.accounts) do idx[i] = string.char(at[a[1]]) end
    out[#out + 1] = string.char(at[ix.program]) .. len(#idx) .. table.concat(idx) .. len(#ix.data) .. ix.data
  end
  return table.concat(out), at
end

return M
