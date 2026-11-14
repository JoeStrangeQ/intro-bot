-- lib/bytes.lua: base64, hex, and u64 as decimal strings (the badge has 32-bit ints).
local M = {}

local B64 = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
local DEC = {}
for i = 1, 64 do DEC[B64:byte(i)] = i - 1 end

function M.unbase64(s)
  if type(s) ~= "string" then return nil end
  s = s:gsub("=+$", "")
  if s:find("[^%w%+/]") then return nil end
  local out, n = {}, #s
  for i = 1, n - 3, 4 do
    local a, b, c, d = DEC[s:byte(i)], DEC[s:byte(i + 1)], DEC[s:byte(i + 2)], DEC[s:byte(i + 3)]
    local v = ((a * 64 + b) * 64 + c) * 64 + d
    out[#out + 1] = string.char(v >> 16, (v >> 8) & 255, v & 255)
  end
  local r = n % 4
  if r == 1 then return nil end
  if r > 0 then
    local i = n - r + 1
    local a, b = DEC[s:byte(i)], DEC[s:byte(i + 1)]
    local c = r == 3 and DEC[s:byte(i + 2)] or 0
    local v = ((a * 64 + b) * 64 + c) * 64
    out[#out + 1] = string.char(v >> 16)
    if r == 3 then out[#out + 1] = string.char((v >> 8) & 255) end
  end
  return table.concat(out)
end

function M.hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end

function M.unhex(h) return (h:gsub("%x%x", function(x) return string.char(tonumber(x, 16)) end)) end

-- 8 little-endian bytes -> decimal string.
function M.u64(b, at)
  local d = {0}  -- little-endian decimal digits
  for i = at + 7, at, -1 do
    local carry = b:byte(i)
    for k = 1, #d do
      local v = d[k] * 256 + carry
      d[k] = v % 10
      carry = v // 10
    end
    while carry > 0 do d[#d + 1] = carry % 10; carry = carry // 10 end
  end
  local s = {}
  for k = #d, 1, -1 do s[#s + 1] = d[k] end
  return (table.concat(s):gsub("^0+(%d)", "%1"))
end

-- Decimal string (<= 20 digits, < 2^64) -> 8 little-endian bytes, or nil.
function M.pack_u64(s)
  if type(s) ~= "string" or not s:find("^%d+$") or #s > 20 then return nil end
  local d = {}
  for i = 1, #s do d[i] = s:byte(i) - 48 end
  local out = {}
  for _ = 1, 8 do
    local rem = 0
    for k = 1, #d do
      local v = rem * 10 + d[k]
      d[k] = v // 256
      rem = v % 256
    end
    out[#out + 1] = string.char(rem)
  end
  for k = 1, #d do if d[k] ~= 0 then return nil end end  -- >= 2^64
  return table.concat(out)
end

-- Small unsigned ints (fit 31 bits).
function M.u8(b, at) return b:byte(at) end
function M.i32(b, at) return (string.unpack("<i4", b, at)) end

-- i64 time: the low 4 bytes as a signed int (good until 2038, the badge has 32-bit ints).
function M.time(b, at) return (string.unpack("<i4", b, at)) end

-- Fixed byte array text: up to the first zero byte.
function M.text(b, at, n)
  local s = b:sub(at, at + n - 1)
  local z = s:find("\0", 1, true)
  if z then s = s:sub(1, z - 1) end
  return (s:gsub("[%z\1-\31\127]", ""))
end

-- Text into a fixed zero-padded array of n bytes.
function M.fixed(s, n)
  s = s:sub(1, n)
  return s .. string.rep("\0", n - #s)
end

return M
