--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Needs of the local player's loaded character, sent by the server to this player only.
---@class UgCore.Needs
local Needs = {}
UgCore.Needs = Needs

local Events = UgCore.Events
local CHANGED = UgCore.Enums.Events.Needs.Changed
local MAX_NEEDS = 16
local MAX_NAME = 32
-- More than any configured damage can add up to: 16 needs of 50.
local MAX_DAMAGE = 800

---@type table<string, number>
local values = {}

---@param name string
---@return number? value from 0 to 100, nil when no character is loaded or the need does not exist
function Needs.Get(name)
    return values[name]
end

---@return table<string, number>
function Needs.GetAll()
    return UgCore.Internal.Utils.Table.DeepCopy(values)
end

-- On clients `Changed` carries `(name, value, previous)` for the local player. `value` is nil once the character unloads.
UgCore.Network.Register('NeedsSync', function(incoming)
    local fresh, count = {}, 0

    for name, value in pairs(type(incoming) == 'table' and incoming or {}) do
        count = count + 1

        if count > MAX_NEEDS then
            break
        end

        if type(name) == 'string' and #name <= MAX_NAME and type(value) == 'number' and value >= 0 and value <= 100 then
            fresh[name] = value
        end
    end

    for name, previous in pairs(values) do
        if fresh[name] == nil then
            values[name] = nil
            Events.Emit(CHANGED, name, nil, previous)
        end
    end

    for name, value in pairs(fresh) do
        local previous = values[name]

        if previous ~= value then
            values[name] = value
            Events.Emit(CHANGED, name, value, previous)
        end
    end
end)

-- The server decides the damage when a need reaches 0. Downed and dead players take none.
UgCore.Network.Register('NeedsDamage', function(amount)
    if math.type(amount) ~= 'integer' or amount <= 0 or amount > MAX_DAMAGE then
        return
    end

    if UgCore.LocalPlayer.GetDeathState() ~= UgCore.Enums.DeathState.Alive then
        return
    end

    ApplyDamageToPed(PlayerPedId(), amount, false)
end)
