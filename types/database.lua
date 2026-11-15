--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---Positional `?` values. MUST be flat: oxmysql treats an array of arrays as a batch.
---@alias UgDbParams (string|number|boolean)[]

---@class UgDbQuery
---@field query string
---@field values? UgDbParams

---@class UgCacheOptions
---@field name string shown in logs and `ug database`
---@field flush fun(key: any, value: any): boolean writes one entry and MUST return true on success
---@field interval? integer ms between periodic flushes, defaults to 30000

---@class UgCacheStats
---@field name string
---@field entries integer
---@field dirty integer
