--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

-- UgPlayer is declared with its methods in core/server/player.lua.

---Hits on the same region with the same category aggregate into one injury.
---@class UgInjury
---@field region UgBodyRegion
---@field category UgDamageCategory
---@field weapon? integer weapon hash of the last hit
---@field attacker? integer player source of the last hit, when confirmed
---@field hits integer
---@field lastAt integer Unix seconds

---@class UgCauseOfDeath
---@field region UgBodyRegion
---@field category UgDamageCategory
---@field weapon? integer
---@field killer? integer player source, only when a recorded weaponDamageEvent confirms it
---@field at integer Unix seconds

---@class UgReviveOptions
---@field by? integer player source who revived
---@field reason? string
---@field health? integer 101 to 200, defaults to 200
---@field clearInjuries? boolean

---@class UgDeathData
---@field state UgDeathState
---@field injuries UgInjury[]
---@field cause? UgCauseOfDeath
