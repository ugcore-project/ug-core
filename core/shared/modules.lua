--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Enabled modules, in load order. Empty until the module loader runs.
---@class UgCore.Modules
local Modules = {}
UgCore.Modules = Modules

---@class UgCore.Internal.Modules
---@field Loader UgCore.Internal.Modules.Loader server only
local InternalModules = {}
UgCore.Internal.Modules = InternalModules

local Utils = UgCore.Internal.Utils

---@type string[]
local order = {}

---@type table<string, boolean>
local enabled = {}

---@param name string
---@return boolean
function Modules.IsEnabled(name)
    return enabled[name] == true
end

---@return string[] names in load order
function Modules.GetEnabled()
    return Utils.Table.DeepCopy(order)
end

---Raises when `name` is not enabled. For code that cannot adapt to a missing module.
---@param name string
function Modules.Require(name)
    if not enabled[name] then
        Utils.Raise(2, 'Modules.Require: module "%s" is not enabled. Enable it in config/modules.lua.', tostring(name))
    end
end

---Only the module loaders call this.
---@param names string[] in load order
function InternalModules.SetEnabled(names)
    order = Utils.Table.DeepCopy(names)
    enabled = {}

    for index = 1, #order do
        enabled[order[index]] = true
    end
end
