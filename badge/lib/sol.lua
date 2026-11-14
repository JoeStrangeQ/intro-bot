-- lib/sol.lua: SOL amounts as digit strings (the badge has 32-bit ints), wallets, URLs.
local M = {}

local MAX_DIGITS = 30

-- Clean lamports: a digit string without leading zeros, or nil.
function M.digits(s)
  if math.type(s) == "integer" and s >= 0 then s = tostring(s) end
  if type(s) ~= "string" or #s == 0 or #s > MAX_DIGITS or s:find("%D") then return nil end
  s = s:gsub("^0+", "")
  return s == "" and "0" or s
end

local function commas(int)
  local out = int:sub(1, (#int - 1) % 3 + 1)
  for i = #out + 1, #int, 3 do out = out .. "," .. int:sub(i, i + 2) end
  return out
end

-- "1234500000" -> "1.2345" (truncated to `places` decimals, trailing zeros cut).
function M.format(lamports, places)
  local d = M.digits(lamports)
  if not d then return "?" end
  places = places or 4
  if #d < 10 then d = string.rep("0", 10 - #d) .. d end
  local int, frac = d:sub(1, -10), d:sub(-9, -10 + places)
  frac = frac:gsub("0+$", "")
  return commas(int) .. (frac ~= "" and "." .. frac or "")
end

-- "0.05" -> "50000000"; nil for anything else or zero.
function M.to_lamports(text)
  if type(text) ~= "string" then return nil end
  local int, frac = text:match("^%s*(%d*)%.?(%d*)%s*$")
  if not int or (int == "" and frac == "") or #int > 9 or #frac > 9 then return nil end
  local d = M.digits(int .. frac .. string.rep("0", 9 - #frac))
  if d == "0" then return nil end
  return d
end

-- Sum of two digit strings.
function M.add(a, b)
  a, b = M.digits(a), M.digits(b)
  if not a or not b then return nil end
  local out, carry = {}, 0
  for k = 1, math.max(#a, #b) do
    local s = (tonumber(a:sub(-k, -k)) or 0) + (tonumber(b:sub(-k, -k)) or 0) + carry
    out[#out + 1] = tostring(s % 10)
    carry = s // 10
  end
  if carry > 0 then out[#out + 1] = tostring(carry) end
  return M.digits(table.concat(out):reverse())
end

-- Rough milli-SOL as a number, for drawing only.
function M.milli(lamports)
  local d = M.digits(lamports)
  if not d or #d <= 6 then return 0 end
  return tonumber(d:sub(1, math.min(#d - 6, 12))) or 0
end

function M.is_wallet(s)
  return type(s) == "string" and #s >= 32 and #s <= 44
    and not s:find("[^1-9A-HJ-NP-Za-km-z]")
end

function M.short(w)
  if type(w) ~= "string" or #w < 10 then return w or "" end
  return w:sub(1, 4) .. ".." .. w:sub(-4)
end

function M.urlencode(s)
  return (tostring(s):gsub("[^%w%-%._~]", function(c) return string.format("%%%02X", c:byte()) end))
end

return M
