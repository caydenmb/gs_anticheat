-- gs_antidupe/server/main.lua

local cfg = GS_ANTIDUPE or {}
local DB  = (cfg.DB and cfg.DB.Enabled) and require 'server.db' or nil

-- Optional ESX handle (not strictly needed)
local ESX = (exports.es_extended and exports.es_extended.getSharedObject)
  and exports.es_extended:getSharedObject() or nil

-- ================
-- Utilities / Logs
-- ================
local function dbg(...)
  if not cfg.DEBUG then return end
  print(('[GS_AntiDupe] %s'):format(table.concat({...}, ' ')))
end

local function reaper(src, code, details)
  if not (cfg.Reaper and cfg.Reaper.Enabled) then return end
  if cfg.Reaper.EventName then
    local ok = pcall(TriggerEvent, cfg.Reaper.EventName, src, code, details)
    if ok then return end
  end
  if cfg.Reaper.ExportResource and cfg.Reaper.ExportMethod then
    pcall(function() exports[cfg.Reaper.ExportResource][cfg.Reaper.ExportMethod](src, code, details) end)
  end
end

-- ============================
-- Live Convar Poll (very light)
-- ============================
CreateThread(function()
  while true do
    Wait(cfg.Ticks.ConvarPollMs or 5000)
    cfg.DEBUG = (GetConvarInt('gs_antidupe_debug', cfg.DEBUG and 1 or 0) == 1)

    local ttl = GetConvarInt('gs_antidupe_token_ttl', cfg.TokenTTLSeconds or 20)
    if ttl > 0 then cfg.TokenTTLSeconds = ttl end

    local rs = GetConvarInt('gs_antidupe_rate_store', cfg.RateLimit.StorePerMin or 6)
    if rs > 0 then cfg.RateLimit.StorePerMin = rs end

    local rr = GetConvarInt('gs_antidupe_rate_retrieve', cfg.RateLimit.RetrievePerMin or 6)
    if rr > 0 then cfg.RateLimit.RetrievePerMin = rr end

    -- Tick tuning (ms)
    local baseMs = GetConvarInt('gs_antidupe_tick_base', cfg.Ticks.BaseIntervalMs or 10000)
    local nearMs = GetConvarInt('gs_antidupe_tick_near', cfg.Ticks.NearWindowIntervalMs or 1000)
    local nearS  = GetConvarInt('gs_antidupe_tick_near_secs', cfg.Ticks.NearWindowSeconds or 120)
    if baseMs >= 500 then cfg.Ticks.BaseIntervalMs = baseMs end
    if nearMs >= 100 then cfg.Ticks.NearWindowIntervalMs = nearMs end
    if nearS >= 10 then cfg.Ticks.NearWindowSeconds = nearS end
  end
end)

-- ======================
-- Time / DST Calculations
-- ======================
local function parseHHMM(s)
  local h, m = s:match('^(%d%d?):(%d%d)$')
  h = tonumber(h or 0); m = tonumber(m or 0)
  if h < 0 or h > 23 then h = 0 end
  if m < 0 or m > 59 then m = 0 end
  return h * 3600 + m * 60
end

local function nowUTC()
  return os.time(os.date("!*t"))
end

-- 0=Sunday..6=Saturday (Gregorian)
local function weekday_gregorian(y, m, d)
  if m < 3 then m = m + 12; y = y - 1 end
  local K = y % 100
  local J = math.floor(y / 100)
  local h = (d + math.floor((13*(m + 1))/5) + K + math.floor(K/4) + math.floor(J/4) + (5*J)) % 7
  return (h + 6) % 7
end

local function nth_weekday_of_month(y, m, weekday, n)
  local first_wd = weekday_gregorian(y, m, 1)
  local delta = (weekday - first_wd + 7) % 7
  return 1 + delta + 7 * (n - 1)
end

-- US Pacific DST detection (second Sun in Mar, first Sun in Nov)
local function pacific_is_dst(utc_ts)
  local t = os.date("!*t", utc_ts - 8*3600) -- PST frame
  local y, mon, day, hour = t.year, t.month, t.day, t.hour
  local march_second_sun = nth_weekday_of_month(y, 3, 0, 2)
  local nov_first_sun    = nth_weekday_of_month(y, 11, 0, 1)

  if mon < 3 then return false end
  if mon > 11 then return false end
  if mon > 3 and mon < 11 then return true end

  if mon == 3 then
    if day > march_second_sun then return true end
    if day < march_second_sun then return false end
    return hour >= 2
  end
  if mon == 11 then
    if day < nov_first_sun then return true end
    if day > nov_first_sun then return false end
    return hour < 2
  end
  return false
end

