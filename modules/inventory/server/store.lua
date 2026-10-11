--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Inventory containers in memory, their persistence and the item audit log.
---A container is saved through a write-behind cache. Its audit rows are written in the same transaction,
---so the log never shows a change the inventory lost.
---@class UgCore.Internal.InventoryStore
local Store = {}
UgCore.Internal.InventoryStore = Store

---@class UgInventoryItem
---@field name string
---@field count integer
---@field metadata? table

---@class UgInventorySlot: UgInventoryItem
---@field slot integer

---@class UgInventoryContainer
---@field id string
---@field label? string shown to players who open it
---@field slots integer
---@field maxWeight integer
---@field items table<integer, UgInventoryItem>
---@field owner? integer player source whose own inventory this is
---@field viewers table<integer, boolean> player sources that have it open
---@field persistent boolean saved to the database
---@field lastUsed integer GetGameTimer ms of the last access, for idle unloading
---@field logs UgDbQuery[] audit rows not written yet

---@class UgInventoryChange
---@field slot integer
---@field item? UgInventoryItem nil when the slot is now empty

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Repository = UgCore.Internal.Database.Repository
local InternalItems = UgCore.Internal.Items

local ID_PATTERN = '^%l[%l%d_]*:[%w_%-%.:]+$'
local MAX_ID = 96
local MAX_REASON = 128

local LOG_QUERY = [[
    INSERT INTO `ug_item_logs` (`inventory`, `item`, `amount`, `metadata`, `reason`, `related`)
    VALUES (?, ?, ?, NULLIF(?, ''), NULLIF(?, ''), NULLIF(?, ''))
]]

local SAVE_QUERY = [[
    INSERT INTO `ug_inventories` (`id`, `items`) VALUES (?, ?)
    ON DUPLICATE KEY UPDATE `items` = VALUES(`items`)
]]

---@type table<string, UgInventoryContainer>
local containers = {}

---@type fun(container: UgInventoryContainer, changes: UgInventoryChange[])?
local listener = nil

