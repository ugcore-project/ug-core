--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Item definitions replicated by the server. Read-only.
---@class UgCore.Items
local Items = {}
UgCore.Items = Items

local Utils = UgCore.Internal.Utils

local REPLICATION_KEY = UgCore.Enums.GlobalState.Items

---@return table<string, UgItemDefinition>
local function definitions()
    local value = GlobalState[REPLICATION_KEY]

    return type(value) == 'table' and value or {}
end

---@param name string
---@return UgItemDefinition? definition a copy, nil for unknown items
function Items.Get(name)
    local definition = definitions()[name]

    return definition and Utils.Table.DeepCopy(definition) or nil
end

---@return table<string, UgItemDefinition> definitions copies, by name
function Items.GetAll()
    return Utils.Table.DeepCopy(definitions())
end

---@param name string
---@return boolean
function Items.Exists(name)
    return definitions()[name] ~= nil
end