local function pacific_offset_hours(utc_ts)
  local forced = GetConvarInt('gs_antidupe_pacific_force', 999)
  if forced == -7 or forced == -8 then return forced end
  return pacific_is_dst(utc_ts) and -7 or -8
end

local function secondsSinceMidnightPacific(utc_ts)
  local offset = pacific_offset_hours(utc_ts)
  local ts = utc_ts + (offset * 3600)
  local t = os.date("!*t", ts)
  return t.hour*3600 + t.min*60 + t.sec, offset
end

-- ===============================================
-- Restart Freeze: window check + smart sleep logic
-- ===============================================
local FREEZE = false

-- Returns true if within a freeze window; also returns seconds until next boundary (enter/exit)
local function windowStateAndNextDelta(utcTimestamp)
  -- Manual override takes precedence
  local manual = GetConvarInt(cfg.RestartFreeze.ConvarName or 'gs_antidupe_freeze', -1)
  if manual == 1 then return true, 10 end
  if manual == 0 then return false, 10 end

  if not (cfg.RestartFreeze.Automatic and cfg.RestartFreeze.Automatic.Enabled) then
    -- Optional fallback timer (rarely used)
    if cfg.RestartFreeze.FallbackTimer and cfg.RestartFreeze.FallbackTimer.Enabled then
      local uptime = GetGameTimer() / 1000
      local inWin = (uptime % 3600 >= (3600 - (cfg.RestartFreeze.FallbackTimer.SecondsLeft or 60)))
      return inWin, 10
    end
    return false, 30
  end

  local pre  = GetConvarInt('gs_antidupe_freeze_pre',  cfg.RestartFreeze.Automatic.WindowSecondsBefore or 30)
  local post = GetConvarInt('gs_antidupe_freeze_post', cfg.RestartFreeze.Automatic.WindowSecondsAfter  or 0)
  local ssm  = secondsSinceMidnightPacific(utcTimestamp)  -- seconds since midnight Pacific
  local day  = 24*3600

  -- Build today's window edges (in seconds since midnight)
  local edges = {}
  for _, hhmm in ipairs(cfg.RestartFreeze.Automatic.Times or {}) do
    local t = parseHHMM(hhmm)
    table.insert(edges, { start = (t - pre), stop = (t + post) })
  end

  -- Normalize edges to [0, day) with wrap handling
  local inWindow = false
  local nextDelta = math.huge

  local function forward_delta(a, b)  -- seconds forward from a to b on a circular day
    local d = (b - a) % day
    if d < 0 then d = d + day end
    return d
  end

  for _, w in ipairs(edges) do
    local lo = w.start
    local hi = w.stop

    if lo < 0 then
      -- window: [lo+day, day) U [0, hi]
      if (ssm >= (lo + day) and ssm < day) or (ssm >= 0 and ssm <= hi) then
        inWindow = true
        nextDelta = math.min(nextDelta, forward_delta(ssm, (hi % day)))
      else
        -- time until entering either segment
        local d1 = forward_delta(ssm, (lo + day) % day)
        local d2 = forward_delta(ssm, hi % day)
        nextDelta = math.min(nextDelta, d1, d2)
      end
    elseif hi >= day then
      -- window: [lo, day) U [0, hi-day]
      local hi2 = hi - day
      if (ssm >= lo and ssm < day) or (ssm >= 0 and ssm <= hi2) then
        inWindow = true
        nextDelta = math.min(nextDelta, forward_delta(ssm, hi2))
      else
        local d1 = forward_delta(ssm, lo)
        local d2 = forward_delta(ssm, hi2)
        nextDelta = math.min(nextDelta, d1, d2)
      end
    else
      -- window: [lo, hi]
      if ssm >= lo and ssm <= hi then
        inWindow = true
        nextDelta = math.min(nextDelta, forward_delta(ssm, hi))
      else
        nextDelta = math.min(nextDelta, forward_delta(ssm, lo))
      end
    end
  end

  if nextDelta == math.huge then nextDelta = 30 end
  return inWindow, nextDelta
end

-- Freeze state loop with smart sleeping:
--  • Sleeps long (BaseIntervalMs) far from windows.
--  • Sleeps short (NearWindowIntervalMs) when next boundary is near.
CreateThread(function()
  while true do
    local utc = nowUTC()
    local inWin, nextDelta = windowStateAndNextDelta(utc)
    FREEZE = inWin

    -- choose dynamic sleep
    local baseMs = cfg.Ticks.BaseIntervalMs or 10000
    local nearMs = cfg.Ticks.NearWindowIntervalMs or 1000
    local nearS  = cfg.Ticks.NearWindowSeconds or 120

    local sleepMs
    if nextDelta <= nearS then
      sleepMs = nearMs
    else
      -- if the next boundary is far, we can sleep min(nextDelta/2, base)
      -- but keep it simple: stick to baseMs to remain predictable & light.
      sleepMs = baseMs
    end

    Wait(math.max(100, math.floor(sleepMs)))
  end
end)

