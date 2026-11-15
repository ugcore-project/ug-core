--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Client and shared config values, replicated by the server. Every call returns a deep copy.
---@class UgCore.Config
local Config = {}
UgCore.Config = Config

---@class UgReplicatedConfig
---@field kind 'settings'|'data'
---@field values table

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local InternalLogger = UgCore.Internal.Logger

local REPLICATION_KEY = UgCore.Enums.GlobalState.Config

---@type table<string, UgReplicatedConfig>?
local configs = nil

---@param payload any
local function apply(payload)
    if type(payload) ~= 'table' then
        return
    end

    configs = payload

    local core = payload.core

    if core and type(core.values.debug) == 'boolean' then
        InternalLogger.SetDebug(core.values.debug)
    end

    Logger.Info('Config: received %d config(s).', Utils.Table.Count(payload))
end

---Server-only configs and options do not exist here.
---@param name string
---@param key? string
---@return any
function Config.Get(name, key)
    if not configs then
        Utils.Raise(2, 'Config.Get: config is not received yet')
    end

    ---@cast configs -nil

    local config = configs[name]

    if not config then
        Utils.Raise(2, 'Config.Get: unknown or server-only config "%s"', tostring(name))
    end

    if key == nil then
        return Utils.Table.DeepCopy(config.values)
    end

    if config.kind == 'settings' and config.values[key] == nil then
        Utils.Raise(2, 'Config.Get: unknown or server-only option "%s.%s"', name, tostring(key))
    end

    return Utils.Table.DeepCopy(config.values[key])
end

apply(GlobalState[REPLICATION_KEY])

AddStateBagChangeHandler(REPLICATION_KEY, 'global', function(_, _, value)
    apply(value)
end)
