--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Which second inventory each player has open. A player acts on it as `other`, next to their own `player`.
---Reach is checked again on every action, so walking away or losing access closes it.
---@class UgCore.Inventory
local Inventory = UgCore.Inventory

---@class UgCore.Internal.InventorySessions
local Sessions = {}
UgCore.Internal.InventorySessions = Sessions

---@class UgInventorySession
---@field id string
---@field reach UgInventoryReach

---@class UgOpenedInventory
---@field label? string
---@field slots integer
---@field maxWeight integer grams
---@field items UgInventorySlot[]

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local InternalHooks = UgCore.Internal.Hooks
local Store = UgCore.Internal.InventoryStore
local Containers = UgCore.Internal.InventoryContainers
local InventoryEvents = UgCore.Enums.Events.Inventory
local InventoryHooks = UgCore.Enums.Hooks.Inventory

local OPENED_EVENT = 'ug-core:InventoryOpened'
local CLOSED_EVENT = 'ug-core:InventoryClosed'

---@type table<integer, UgInventorySession>
local open = {}

---@param container UgInventoryContainer
---@return UgOpenedInventory
function Sessions.Describe(container)
    local items = {}

    for slot, item in pairs(container.items) do
        items[#items + 1] = { slot = slot, name = item.name, count = item.count, metadata = item.metadata and Utils.Table.DeepCopy(item.metadata) or nil }
    end

    table.sort(items, function(a, b)
        return a.slot < b.slot
    end)

    return { label = container.label, slots = container.slots, maxWeight = container.maxWeight, items = items }
end

---@param source integer
---@return UgInventorySession?
function Sessions.Get(source)
    return open[source]
end

---Closes the player's open inventory.
---@param source integer
---@param notify boolean tells the client, false when the client closed it
function Sessions.Close(source, notify)
    local session = open[source]

    if not session then
        return
    end

    open[source] = nil

    local container = Store.Get(session.id)

    if container then
        container.viewers[source] = nil
    end

    if notify then
        TriggerClientEvent(CLOSED_EVENT, source)
    end

    Events.Emit(InventoryEvents.Closed, source, session.id)
end

---Closes an inventory for everyone who has it open.
---@param id string
function Sessions.CloseAll(id)
    for source, session in pairs(open) do
        if session.id == id then
            Sessions.Close(source, true)
        end
    end
end

---Opens a container for the player, after `Inventory:BeforeOpen`. Closes what the player had open.
---@param source integer
---@param container UgInventoryContainer
---@param reach UgInventoryReach
---@return UgOpenedInventory? opened nil when a hook cancelled
function Sessions.Open(source, container, reach)
    if not InternalHooks.Run(InventoryHooks.BeforeOpen, { source = source, inventory = container.id }) then
        return nil
    end

    Sessions.Close(source, false)

    open[source] = { id = container.id, reach = reach }
    container.viewers[source] = true
    Store.Touch(container)
    Events.Emit(InventoryEvents.Opened, source, container.id)

    return Sessions.Describe(container)
end

---The id the player MAY act on as `other`, checked now. Losing reach closes it.
---@param source integer
---@return string? id
---@return boolean known false when the player had nothing open
function Sessions.Resolve(source)
    local session = open[source]

    if not session then
        return nil, false
    end

    if not Store.Get(session.id) or not Containers.CanReach(source, session.reach) then
        Sessions.Close(source, true)
        return nil, true
    end

    return session.id, true
end

---Opens an inventory for a player from server code, such as a house stash or a search.
---Reach is not checked: the caller decided. The player sees it as `other` until it closes. MUST run in a thread.
---@param source integer
---@param inventoryId string any saved inventory id, or a loaded one
---@return boolean ok
---@return UgErrorCode? errorCode `not_loaded`, `not_found`, `no_permission` when a hook cancelled
function Inventory.Open(source, inventoryId)
    if math.type(source) ~= 'integer' or source < 1 or not Store.IsId(inventoryId) then
        Utils.Raise(2, 'Inventory.Open expects a player source and an inventory id')
    end

    if not UgCore.Internal.Inventory.GetPlayerId(source) then
        return false, Errors.NotLoaded
    end

    local container, errorCode = Containers.LoadById(inventoryId)

    if not container then
        return false, errorCode
    end

    local opened = Sessions.Open(source, container, { kind = 'direct' })

    if not opened then
        return false, Errors.NoPermission
    end

    TriggerClientEvent(OPENED_EVENT, source, opened)

    return true, nil
end

---@param source integer
function Inventory.Close(source)
    Sessions.Close(source, true)
end

---@param source integer
---@return string? id the inventory the player has open
function Inventory.GetOpen(source)
    local session = open[source]

    return session and session.id or nil
end

function Sessions.Init()
    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        if dropped then
            Sessions.Close(dropped, false)
        end
    end)
end
