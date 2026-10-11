--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Weapons are inventory items. The server gives the equipped one to the ped and owns its state:
---serial, loaded ammo, durability, components and tint, stored in the item's metadata.
---Clients report their ammo count. The server only accepts it going down, and wears the weapon per shot.
---@class UgCore.Weapons
local Weapons = {}
UgCore.Weapons = Weapons

---@class UgCore.Internal.Weapons
local InternalWeapons = {}
UgCore.Internal.Weapons = InternalWeapons

---@class UgWeaponDefinition
---@field name string item name
---@field hash integer
---@field weapon string weapon name, such as `WEAPON_PISTOL`
---@field ammo? string ammo item
---@field capacity integer most rounds loaded, 0 without ammo
---@field wear number durability lost per shot, out of 100
---@field components table<string, integer> attachment item -> component hash

---@class UgEquippedWeapon
---@field name string item name
---@field serial string
---@field hash integer
---@field ammo integer rounds loaded
---@field durability number 0 to 100

---@class UgWeaponSerial
---@field serial string
---@field item string
---@field characterId? integer character it was created for
---@field createdAt integer Unix seconds

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local Violations = UgCore.Enums.Violations
local Repository = UgCore.Internal.Database.Repository
local InternalHooks = UgCore.Internal.Hooks
local InternalItems = UgCore.Internal.Items
local InternalInventory = UgCore.Internal.Inventory
local Store = UgCore.Internal.InventoryStore
local Inventory = UgCore.Inventory
local WeaponEvents = UgCore.Enums.Events.Weapons
local WeaponHooks = UgCore.Enums.Hooks.Weapons

local SERIAL_CHARACTERS = 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789'
local SERIAL_LENGTH = 10
local MAX_DURABILITY = 100
local EQUIPPED_EVENT = 'ug-core:WeaponEquipped'
local UNEQUIPPED_EVENT = 'ug-core:WeaponUnequipped'
local AMMO_EVENT = 'ug-core:WeaponAmmo'
local TINT_EVENT = 'ug-core:WeaponTint'

---@type table<string, UgWeaponDefinition>
local weapons = {}

---@type table<string, integer> tint item -> tint index
local tints = {}

---@type table<integer, string> weapon hash -> item name
local byHash = {}

---@type table<integer, UgEquippedWeapon>
local equipped = {}

---@type table<string, boolean> serials issued since boot
local issued = {}

