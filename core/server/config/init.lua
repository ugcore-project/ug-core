--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Registry of config definitions. Values resolve in `Loader.Load`.
---@class UgCore.Internal.Config
---@field Validator UgCore.Internal.Config.Validator
---@field Serializer UgCore.Internal.Config.Serializer
---@field Loader UgCore.Internal.Config.Loader
local InternalConfig = {}
UgCore.Internal.Config = InternalConfig

---@class UgConfigEntry
---@field name string
---@field definition UgConfigDefinition
---@field values table? resolved values, nil until loaded
---@field sources table<string, UgConfigSource>? per setting key, nil until loaded

local Utils = UgCore.Internal.Utils

---@type UgConfigEntry[]
local entries = {}

---@type table<string, UgConfigEntry>
local byName = {}

---Raises when the definition is invalid, including a default that fails its own validation.
---@param name string camelCase, also the file name `config/<name>.lua`
---@param definition UgConfigDefinition
function InternalConfig.Register(name, definition)
    local problem = InternalConfig.Validator.CheckDefinition(name, definition)

    if problem then
        Utils.Raise(2, 'Config.Register("%s"): %s', tostring(name), problem)
    end

    if byName[name] then
        Utils.Raise(2, 'Config.Register: "%s" is already registered', name)
    end

    local entry = { name = name, definition = definition }
    entries[#entries + 1] = entry
    byName[name] = entry
end

---@param name string
---@return UgConfigEntry?
function InternalConfig.GetEntry(name)
    return byName[name]
end

---In registration order.
---@return UgConfigEntry[]
function InternalConfig.GetEntries()
    return entries
end