---@param container UgInventoryContainer
---@return string
local function encode(container)
    local list = {}

    for slot, item in pairs(container.items) do
        list[#list + 1] = { slot = slot, name = item.name, count = item.count, metadata = item.metadata }
    end

    table.sort(list, function(a, b)
        return a.slot < b.slot
    end)

    return json.encode(list)
end

---@param id string
---@param text any
---@param slots integer
---@return table<integer, UgInventoryItem>
local function decode(id, text, slots)
    local items = {}

    if type(text) ~= 'string' or text == '' then
        return items
    end

    local ok, list = pcall(json.decode, text)

    if not ok or type(list) ~= 'table' then
        Logger.Error('Inventory: %s has unreadable items. It starts empty and is not saved until it changes.', id)
        return items
    end

    for _, entry in ipairs(list) do
        local slot, count = math.tointeger(entry.slot), math.tointeger(entry.count)

        if slot and slot >= 1 and slot <= slots and not items[slot] and type(entry.name) == 'string' and count and count > 0 then
            items[slot] = { name = entry.name, count = count, metadata = type(entry.metadata) == 'table' and entry.metadata or nil }
        else
            Logger.Warn('Inventory: %s has an invalid entry that is kept out of reach.', id)
        end
    end

    return items
end

---@param id string
---@param container UgInventoryContainer
---@return boolean ok
local function write(id, container)
    local logs = container.logs
    local queries = { { query = SAVE_QUERY, values = { id, encode(container) } } }

    container.logs = {}

    for _, log in ipairs(logs) do
        queries[#queries + 1] = log
    end

    local ok = Repository.Transaction(queries)

    if not ok then
        -- Kept in order, before rows logged while this write ran.
        for index = #logs, 1, -1 do
            table.insert(container.logs, 1, logs[index])
        end
    end

    return ok
end

local cache = UgCore.Internal.Database.Cache.Create({ name = 'inventory', flush = write })

---@param value any
---@return boolean
function Store.IsId(value)
    return type(value) == 'string' and #value <= MAX_ID and value:find(ID_PATTERN) ~= nil
end

---@param value any
---@return boolean
function Store.IsReason(value)
    return value == nil or (type(value) == 'string' and #value <= MAX_REASON)
end

---@param fn fun(container: UgInventoryContainer, changes: UgInventoryChange[])
function Store.OnChange(fn)
    listener = fn
end

---@param id string
---@return UgInventoryContainer?
function Store.Get(id)
    return containers[id]
end

---@param id string
---@param slots integer
---@param maxWeight integer
---@param items table<integer, UgInventoryItem>
---@param persistent boolean
---@param label? string
---@param owner? integer
---@return UgInventoryContainer
local function new(id, slots, maxWeight, items, persistent, label, owner)
    return {
        id = id,
        label = label,
        slots = slots,
        maxWeight = maxWeight,
        items = items,
        owner = owner,
        viewers = {},
        persistent = persistent,
        lastUsed = GetGameTimer(),
        logs = {},
    }
end

---Loads a saved container. MUST run in a thread.
---With `ifSaved`, a container without a saved row is created temporary: it lives in memory only.
---Otherwise it is created empty and saved from its first change.
---@param id string
---@param slots integer
---@param maxWeight integer
---@param owner? integer player source whose drop saves and unloads it
---@param label? string
---@param ifSaved? boolean
---@return UgInventoryContainer? container nil when the database failed
function Store.Load(id, slots, maxWeight, owner, label, ifSaved)
    local loaded = containers[id]

    if loaded then
        loaded.owner = owner or loaded.owner
        return loaded
    end

    local ok, row = Repository.Single('SELECT `items` FROM `ug_inventories` WHERE `id` = ?', { id })

    if not ok then
        return nil
    end

    -- Another thread MAY have loaded it while the query ran.
    if containers[id] then
        return containers[id]
    end

    local persistent = row ~= nil or not ifSaved
    local container = new(id, slots, maxWeight, decode(id, row and row.items, slots), persistent, label, owner)

    containers[id] = container

    if persistent then
        cache:Put(id, container, owner)
    end

    return container
end

---Creates a temporary container that is never saved, such as a ground drop.
---@param id string
---@param slots integer
---@param maxWeight integer
---@param label? string
---@return UgInventoryContainer
function Store.Create(id, slots, maxWeight, label)
    local container = new(id, slots, maxWeight, {}, false, label, nil)

    containers[id] = container

    return container
end

---@return table<string, UgInventoryContainer> containers in memory. MUST NOT be changed.
function Store.All()
    return containers
end

---Saves and forgets a container. Runs the write in its own thread, so callers never wait.
---Temporary containers are forgotten with their items.
---@param id string
function Store.Unload(id)
    local container = containers[id]

    if not container then
        return
    end

    containers[id] = nil
    container.owner = nil

    if container.persistent then
        CreateThread(function()
            cache:Evict(id)
        end)
    end
end

---Starts or stops saving a loaded container. Stopping deletes the saved row. MUST run in a thread.
---@param id string
---@param persistent boolean
---@return boolean ok false when the database failed
function Store.SetPersistent(id, persistent)
    local container = containers[id]

    if not container or container.persistent == persistent then
        return true
    end

    container.persistent = persistent

    if persistent then
        cache:Put(id, container, container.owner)
        cache:MarkDirty(id)

        return cache:Flush(id)
    end

    cache:Flush(id)
    cache:Evict(id)

    return (Repository.Update('DELETE FROM `ug_inventories` WHERE `id` = ?', { id }))
end

---Forgets a container and deletes its saved row. MUST run in a thread.
---@param id string
---@return boolean ok
function Store.Delete(id)
    local container = containers[id]

    if container and container.persistent then
        cache:Flush(id)
        cache:Evict(id)
    end

    containers[id] = nil

    return (Repository.Update('DELETE FROM `ug_inventories` WHERE `id` = ?', { id }))
end

---Unloads saved containers nobody owns or views, idle for `idleMs`.
---@param now integer GetGameTimer ms
---@param idleMs integer
function Store.Sweep(now, idleMs)
    local idle = {}

    for id, container in pairs(containers) do
        if container.persistent and not container.owner and next(container.viewers) == nil and now - container.lastUsed >= idleMs then
            idle[#idle + 1] = id
        end
    end

    for _, id in ipairs(idle) do
        Store.Unload(id)
    end
end

---Forgets containers whose owner dropped. The cache saves and evicts them on its own.
---@param source integer
function Store.DropOwner(source)
    for id, container in pairs(containers) do
        if container.owner == source then
            containers[id] = nil
        end
    end
end

---Saves now, then returns the latest audit rows. MUST run in a thread.
---@param id string
---@param limit integer
---@return boolean ok
---@return table[]? rows newest first
function Store.GetLogs(id, limit)
    local container = containers[id]

    if container and container.persistent and not cache:Flush(id) then
        return false, nil
    end

    return Repository.Query(([[
        SELECT `item`, `amount`, `metadata`, `reason`, `related`, UNIX_TIMESTAMP(`created_at`) AS `createdAt`
        FROM `ug_item_logs` WHERE `inventory` = ? ORDER BY `id` DESC LIMIT %d
    ]]):format(limit), { id })
end

---@param name string
---@return integer
local function unitWeight(name)
    local definition = InternalItems.GetDefinition(name)

    return definition and definition.weight or 0
end

---@param item UgInventoryItem
---@return integer grams
function Store.ItemWeight(item)
    return unitWeight(item.name) * item.count
end

---@param container UgInventoryContainer
---@return integer grams
function Store.Weight(container)
    local total = 0

    for _, item in pairs(container.items) do
        total = total + unitWeight(item.name) * item.count
    end

    return total
end

---@param a any
---@param b any
---@return boolean
local function equal(a, b)
    if a == b then
        return true
    end

    if type(a) ~= 'table' or type(b) ~= 'table' then
        return false
    end

    for key, value in pairs(a) do
        if not equal(value, b[key]) then
            return false
        end
    end

    for key in pairs(b) do
        if a[key] == nil then
            return false
        end
    end

    return true
end

Store.Equal = equal

---True when every key of `filter` matches. A nil filter matches everything.
---@param metadata table?
---@param filter table?
---@return boolean
function Store.Matches(metadata, filter)
    if filter == nil then
        return true
    end

    for key, value in pairs(filter) do
        if not equal((metadata or {})[key], value) then
            return false
        end
    end

    return true
end

---True when units of `name` with `metadata` MAY join this stack, full or not.
---@param item UgInventoryItem
---@param name string
---@param metadata table?
---@return boolean
function Store.SameStack(item, name, metadata)
    local definition = InternalItems.GetDefinition(name)

    return definition ~= nil and definition.stack and item.name == name and equal(item.metadata, metadata)
end

---@param item UgInventoryItem?
---@param name string
---@param metadata table?
---@return integer space units this slot still takes, 0 when it cannot take the item
function Store.SpaceIn(item, name, metadata)
    local definition = InternalItems.GetDefinition(name)

    if not definition then
        return 0
    end

    if item == nil then
        return definition.maxStack
    end

    if item.name ~= name or not definition.stack or not equal(item.metadata, metadata) then
        return 0
    end

    return math.max(0, definition.maxStack - item.count)
end

---Where `count` units would go: existing stacks first, then empty slots, lowest slot first. All or nothing.
---@param container UgInventoryContainer
---@param name string
---@param count integer
---@param metadata table?
---@param slot? integer only this slot
---@param ignoreWeight? boolean for moves inside one inventory, which never change its weight
---@return table<integer, integer>? plan slot -> units, nil when they do not all fit
function Store.PlanAdd(container, name, count, metadata, slot, ignoreWeight)
    if not ignoreWeight and Store.Weight(container) + unitWeight(name) * count > container.maxWeight then
        return nil
    end

    local plan, left = {}, count

    if slot then
        if slot < 1 or slot > container.slots or Store.SpaceIn(container.items[slot], name, metadata) < count then
            return nil
        end

        plan[slot] = count

        return plan
    end

    for pass = 1, 2 do
        for index = 1, container.slots do
            local item = container.items[index]

            if left > 0 and ((pass == 1 and item ~= nil) or (pass == 2 and item == nil)) then
                local take = math.min(left, Store.SpaceIn(item, name, metadata))

                if take > 0 then
                    plan[index] = take
                    left = left - take
                end
            end
        end
    end

    return left == 0 and plan or nil
end

---Which stacks give `count` units of `name`, lowest slot first. All or nothing.
---@param container UgInventoryContainer
---@param name string
---@param count integer
---@param filter table?
---@return table<integer, integer>? plan slot -> units, nil when there are not enough
function Store.PlanRemove(container, name, count, filter)
    local plan, left = {}, count

    for index = 1, container.slots do
        local item = container.items[index]

        if left > 0 and item and item.name == name and Store.Matches(item.metadata, filter) then
            local take = math.min(left, item.count)

            plan[index] = take
            left = left - take
        end
    end

    return left == 0 and plan or nil
end

---Queues an audit row, written with the container.
---@param container UgInventoryContainer
---@param name string
---@param amount integer positive when added
---@param metadata table?
---@param reason string?
---@param related string? the other inventory of a move
function Store.Log(container, name, amount, metadata, reason, related)
    local row = {
        query = LOG_QUERY,
        values = { container.id, name, amount, metadata and json.encode(metadata) or '', reason or '', related or '' },
    }

    if container.persistent then
        container.logs[#container.logs + 1] = row
        return
    end

    -- Temporary containers have no save to join, so their rows are written on their own.
    CreateThread(function()
        Repository.Insert(row.query, row.values)
    end)
end

---@param container UgInventoryContainer
function Store.Touch(container)
    container.lastUsed = GetGameTimer()
end

---Marks the container for saving and tells the listener which slots changed.
---@param container UgInventoryContainer
---@param slots table<integer, boolean>
function Store.Changed(container, slots)
    container.lastUsed = GetGameTimer()

    if container.persistent then
        cache:MarkDirty(container.id)
    end

    if not listener then
        return
    end

    local changes = {}

    for slot in pairs(slots) do
        local item = container.items[slot]

        changes[#changes + 1] = { slot = slot, item = item and Utils.Table.DeepCopy(item) or nil }
    end

    table.sort(changes, function(a, b)
        return a.slot < b.slot
    end)

    listener(container, changes)
end
