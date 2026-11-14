-- lib/art.lua: BotBot's rainbow "B" (botbot-brand glyphs.py): 12x12 cells in 6 bands of
-- 2 rows, green to blue, with a 1px black drop shadow at +1,+1. Drawn as pixel art.
local M = {}

local B = {
  "##########..",
  "###########.",
  "###......###",
  "###......###",
  "###########.",
  "##########..",
  "###......###",
  "###......###",
  "###......###",
  "###......###",
  "###########.",
  "##########..",
}
M.RAINBOW = {0x61BB46, 0xFDB827, 0xF5821F, 0xE03A3E, 0x963D97, 0x009DDC}
local BAND = {"A", "C", "D", "E", "F", "G"}  -- palette letters, top to bottom

-- 13x13 rows: band letters where filled, K for the shadow, "." see-through.
local function rows()
  local out = {}
  for y = 1, 13 do
    local r = {}
    for x = 1, 13 do
      local filled = B[y] and B[y]:sub(x, x) == "#"
      local shade = B[y - 1] and B[y - 1]:sub(x - 1, x - 1) == "#"
      r[x] = filled and BAND[(y - 1) // 2 + 1] or (shade and "K" or ".")
    end
    out[y] = table.concat(r)
  end
  return out
end
M.ROWS = rows()

-- The colours, with the bands turned by `shift` (for the receipt animation).
function M.palette(shift)
  local p = {K = 0x000000}
  for k = 1, 6 do p[BAND[k]] = M.RAINBOW[(k - 1 + (shift or 0)) % 6 + 1] end
  return p
end

-- The logo at x, y (13 x scale px a side), or nothing on badges without images.
function M.logo(x, y, scale, shift)
  if not ui.image then return nil end
  return ui.image(x, y, M.ROWS, {scale = scale, palette = M.palette(shift)})
end

return M
