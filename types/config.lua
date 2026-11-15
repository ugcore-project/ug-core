--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---@alias UgConfigType 'string'|'number'|'integer'|'boolean'|'table'|'vector2'|'vector3'|'vector4'

---Where a value is readable. `client` and `shared` values replicate to clients.
---@alias UgConfigSide 'server'|'client'|'shared'

---Where a resolved value came from, lowest to highest precedence.
---@alias UgConfigSource 'default'|'file'|'convar'

---@class UgConfigOption
---@field key string camelCase
---@field type UgConfigType
---@field default any MUST pass its own validation
---@field description string
---@field side? UgConfigSide defaults to 'server'
---@field values? any[] allowed values
---@field min? number minimum number, string length or table entry count
---@field max? number maximum number, string length or table entry count
---@field validate? fun(value: any): boolean, string?

---Owner files merge per key.
---@class UgConfigSettingsDefinition
---@field kind 'settings'
---@field options UgConfigOption[]

---Owner content such as jobs. Owner files replace the default entirely.
---@class UgConfigDataDefinition
---@field kind 'data'
---@field description string
---@field default table
---@field side? UgConfigSide defaults to 'server'
---@field validate? fun(entry: any, id: any): boolean, string?

---@alias UgConfigDefinition UgConfigSettingsDefinition|UgConfigDataDefinition
