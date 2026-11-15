-- lib/api.lua: talks to the Intro Bot server (relay.botbotcap.com). The badge server signs
-- each request with the badge and its owner, so the app sends no ids or keys.
local M = {}

M.BASE = "https://relay.botbotcap.com/api"

-- cb(true, table) on a 200, else cb(false, "why").
local function answer(cb)
  return function(ok, res)
    if not ok then return cb(false, tostring(res)) end
    local data = res.body and json.decode(res.body)
    if res.status == 200 and type(data) == "table" then return cb(true, data) end
    cb(false, type(data) == "table" and data.error or ("server said " .. tostring(res.status)))
  end
end

function M.get(path, cb) http.get(M.BASE .. path, answer(cb)) end
function M.post(path, body, cb) http.post(M.BASE .. path, body or {}, answer(cb)) end

return M
