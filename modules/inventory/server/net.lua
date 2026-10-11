--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---What clients may ask for, and what they see. Clients name inventories by reference, never by id:
---`player` is their own inventory, `other` the one they have open. Every callback replies `true` or an error code,
---except `InventoryOpen`, which replies the opened inventory.
---@class UgCore.Internal.InventoryNet
local Net = {}
UgCore.Internal.InventoryNet = Net

local Errors = UgCore.Enums.Errors
local Violations = UgCore.Enums.Violations
local Inventory = UgCore.Inventory
local InternalInventory = UgCore.Internal.Inventory
local Store = UgCore.Internal.InventoryStore
local Containers = UgCore.Internal.InventoryContainers
local Sessions = UgCore.Internal.InventorySessions

local SYNC_EVENT = 'ug-core:InventorySync'
local UPDATE_EVENT = 'ug-core:InventoryUpdate'
local PLAYER_REF = 'player'
local OTHER_REF = 'other'
local MAX_SLOT = 1000
local MAX_COUNT = 1000000
local KINDS = { 'stash', 'trunk', 'glovebox', 'drop' }

---Sends the whole player inventory, or nil when no character is loaded.
---@param source integer
function Net.Sync(source)
    local id = InternalInventory.GetPlayerId(source)
    local container = id and Store.Get(id)

    if not container then
        TriggerClientEvent(SYNC_EVENT, source, nil)
        return
    end

    TriggerClientEvent(SYNC_EVENT, source, Sessions.Describe(container))
end

---@param source integer
---@param ref string
---@return string? id nil when the player MAY NOT act on it
---@return boolean suspicious true when an honest client never sends this
local function access(source, ref)
    if ref == PLAYER_REF then
        return InternalInventory.GetPlayerId(source), false
    end

    if ref == OTHER_REF then
        local id, known = Sessions.Resolve(source)

        return id, not known
    end

    return nil, true
end

---@param ok boolean
---@param errorCode UgErrorCode?
---@return true|UgErrorCode
local function reply(ok, errorCode)
    return ok and true or errorCode or Errors.InternalError
end

---Empty drops leave once the current change is done.
---@param container UgInventoryContainer
local function checkDrop(container)
    if next(container.items) == nil and Containers.IsDrop(container.id) then
        SetTimeout(0, function()
            local current = Store.Get(container.id)

            if current and next(current.items) == nil then
                Containers.RemoveDrop(container.id, 'empty')
            end
        end)
    end
end

---@param ctx UgModuleContext
function Net.Init(ctx)
    local S = UgCore.Schema
    local REF = S.Enum({ PLAYER_REF, OTHER_REF })
    local SLOT = S.Integer({ min = 1, max = MAX_SLOT })
    local COUNT = S.Optional(S.Integer({ min = 1, max = MAX_COUNT }))
    local giveDistance = (ctx.config or {}).giveDistance or 3.0

    Store.OnChange(function(container, changes)
        if container.owner then
            TriggerClientEvent(UPDATE_EVENT, container.owner, PLAYER_REF, changes)
        end

        for viewer in pairs(container.viewers) do
            TriggerClientEvent(UPDATE_EVENT, viewer, OTHER_REF, changes)
        end

        checkDrop(container)
    end)

    UgCore.Callback.Register('InventoryRefresh', {
        schema = S.Define({}),
        rate = { max = 2, per = 5000 },
        requirePlayer = true,
    }, function(source)
        Net.Sync(source)
        return true
    end)

    UgCore.Callback.Register('InventoryOpen', {
        schema = S.Define({ S.Enum(KINDS), S.Optional(S.String({ min = 1, max = 64 })), S.Optional(S.Integer({ min = 1, max = 2147483647 })) }),
        rate = { max = 3, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, kind, name, netId)
        -- Stashes and drops are named, vehicles are network ids.
        local key = (kind == 'trunk' or kind == 'glovebox') and netId or name
        local container, reach, errorCode = Containers.Request(source, kind, key)

        if not container or not reach then
            return errorCode or Errors.NotFound
        end

        return Sessions.Open(source, container, reach) or Errors.NoPermission
    end)

    UgCore.Callback.Register('InventoryClose', {
        schema = S.Define({}),
        rate = { max = 5, per = 1000 },
        requirePlayer = true,
    }, function(source)
        Sessions.Close(source, false)
        return true
    end)

    UgCore.Callback.Register('InventoryMove', {
        schema = S.Define({ REF, SLOT, REF, SLOT, COUNT }),
        rate = { max = 10, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, fromRef, fromSlot, toRef, toSlot, count)
        local from, fromSuspicious = access(source, fromRef)
        local to, toSuspicious = access(source, toRef)

        if not from or not to then
            if fromSuspicious or toSuspicious then
                UgCore.Guard.Flag(source, Violations.NoPermission, 'inventory move without an open inventory')
            end

            return Errors.NoPermission
        end

        return reply(Inventory.Move(from, fromSlot, to, toSlot, count, from == to and nil or 'move'))
    end)

    UgCore.Callback.Register('InventoryUse', {
        schema = S.Define({ SLOT }),
        rate = { max = 4, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, slot)
        return reply(Inventory.Use(source, slot))
    end)

    UgCore.Callback.Register('InventoryGive', {
        schema = S.Define({ S.Integer({ min = 1, max = 65535 }), SLOT, COUNT }),
        rate = { max = 2, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, target, slot, count)
        local from, to = InternalInventory.GetPlayerId(source), InternalInventory.GetPlayerId(target)

        if target == source or not from or not to then
            return Errors.InvalidArgs
        end

        -- Both positions are read on the server. Latency MAY put honest players slightly out of range, so no flag.
        local ped = GetPlayerPed(tostring(target))

        if not ped or ped == 0 or not UgCore.Guard.IsNear(source, GetEntityCoords(ped), giveDistance) then
            return Errors.NoPermission
        end

        return reply(Inventory.Move(from, slot, to, nil, count, 'give'))
    end)

    UgCore.Callback.Register('InventoryDrop', {
        schema = S.Define({ SLOT, COUNT }),
        rate = { max = 3, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, slot, count)
        local from = InternalInventory.GetPlayerId(source)
        local ped = GetPlayerPed(tostring(source))

        if not from or not ped or ped == 0 then
            return Errors.NotLoaded
        end

        if not Inventory.GetSlot(from, slot) then
            return Errors.NotFound
        end

        local coords = GetEntityCoords(ped)
        local drop = Containers.FindDrop(coords)
        local created = false

        if not drop then
            local ok, id, errorCode = Inventory.CreateDrop(coords, nil, nil)

            if not ok or not id then
                return errorCode or Errors.InternalError
            end

            drop, created = id, true
        end

        local ok, errorCode = Inventory.Move(from, slot, drop, nil, count, 'drop')

        if not ok and created then
            Containers.RemoveDrop(drop, 'empty')
        end

        return reply(ok, errorCode)
    end)
end
