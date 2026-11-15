-- lib/list.lua: a list in BotBot colours, in place of ui.list (whose rows the badge draws in
-- white on our light paper, with a black bar). Black text; the selected row is a brand
-- purple bar with white text. Rows are 36 px; the row objects are made once and reused
-- while scrolling. main.lua sends up/down/select here (M.key); one list per screen.
local M = {}

local ROW = 36
local INK, BAR, ON_BAR = 0x000000, 0x6A50D8, 0xFFFFFF
M.INK, M.BAR = INK, BAR

M.active = nil

-- Cut text that won't fit, by an approximate glyph width.
local function fit(text, px, cw)
  text = tostring(text or "")
  local n = px // cw
  if #text <= n then return text end
  return text:sub(1, math.max(n - 3, 0)) .. "..."
end

local function norm(it)
  if type(it) == "table" then return it end
  return {title = tostring(it)}
end

local List = {}
List.__index = List

function List:draw()
  local n = #self.its
  if self.sel > n then self.sel = math.max(n, 1) end
  if self.sel < self.top then self.top = self.sel end
  if self.sel >= self.top + #self.rows then self.top = self.sel - #self.rows + 1 end
  for k, r in ipairs(self.rows) do
    local i = self.top + k - 1
    local it = i <= n and norm(self.its[i]) or nil
    local on = it ~= nil and i == self.sel
    local fg = on and ON_BAR or INK
    r.bar:show(on)
    local right = it and it.right and tostring(it.right) or ""
    local rw = #right * 7
    r.title:text(it and fit(it.title, self.w - 16 - (rw > 0 and rw + 8 or 0), 8) or "")
    r.sub:text(it and it.sub and fit(it.sub, self.w - 16, 7) or "")
    r.right:text(it and fit(right, self.w // 2, 7) or "")
    r.title:color(fg)
    r.sub:color(fg)
    r.right:color(fg)
  end
end

function List:items(its)
  self.its = its or {}
  self:draw()
end

function List:selected() return self.sel end

function List:select(i)
  self.sel = math.max(1, math.min(i, #self.its))
  self:draw()
end

function List:remove()
  for _, r in ipairs(self.rows) do
    r.bar:remove() r.title:remove() r.sub:remove() r.right:remove()
  end
  self.rows = {}
  if M.active == self then M.active = nil end
end

-- Same arguments as ui.list: items are strings or {title=, sub=, right=}.
function M.new(x, y, w, h, its, opts)
  local o = setmetatable({x = x, y = y, w = w, its = its or {}, sel = 1, top = 1, rows = {},
    on_select = opts and opts.on_select}, List)
  for k = 1, math.max(1, h // ROW) do
    local ry = y + (k - 1) * ROW
    o.rows[k] = {
      bar = ui.rect(x, ry, w, ROW, {color = BAR}),
      title = ui.label(x + 8, ry + 3, "", {size = 14, color = INK}),
      sub = ui.label(x + 8, ry + 21, "", {size = 12, color = INK}),
      right = ui.label(x + w // 2, ry + 10, "", {size = 12, color = INK, w = w // 2 - 8, align = "right"}),
    }
  end
  M.active = o
  o:draw()
  return o
end

-- After ui.clear the objects are gone; forget the list.
function M.reset() M.active = nil end

-- up/down move, select chooses. True when the key was used.
function M.key(key)
  local o = M.active
  if not o or #o.its == 0 then return false end
  if key == "up" then o:select(o.sel - 1) return true end
  if key == "down" then o:select(o.sel + 1) return true end
  if key == "select" then
    if o.on_select then o.on_select(o.sel, o.its[o.sel]) end
    return true
  end
  return false
end

return M
