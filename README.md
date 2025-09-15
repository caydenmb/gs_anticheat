# gs_antidupe

Anti-duplication guard for **jg-advancedgarages** + **ox_inventory** on ESX servers.  
Works with **Reaper anti-cheat** to block common duplication exploits.

## Features
- Closes player inventory, trunk, and glovebox before garage actions  
- One-time tokens & cooldowns (~once every 10s)  
- Atomic database checks (no double spawns)  
- Freeze garage use before scheduled restarts (Pacific time, auto DST)  

## Installation
1. Place `gs_antidupe` in your server resources.  
2. Add to `server.cfg` after `jg-advancedgarages`:  
   ```cfg
   ensure [jg]
   ensure gs_antidupe
````

## Customizable Options

```cfg
# Freeze windows (seconds before/after restart)
set gs_antidupe_freeze_pre 30
set gs_antidupe_freeze_post 0

# Cooldowns (actions per minute)
set gs_antidupe_rate_store 6
set gs_antidupe_rate_retrieve 6

# Scheduler timing (ms / seconds)
set gs_antidupe_tick_base 10000
set gs_antidupe_tick_near 1000
set gs_antidupe_tick_near_secs 120

# Debug (0 = off, 1 = on)
set gs_antidupe_debug 0
```