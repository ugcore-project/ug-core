--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Resolved config values. Every call returns a deep copy.
---@class UgCore.Config
local Config = {}
UgCore.Config = Config

local Utils = UgCore.Internal.Utils
local InternalConfig = UgCore.Internal.Config

---Without `key`, returns the whole config. For data configs, `key` is an entry id and MAY be missing.
---@param name string
---@param key? string
---@return any
function Config.Get(name, key)
    local entry = InternalConfig.GetEntry(name)

    if not entry then
        Utils.Raise(2, 'Config.Get: unknown config "%s"', tostring(name))
    end

    ---@cast entry -nil

    if not entry.values then
        Utils.Raise(2, 'Config.Get: config "%s" is not loaded yet', name)
    end

    if key == nil then
        return Utils.Table.DeepCopy(entry.values)
    end

    if entry.definition.kind == 'settings' and entry.sources[key] == nil then
        local keys = {}

        for _, option in ipairs(entry.definition.options) do
            keys[#keys + 1] = option.key
        end

        local suggestion = type(key) == 'string' and Utils.String.Suggest(key, keys) or nil
        local hint = suggestion and (' Did you mean "%s"?'):format(suggestion) or ''

        Utils.Raise(2, 'Config.Get: unknown option "%s.%s".%s', name, tostring(key), hint)
    end

    return Utils.Table.DeepCopy(entry.values[key])
end
