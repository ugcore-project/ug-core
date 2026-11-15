--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local NAME_PATTERN = '^%l[%w]*$'
local MAX_NAME = 32
local MAX_LABEL = 32

---@param value any
---@param low number
---@param high number
---@return boolean
local function between(value, low, high)
    return type(value) == 'number' and value == value and value >= low and value <= high
end

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'needs',
            type = 'table',
            default = {
                hunger = {
                    label = 'Hunger',
                    start = 100,
                    rate = -0.6,
                    damage = 5,
                },
                thirst = {
                    label = 'Thirst',
                    start = 100,
                    rate = -0.9,
                    damage = 5,
                },
                stress = {
                    label = 'Stress',
                    start = 0,
                    rate = -0.5,
                    damage = 0,
                },
            },
            min = 1,
            max = 16,
            side = 'shared',
            description = 'Needs of every character, by camelCase name: { label, start, rate, damage }. Values go from 0 to 100. '
                .. 'rate: change per minute, negative to drain. damage: health lost per tick while the value is 0.',
            validate = function(value)
                for name, need in pairs(value) do
                    if type(name) ~= 'string' or #name > MAX_NAME or not name:find(NAME_PATTERN) then
                        return false, ('need names MUST be camelCase, got %s'):format(tostring(name))
                    end

                    if type(need) ~= 'table' or type(need.label) ~= 'string' or need.label == '' or #need.label > MAX_LABEL then
                        return false, ('need "%s" MUST have a label of 1 to %d characters'):format(name, MAX_LABEL)
                    end

                    if not between(need.start, 0, 100) then
                        return false, ('need "%s" start MUST be a number from 0 to 100'):format(name)
                    end

                    if not between(need.rate, -100, 100) then
                        return false, ('need "%s" rate MUST be a number from -100 to 100'):format(name)
                    end

                    if math.type(need.damage) ~= 'integer' or need.damage < 0 or need.damage > 50 then
                        return false, ('need "%s" damage MUST be an integer from 0 to 50'):format(name)
                    end
                end

                return true
            end,
        },
        {
            key = 'interval',
            type = 'integer',
            default = 10000,
            min = 1000,
            max = 300000,
            description = 'Milliseconds between two need ticks.',
        },
        {
            key = 'pauseWhileDown',
            type = 'boolean',
            default = true,
            description = 'Needs stop changing while the player is downed or dead.',
        },
        {
            key = 'resetOnRespawn',
            type = 'boolean',
            default = true,
            description = 'Respawning sets every need back to its start value.',
        },
    },
}