-- =========================
-- Tokens & Rate-limits
-- =========================
local tokens = {} -- [src] = { ["action|garageId"]= {token=..., exp=...} }
local rl = { store = {}, retrieve = {} }

local function makeToken(len)
  local t = {}
  for i=1,(len or 28) do t[i] = string.char(math.random(48, 122)) end
  return table.concat(t)
end

local function saveToken(src, action, garageId)
  local s = tokens[src]; if not s then s = {}; tokens[src] = s end
  local key = action .. '|' .. garageId
  local tok = makeToken(28)
  local exp = os.time() + (cfg.TokenTTLSeconds or 20)
  s[key] = { token = tok, exp = exp }
  return tok
end

local function useToken(src, action, garageId, provided)
  local s = tokens[src]; if not s then return false, 'no_token' end
  local t = s[action .. '|' .. garageId]; if not t then return false, 'no_token' end
  if os.time() > t.exp then s[action .. '|' .. garageId] = nil; return false, 'expired' end
  if provided ~= t.token then return false, 'mismatch' end
  s[action .. '|' .. garageId] = nil
  return true
end

local function allowRate(bucket, src, limitPerMin)
  local now = GetGameTimer()
  local r = bucket[src]
  if not r or now - r.t > 60000 then
    r = { t = now, n = 0 }; bucket[src] = r
  end
  r.n = r.n + 1
  return r.n <= limitPerMin
end

-- =========================
-- ox_inventory closures
-- =========================
local function closeStashesForPlate(src, plate)
  if GetResourceState('ox_inventory') ~= 'started' then
    dbg('ox_inventory not started; skip closures'); return true
  end
  if cfg.Inventory.ClosePlayerInventory then
    pcall(function() exports.ox_inventory:closeInventory(src) end)
  end
  if cfg.Inventory.CloseVehicleStashes and plate and plate ~= '' then
    local trunk = (cfg.Inventory.TrunkPrefix or 'trunk:') .. plate
    local box   = (cfg.Inventory.GloveboxPrefix or 'glovebox:') .. plate
    pcall(function() exports.ox_inventory:forceCloseInventory(trunk) end)
    pcall(function() exports.ox_inventory:forceCloseInventory(box) end)
  end
  return true
end

-- =========================
-- Garage coords & proximity
-- =========================
local cache = {} -- garageId -> {x,y,z,exp}
local function getGarageCoords(garageId)
  if not (cfg.JG and cfg.JG.UseExportsForCoords) then return false end
  local c = cache[garageId]
  local now = GetGameTimer()
  if c and c.exp > now then return c end

  local ok, coords = pcall(function()
    return exports[cfg.JG.ExportName][cfg.JG.ExportMethod](garageId)
  end)
  if not ok or not coords then return false end

  local res
  if type(coords) == 'vector4' then res = { x=coords.x, y=coords.y, z=coords.z }
  elseif type(coords) == 'vector3' then res = { x=coords.x, y=coords.y, z=coords.z }
  elseif type(coords) == 'table' and coords.x then res = coords end

  if not res then return false end
  res.exp = now + (1000 * (cfg.JG.CacheSeconds or 5))
  cache[garageId] = res
  return res
end

local function nearGarage(src, garageId, maxDist)
  local ped = GetPlayerPed(src)
  if ped <= 0 then return false, -1 end
  local p = GetEntityCoords(ped)
  local gc = getGarageCoords(garageId)
  if not gc then return true, 0.0 end -- still safe; other guards apply
  local dist = #(p - vector3(gc.x, gc.y, gc.z))
  return dist <= (maxDist or cfg.MaxActionDistance or 14.0), dist
end

-- =========================
-- Minimal ownership sanity
-- =========================
local function ownsPlate(_src, plate)
  if not cfg.EnforceOwnershipByPlate then return true end
  return (plate and plate ~= '')
end
local function up(s) return s and s:upper() or '' end

-- =========================
-- Public callbacks
-- =========================
lib.callback.register('gs_antidupe:getToken', function(src, action, garageId)
  if cfg.RestartFreeze.Enabled and FREEZE then
    TriggerClientEvent('ox_lib:notify', src, { title='Garages', description='Temporarily unavailable (restart window).', type='warning' })
    reaper(src, 'GARAGE_FREEZE', ('action=' .. tostring(action) .. ' garage=' .. tostring(garageId)))
    return false
  end
  local tok = saveToken(src, tostring(action or ''), tostring(garageId or ''))
  dbg('mint token', src, action or 'nil', garageId or 'nil', tok)
  return tok
end)

