-- gs_antidupe/shared/config.lua

GS_ANTIDUPE = {
  DEBUG = false,  -- enable with: set gs_antidupe_debug 1

  Reaper = {
    Enabled        = true,
    EventName      = 'Reaper:Flag',   -- TriggerEvent(EventName, src, code, details)
    ExportResource = 'ReaperV4',      -- exports.ReaperV4:Flag(src, code, details)
    ExportMethod   = 'Flag',
  },

  -- Replay + spam control
  TokenTTLSeconds = 20,
  RateLimit = {
    StorePerMin    = 6,               -- ~once every 10s (6/min)
    RetrievePerMin = 6,
  },

  -- Final checks
  MaxActionDistance   = 14.0,
  MaxPedToVehicleDist = 7.5,
  RequireDriverSeat   = true,
  RequireEngineOff    = true,
  EnforceOwnershipByPlate = true,

  -- DB guard (ESX owned_vehicles)
  DB = {
    Enabled              = true,
    ResourceUsesOxMySQL  = true,
    VehiclesTable        = 'owned_vehicles',
    Columns = {
      plate    = 'plate',
      owner    = 'owner',
      vehProps = 'vehicle',
      inGarage = 'in_garage',  -- 0 out, 1 in
      garageId = 'garage_id',
      fuel     = 'fuel',
      body     = 'body',
      engine   = 'engine',
      damage   = 'damage'
    },
    UseAtomicUpdate = true,
  },

  -- ox_inventory closures
  Inventory = {
    ClosePlayerInventory = true,
    CloseVehicleStashes  = true,
    TrunkPrefix          = 'trunk:',
    GloveboxPrefix       = 'glovebox:',
  },

  -- Restart freeze window (Pacific local time)
  RestartFreeze = {
    Enabled    = true,

    -- Manual override (highest priority):
    --   set gs_antidupe_freeze 1/0    -> force ON/OFF
    --   set gs_antidupe_pacific_force -7 (PDT) or -8 (PST) -> force offset (optional)
    ConvarName = 'gs_antidupe_freeze',

    Automatic = {
      Enabled = true,

      -- Daily restart times in Pacific local time
      Times = { '03:00', '09:00', '15:00', '21:00' },

      -- Freeze window lengths (seconds)
      -- You asked for freeze BEFORE restart only; default below matches that.
      WindowSecondsBefore = 30,       -- set gs_antidupe_freeze_pre  <sec>
      WindowSecondsAfter  = 0,        -- set gs_antidupe_freeze_post <sec>
    },

    -- Fallback (unused when Automatic.Enabled = true)
    FallbackTimer = { Enabled = false, SecondsLeft = 60 },
  },

  -- jg-advancedgarages garage coords (optional)
  JG = {
    UseExportsForCoords = true,
    ExportName   = 'jg-advancedgarages',
    ExportMethod = 'getGarageCoords',
    CacheSeconds = 5,
  },

  -- Scheduler/tick tuning (keeps CPU very low; live-tunable with convars)
  Ticks = {
    BaseIntervalMs       = 10000,     -- normal sleep interval (set gs_antidupe_tick_base 10000)
    NearWindowIntervalMs = 1000,      -- when close to a window (set gs_antidupe_tick_near 1000)
    NearWindowSeconds    = 120,       -- how near counts as "near" (set gs_antidupe_tick_near_secs 120)
    ConvarPollMs         = 5000       -- convar poll loop sleep
  }
}
