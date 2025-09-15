-- gs_antidupe/server/db.lua

local C   = GS_ANTIDUPE.DB
local col = C and C.Columns or {}

local function dbg(...)
  if not GS_ANTIDUPE.DEBUG then return end
  print(('[GS_AntiDupe:DB] %s'):format(table.concat({...}, ' ')))
end

local function trim(s) return s and s:match('^%s*(.-)%s*$') or s end
local function normalizePlate(plate)
  if not plate then return nil end
  plate = trim(plate)
  return plate and plate:upper() or nil
end

local DB = {}

function DB.IsVehicleOut(plate)
  if not C.Enabled then return false end
  plate = normalizePlate(plate)
  if not plate then return false end

  local q = ("SELECT `%s` FROM `%s` WHERE `%s` = ? LIMIT 1")
    :format(col.inGarage, C.VehiclesTable, col.plate)

  local row = MySQL.single.await(q, { plate })
  if not row then return false end
  return (tonumber(row[col.inGarage]) == 0)
end

-- Flip to "in garage" on STORE (only if it was out)
function DB.AtomicSetInGarageOnStore(plate, garageId, fuel, body, engine, damage)
  if not (C.Enabled and C.UseAtomicUpdate) then return true end
  plate = normalizePlate(plate)
  if not plate then return false end

  local q = ("UPDATE `%s` SET `%s` = 1, `%s` = ?, `%s` = ?, `%s` = ?, `%s` = ?, `%s` = ? WHERE `%s` = ? AND `%s` = 0")
    :format(C.VehiclesTable, col.inGarage, col.garageId, col.fuel, col.body, col.engine, col.damage, col.plate, col.inGarage)

  local res = MySQL.update.await(q, { tostring(garageId or ''), fuel or 0, body or 1000, engine or 1000, damage or '[]', plate })
  dbg('AtomicSetInGarageOnStore', plate, 'affected=', res or 0)
  return (res and res > 0)
end

-- Flip to "out" on TAKEOUT (only if it was in)
function DB.AtomicSetOutOnTakeout(plate)
  if not (C.Enabled and C.UseAtomicUpdate) then return true end
  plate = normalizePlate(plate)
  if not plate then return false end

  local q = ("UPDATE `%s` SET `%s` = 0 WHERE `%s` = ? AND `%s` = 1")
    :format(C.VehiclesTable, col.inGarage, col.plate, col.inGarage)

  local res = MySQL.update.await(q, { plate })
  dbg('AtomicSetOutOnTakeout', plate, 'affected=', res or 0)
  return (res and res > 0)
end

return DB
