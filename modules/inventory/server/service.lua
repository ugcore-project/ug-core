--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Moves, use, the audit log and the character lifecycle of player inventories.
---@class UgCore.Inventory
local Inventory = UgCore.Inventory

---@class UgCore.Internal.Inventory
local InternalInventory = UgCore.Internal.Inventory

local Logger = UgCore.Logger
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local InternalHooks = UgCore.Internal.Hooks
local InternalItems = UgCore.Internal.Items
local Store = UgCore.Internal.InventoryStore
local InventoryEvents = UgCore.Enums.Events.Inventory
local InventoryHooks = UgCore.Enums.Hooks.Inventory
local ItemEvents = UgCore.Enums.Events.Items
local ItemHooks = UgCore.Enums.Hooks.Items
local Utils = UgCore.Internal.Utils

local resolve = InternalInventory.Resolve
local checkCount = InternalInventory.CheckCount
local checkReason = InternalInventory.CheckReason
local checkSlot = InternalInventory.CheckSlot
local slotCopy = InternalInventory.SlotCopy
local applyAdd = InternalInventory.ApplyAdd
local applyRemove = InternalInventory.ApplyRemove

local MAX_LOG = 100
local DEFAULT_LOG = 25

---@type UgModuleContext?
local context = nil

---@type table<integer, table<string, integer>> source -> item -> last use, GetGameTimer ms
local lastUse = {}

---@param characterId integer
---@return string
local function playerId(characterId)
    return 'player:' .. characterId
end

---Moves units between slots of one or two inventories. A full stack swaps with a different item.
---Without `toSlot`, the units go where `AddItem` would put them.
---@param from integer|string player source or inventory id
---@param fromSlot integer
---@param to integer|string player source or inventory id
---@param toSlot? integer
---@param count? integer defaults to the whole stack
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode `not_found`, `cannot_carry`, `invalid_args`, `no_permission`
function Inventory.Move(from, fromSlot, to, toSlot, count, reason)
    checkSlot(fromSlot, 'Move')
    checkReason(reason, 'Move')

    if toSlot ~= nil then
        checkSlot(toSlot, 'Move')
    end

    if count ~= nil then
        checkCount(count, 'Move')
    end

    local source, errorCode = resolve(from, 'Move')

    if not source then
        return false, errorCode
    end

    local target
    target, errorCode = resolve(to, 'Move')

    if not target then
        return false, errorCode
    end

    local item = source.items[fromSlot]

    if not item then
        return false, Errors.NotFound
    end

    count = count or item.count

    if count > item.count or (toSlot and toSlot > target.slots) then
        return false, Errors.InvalidArgs
    end

    if source == target and toSlot == fromSlot then
        return true, nil
    end

    local payload = { from = source.id, fromSlot = fromSlot, to = target.id, toSlot = toSlot, count = count, reason = reason }

    if not InternalHooks.Run(InventoryHooks.BeforeMove, payload) then
        return false, Errors.NoPermission
    end

    item = source.items[fromSlot]

    if not item or count > item.count then
        return false, Errors.NotFound
    end

    local name, metadata = item.name, item.metadata
    local other = toSlot and target.items[toSlot] or nil
    local sourceChanged, targetChanged = {}, {}

    if other and toSlot and not Store.SameStack(other, name, metadata) then
        -- Different items: only whole stacks swap.
        if count ~= item.count then
            return false, Errors.InvalidArgs
        end

        if source ~= target then
            local sourceWeight = Store.Weight(source) - Store.ItemWeight(item) + Store.ItemWeight(other)
            local targetWeight = Store.Weight(target) - Store.ItemWeight(other) + Store.ItemWeight(item)

            if sourceWeight > source.maxWeight or targetWeight > target.maxWeight then
                return false, Errors.CannotCarry
            end

            Store.Log(source, name, -item.count, metadata, reason, target.id)
            Store.Log(target, name, item.count, metadata, reason, source.id)
            Store.Log(target, other.name, -other.count, other.metadata, reason, source.id)
            Store.Log(source, other.name, other.count, other.metadata, reason, target.id)
        end

        source.items[fromSlot], target.items[toSlot] = other, item
        sourceChanged[fromSlot], targetChanged[toSlot] = true, true
    else
        local plan

        if source == target then
            -- Weight does not change inside one inventory.
            local free = toSlot and Store.SpaceIn(other, name, metadata) or 0

            plan = toSlot and free >= count and { [toSlot] = count } or nil

            if not toSlot then
                -- Planned as if the units already left their slot. Nothing yields in between.
                local saved = source.items[fromSlot]

                source.items[fromSlot] = count < saved.count and { name = name, count = saved.count - count, metadata = metadata } or nil
                plan = Store.PlanAdd(source, name, count, metadata, nil, true)
                source.items[fromSlot] = saved
            end
        else
            plan = Store.PlanAdd(target, name, count, metadata, toSlot)
        end

        if not plan then
            return false, Errors.CannotCarry
        end

        applyRemove(source, { [fromSlot] = count }, sourceChanged)
        applyAdd(target, name, metadata, plan, targetChanged)

        if source ~= target then
            Store.Log(source, name, -count, metadata, reason, target.id)
            Store.Log(target, name, count, metadata, reason, source.id)
        end
    end

    if source == target then
        for slot in pairs(targetChanged) do
            sourceChanged[slot] = true
        end

        Store.Changed(source, sourceChanged)
    else
        Store.Changed(source, sourceChanged)
        Store.Changed(target, targetChanged)
    end

    return true, nil
