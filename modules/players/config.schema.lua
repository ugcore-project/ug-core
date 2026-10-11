--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Config schemas load before module files, so the DamageCategory enum is not available here.
local CATEGORIES = {
    Gunshot = true, Stab = true, Blunt = true, Explosion = true, Fire = true,
    Fall = true, Vehicle = true, Drowning = true, Animal = true, Unknown = true,
}

---@param value any
---@return boolean
local function isAnimation(value)
    return value == false or (type(value) == 'table' and type(value.dict) == 'string' and type(value.name) == 'string')
end

---@param value any
---@return boolean
local function isPositiveInteger(value)
    return math.type(value) == 'integer' and value > 0
end

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'downed',
            type = 'table',
            default = {
                enabled = true,
                duration = 300000,
                killOnDamage = true,
                animation = { dict = 'combat@damage@writhe', name = 'writhe_loop' },
            },
            side = 'shared',
            description = 'Downed state before death. duration is the bleedout time in ms. animation is { dict, name } or false.',
            validate = function(value)
                if type(value.enabled) ~= 'boolean' or type(value.killOnDamage) ~= 'boolean' then
                    return false, 'enabled and killOnDamage MUST be booleans'
                end

                if not isPositiveInteger(value.duration) then
                    return false, 'duration MUST be a positive integer of ms'
                end

                return isAnimation(value.animation), 'animation MUST be { dict, name } or false'
            end,
        },
        {
            key = 'dead',
            type = 'table',
            default = { animation = { dict = 'dead', name = 'dead_a' } },
            side = 'shared',
            description = 'Dead state. animation is { dict, name } or false.',
            validate = function(value)
                return isAnimation(value.animation), 'animation MUST be { dict, name } or false'
            end,
        },
        {
            key = 'instantDeath',
            type = 'table',
            default = { headshot = true, categories = { 'Explosion' } },
            description = 'Fatal damage that skips downed. categories are damage categories such as Explosion.',
            validate = function(value)
                if type(value.headshot) ~= 'boolean' or type(value.categories) ~= 'table' then
                    return false, 'headshot MUST be a boolean and categories an array'
                end

                for _, category in ipairs(value.categories) do
                    if not CATEGORIES[category] then
                        return false, ('unknown damage category "%s"'):format(tostring(category))
                    end
                end

                return true
            end,
        },
        {
            key = 'respawn',
            type = 'table',
            default = { auto = false, delay = 5000, coords = vector4(298.5, -584.6, 43.3, 70.0) },
            description = 'Automatic respawn after death. coords is the default respawn position.',
            validate = function(value)
                if type(value.auto) ~= 'boolean' or not isPositiveInteger(value.delay) then
                    return false, 'auto MUST be a boolean and delay a positive integer of ms'
                end

                return type(value.coords) == 'vector4', 'coords MUST be a vector4'
            end,
        },
        {
            key = 'persistDeathState',
            type = 'boolean',
            default = true,
            description = 'Saves death state, injuries and cause of death with the character. Needs the characters module.',
        },
    },
}
