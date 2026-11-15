--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---`player` is the source of a connected player. `text` takes the rest of the line and MUST be last.
---@alias UgCommandArgumentType 'string'|'integer'|'number'|'boolean'|'player'|'text'

---@class UgCommandArgument
---@field name string
---@field type UgCommandArgumentType
---@field optional? boolean optional arguments MUST be trailing
---@field max? integer maximum characters for string and text, defaults to 64 and 256
---@field help? string

---@class UgCommandOptions
---@field help? string
---@field args? UgCommandArgument[]
---@field permission? string ACE the player MUST have
---@field groups? string[] groups from config/permissions.lua. The player MUST be in at least one, inheritance included. With `permission`, both MUST pass.
---@field rate? UgRateLimitOptions per player, defaults to 3 per 2000 ms
---@field requirePlayer? boolean rejects players whose `ug-core:Loaded` statebag is not true
---@field console? boolean allowed from the server console, defaults to true

---@class UgCommandInfo
---@field name string
---@field help? string
---@field permission? string
---@field groups? string[]
---@field args UgCommandArgument[]