---@return string
local function newSerial()
    while true do
        local characters = {}

        for index = 1, SERIAL_LENGTH do
            local position = math.random(1, #SERIAL_CHARACTERS)

            characters[index] = SERIAL_CHARACTERS:sub(position, position)
        end

        local serial = table.concat(characters)

        if not issued[serial] then
            issued[serial] = true
            return serial
        end
    end
end

---@param source integer
---@return UgInventoryContainer?
local function inventoryOf(source)
    local id = InternalInventory.GetPlayerId(source)

    return id and Store.Get(id) or nil
end

---@param source integer
---@return integer? ped
local function pedOf(source)
    local ped = GetPlayerPed(tostring(source))

    return ped and ped ~= 0 and ped or nil
end

---Normalizes weapon metadata, and gives new weapons a serial registered to their first owner.
---@param name string
---@param metadata table
---@param inventoryId string
---@return table
local function fill(name, metadata, inventoryId)
    metadata.ammo = math.max(0, math.tointeger(metadata.ammo) or 0)
    metadata.durability = math.max(0, math.min(MAX_DURABILITY, tonumber(metadata.durability) or MAX_DURABILITY))

    if type(metadata.serial) ~= 'string' or metadata.serial == '' then
        local serial = newSerial()
        local characterId = math.tointeger(tonumber(inventoryId:match('^player:(%d+)$'))) or 0

        metadata.serial = serial

        CreateThread(function()
            Repository.Insert('INSERT INTO `ug_weapon_serials` (`serial`, `item`, `character_id`) VALUES (?, ?, NULLIF(?, 0))', { serial, name, characterId })
        end)
    end

    return metadata
end

---@param source integer
---@param entry UgEquippedWeapon
---@return UgInventoryContainer? container
---@return integer? slot
local function locate(source, entry)
    local container = inventoryOf(source)
    local slot = container and InternalInventory.FindByMetadata(container, 'serial', entry.serial)

    return container, slot
end

---Writes the equipped state back to the item, without an audit row.
---@param source integer
---@param entry UgEquippedWeapon
local function persist(source, entry)
    local container, slot = locate(source, entry)

    if not container or not slot then
        return
    end

    local metadata = Utils.Table.DeepCopy(container.items[slot].metadata or {})

    metadata.ammo = entry.ammo
    metadata.durability = entry.durability
    InternalInventory.UpdateMetadata(container, slot, metadata)
end

---@param source integer
---@param hash integer
---@param ammo integer
local function syncAmmo(source, hash, ammo)
    local ped = pedOf(source)

    if ped then
        SetPedAmmo(ped, hash, ammo)
    end

    TriggerClientEvent(AMMO_EVENT, source, ammo)
end

---Takes the weapon away. Its state is already in the item.
---@param source integer
---@param reason? string
---@return boolean ok false when nothing was equipped
function Weapons.Unequip(source, reason)
    local entry = equipped[source]

    if not entry then
        return false
    end

    equipped[source] = nil

    local ped = pedOf(source)

    if ped then
        RemoveWeaponFromPed(ped, entry.hash)
    end

    TriggerClientEvent(UNEQUIPPED_EVENT, source)
    Events.Emit(WeaponEvents.Unequipped, source, entry.name, entry.serial, reason)

    return true
end

---Gives the weapon in a slot of the player's inventory to the ped. Equipping the equipped weapon takes it away.
---@param source integer
---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_loaded`, `not_found`, `invalid_args` for other items and broken weapons, `no_permission`
function Weapons.Equip(source, slot)
    if math.type(slot) ~= 'integer' or slot < 1 then
        Utils.Raise(2, 'Weapons.Equip: slot MUST be a positive integer')
    end

    local container = inventoryOf(source)

    if not container then
        return false, Errors.NotLoaded
    end

    local item = container.items[slot]

    if not item then
        return false, Errors.NotFound
    end

    local definition = weapons[item.name]
    local metadata = item.metadata or {}

    if not definition or type(metadata.serial) ~= 'string' or (tonumber(metadata.durability) or 0) <= 0 then
        return false, Errors.InvalidArgs
    end

    local current = equipped[source]

    if current and current.serial == metadata.serial then
        Weapons.Unequip(source, 'toggle')
        return true, nil
    end

    if UgCore.Players.IsDead(source) or UgCore.Players.IsDowned(source) then
        return false, Errors.NoPermission
    end

    if not InternalHooks.Run(WeaponHooks.BeforeEquip, { source = source, name = item.name, serial = metadata.serial }) then
        return false, Errors.NoPermission
    end

    local ped = pedOf(source)

    if not ped then
        return false, Errors.NotLoaded
    end

    Weapons.Unequip(source, 'switch')

    local entry = {
        name = item.name,
        serial = metadata.serial,
        hash = definition.hash,
        ammo = math.min(math.tointeger(metadata.ammo) or 0, definition.capacity),
        durability = tonumber(metadata.durability) or MAX_DURABILITY,
    }

    equipped[source] = entry
    GiveWeaponToPed(ped, definition.hash, 0, false, true)
    SetPedAmmo(ped, definition.hash, entry.ammo)

    for _, component in ipairs(type(metadata.components) == 'table' and metadata.components or {}) do
        local hash = definition.components[component]

        if hash then
            GiveWeaponComponentToPed(ped, definition.hash, hash)
        end
    end

    SetCurrentPedWeapon(ped, definition.hash, true)
    TriggerClientEvent(EQUIPPED_EVENT, source, { hash = definition.hash, ammo = entry.ammo, tint = math.tointeger(metadata.tint) })
    Events.Emit(WeaponEvents.Equipped, source, item.name, metadata.serial)

    return true, nil
end

---@param source integer
---@return UgEquippedWeapon? weapon a copy, nil when nothing is equipped
function Weapons.GetEquipped(source)
    local entry = equipped[source]

    return entry and Utils.Table.DeepCopy(entry) or nil
end

---Loads ammo items from the player's inventory, up to the weapon's capacity.
---@param source integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` without an equipped weapon, `invalid_args` for weapons without ammo, `insufficient_items`
function Weapons.Reload(source)
    local entry = equipped[source]

    if not entry then
        return false, Errors.NotFound
    end

    local definition = weapons[entry.name]

    if not definition.ammo then
        return false, Errors.InvalidArgs
    end

    local missing = definition.capacity - entry.ammo
    local take = math.min(missing, Inventory.Count(source, definition.ammo))

    if missing <= 0 then
        return true, nil
    end

    if take <= 0 then
        return false, Errors.InsufficientItems
    end

    local ok, errorCode = Inventory.RemoveItem(source, definition.ammo, take, nil, 'reload')

    if not ok then
        return false, errorCode
    end

    entry.ammo = entry.ammo + take
    persist(source, entry)
    syncAmmo(source, entry.hash, entry.ammo)

    return true, nil
end

---Takes the loaded rounds out, back into the player's inventory.
---@param source integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` without an equipped weapon, `invalid_args` for weapons without ammo, `cannot_carry`
function Weapons.Unload(source)
    local entry = equipped[source]

    if not entry then
        return false, Errors.NotFound
    end

    local definition = weapons[entry.name]

    if not definition.ammo then
        return false, Errors.InvalidArgs
    end

    if entry.ammo == 0 then
        return true, nil
    end

    local ok, errorCode = Inventory.AddItem(source, definition.ammo, entry.ammo, nil, 'unload')

    if not ok then
        return false, errorCode
    end

    entry.ammo = 0
    persist(source, entry)
    syncAmmo(source, entry.hash, 0)

    return true, nil
end

---A client's ammo count for the equipped weapon. Fewer rounds are shots: they wear the weapon.
---More rounds than the server gave never happen honestly: they are flagged and reverted.
---@param source integer
---@param ammo integer
function InternalWeapons.ReportAmmo(source, ammo)
    local entry = equipped[source]

    if not entry or ammo == entry.ammo then
        return
    end

    if ammo > entry.ammo then
        UgCore.Guard.Flag(source, Violations.WeaponMismatch, ('%s ammo %d, server has %d'):format(entry.name, ammo, entry.ammo))
        syncAmmo(source, entry.hash, entry.ammo)
        return
    end

    local shots = entry.ammo - ammo

    entry.ammo = ammo
    entry.durability = math.max(0, entry.durability - shots * weapons[entry.name].wear)
    persist(source, entry)

    if entry.durability <= 0 then
        Weapons.Unequip(source, 'broken')
        Events.Emit(WeaponEvents.Broken, source, entry.name, entry.serial)
    end
end

---Attaches a component or tint item from the player's inventory to a weapon in it. The item is used up.
---@param source integer
---@param weaponSlot integer
---@param itemSlot integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_loaded`, `not_found`, `invalid_args` when the item does not fit this weapon or is already attached
function Weapons.Attach(source, weaponSlot, itemSlot)
    local container = inventoryOf(source)

    if not container then
        return false, Errors.NotLoaded
    end

    local weapon, attachment = container.items[weaponSlot], container.items[itemSlot]

    if not weapon or not attachment then
        return false, Errors.NotFound
    end

    local definition = weapons[weapon.name]
    local metadata = Utils.Table.DeepCopy(weapon.metadata or {})
    local components = type(metadata.components) == 'table' and metadata.components or {}
    local tint = tints[attachment.name]
    local component = definition and definition.components[attachment.name]

    if not definition or (not tint and not component) then
        return false, Errors.InvalidArgs
    end

    for _, attached in ipairs(components) do
        if attached == attachment.name then
            return false, Errors.InvalidArgs
        end
    end

    local ok, errorCode = Inventory.RemoveFromSlot(source, itemSlot, 1, 'attach')

    if not ok then
        return false, errorCode
    end

    if tint then
        metadata.tint = tint
    else
        components[#components + 1] = attachment.name
        metadata.components = components
    end

    Inventory.SetMetadata(source, weaponSlot, metadata, 'attach')

    local entry = equipped[source]
    local ped = pedOf(source)

    if entry and entry.serial == metadata.serial and ped then
        if tint then
            TriggerClientEvent(TINT_EVENT, source, entry.hash, tint)
        else
            GiveWeaponComponentToPed(ped, entry.hash, component --[[@as integer]])
        end
    end

    return true, nil
end

---Takes a component off a weapon, back into the player's inventory. Tints cannot be removed.
---@param source integer
---@param weaponSlot integer
---@param item string the attachment item
---@return boolean ok
---@return UgErrorCode? errorCode `not_loaded`, `not_found`, `cannot_carry`
function Weapons.Detach(source, weaponSlot, item)
    local container = inventoryOf(source)

    if not container then
        return false, Errors.NotLoaded
    end

    local weapon = container.items[weaponSlot]
    local definition = weapon and weapons[weapon.name]
    local metadata = weapon and Utils.Table.DeepCopy(weapon.metadata or {}) or {}
    local components = type(metadata.components) == 'table' and metadata.components or {}
    local index = nil

    for position, attached in ipairs(components) do
        if attached == item then
            index = position
        end
    end

    if not definition or not index then
        return false, Errors.NotFound
    end

    if not Inventory.CanCarry(source, item, 1) then
        return false, Errors.CannotCarry
    end

    table.remove(components, index)
    metadata.components = #components > 0 and components or nil
    Inventory.SetMetadata(source, weaponSlot, metadata, 'detach')
    Inventory.AddItem(source, item, 1, nil, 'detach')

    local entry = equipped[source]
    local ped = pedOf(source)

    if entry and entry.serial == metadata.serial and ped then
        RemoveWeaponComponentFromPed(ped, entry.hash, definition.components[item])
    end

    return true, nil
end

---Sets a weapon's durability, for repair benches and gunsmiths.
---@param target integer|string player source or inventory id
---@param slot integer
---@param durability? number 0 to 100, defaults to 100
---@return boolean ok
---@return UgErrorCode? errorCode `not_found`, `invalid_args` for other items
function Weapons.Repair(target, slot, durability)
    durability = durability or MAX_DURABILITY

    if type(durability) ~= 'number' or durability < 0 or durability > MAX_DURABILITY then
        Utils.Raise(2, 'Weapons.Repair: durability MUST be a number from 0 to 100')
    end

    local item = Inventory.GetSlot(target, slot)

    if not item then
        return false, Errors.NotFound
    end

    if not weapons[item.name] then
        return false, Errors.InvalidArgs
    end

    local metadata = item.metadata or {}

    metadata.durability = durability

    local ok, errorCode = Inventory.SetMetadata(target, slot, metadata, 'repair')

    for _, entry in pairs(equipped) do
        if entry.serial == metadata.serial then
            entry.durability = durability
        end
    end

    return ok, errorCode
end

---Who a serial was made for. MUST run in a thread.
---@param serial string
---@return boolean ok
---@return UgWeaponSerial? record nil for unknown serials
---@return UgErrorCode? errorCode
function Weapons.GetBySerial(serial)
    if type(serial) ~= 'string' or #serial > 16 then
        Utils.Raise(2, 'Weapons.GetBySerial expects a serial')
    end

    local ok, row = Repository.Single(
        'SELECT `serial`, `item`, `character_id` AS `characterId`, UNIX_TIMESTAMP(`created_at`) AS `createdAt` FROM `ug_weapon_serials` WHERE `serial` = ?',
        { serial }
    )

    if not ok then
        return false, nil, Errors.InternalError
    end

    if not row then
        return true, nil, nil
    end

    return true, {
        serial = row.serial,
        item = row.item,
        characterId = math.tointeger(row.characterId),
        createdAt = math.tointeger(row.createdAt) or 0,
    }, nil
end

---@param name string
---@return boolean
function Weapons.IsWeapon(name)
    return weapons[name] ~= nil
end

---@param name string item name
---@return { weapon: string, ammo?: string, capacity: integer, wear: number, components: string[] }? definition
function Weapons.GetDefinition(name)
    local definition = weapons[name]

    if not definition then
        return nil
    end

    local components = {}

    for item in pairs(definition.components) do
        components[#components + 1] = item
    end

    table.sort(components)

    return { weapon = definition.weapon, ammo = definition.ammo, capacity = definition.capacity, wear = definition.wear, components = components }
end

---@param hash integer
---@return string? item
function InternalWeapons.ItemOf(hash)
    return byHash[hash]
end

---@return table<integer, UgEquippedWeapon>
function InternalWeapons.GetAllEquipped()
    return equipped
end

---@param name string
---@param kind string
---@param problems string[]
local function requireItem(name, kind, problems)
    if not InternalItems.GetDefinition(name) then
        problems[#problems + 1] = ('%s "%s" is not in config/items.lua'):format(kind, name)
    end
end

---@param ctx UgModuleContext
function InternalWeapons.Init(ctx)
    local config = ctx.config or {}
    local problems = {}

    weapons, tints, byHash = {}, {}, {}

    for name, weapon in pairs(config.weapons or {}) do
        local definition = InternalItems.GetDefinition(name)

        if not definition then
            problems[#problems + 1] = ('weapon "%s" is not in config/items.lua'):format(name)
        elseif definition.stack then
            problems[#problems + 1] = ('weapon "%s" MUST have stack = false in config/items.lua'):format(name)
        end

        if weapon.ammo then
            requireItem(weapon.ammo, 'ammo', problems)
        end

        local components = {}

        for item, component in pairs(weapon.components or {}) do
            requireItem(item, 'component', problems)
            components[item] = GetHashKey(component)
        end

        local hash = GetHashKey(weapon.hash)

        weapons[name] = {
            name = name,
            hash = hash,
            weapon = weapon.hash,
            ammo = weapon.ammo,
            capacity = weapon.ammo and weapon.capacity or 0,
            wear = weapon.wear or 0,
            components = components,
        }
        byHash[hash] = name
    end

    for item, index in pairs(config.tints or {}) do
        requireItem(item, 'tint', problems)
        tints[item] = index
    end

    if #problems > 0 then
        error(table.concat(problems, '; '), 0)
    end

    for name in pairs(weapons) do
        InternalItems.SetFill(name, function(metadata, inventoryId)
            return fill(name, metadata, inventoryId)
        end)

        -- Using a weapon equips it, or puts it away.
        UgCore.Items.RegisterUse(name, function(source, item)
            return (Weapons.Equip(source, item.slot))
        end, { cooldown = 500 })
    end

    local ammoItems = {}

    for _, definition in pairs(weapons) do
        if definition.ammo then
            ammoItems[definition.ammo] = true
        end
    end

    for ammo in pairs(ammoItems) do
        -- Using ammo loads the equipped weapon, when it takes that ammo.
        UgCore.Items.RegisterUse(ammo, function(source)
            local entry = equipped[source]

            if not entry or weapons[entry.name].ammo ~= ammo then
                return false
            end

            return (Weapons.Reload(source))
        end, { cooldown = 500 })
    end

    local attachments = {}

    for item in pairs(tints) do
        attachments[item] = true
    end

    for _, definition in pairs(weapons) do
        for item in pairs(definition.components) do
            attachments[item] = true
        end
    end

    for item in pairs(attachments) do
        -- Using an attachment fits it on the equipped weapon.
        UgCore.Items.RegisterUse(item, function(source, used)
            local entry = equipped[source]
            local container, slot = nil, nil

            if entry then
                container, slot = locate(source, entry)
            end

            if not container or not slot then
                return false
            end

            return (Weapons.Attach(source, slot, used.slot))
        end, { cooldown = 500 })
    end

    -- A weapon leaving the player's inventory, or the player going down, takes it out of their hands.
    UgCore.Hooks.Register(UgCore.Enums.Hooks.Inventory.BeforeMove, function(payload)
        for source, entry in pairs(equipped) do
            if payload.from == InternalInventory.GetPlayerId(source) and payload.to ~= payload.from then
                local container = Store.Get(payload.from)
                local item = container and container.items[payload.fromSlot]

                if item and item.metadata and item.metadata.serial == entry.serial then
                    Weapons.Unequip(source, 'moved')
                end
            end
        end
    end)

    Events.On(UgCore.Enums.Events.Inventory.ItemRemoved, function(inventoryId)
        for source, entry in pairs(equipped) do
            if inventoryId == InternalInventory.GetPlayerId(source) and not select(2, locate(source, entry)) then
                Weapons.Unequip(source, 'removed')
            end
        end
    end)

    for _, event in ipairs({ UgCore.Enums.Events.Players.Downed, UgCore.Enums.Events.Players.Died }) do
        Events.On(event, function(source)
            Weapons.Unequip(source, 'down')
        end)
    end

    Events.On(UgCore.Enums.Events.Characters.Unloaded, function(source)
        Weapons.Unequip(source, 'unload')
    end)

    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        if dropped then
            equipped[dropped] = nil
        end
    end)

    ctx.logger.Debug('%d weapon(s) defined.', Utils.Table.Count(weapons))
end
