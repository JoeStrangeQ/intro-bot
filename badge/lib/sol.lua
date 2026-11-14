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

-- floor(a * mul / div) for a digit string and small mul, div (fits 31 bits).
function M.mul_div(a, mul, div)
  a = M.digits(a)
  if not a then return nil end
  local prod, carry = {}, 0
  for k = #a, 1, -1 do
    local v = (a:byte(k) - 48) * mul + carry
    prod[#prod + 1] = v % 10
    carry = v // 10
  end
  while carry > 0 do prod[#prod + 1] = carry % 10; carry = carry // 10 end
  local out, rem = {}, 0
  for k = #prod, 1, -1 do
    local v = rem * 10 + prod[k]
    out[#out + 1] = tostring(v // div)
    rem = v % div
  end
  return M.digits(table.concat(out))
end

-- -1, 0 or 1.
function M.cmp(a, b)
  a, b = M.digits(a) or "0", M.digits(b) or "0"
  if #a ~= #b then return #a < #b and -1 or 1 end
  if a == b then return 0 end
  return a < b and -1 or 1
end

-- Machine value (display only): earned x 0.8 x wear, wear = max(0.5, 1 - 0.01 x days).
function M.machine_value(earned, created_at, now)
  local days = (now and created_at and now > created_at) and (now - created_at) // 86400 or 0
  local wear = math.max(50, 100 - days)
  return M.mul_div(earned, 8 * wear, 1000)
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
