--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Server-authoritative inventories. Every change is all or nothing, runs a hook, writes an audit row and emits an event.
---`target` is a player source, for that player's inventory, or an inventory id such as `player:12`.
---@class UgCore.Inventory
local Inventory = {}
UgCore.Inventory = Inventory

---@class UgCore.Internal.Inventory
local InternalInventory = {}
UgCore.Internal.Inventory = InternalInventory

---@class UgInventoryInfo
---@field id string
---@field slots integer
---@field maxWeight integer grams
---@field weight integer grams

---@class UgItemLogEntry
---@field item string
---@field amount integer positive when added
---@field metadata? table
---@field reason? string
---@field related? string the other inventory of a move or give
---@field createdAt integer Unix seconds

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local InternalHooks = UgCore.Internal.Hooks
local InternalItems = UgCore.Internal.Items
local Store = UgCore.Internal.InventoryStore
local InventoryEvents = UgCore.Enums.Events.Inventory
local InventoryHooks = UgCore.Enums.Hooks.Inventory

local MAX_COUNT = 1000000

---@type table<integer, string> source -> player inventory id
local byPlayer = {}

---@param target any
---@param caller string
---@return UgInventoryContainer? container
---@return UgErrorCode? errorCode
local function resolve(target, caller)
    if math.type(target) == 'integer' and target > 0 then
        local id = byPlayer[target]
        local container = id and Store.Get(id)

        if not container then
            return nil, Errors.NotLoaded
        end

        Store.Touch(container)

        return container, nil
    end

    if not Store.IsId(target) then
        Utils.Raise(3, 'Inventory.%s expects a player source or an inventory id such as "player:12"', caller)
    end

    local container = Store.Get(target)

    if not container then
        return nil, Errors.NotFound
    end

    Store.Touch(container)

    return container, nil
end

---@param count any
---@param caller string
local function checkCount(count, caller)
    if math.type(count) ~= 'integer' or count < 1 or count > MAX_COUNT then
        Utils.Raise(3, 'Inventory.%s: count MUST be an integer from 1 to %d', caller, MAX_COUNT)
    end
end

---@param reason any
---@param caller string
local function checkReason(reason, caller)
    if not Store.IsReason(reason) then
        Utils.Raise(3, 'Inventory.%s: reason MUST be a string of up to 128 characters', caller)
    end
end

---@param slot any
---@param caller string
local function checkSlot(slot, caller)
    if math.type(slot) ~= 'integer' or slot < 1 then
        Utils.Raise(3, 'Inventory.%s: slot MUST be a positive integer', caller)
    end
end

---@param container UgInventoryContainer
---@param slot integer
---@return UgInventorySlot
local function slotCopy(container, slot)
    local item = container.items[slot]

    return { slot = slot, name = item.name, count = item.count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil }
end

---Applies an add plan. Callers checked the plan and ran hooks.
---@param container UgInventoryContainer
---@param name string
---@param metadata table?
---@param plan table<integer, integer>
---@param changed table<integer, boolean>
local function applyAdd(container, name, metadata, plan, changed)
    for slot, units in pairs(plan) do
        local item = container.items[slot]

        if item then
            item.count = item.count + units
        else
            container.items[slot] = { name = name, count = units, metadata = metadata and Utils.Table.DeepCopy(metadata) or nil }
        end

        changed[slot] = true
    end
end

---@param container UgInventoryContainer
---@param plan table<integer, integer>
---@param changed table<integer, boolean>
local function applyRemove(container, plan, changed)
    for slot, units in pairs(plan) do
        local item = container.items[slot]

        item.count = item.count - units

        if item.count <= 0 then
            container.items[slot] = nil
        end

        changed[slot] = true
    end
end

