--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local NAME_PATTERN = '^%l[%l%d_]*$'
local MAX_STASH_NAME = 48
local MAX_SLOTS = 200
local MAX_WEIGHT = 10000000

local STASH_FIELDS = {
    label = true, slots = true, weight = true, coords = true, distance = true, personal = true, jobs = true, gangs = true, groups = true,
}

---@param value any
---@param min integer
---@param max integer
---@return boolean
local function isInteger(value, min, max)
    return math.type(value) == 'integer' and value >= min and value <= max
end

---`{ slots, weight }`, shared by stashes, vehicles and drops.
---@param value any
---@param label string
---@return string? problem
local function checkSize(value, label)
    if type(value) ~= 'table' or not isInteger(value.slots, 1, MAX_SLOTS) then
        return ('%s slots MUST be an integer from 1 to %d'):format(label, MAX_SLOTS)
    end

    if not isInteger(value.weight, 1, MAX_WEIGHT) then
        return ('%s weight MUST be an integer of grams from 1 to %d'):format(label, MAX_WEIGHT)
    end

    return nil
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

---@param name any
---@param stash any
---@return string? problem
local function checkStash(name, stash)
    if type(name) ~= 'string' or #name > MAX_STASH_NAME or not name:find(NAME_PATTERN) then
        return ('stash names MUST be lowercase letters, digits and underscores, up to %d characters'):format(MAX_STASH_NAME)
    end

    local where = ('stash "%s"'):format(name)

    if type(stash) ~= 'table' then
        return where .. ' MUST be a table'
    end

    for key in pairs(stash) do
        if not STASH_FIELDS[key] then
            return ('%s has an unknown field "%s"'):format(where, tostring(key))
        end
    end

    if type(stash.label) ~= 'string' or stash.label == '' or #stash.label > 64 then
        return where .. ' MUST have a label of up to 64 characters'
    end

    local problem = checkSize(stash, where)

    if problem then
        return problem
    end

    if stash.coords ~= nil and type(stash.coords) ~= 'vector3' then
        return where .. ' coords MUST be a vector3'
    end

    local distance = stash.distance

    if distance ~= nil and (type(distance) ~= 'number' or distance ~= distance or distance < 0.5 or distance > 20) then
        return where .. ' distance MUST be a number from 0.5 to 20'
    end

    if stash.personal ~= nil and type(stash.personal) ~= 'boolean' then
        return where .. ' personal MUST be a boolean'
    end

    problem = checkGrades(stash.jobs, where .. ' jobs') or checkGrades(stash.gangs, where .. ' gangs')

    if problem then
        return problem
    end

    if stash.groups ~= nil then
        if type(stash.groups) ~= 'table' or #stash.groups == 0 then
            return where .. ' groups MUST be an array of group names'
        end

        for _, group in ipairs(stash.groups) do
            if type(group) ~= 'string' or not group:find(NAME_PATTERN) then
                return where .. ' groups MUST be an array of group names'
            end
        end
    end

    return nil
end

---@param label string
---@param fields table<string, boolean>
---@return fun(value: any): boolean, string?
local function sizeValidator(label, fields)
    return function(value)
        local problem = checkSize(value, label)

        if not problem then
            for key in pairs(value) do
                if not fields[key] then
                    problem = ('%s has an unknown field "%s"'):format(label, tostring(key))
                end
            end
        end

        return problem == nil, problem
    end
end

local checkDrops = sizeValidator('drops', { slots = true, weight = true, lifetime = true })

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'playerSlots',
            type = 'integer',
            default = 40,
            min = 1,
            max = 200,
            description = 'Slots in a player inventory.',
        },
        {
            key = 'playerWeight',
            type = 'integer',
            default = 30000,
            min = 1,
            max = 10000000,
            description = 'Maximum weight of a player inventory, in grams.',
        },
        {
            key = 'giveDistance',
            type = 'number',
            default = 3.0,
            min = 0.5,
            max = 20.0,
            description = 'Maximum distance in meters to give items to another player.',
        },
        {
            key = 'clearOnRespawn',
            type = 'boolean',
            default = false,
            description = 'Empties player inventories on respawn, except items with keepOnRespawn.',
        },
        {
            -- UgCore.Inventory.RegisterStash checks runtime stashes with this validate, one stash at a time.
            key = 'stashes',
            type = 'table',
            default = {
                police_locker = {
                    label = 'Police locker',
                    slots = 50,
                    weight = 100000,
                    coords = vector3(461.7, -996.0, 30.7),
                    personal = true,
                    jobs = { police = 1 },
                },
            },
            max = 256,
            description = 'Stashes by name: { label, slots, weight, coords?, distance?, personal?, jobs?, gangs?, groups? }. jobs and gangs map a name to a minimum grade. Any listed job, gang or group gives access; none listed means everyone.',
            validate = function(value)
                for name, stash in pairs(value) do
                    local problem = checkStash(name, stash)

                    if problem then
                        return false, problem
                    end
                end

                return true
            end,
        },
        {
            key = 'trunk',
            type = 'table',
            default = { slots = 20, weight = 50000 },
            description = 'Size of vehicle trunks: { slots, weight }.',
            validate = sizeValidator('trunk', { slots = true, weight = true }),
        },
        {
            key = 'glovebox',
            type = 'table',
            default = { slots = 5, weight = 5000 },
            description = 'Size of vehicle gloveboxes: { slots, weight }.',
            validate = sizeValidator('glovebox', { slots = true, weight = true }),
        },
        {
            key = 'drops',
            type = 'table',
            default = { slots = 20, weight = 100000, lifetime = 15 },
            description = 'Ground drops: { slots, weight, lifetime }. lifetime is in minutes. Drops are never saved.',
            validate = function(value)
                local ok, problem = checkDrops(value)

                if ok and not isInteger(value.lifetime, 1, 1440) then
                    return false, 'drops lifetime MUST be an integer of minutes from 1 to 1440'
                end

                return ok, problem
            end,
        },
    },
}
