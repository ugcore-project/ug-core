--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local NAME_PATTERN = '^%l[%l%d_]*$'
local MAX_NAME = 64
local MAX_LABEL = 64
local MAX_DESCRIPTION = 256
local MAX_WEIGHT = 1000000
local MAX_STACK = 1000000

local FIELDS = { label = true, weight = true, stack = true, maxStack = true, description = true, keepOnRespawn = true }

---Shared by config entries and `UgCore.Items.Register`, which adds `metadata` on top.
---@param entry any
---@param id any
---@return boolean ok
---@return string? message
local function validate(entry, id)
    if type(id) ~= 'string' or #id > MAX_NAME or not id:find(NAME_PATTERN) then
        return false, ('item names MUST be lowercase letters, digits and underscores, up to %d characters'):format(MAX_NAME)
    end

    if type(entry) ~= 'table' then
        return false, 'MUST be a table'
    end

    for key in pairs(entry) do
        if not FIELDS[key] then
            return false, ('unknown field "%s"'):format(tostring(key))
        end
    end

    if type(entry.label) ~= 'string' or entry.label == '' or #entry.label > MAX_LABEL then
        return false, ('MUST have a label of up to %d characters'):format(MAX_LABEL)
    end

    if math.type(entry.weight) ~= 'integer' or entry.weight < 0 or entry.weight > MAX_WEIGHT then
        return false, ('weight MUST be an integer of grams from 0 to %d'):format(MAX_WEIGHT)
    end

    for _, key in ipairs({ 'stack', 'keepOnRespawn' }) do
        if entry[key] ~= nil and type(entry[key]) ~= 'boolean' then
            return false, ('%s MUST be a boolean'):format(key)
        end
    end

    if entry.maxStack ~= nil and (math.type(entry.maxStack) ~= 'integer' or entry.maxStack < 1 or entry.maxStack > MAX_STACK) then
        return false, ('maxStack MUST be an integer from 1 to %d'):format(MAX_STACK)
    end

    if entry.description ~= nil and (type(entry.description) ~= 'string' or #entry.description > MAX_DESCRIPTION) then
        return false, ('description MUST be a string of up to %d characters'):format(MAX_DESCRIPTION)
    end

    return true
end

---@type UgConfigDataDefinition
return {
    kind = 'data',
    description = 'Items by lowercase name: { label, weight, stack?, maxStack?, description?, keepOnRespawn? }. Weight is in grams. Items stack unless stack = false.',
    default = {
        water = { label = 'Water', weight = 500, maxStack = 10 },
        bread = { label = 'Bread', weight = 250, maxStack = 10 },
        bandage = { label = 'Bandage', weight = 100, maxStack = 20 },
        weapon_pistol = { label = 'Pistol', weight = 1100, stack = false },
        ammo_9mm = { label = '9mm rounds', weight = 10, maxStack = 250 },
        pistol_suppressor = { label = 'Pistol suppressor', weight = 200, maxStack = 5 },
        weapon_tint_gold = { label = 'Gold weapon tint', weight = 50, maxStack = 5 },
    },
    validate = validate,
}
