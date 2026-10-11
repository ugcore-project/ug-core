--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---The local player's inventory, sent by the server to this player only. Reads are local.
---Actions ask the server, which decides. They MUST run in a thread and return `ok, errorCode`.
---@class UgCore.Inventory
local Inventory = {}
UgCore.Inventory = Inventory

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Callback = UgCore.Callback
local InventoryEvents = UgCore.Enums.Events.Inventory

local PLAYER_REF = 'player'
local OTHER_REF = 'other'
local ITEMS_KEY = UgCore.Enums.GlobalState.Items
local DROPS_KEY = UgCore.Enums.GlobalState.Drops

---@class UgClientInventory
---@field label? string
---@field slots integer
---@field maxWeight integer
---@field items table<integer, UgInventoryItem>

---@type UgClientInventory?
local state = nil

---The inventory opened next to the player's, acted on as `other`.
---@type UgClientInventory?
local other = nil

---@param name string
---@param ... any
---@return boolean ok
---@return UgErrorCode? errorCode
---@return any value the reply, when it is not `true`
local function ask(name, ...)
    local ok, value, errorCode = Callback.Await(name, ...)

    if not ok then
        return false, errorCode, nil
    end

    if value == true or type(value) == 'table' then
        return true, nil, value
    end

    return false, type(value) == 'string' and value or nil, nil
end

---@param item any
---@return UgInventoryItem?
local function readItem(item)
    if type(item) ~= 'table' or type(item.name) ~= 'string' or math.type(item.count) ~= 'integer' then
        return nil
    end

    return { name = item.name, count = item.count, metadata = type(item.metadata) == 'table' and item.metadata or nil }
end

---@param payload any
---@return UgClientInventory?
local function readInventory(payload)
    if type(payload) ~= 'table' then
        return nil
    end

    local items = {}

    for _, entry in ipairs(type(payload.items) == 'table' and payload.items or {}) do
        local slot, item = math.tointeger(entry.slot), readItem(entry)

        if slot and item then
            items[slot] = item
        end
    end

    return {
        label = type(payload.label) == 'string' and payload.label or nil,
        slots = math.tointeger(payload.slots) or 0,
        maxWeight = math.tointeger(payload.maxWeight) or 0,
        items = items,
    }
end

