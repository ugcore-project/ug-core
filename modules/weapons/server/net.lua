--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---What clients may ask for, and the check that keeps weapons in the inventory. Callbacks reply `true` or an error code.
---@class UgCore.Internal.WeaponsNet
local Net = {}
UgCore.Internal.WeaponsNet = Net

local Errors = UgCore.Enums.Errors
local Violations = UgCore.Enums.Violations
local Weapons = UgCore.Weapons
local InternalWeapons = UgCore.Internal.Weapons
local InternalInventory = UgCore.Internal.Inventory

local CHECK_INTERVAL = 2000
local MAX_SLOT = 1000

---@param ok boolean
---@param errorCode UgErrorCode?
---@return true|UgErrorCode
local function reply(ok, errorCode)
    return ok and true or errorCode or Errors.InternalError
end

---Weapons in hand MUST come from the inventory. Anything else is taken away and flagged.
---@param allowed table<integer, boolean>
local function enforce(allowed)
    local equipped = InternalWeapons.GetAllEquipped()

    for _, player in ipairs(GetPlayers()) do
        local source = math.tointeger(tonumber(player))
        local ped = source and InternalInventory.GetPlayerId(source) and GetPlayerPed(player)

        if source and ped and ped ~= 0 then
            local weapon = GetCurrentPedWeapon(ped)
            local entry = equipped[source]

            if weapon ~= 0 and not allowed[weapon] and not (entry and entry.hash == weapon) then
                RemoveWeaponFromPed(ped, weapon)
                UgCore.Guard.Flag(source, Violations.WeaponMismatch, ('holding weapon %d without an equipped item'):format(weapon))
            end
        end
    end
end

---@param ctx UgModuleContext
function Net.Init(ctx)
    local S = UgCore.Schema
    local SLOT = S.Integer({ min = 1, max = MAX_SLOT })
    local config = ctx.config or {}
    local options = { rate = { max = 3, per = 1000 }, requirePlayer = true, requireAlive = true }

    ---@param schema UgSchema
    ---@return UgNetworkOptions
    local function with(schema)
        return { schema = schema, rate = options.rate, requirePlayer = options.requirePlayer, requireAlive = options.requireAlive }
    end

    UgCore.Callback.Register('WeaponEquip', with(S.Define({ SLOT })), function(source, slot)
        return reply(Weapons.Equip(source, slot))
    end)

    UgCore.Callback.Register('WeaponUnequip', with(S.Define({})), function(source)
        Weapons.Unequip(source, 'request')
        return true
    end)

    UgCore.Callback.Register('WeaponReload', with(S.Define({})), function(source)
        return reply(Weapons.Reload(source))
    end)

    UgCore.Callback.Register('WeaponUnload', with(S.Define({})), function(source)
        return reply(Weapons.Unload(source))
    end)

    UgCore.Callback.Register('WeaponAttach', with(S.Define({ SLOT, SLOT })), function(source, weaponSlot, itemSlot)
        return reply(Weapons.Attach(source, weaponSlot, itemSlot))
    end)

    UgCore.Callback.Register('WeaponDetach', with(S.Define({ SLOT, S.String({ min = 1, max = 64, pattern = '^%l[%l%d_]*$' }) })), function(source, weaponSlot, item)
        return reply(Weapons.Detach(source, weaponSlot, item))
    end)

    -- Sent on every ammo change of the equipped weapon, so shots wear it.
    UgCore.Network.Register('WeaponAmmo', {
        schema = S.Define({ S.Integer({ min = 0, max = 1000 }) }),
        rate = { max = 20, per = 1000 },
        requirePlayer = true,
    }, function(source, ammo)
        InternalWeapons.ReportAmmo(source, ammo)
    end)

    if not config.enforce then
        return
    end

    local allowed = { [GetHashKey('WEAPON_UNARMED')] = true }

    for _, weapon in ipairs(config.allowed or {}) do
        allowed[GetHashKey(weapon)] = true
    end

    CreateThread(function()
        while true do
            Wait(CHECK_INTERVAL)
            enforce(allowed)
        end
    end)
end
