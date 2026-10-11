--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---The local player. Reads statebags only.
---@class UgCore.LocalPlayer
local LocalPlayerApi = {}
UgCore.LocalPlayer = LocalPlayerApi

local Utils = UgCore.Internal.Utils
local States = UgCore.Enums.DeathState

local LOADED_KEY = UgCore.Enums.StateBags.Loaded
local PLAYER_KEY = UgCore.Enums.StateBags.Player
local METADATA_KEY = UgCore.Enums.StateBags.Metadata
local STATE_KEY = UgCore.Enums.StateBags.DeathState
local INJURIES_KEY = UgCore.Enums.StateBags.Injuries

---@param key string
---@return any
local function read(key)
    return Utils.Table.DeepCopy(LocalPlayer.state[key])
end

---@return { name: string, characterId: integer? }?
function LocalPlayerApi.GetData()
    return read(PLAYER_KEY)
end

---@return boolean
function LocalPlayerApi.IsLoaded()
    return LocalPlayer.state[LOADED_KEY] == true
end

---Replicated metadata only.
---@param key? string every replicated key when nil
---@return any
function LocalPlayerApi.GetMetadata(key)
    local metadata = LocalPlayer.state[METADATA_KEY]

    if type(metadata) ~= 'table' then
        return key == nil and {} or nil
    end

    return Utils.Table.DeepCopy(key == nil and metadata or metadata[key])
end

---@return UgDeathState
function LocalPlayerApi.GetDeathState()
    return LocalPlayer.state[STATE_KEY] or States.Alive
end

---@return boolean
function LocalPlayerApi.IsDead()
    return LocalPlayerApi.GetDeathState() == States.Dead
end

---@return boolean
function LocalPlayerApi.IsDowned()
    return LocalPlayerApi.GetDeathState() == States.Downed
end

---@return UgInjury[]
function LocalPlayerApi.GetInjuries()
    return read(INJURIES_KEY) or {}
end
