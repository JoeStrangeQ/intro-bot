-- Test-side helpers shared by sim.lua and e2e.lua: JSON, base58, base64, hex, and
-- program-derived addresses (pda.py stands in for the badge's solana.pda).
local HERE = ...
local M = {}

-- Minimal JSON (enough for the API answers and to size storage) ------------
local json = {}
do
  local function enc(v)
    local t = type(v)
    if t == "table" then
      if #v > 0 or next(v) == nil then
        local o = {}
        for i = 1, #v do o[i] = enc(v[i]) end
        return "[" .. table.concat(o, ",") .. "]"
      end
      local o = {}
      for k, x in pairs(v) do o[#o + 1] = enc(tostring(k)) .. ":" .. enc(x) end
      return "{" .. table.concat(o, ",") .. "}"
    elseif t == "string" then return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", c:byte()) end) .. '"'
    else return tostring(v) end
  end
  json.encode = enc
  function json.decode_lua(s)
    local i = 1
    local function ws() i = s:find("[^ \t\r\n]", i) or #s + 1 end
    local val
    local function str()
      local j, out = i + 1, {}
      while true do
        local c = s:sub(j, j)
        if c == "" then error("eof") end
        if c == '"' then i = j + 1; return table.concat(out) end
        if c == "\\" then
          local e = s:sub(j + 1, j + 1)
          if e == "u" then out[#out + 1] = utf8.char(tonumber(s:sub(j + 2, j + 5), 16)); j = j + 6
          else out[#out + 1] = ({n = "\n", t = "\t", r = "\r", b = "\b", f = "\f"})[e] or e; j = j + 2 end
        else out[#out + 1] = c; j = j + 1 end
      end
    end
    function val()
      ws()
      local c = s:sub(i, i)
      if c == "{" then
        local t = {}; i = i + 1; ws()
        if s:sub(i, i) == "}" then i = i + 1 return t end
        while true do
          ws(); local k = str(); ws(); assert(s:sub(i, i) == ":"); i = i + 1
          t[k] = val(); ws()
          local d = s:sub(i, i); i = i + 1
          if d == "}" then return t end
          assert(d == ",")
        end
      elseif c == "[" then
        local t = {}; i = i + 1; ws()
        if s:sub(i, i) == "]" then i = i + 1 return t end
        while true do
          t[#t + 1] = val(); ws()
          local d = s:sub(i, i); i = i + 1
          if d == "]" then return t end
          assert(d == ",")
        end
      elseif c == '"' then return str()
      elseif s:sub(i, i + 3) == "true" then i = i + 4 return true
      elseif s:sub(i, i + 4) == "false" then i = i + 5 return false
      elseif s:sub(i, i + 3) == "null" then i = i + 4 return nil
      else
        local n = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
        if not n or n == "" then error("bad json") end
        i = i + #n
        return math.tointeger(tonumber(n)) or tonumber(n)
      end
    end
    local ok, r = pcall(val)
    if not ok then return nil, r end
    return r
  end
end


-- base58 (test side) ---------------------------------------------------------
local B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz"
local function b58d(s)
  local b = {}
  for i = 1, #s do
    local p = B58:find(s:sub(i, i), 1, true)
    if not p then return nil, "not base58" end
    local carry = p - 1
    for j = 1, #b do carry = carry + b[j] * 58; b[j] = carry & 0xFF; carry = carry >> 8 end
    while carry > 0 do b[#b + 1] = carry & 0xFF; carry = carry >> 8 end
  end
  for i = 1, #s do if s:sub(i, i) ~= "1" then break end b[#b + 1] = 0 end
  local out = {}
  for i = #b, 1, -1 do out[#out + 1] = string.char(b[i]) end
  return table.concat(out)
end
local function b58e(bytes)
  local d = {}
  for i = 1, #bytes do
    local carry = bytes:byte(i)
    for j = 1, #d do carry = carry + d[j] * 256; d[j] = carry % 58; carry = carry // 58 end
    while carry > 0 do d[#d + 1] = carry % 58; carry = carry // 58 end
  end
  local out = {}
  for i = 1, #bytes do if bytes:byte(i) ~= 0 then break end out[#out + 1] = "1" end
  for i = #d, 1, -1 do out[#out + 1] = B58:sub(d[i] + 1, d[i] + 1) end
  return table.concat(out)
end
local function hex(s) return (s:gsub(".", function(c) return string.format("%02x", c:byte()) end)) end
local function b64(s)
  local A = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
  return ((s:gsub(".", function(x)
    local r, b = "", x:byte()
    for i = 8, 1, -1 do r = r .. (b % 2 ^ i - b % 2 ^ (i - 1) > 0 and "1" or "0") end
    return r
  end) .. "0000"):gsub("%d%d%d?%d?%d?%d?", function(x)
    if #x < 6 then return "" end
    local c = 0
    for i = 1, 6 do c = c + (x:sub(i, i) == "1" and 2 ^ (6 - i) or 0) end
    return A:sub(c + 1, c + 1)
  end) .. ({"", "==", "="})[#s % 3 + 1])
end


local pda_cache = {}
-- cost(bump) is told the bump found, so callers can charge the badge's price.
function M.pda(seeds, program, cost)
  local args = {}
  for _, s in ipairs(seeds) do
    assert(type(s) == "string" and #s <= 32, "pda seed <= 32 bytes")
    args[#args + 1] = hex(s)
  end
  assert(#program == 32 and #seeds <= 15, "pda args")
  local key = b58e(program) .. " " .. table.concat(args, " ")
  if not pda_cache[key] then
    local p = io.popen("python3 " .. HERE .. "/pda.py " .. key)
    local out = p:read("a")
    p:close()
    local a, bump = out:match("(%w+) (%d+)")
    pda_cache[key] = {b58d(a), tonumber(bump)}
  end
  local r = pda_cache[key]
  if cost then cost(r[2]) end
  return r[1], r[2]
end

function M.sha256(s)
  local p = io.popen("printf '%s' '" .. s .. "' | shasum -a 256")
  local out = p:read("a")
  p:close()
  return out:sub(1, 64)
end

M.json, M.b58e, M.b58d, M.hex, M.b64 = json, b58e, b58d, hex, b64
return M
