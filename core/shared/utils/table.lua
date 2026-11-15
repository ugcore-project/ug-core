--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@class UgCore.Internal.Utils.Table
local Table = {}
UgCore.Internal.Utils.Table = Table

local Utils = UgCore.Internal.Utils

---@param value any
---@param seen table<table, table>
---@return any
local function deepCopy(value, seen)
    if type(value) ~= 'table' then
        return value
    end

    local existing = seen[value]
    if existing then
        return existing
    end

    local copy = {}
    seen[value] = copy

    for key, entry in pairs(value) do
        copy[deepCopy(key, seen)] = deepCopy(entry, seen)
    end

    return copy
end

---Metatables are not copied. Cycles and shared references keep their shape in the copy.
---@generic T
---@param value T
---@return T
function Table.DeepCopy(value)
    return deepCopy(value, {})
end

---Counts every key, not only the array part.
---@param tbl table
---@return integer
function Table.Count(tbl)
    if type(tbl) ~= 'table' then
        Utils.Raise(2, 'Table.Count expects a table, got %s', type(tbl))
    end

    local count = 0

    for _ in pairs(tbl) do
        count = count + 1
    end

    return count
end