-- data = { garageId, plate, token, fuel?, body?, engine?, damage? }
lib.callback.register('gs_antidupe:verifyStore', function(src, data)
  if cfg.RestartFreeze.Enabled and FREEZE then
    TriggerClientEvent('ox_lib:notify', src, { title='Garages', description='Temporarily unavailable (restart window).', type='warning' })
    reaper(src, 'GARAGE_FREEZE', 'store'); return false, 'restart_freeze'
  end

  if not allowRate(rl.store, src, cfg.RateLimit.StorePerMin or 6) then
    reaper(src, 'GARAGE_STORE_RL', 'rate_limit'); return false, 'rate_limit'
  end

  local okTok, why = useToken(src, 'store', tostring(data.garageId or ''), data.token or '')
  if not okTok then
    reaper(src, 'GARAGE_STORE_TOKEN', why or 'invalid'); return false, 'token_' .. (why or 'invalid')
  end

  local near, dist = nearGarage(src, data.garageId, cfg.MaxActionDistance)
  if not near then
    reaper(src, 'GARAGE_STORE_RANGE', ('dist=' .. string.format('%.2f', dist or -1))); return false, 'range'
  end

  if cfg.RequireDriverSeat or cfg.RequireEngineOff then
    local ped = GetPlayerPed(src)
    local veh = GetVehiclePedIsIn(ped, false)
    if cfg.RequireDriverSeat and (veh == 0 or GetPedInVehicleSeat(veh, -1) ~= ped) then
      reaper(src, 'GARAGE_STORE_SEAT', 'not_driver'); return false, 'driver'
    end
    if cfg.RequireEngineOff and veh ~= 0 and GetIsVehicleEngineRunning(veh) then
      reaper(src, 'GARAGE_STORE_ENGINE', 'engine_on'); return false, 'engine'
    end
    if veh ~= 0 then
      local d = #(GetEntityCoords(ped) - GetEntityCoords(veh))
      if d > (cfg.MaxPedToVehicleDist or 7.5) then
        reaper(src, 'GARAGE_STORE_PEDVEH', ('dist=' .. string.format('%.2f', d))); return false, 'pedveh'
      end
    end
  end

  local plate = up(data.plate)
  if not ownsPlate(src, plate) then
    reaper(src, 'GARAGE_STORE_OWNER', 'plate_not_owned'); return false, 'owner'
  end

  -- Close inventories BEFORE DB/state changes
  closeStashesForPlate(src, plate)

  -- DB atomic flip to in_garage=1 (only if it was out)
  if DB and cfg.DB.UseAtomicUpdate then
    local ok = DB.AtomicSetInGarageOnStore(plate, data.garageId, data.fuel, data.body, data.engine, data.damage)
    if not ok then
      reaper(src, 'GARAGE_STORE_DB_ATOMIC_FAIL', plate); return false, 'db_atomic'
    end
  end

  return true
end)

-- data = { garageId, plate, token }
lib.callback.register('gs_antidupe:verifyTakeout', function(src, data)
  if cfg.RestartFreeze.Enabled and FREEZE then
    TriggerClientEvent('ox_lib:notify', src, { title='Garages', description='Temporarily unavailable (restart window).', type='warning' })
    reaper(src, 'GARAGE_FREEZE', 'retrieve'); return false, 'restart_freeze'
  end

  if not allowRate(rl.retrieve, src, cfg.RateLimit.RetrievePerMin or 6) then
    reaper(src, 'GARAGE_RET_RL', 'rate_limit'); return false, 'rate_limit'
  end

  local okTok, why = useToken(src, 'retrieve', tostring(data.garageId or ''), data.token or '')
  if not okTok then
    reaper(src, 'GARAGE_RET_TOKEN', why or 'invalid'); return false, 'token_' .. (why or 'invalid')
  end

  local near, dist = nearGarage(src, data.garageId, cfg.MaxActionDistance)
  if not near then
    reaper(src, 'GARAGE_RET_RANGE', ('dist=' .. string.format('%.2f', dist or -1))); return false, 'range'
  end

  local plate = up(data.plate)
  if not ownsPlate(src, plate) then
    reaper(src, 'GARAGE_RET_OWNER', 'plate_not_owned'); return false, 'owner'
  end

  -- Close stale stashes BEFORE spawning a fresh entity
  closeStashesForPlate(src, plate)

  -- DB atomic flip to in_garage=0 (only if it was in)
  if DB and cfg.DB.UseAtomicUpdate then
    local ok = DB.AtomicSetOutOnTakeout(plate)
    if not ok then
      reaper(src, 'GARAGE_RET_DB_ATOMIC_FAIL', plate); return false, 'db_atomic'
    end
  end

  return true
end)
