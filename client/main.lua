-- gs_antidupe/client/main.lua

local DEBUG = false

local function dbg(...)
  if not DEBUG then return end
  print(('[GS_AntiDupe:CL] %s'):format(table.concat({...}, ' ')))
end

-- Optional: expose tiny helpers for other resources that want to request tokens directly
exports('GetActionToken', function(action, garageId)
  local tok = lib.callback.await('gs_antidupe:getToken', false, action, tostring(garageId or ''))
  dbg('GetActionToken', action, garageId, tok and '<token>' or 'nil')
  return tok
end)
