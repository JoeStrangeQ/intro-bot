-- lib/feed.lua: checks the /api/badge/:wallet answer, and makes demo data.
-- Answer: {v, j, e, q:[{i, t, g, b, s}], n}; lamports are digit strings.
local sol = require("lib.sol")

local M = {}

M.MAX_ROWS = 5

local function text(s, n)
  if type(s) == "number" then s = tostring(s) end
  if type(s) ~= "string" then return "" end
  s = s:gsub("[%z\1-\31\127]", "")
  if #s > n then s = s:sub(1, n):gsub("[\192-\255][\128-\191]*$", "") .. ".." end
  return s
end

-- A clean copy of a decoded answer, or nil and why.
function M.check(t)
  local j = type(t) == "table" and math.tointeger(tonumber(t.j))
  if not j or j < 0 then return nil, "bad answer" end
  local d = {
    v = sol.digits(t.v) or "0",
    e = sol.digits(t.e) or "0",
    n = sol.digits(t.n) or "0",
    j = j,
    q = {},
  }
  if type(t.q) == "table" then
    for k = 1, M.MAX_ROWS do
      local r = t.q[k]
      if type(r) ~= "table" then break end
      local id = (type(r.i) == "string" or math.type(r.i) == "integer") and tostring(r.i) or ""
      if #id <= 64 and id:find("^[%w%-_]+$") then
        local tg = text(r.g, 32)
        if tg ~= "" and tg:sub(1, 1) ~= "@" then tg = "@" .. tg end
        d.q[#d.q + 1] = {
          i = id, t = text(r.t, 40), g = tg,
          b = sol.digits(r.b) or "0", s = text(r.s, 12):lower(),
        }
      end
    end
  end
  return d
end

function M.parse(body)
  if type(body) ~= "string" or body == "" then return nil, "empty answer" end
  local t = json.decode(body)
  if not t then return nil, "bad answer" end
  return M.check(t)
end

-- Demo mode ----------------------------------------------------------------

local NAMES = {
  {"Mert @ Helius", "@mert"}, {"Anza core dev", "@sol_dev"}, {"Jupiter BD", "@jup_bd"},
  {"Breakpoint MC", "@bp_mc"}, {"Phantom PM", "@ph_pm"}, {"Superteam lead", "@st_lead"},
}

function M.mock_new()
  return {
    v = "1250000000", e = "1560000000", j = 3, n = "50000000", step = 0, next_id = 4,
    q = {
      {i = "demo1", t = NAMES[1][1], g = NAMES[1][2], b = "200000000", s = "open"},
      {i = "demo2", t = NAMES[2][1], g = NAMES[2][2], b = "120000000", s = "active"},
      {i = "demo3", t = NAMES[3][1], g = NAMES[3][2], b = "80000000", s = "open"},
    },
  }
end

-- Move the demo along one poll and return a checked copy.
function M.mock_step(m)
  m.step = m.step + 1
  m.v = sol.add(m.v, tostring(math.random(0, 25) * 1000000))
  if m.step % 5 == 0 and #m.q > 0 then
    local done = table.remove(m.q, 1)
    m.j = m.j + 1
    m.e = sol.add(m.e, done.b)
    m.v = sol.add(m.v, done.b)
  end
  if m.step % 3 == 0 and #m.q < M.MAX_ROWS then
    local nm = NAMES[m.next_id % #NAMES + 1]
    m.q[#m.q + 1] = {i = "demo" .. m.next_id, t = nm[1], g = nm[2],
      b = tostring(math.random(5, 40) * 10000000), s = "open"}
    m.next_id = m.next_id + 1
  end
  return M.check(m)
end

return M