---@param inventory UgClientInventory?
---@return { label?: string, slots: integer, maxWeight: integer, items: UgInventorySlot[] }?
local function describe(inventory)
    if not inventory then
        return nil
    end

    local items = {}

    for slot, item in pairs(inventory.items) do
        items[#items + 1] = { slot = slot, name = item.name, count = item.count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil }
    end

    table.sort(items, function(a, b)
        return a.slot < b.slot
    end)

    return { label = inventory.label, slots = inventory.slots, maxWeight = inventory.maxWeight, items = items }
end

---@param payload any
local function setOther(payload)
    other = readInventory(payload)

    if other then
        Events.Emit(InventoryEvents.Opened, describe(other))
    end
end

UgCore.Network.Register('InventorySync', function(payload)
    state = readInventory(payload)
    Events.Emit(InventoryEvents.Changed, nil, PLAYER_REF)
end)

UgCore.Network.Register('InventoryUpdate', function(ref, changes)
    local target = ref == PLAYER_REF and state or ref == OTHER_REF and other or nil

    if not target or type(changes) ~= 'table' then
        return
    end

    local applied = {}

    for _, change in ipairs(changes) do
        local slot = type(change) == 'table' and math.tointeger(change.slot)

        if slot then
            target.items[slot] = readItem(change.item)
            applied[#applied + 1] = { slot = slot, item = target.items[slot] and Utils.Table.DeepCopy(target.items[slot]) or nil }
        end
    end

    Events.Emit(InventoryEvents.Changed, applied, ref)
end)

UgCore.Network.Register('InventoryOpened', function(payload)
    setOther(payload)
end)

UgCore.Network.Register('InventoryClosed', function()
    if other then
        other = nil
        Events.Emit(InventoryEvents.Closed)
    end
end)

---@return boolean loaded false before a character is loaded
function Inventory.IsLoaded()
    return state ~= nil
end

---@return UgInventorySlot[] items copies, by slot
function Inventory.GetItems()
    local list = {}

    for slot, item in pairs(state and state.items or {}) do
        list[#list + 1] = { slot = slot, name = item.name, count = item.count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil }
    end

    table.sort(list, function(a, b)
        return a.slot < b.slot
    end)

    return list
end

---@param slot integer
---@return UgInventorySlot? item a copy, nil for empty slots
function Inventory.GetSlot(slot)
    local item = state and state.items[slot]

    if not item then
        return nil
    end

    return { slot = slot, name = item.name, count = item.count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil }
end

---@param name string
---@return integer
function Inventory.Count(name)
    local sum = 0

    for _, item in pairs(state and state.items or {}) do
        if item.name == name then
            sum = sum + item.count
        end
    end

    return sum
end

---@param name string
---@param count? integer defaults to 1
---@return boolean
function Inventory.HasItem(name, count)
    return Inventory.Count(name) >= (count or 1)
end

---Total weight in grams, from the replicated item weights.
---@return integer
function Inventory.GetWeight()
    local definitions = GlobalState[ITEMS_KEY]
    local sum = 0

    for _, item in pairs(state and state.items or {}) do
        local definition = type(definitions) == 'table' and definitions[item.name] or nil

        sum = sum + (definition and definition.weight or 0) * item.count
    end

    return sum
end

---Maximum weight in grams.
---@return integer
function Inventory.GetMaxWeight()
    return state and state.maxWeight or 0
end

---@return integer
function Inventory.GetSlots()
    return state and state.slots or 0
end

---Moves or splits within the player's inventory. MUST run in a thread.
---@param fromSlot integer
---@param toSlot integer
---@param count? integer defaults to the whole stack
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Move(fromSlot, toSlot, count)
    local ok, errorCode = ask('ug-core:InventoryMove', PLAYER_REF, fromSlot, PLAYER_REF, toSlot, count)

    return ok, errorCode
end

---Uses the item in a slot. MUST run in a thread.
---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Use(slot)
    local ok, errorCode = ask('ug-core:InventoryUse', slot)

    return ok, errorCode
end

---Gives items to a nearby player. MUST run in a thread.
---@param target integer server id of the other player
---@param slot integer
---@param count? integer defaults to the whole stack
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Give(target, slot, count)
    local ok, errorCode = ask('ug-core:InventoryGive', target, slot, count)

    return ok, errorCode
end

---Asks the server to send the whole inventory again. MUST run in a thread.
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Refresh()
    local ok, errorCode = ask('ug-core:InventoryRefresh')

    return ok, errorCode
end

---Moves units between the player's inventory and the open one. MUST run in a thread.
---@param from 'player'|'other'
---@param fromSlot integer
---@param to 'player'|'other'
---@param toSlot integer
---@param count? integer defaults to the whole stack
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.MoveBetween(from, fromSlot, to, toSlot, count)
    local ok, errorCode = ask('ug-core:InventoryMove', from, fromSlot, to, toSlot, count)

    return ok, errorCode
end

---Opens a stash by name, a trunk or glovebox by vehicle entity, or a drop by id. MUST run in a thread.
---@param kind 'stash'|'trunk'|'glovebox'|'drop'
---@param key string|integer stash name, vehicle entity, or drop id
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Open(kind, key)
    local ok, errorCode, opened

    if kind == 'trunk' or kind == 'glovebox' then
        ok, errorCode, opened = ask('ug-core:InventoryOpen', kind, nil, NetworkGetNetworkIdFromEntity(key --[[@as integer]]))
    else
        ok, errorCode, opened = ask('ug-core:InventoryOpen', kind, key)
    end

    if ok then
        setOther(opened)
    end

    return ok, errorCode
end

---Closes the open inventory. MUST run in a thread.
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Close()
    local ok, errorCode = ask('ug-core:InventoryClose')

    if ok and other then
        other = nil
        Events.Emit(InventoryEvents.Closed)
    end

    return ok, errorCode
end

---Drops items on the ground, into a drop nearby or a new one. MUST run in a thread.
---@param slot integer
---@param count? integer defaults to the whole stack
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.Drop(slot, count)
    local ok, errorCode = ask('ug-core:InventoryDrop', slot, count)

    return ok, errorCode
end

---@return { label?: string, slots: integer, maxWeight: integer, items: UgInventorySlot[] }? inventory a copy of the open inventory
function Inventory.GetOther()
    return describe(other)
end

---Positions of ground drops, to draw them. Their contents are only sent when opened.
---@return table<string, vector3> drops by id
function Inventory.GetDrops()
    local payload = GlobalState[DROPS_KEY]
    local list = {}

    for id, position in pairs(type(payload) == 'table' and payload or {}) do
        list[id] = vector3(position.x, position.y, position.z)
    end

    return list
end
