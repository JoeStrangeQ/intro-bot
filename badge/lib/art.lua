-- lib/art.lua: the BotBot robot glyph (16x16, from BotGlyph.tsx) as pixel art.
local M = {}

M.robot = {
  "",
  "",
  ".......AA",
  "......AAAA",
  "..BBBBBBBBBBBB",
  "..BBBBBBBBBBBBK",
  "..CCCKKCCKKCCCK",
  "..CCCK.CCK.CCCK",
  "..DDDDDDDDDDDDK",
  "..DDDDDDDDDDDDK",
  "..EEEKKKKKKEEEK",
  "..EEEE....EEEEK",
  "..FFFFFFFFFFFFK",
  "..FFFFFFFFFFFFK",
  "...KKKKKKKKKKKK",
}

-- Lavender bands, light to dark, with an ink shadow.
M.palette = {
  A = 0xE4DEFA, B = 0xC9BFF2, C = 0xA897EA, D = 0x8A73E0, E = 0x6A50D8, F = 0x4B37A6,
  K = 0x241A52,
}

-- Draw the robot (or nothing on badges without images).
function M.robot_at(x, y, scale)
  if not ui.image then return nil end
  return ui.image(x, y, M.robot, {scale = scale, palette = M.palette})
end

return M
