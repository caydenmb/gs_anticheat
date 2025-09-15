fx_version 'cerulean'
game 'gta5'
lua54 'yes'

name 'gs_antidupe'
author 'Gingr Snaps'
description 'Standalone anti-duplication guard for ESX + jg-advancedgarages + ox_inventory + Reaper'
version '1.1.0'

dependencies {
  'ox_lib',
  'oxmysql',
  'ox_inventory',
  'jg-advancedgarages'
}

shared_scripts {
  '@ox_lib/init.lua',
  'shared/config.lua',
}

server_scripts {
  '@oxmysql/lib/MySQL.lua',
  'server/db.lua',
  'server/main.lua',
}

client_scripts {
  'client/main.lua',
}

-- Start order in server.cfg (recommended):
-- ensure ox_lib
-- ensure oxmysql
-- ensure ox_inventory
-- ensure jg-advancedgarages
-- ensure gs_antidupe
