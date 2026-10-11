--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Item names and accounts are checked against their configs when the module starts, since this file loads first.

local NAME_PATTERN = '^%l[%l%d_]*$'
local MAX_PRICE = 1000000000
local MAX_STOCK = 1000000
local SHOP_FIELDS = { label = true, coords = true, distance = true, account = true, items = true, jobs = true, gangs = true, groups = true }
local ITEM_FIELDS = { name = true, price = true, stock = true, restock = true, metadata = true }

---@param value any
---@param min integer
---@param max integer
---@return boolean
local function isInteger(value, min, max)
    return math.type(value) == 'integer' and value >= min and value <= max
end

---@param value any
---@param label string
---@return string? problem
local function checkGrades(value, label)
    if value == nil then
        return nil
    end

    if type(value) ~= 'table' then
        return label .. ' MUST be a table of name = minimum grade'
    end

    for name, grade in pairs(value) do
        if type(name) ~= 'string' or not name:find(NAME_PATTERN) or not isInteger(grade, 1, 1000) then
            return label .. ' MUST be a table of name = minimum grade'
        end
    end

    return nil
end

---@param coords any
---@return boolean
local function isCoords(coords)
    if type(coords) == 'vector3' then
        return true
    end

    if type(coords) ~= 'table' or #coords == 0 or #coords > 64 then
        return false
    end

    for _, point in ipairs(coords) do
        if type(point) ~= 'vector3' then
            return false
        end
    end

    return true
end

---@param where string
---@param items any
---@return string? problem
local function checkItems(where, items)
    if type(items) ~= 'table' or #items == 0 or #items > 200 then
        return where .. ' items MUST be an array of 1 to 200 items'
    end

    local seen = {}

    for index, item in ipairs(items) do
        local at = ('%s item %d'):format(where, index)

        if type(item) ~= 'table' then
            return at .. ' MUST be a table'
        end

        for key in pairs(item) do
            if not ITEM_FIELDS[key] then
                return ('%s has an unknown field "%s"'):format(at, tostring(key))
            end
        end

        if type(item.name) ~= 'string' or not item.name:find(NAME_PATTERN) then
            return at .. ' name MUST be an item name'
        end

        if seen[item.name] then
            return ('%s sells "%s" twice'):format(where, item.name)
        end

        seen[item.name] = true

        if not isInteger(item.price, 0, MAX_PRICE) then
            return ('%s price MUST be an integer from 0 to %d'):format(at, MAX_PRICE)
        end

        if item.stock ~= nil and not isInteger(item.stock, 0, MAX_STOCK) then
            return ('%s stock MUST be an integer from 0 to %d'):format(at, MAX_STOCK)
        end

        if item.restock ~= nil and (item.stock == nil or not isInteger(item.restock, 1, 10080)) then
            return at .. ' restock MUST be minutes from 1 to 10080, with a stock'
        end

        if item.metadata ~= nil and type(item.metadata) ~= 'table' then
            return at .. ' metadata MUST be a table'
        end
    end

    return nil
end

---@param name any
---@param shop any
---@return string? problem
local function checkShop(name, shop)
    if type(name) ~= 'string' or #name > 48 or not name:find(NAME_PATTERN) then
        return 'shop names MUST be lowercase letters, digits and underscores, up to 48 characters'
    end

    local where = ('shop "%s"'):format(name)

    if type(shop) ~= 'table' then
        return where .. ' MUST be a table'
    end

    for key in pairs(shop) do
        if not SHOP_FIELDS[key] then
            return ('%s has an unknown field "%s"'):format(where, tostring(key))
        end
    end

    if type(shop.label) ~= 'string' or shop.label == '' or #shop.label > 64 then
        return where .. ' MUST have a label of up to 64 characters'
    end

    if not isCoords(shop.coords) then
        return where .. ' coords MUST be a vector3 or an array of up to 64 vector3'
    end

    local distance = shop.distance

    if distance ~= nil and (type(distance) ~= 'number' or distance ~= distance or distance < 0.5 or distance > 20) then
        return where .. ' distance MUST be a number from 0.5 to 20'
    end

    if type(shop.account) ~= 'string' or not shop.account:find('^%l[%w]*$') then
        return where .. ' account MUST be an account name such as "cash"'
    end

    local problem = checkGrades(shop.jobs, where .. ' jobs') or checkGrades(shop.gangs, where .. ' gangs')

    if problem then
        return problem
    end

    if shop.groups ~= nil then
        if type(shop.groups) ~= 'table' or #shop.groups == 0 then
            return where .. ' groups MUST be an array of group names'
        end

        for _, group in ipairs(shop.groups) do
            if type(group) ~= 'string' or not group:find(NAME_PATTERN) then
                return where .. ' groups MUST be an array of group names'
            end
        end
    end

    return checkItems(where, shop.items)
end

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            -- UgCore.Shops.Register checks runtime shops with this validate, one shop at a time.
            key = 'shops',
            type = 'table',
            default = {
                general_store = {
                    label = '24/7',
                    coords = { vector3(25.7, -1347.3, 29.5), vector3(-3038.9, 585.9, 7.9) },
                    account = 'cash',
                    items = {
                        { name = 'water', price = 5 },
                        { name = 'bread', price = 8 },
                        { name = 'bandage', price = 50, stock = 20, restock = 60 },
                    },
                },
                ammunation = {
                    label = 'Ammu-Nation',
                    coords = vector3(21.9, -1107.3, 29.8),
                    account = 'bank',
                    items = {
                        { name = 'weapon_pistol', price = 2500, stock = 5, restock = 120 },
                        { name = 'ammo_9mm', price = 2 },
                        { name = 'pistol_suppressor', price = 750 },
                    },
                },
            },
            max = 256,
            description = 'Shops by name: { label, coords, distance?, account, items, jobs?, gangs?, groups? }. coords is one vector3 or an array of them. Each item is { name, price, stock?, restock?, metadata? }: without stock it never runs out, restock refills it every N minutes.',
            validate = function(value)
                for name, shop in pairs(value) do
                    local problem = checkShop(name, shop)

                    if problem then
                        return false, problem
                    end
                end

                return true
            end,
        },
    },
}
