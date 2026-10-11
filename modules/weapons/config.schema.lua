--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Item names are checked against config/items.lua when the module starts, since this file loads first.

local ITEM_PATTERN = '^%l[%l%d_]*$'
local WEAPON_PATTERN = '^WEAPON_[%u%d_]+$'
local COMPONENT_PATTERN = '^COMPONENT_[%u%d_]+$'
local FIELDS = { hash = true, ammo = true, capacity = true, wear = true, components = true }

---@param name any
---@param weapon any
---@return string? problem
local function checkWeapon(name, weapon)
    if type(name) ~= 'string' or not name:find(ITEM_PATTERN) then
        return 'weapon keys MUST be item names'
    end

    local where = ('weapon "%s"'):format(name)

    if type(weapon) ~= 'table' then
        return where .. ' MUST be a table'
    end

    for key in pairs(weapon) do
        if not FIELDS[key] then
            return ('%s has an unknown field "%s"'):format(where, tostring(key))
        end
    end

    if type(weapon.hash) ~= 'string' or not weapon.hash:find(WEAPON_PATTERN) then
        return where .. ' hash MUST be a weapon name such as "WEAPON_PISTOL"'
    end

    if weapon.ammo ~= nil and (type(weapon.ammo) ~= 'string' or not weapon.ammo:find(ITEM_PATTERN)) then
        return where .. ' ammo MUST be an item name'
    end

    if weapon.ammo ~= nil and (math.type(weapon.capacity) ~= 'integer' or weapon.capacity < 1 or weapon.capacity > 1000) then
        return where .. ' capacity MUST be an integer from 1 to 1000 when it uses ammo'
    end

    if weapon.wear ~= nil and (type(weapon.wear) ~= 'number' or weapon.wear ~= weapon.wear or weapon.wear < 0 or weapon.wear > 100) then
        return where .. ' wear MUST be a number from 0 to 100, in durability points per shot'
    end

    if weapon.components ~= nil then
        if type(weapon.components) ~= 'table' then
            return where .. ' components MUST be a table of item name = component name'
        end

        for item, component in pairs(weapon.components) do
            if type(item) ~= 'string' or not item:find(ITEM_PATTERN) or type(component) ~= 'string' or not component:find(COMPONENT_PATTERN) then
                return where .. ' components MUST be a table of item name = component name such as "COMPONENT_AT_PI_SUPP_02"'
            end
        end
    end

    return nil
end

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'weapons',
            type = 'table',
            default = {
                weapon_pistol = {
                    hash = 'WEAPON_PISTOL',
                    ammo = 'ammo_9mm',
                    capacity = 60,
                    wear = 0.05,
                    components = { pistol_suppressor = 'COMPONENT_AT_PI_SUPP_02' },
                },
            },
            max = 256,
            description = 'Weapon items by item name: { hash, ammo?, capacity?, wear?, components? }. capacity is the most rounds loaded. wear is durability lost per shot, out of 100. components maps attachment items to component names.',
            validate = function(value)
                for name, weapon in pairs(value) do
                    local problem = checkWeapon(name, weapon)

                    if problem then
                        return false, problem
                    end
                end

                return true
            end,
        },
        {
            key = 'tints',
            type = 'table',
            default = { weapon_tint_gold = 2 },
            max = 64,
            description = 'Tint items by item name: tint index from 0 to 31. Applying a tint uses the item.',
            validate = function(value)
                for item, index in pairs(value) do
                    if type(item) ~= 'string' or not item:find(ITEM_PATTERN) or math.type(index) ~= 'integer' or index < 0 or index > 31 then
                        return false, 'tints MUST be a table of item name = tint index from 0 to 31'
                    end
                end

                return true
            end,
        },
        {
            key = 'enforce',
            type = 'boolean',
            default = true,
            description = 'Removes and flags weapons a player holds without having equipped them from the inventory.',
        },
        {
            key = 'allowed',
            type = 'table',
            default = {},
            max = 64,
            description = 'Weapon names players MAY hold without an item, such as "WEAPON_PETROLCAN". Unarmed is always allowed.',
            validate = function(value)
                for _, weapon in pairs(value) do
                    if type(weapon) ~= 'string' or not weapon:find(WEAPON_PATTERN) then
                        return false, 'allowed MUST be an array of weapon names such as "WEAPON_PETROLCAN"'
                    end
                end

                return true
            end,
        },
    },
}