end


---Latest audit rows, newest first. Saves the inventory first, so the log is complete. MUST run in a thread.
---@param target integer|string player source or inventory id
---@param limit? integer 1 to 100, defaults to 25
---@return boolean ok
---@return UgItemLogEntry[]? entries
---@return UgErrorCode? errorCode
function Inventory.GetLog(target, limit)
    if limit ~= nil and (math.type(limit) ~= 'integer' or limit < 1 or limit > MAX_LOG) then
        Utils.Raise(2, 'Inventory.GetLog: limit MUST be an integer from 1 to %d', MAX_LOG)
    end

    ---@type string?
    local id = nil

    if math.type(target) == 'integer' then
        id = InternalInventory.GetPlayerId(target --[[@as integer]])

        if not id then
            return false, nil, Errors.NotLoaded
        end
    elseif Store.IsId(target) then
        id = target --[[@as string]]
    else
        Utils.Raise(2, 'Inventory.GetLog expects a player source or an inventory id such as "player:12"')
    end

    ---@cast id string
    local ok, rows = Store.GetLogs(id, limit or DEFAULT_LOG)

    if not ok or not rows then
        return false, nil, Errors.InternalError
    end

    local entries = {}

    for index, row in ipairs(rows) do
        local metadata = nil

        if type(row.metadata) == 'string' then
            local decoded, value = pcall(json.decode, row.metadata)
            metadata = decoded and type(value) == 'table' and value or nil
        end

        entries[index] = {
            item = row.item,
            amount = math.tointeger(row.amount) or 0,
            metadata = metadata,
            reason = row.reason,
            related = row.related,
            createdAt = math.tointeger(row.createdAt) or 0,
        }
    end

    return true, entries, nil
end

---Uses the item in a slot of the player's inventory: checks, then the registered handler, then consumption.
---@param source integer
---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_loaded`, `not_found`, `invalid_args` when not usable, `rate_limited` during cooldown, `no_permission`
function Inventory.Use(source, slot)
    checkSlot(slot, 'Use')

    local container, errorCode = resolve(source, 'Use')

    if not container then
        return false, errorCode
    end

    local item = container.items[slot]

    if not item then
        return false, Errors.NotFound
    end

    local use = InternalItems.GetUse(item.name)

    if not use then
        return false, Errors.InvalidArgs
    end

    if use.options.requireAlive and (UgCore.Players.IsDead(source) or UgCore.Players.IsDowned(source)) then
        return false, Errors.NoPermission
    end

    local now = GetGameTimer()
    local used = lastUse[source] and lastUse[source][item.name]

    if used and now - used < use.options.cooldown then
        return false, Errors.RateLimited
    end

    local copy = slotCopy(container, slot)

    if not InternalHooks.Run(ItemHooks.BeforeUse, { source = source, name = copy.name, slot = slot, metadata = copy.metadata }) then
        return false, Errors.NoPermission
    end

    local called, result = pcall(use.handler, source, copy)

    if not called then
        Logger.Error('Items: use of %s failed: %s', copy.name, tostring(result))
        return false, Errors.InternalError
    end

    if result == false then
        return false, Errors.NoPermission
    end

    lastUse[source] = lastUse[source] or {}
    lastUse[source][copy.name] = now

    local consume = use.options.consume or 0
    local current = container.items[slot]

    if consume > 0 and current and current.name == copy.name and Store.Equal(current.metadata, copy.metadata) then
        local changed = {}
        local units = math.min(consume, current.count)

        applyRemove(container, { [slot] = units }, changed)
        Store.Log(container, copy.name, -units, copy.metadata, 'use', nil)
        Store.Changed(container, changed)
        Events.Emit(InventoryEvents.ItemRemoved, container.id, copy.name, units, copy.metadata, 'use')
    end

    Events.Emit(ItemEvents.Used, source, copy.name, slot, copy.metadata)

    return true, nil
end

---@return UgModuleContext?
function InternalInventory.GetContext()
    return context
end

---@param ctx UgModuleContext
function InternalInventory.Init(ctx)
    context = ctx

    local config = ctx.config or {}

    UgCore.Internal.Characters.Participate({
        load = function(source, characterId)
            local container = Store.Load(playerId(characterId), config.playerSlots, config.playerWeight, source)

            if not container then
                return false
            end

            InternalInventory.SetPlayerId(source, container.id)
            UgCore.Internal.InventoryNet.Sync(source)

            return true
        end,
        unload = function(source, characterId)
            InternalInventory.SetPlayerId(source, nil)
            lastUse[source] = nil
            UgCore.Internal.InventorySessions.Close(source, true)
            UgCore.Internal.InventorySessions.CloseAll(playerId(characterId))
            Store.Unload(playerId(characterId))
            UgCore.Internal.InventoryNet.Sync(source)
        end,
    })

    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        if dropped then
            InternalInventory.SetPlayerId(dropped, nil)
            lastUse[dropped] = nil
            Store.DropOwner(dropped)
        end
    end)

    UgCore.Events.On(UgCore.Enums.Events.Players.Respawned, function(respawned)
        local id = config.clearOnRespawn and InternalInventory.GetPlayerId(respawned)
        local container = id and Store.Get(id)

        if not container or not InternalHooks.Run(InventoryHooks.BeforeClearOnRespawn, { source = respawned }) then
            return
        end

        InternalInventory.Clear(container, 'respawn', function(item)
            local definition = InternalItems.GetDefinition(item.name)

            return definition ~= nil and definition.keepOnRespawn
        end)
    end)
end