---@param target integer|string
---@param name string
---@param metadata any
---@param caller string
---@return UgInventoryContainer? container
---@return table? metadata checked copy
---@return UgErrorCode? errorCode
local function prepare(target, name, metadata, caller)
    local container, errorCode = resolve(target, caller)

    if not container then
        return nil, nil, errorCode
    end

    if type(name) ~= 'string' or not InternalItems.GetDefinition(name) then
        return nil, nil, Errors.InvalidArgs
    end

    local ok, checked, detail = InternalItems.CheckMetadata(name, metadata)

    if not ok then
        Logger.Debug('Inventory: rejected metadata for %s: %s', name, tostring(detail))
        return nil, nil, Errors.InvalidArgs
    end

    return container, checked, nil
end

---Adds items, filling existing stacks first. MUST NOT be partial: all units fit, or nothing changes.
---@param target integer|string player source or inventory id
---@param name string
---@param count integer 1 to 1,000,000
---@param metadata? table
---@param reason? string stored in the audit log
---@return boolean ok
---@return UgErrorCode? errorCode `invalid_args`, `cannot_carry`, `no_permission` when a hook cancelled
function Inventory.AddItem(target, name, count, metadata, reason)
    checkCount(count, 'AddItem')
    checkReason(reason, 'AddItem')

    local container, checked, errorCode = prepare(target, name, metadata, 'AddItem')

    if not container then
        return false, errorCode
    end

    local plan = Store.PlanAdd(container, name, count, checked)

    if not plan then
        return false, Errors.CannotCarry
    end

    local payload = { inventory = container.id, name = name, count = count, metadata = checked, reason = reason }

    if not InternalHooks.Run(InventoryHooks.BeforeAdd, payload) then
        return false, Errors.NoPermission
    end

    -- Hooks MAY yield, so the plan is made again on the current state.
    plan = Store.PlanAdd(container, name, count, checked)

    if not plan then
        return false, Errors.CannotCarry
    end

    local changed = {}
    local fill = InternalItems.GetFill(name)

    if fill then
        -- Each unit has its own slot and its own metadata, so each gets its own audit row and event.
        local slots = {}

        for slot in pairs(plan) do
            slots[#slots + 1] = slot
        end

        table.sort(slots)

        for _, slot in ipairs(slots) do
            local unit = fill(checked and Utils.Table.DeepCopy(checked) or {}, container.id)

            container.items[slot] = { name = name, count = 1, metadata = unit }
            changed[slot] = true
            Store.Log(container, name, 1, unit, reason, nil)
            Events.Emit(InventoryEvents.ItemAdded, container.id, name, 1, Utils.Table.DeepCopy(unit), reason)
        end

        Store.Changed(container, changed)

        return true, nil
    end

    applyAdd(container, name, checked, plan, changed)
    Store.Log(container, name, count, checked, reason, nil)
    Store.Changed(container, changed)
    Events.Emit(InventoryEvents.ItemAdded, container.id, name, count, checked and Utils.Table.DeepCopy(checked) or nil, reason)

    return true, nil
end

---Removes items from the lowest slots first. With `metadata`, only stacks whose metadata has those keys and values.
---@param target integer|string player source or inventory id
---@param name string
---@param count integer
---@param metadata? table filter
---@param reason? string stored in the audit log
---@return boolean ok
---@return UgErrorCode? errorCode `insufficient_items`, `no_permission` when a hook cancelled
function Inventory.RemoveItem(target, name, count, metadata, reason)
    checkCount(count, 'RemoveItem')
    checkReason(reason, 'RemoveItem')

    if metadata ~= nil and type(metadata) ~= 'table' then
        Utils.Raise(2, 'Inventory.RemoveItem: metadata MUST be a table filter')
    end

    local container, errorCode = resolve(target, 'RemoveItem')

    if not container then
        return false, errorCode
    end

    if type(name) ~= 'string' or not Store.PlanRemove(container, name, count, metadata) then
        return false, Errors.InsufficientItems
    end

    local payload = { inventory = container.id, name = name, count = count, metadata = metadata and Utils.Table.DeepCopy(metadata) or nil, reason = reason }

    if not InternalHooks.Run(InventoryHooks.BeforeRemove, payload) then
        return false, Errors.NoPermission
    end

    local plan = Store.PlanRemove(container, name, count, metadata)

    if not plan then
        return false, Errors.InsufficientItems
    end

    local changed, removed = {}, {}

    for slot, units in pairs(plan) do
        local metadata = container.items[slot].metadata

        Store.Log(container, name, -units, metadata, reason, nil)
        removed[#removed + 1] = { units = units, metadata = metadata and Utils.Table.DeepCopy(metadata) or nil }
    end

    -- Events go out once the inventory holds its new state.
    applyRemove(container, plan, changed)
    Store.Changed(container, changed)

    for _, entry in ipairs(removed) do
        Events.Emit(InventoryEvents.ItemRemoved, container.id, name, entry.units, entry.metadata, reason)
    end

    return true, nil
end

---Removes units from one slot.
---@param target integer|string player source or inventory id
---@param slot integer
---@param count? integer defaults to the whole stack
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` for an empty slot, `insufficient_items`, `no_permission`
function Inventory.RemoveFromSlot(target, slot, count, reason)
    checkSlot(slot, 'RemoveFromSlot')
    checkReason(reason, 'RemoveFromSlot')

    if count ~= nil then
        checkCount(count, 'RemoveFromSlot')
    end

    local container, errorCode = resolve(target, 'RemoveFromSlot')

    if not container then
        return false, errorCode
    end

    local item = container.items[slot]

    if not item then
        return false, Errors.NotFound
    end

    count = count or item.count

    if count > item.count then
        return false, Errors.InsufficientItems
    end

    local payload = { inventory = container.id, name = item.name, count = count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil, reason = reason }

    if not InternalHooks.Run(InventoryHooks.BeforeRemove, payload) then
        return false, Errors.NoPermission
    end

    item = container.items[slot]

    if not item or count > item.count then
        return false, Errors.InsufficientItems
    end

    local changed = {}
    local name, metadata = item.name, item.metadata

    applyRemove(container, { [slot] = count }, changed)
    Store.Log(container, name, -count, metadata, reason, nil)
    Store.Changed(container, changed)
    Events.Emit(InventoryEvents.ItemRemoved, container.id, name, count, metadata and Utils.Table.DeepCopy(metadata) or nil, reason)

    return true, nil
end

---Replaces the metadata of a whole slot. The audit log records it with an amount of 0.
---@param target integer|string player source or inventory id
---@param slot integer
---@param metadata? table nil removes it
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` for an empty slot, `invalid_args` for rejected metadata
function Inventory.SetMetadata(target, slot, metadata, reason)
    checkSlot(slot, 'SetMetadata')
    checkReason(reason, 'SetMetadata')

    local container, errorCode = resolve(target, 'SetMetadata')

    if not container then
        return false, errorCode
    end

    local item = container.items[slot]

    if not item then
        return false, Errors.NotFound
    end

    local ok, checked, detail = InternalItems.CheckMetadata(item.name, metadata)

    if not ok then
        Logger.Debug('Inventory: rejected metadata for %s: %s', item.name, tostring(detail))
        return false, Errors.InvalidArgs
    end

    item.metadata = checked
    Store.Log(container, item.name, 0, checked, reason, nil)
    Store.Changed(container, { [slot] = true })

    return true, nil
end

---Removes every item, except those `keep` returns true for.
---@param target integer|string player source or inventory id
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Clear(target, reason)
    checkReason(reason, 'Clear')

    local container, errorCode = resolve(target, 'Clear')

    if not container then
        return false, errorCode
    end

    InternalInventory.Clear(container, reason, nil)

    return true, nil
end

---@param container UgInventoryContainer
---@param reason? string
---@param keep? fun(item: UgInventoryItem): boolean
function InternalInventory.Clear(container, reason, keep)
    local changed, removed = {}, {}

    for slot, item in pairs(container.items) do
        if not (keep and keep(item)) then
            Store.Log(container, item.name, -item.count, item.metadata, reason, nil)
            removed[#removed + 1] = item
            container.items[slot] = nil
            changed[slot] = true
        end
    end

    if next(changed) then
        Store.Changed(container, changed)
    end

    for _, item in ipairs(removed) do
        Events.Emit(InventoryEvents.ItemRemoved, container.id, item.name, item.count, item.metadata and Utils.Table.DeepCopy(item.metadata) or nil, reason)
    end
end

---@param target integer|string player source or inventory id
---@param name string
---@param metadata? table filter
---@return integer count 0 for unknown inventories
function Inventory.Count(target, name, metadata)
    local container = resolve(target, 'Count')
    local sum = 0

    for _, item in pairs(container and container.items or {}) do
        if item.name == name and Store.Matches(item.metadata, metadata) then
            sum = sum + item.count
        end
    end

    return sum
end

---@param target integer|string player source or inventory id
---@param name string
---@param count? integer defaults to 1
---@param metadata? table filter
---@return boolean
function Inventory.HasItem(target, name, count, metadata)
    return Inventory.Count(target, name, metadata) >= (count or 1)
end

---@param target integer|string player source or inventory id
---@param name string
---@param count integer
---@param metadata? table
---@return boolean
function Inventory.CanCarry(target, name, count, metadata)
    checkCount(count, 'CanCarry')

    local container = resolve(target, 'CanCarry')

    if not container or not InternalItems.GetDefinition(name) then
        return false
    end

    local ok, checked = InternalItems.CheckMetadata(name, metadata)

    return ok and Store.PlanAdd(container, name, count, checked) ~= nil
end

---@param target integer|string player source or inventory id
---@return UgInventorySlot[] items copies, by slot
function Inventory.GetItems(target)
    local container = resolve(target, 'GetItems')
    local list = {}

    for slot in pairs(container and container.items or {}) do
        list[#list + 1] = slotCopy(container --[[@as UgInventoryContainer]], slot)
    end

    table.sort(list, function(a, b)
        return a.slot < b.slot
    end)

    return list
end

---@param target integer|string player source or inventory id
---@param slot integer
---@return UgInventorySlot? item a copy, nil for empty slots
function Inventory.GetSlot(target, slot)
    checkSlot(slot, 'GetSlot')

    local container = resolve(target, 'GetSlot')

    return container and container.items[slot] and slotCopy(container, slot) or nil
end

---@param target integer|string player source or inventory id
---@return UgInventoryInfo? info nil for unknown inventories
function Inventory.Get(target)
    local container = resolve(target, 'Get')

    if not container then
        return nil
    end

    return { id = container.id, slots = container.slots, maxWeight = container.maxWeight, weight = Store.Weight(container) }
end

---@param inventoryId string
---@return integer? source the player who owns it, nil when offline or not a player inventory
function Inventory.GetSource(inventoryId)
    for source, id in pairs(byPlayer) do
        if id == inventoryId then
            return source
        end
    end

    return nil
end

---Replaces metadata without an audit row, for frequent state such as weapon ammo and durability.
---@param container UgInventoryContainer
---@param slot integer
---@param metadata table?
function InternalInventory.UpdateMetadata(container, slot, metadata)
    local item = container.items[slot]

    if item then
        item.metadata = metadata
        Store.Changed(container, { [slot] = true })
    end
end

---First slot whose metadata has this key and value, such as a weapon serial.
---@param container UgInventoryContainer
---@param key string
---@param value any
---@return integer? slot
function InternalInventory.FindByMetadata(container, key, value)
    for slot = 1, container.slots do
        local item = container.items[slot]

        if item and item.metadata and item.metadata[key] == value then
            return slot
        end
    end

    return nil
end

---@param source integer
---@return string? id
function InternalInventory.GetPlayerId(source)
    return byPlayer[source]
end

---@param source integer
---@param id? string nil when the character unloads
function InternalInventory.SetPlayerId(source, id)
    byPlayer[source] = id
end

-- Shared with service.lua, which raises through them at the same depth.
InternalInventory.Resolve = resolve
InternalInventory.CheckCount = checkCount
InternalInventory.CheckReason = checkReason
InternalInventory.CheckSlot = checkSlot
InternalInventory.SlotCopy = slotCopy
InternalInventory.ApplyAdd = applyAdd
InternalInventory.ApplyRemove = applyRemove

