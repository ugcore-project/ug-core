--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---The equipped weapon of the local player. The server gives and takes it. The client applies the tint,
---which has no server native, and reports its ammo count so shots wear the weapon.
---Actions MUST run in a thread and return `ok, errorCode`.
---@class UgCore.Weapons
local Weapons = {}
UgCore.Weapons = Weapons

local Events = UgCore.Events
local Callback = UgCore.Callback
local Network = UgCore.Network
local WeaponEvents = UgCore.Enums.Events.Weapons

local WATCH_INTERVAL = 250
local MAX_AMMO = 1000

---@type { hash: integer, ammo: integer, tint?: integer }?
local current = nil

-- Bumped on every equip, so an old watcher stops.
local generation = 0

---@param name string
---@param ... any
---@return boolean ok
---@return UgErrorCode? errorCode
local function ask(name, ...)
    local ok, value, errorCode = Callback.Await(name, ...)

    if not ok then
        return false, errorCode
    end

    if value == true then
        return true, nil
    end

    return false, type(value) == 'string' and value or nil
end

---@param hash integer
---@param tint integer
local function applyTint(hash, tint)
    SetPedWeaponTintIndex(PlayerPedId(), hash, tint)
end

---@param watched integer
local function watch(watched)
    CreateThread(function()
        while current and generation == watched do
            Wait(WATCH_INTERVAL)

            local weapon = current

            if not weapon or generation ~= watched then
                return
            end

            local ammo = math.max(0, math.min(MAX_AMMO, GetAmmoInPedWeapon(PlayerPedId(), weapon.hash)))

            if ammo ~= weapon.ammo then
                weapon.ammo = ammo
                Network.TriggerServer('ug-core:WeaponAmmo', ammo)
            end
        end
    end)
end

Network.Register('WeaponEquipped', function(payload)
    if type(payload) ~= 'table' or math.type(payload.hash) ~= 'integer' then
        return
    end

    generation = generation + 1
    current = { hash = payload.hash, ammo = math.tointeger(payload.ammo) or 0, tint = math.tointeger(payload.tint) }

    if current.tint then
        applyTint(current.hash, current.tint)
    end

    Events.Emit(WeaponEvents.Equipped, current.hash, current.ammo)
    watch(generation)
end)

Network.Register('WeaponUnequipped', function()
    if current then
        current = nil
        generation = generation + 1
        Events.Emit(WeaponEvents.Unequipped)
    end
end)

Network.Register('WeaponAmmo', function(ammo)
    if current and math.type(ammo) == 'integer' then
        current.ammo = ammo
    end
end)

Network.Register('WeaponTint', function(hash, tint)
    if current and current.hash == hash and math.type(tint) == 'integer' then
        current.tint = tint
        applyTint(hash, tint)
    end
end)

---@return { hash: integer, ammo: integer, tint?: integer }? weapon a copy, nil when nothing is equipped
function Weapons.GetEquipped()
    return current and { hash = current.hash, ammo = current.ammo, tint = current.tint } or nil
end

---Equips the weapon in a slot, or puts it away when it is equipped. MUST run in a thread.
---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Equip(slot)
    return ask('ug-core:WeaponEquip', slot)
end

---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Unequip()
    return ask('ug-core:WeaponUnequip')
end

---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Reload()
    return ask('ug-core:WeaponReload')
end

---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Unload()
    return ask('ug-core:WeaponUnload')
end

---@param weaponSlot integer
---@param itemSlot integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Attach(weaponSlot, itemSlot)
    return ask('ug-core:WeaponAttach', weaponSlot, itemSlot)
end

---@param weaponSlot integer
---@param item string the attachment item
---@return boolean ok
---@return UgErrorCode? errorCode
function Weapons.Detach(weaponSlot, item)
    return ask('ug-core:WeaponDetach', weaponSlot, item)
end
