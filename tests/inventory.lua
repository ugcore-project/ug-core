--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { identifier: string, name: string, data: string }[]
local characters

---@type table<string, string> inventory id -> items JSON
local saved

---@type { inventory: string, item: string, amount: integer, metadata: string?, reason: string?, related: string? }[]
local logs

---In-memory characters, inventories and audit log.
---@param sql string
---@param params table?
---@return any
local function store(sql, params)
    local v = params or {}

    if sql:find('INSERT INTO `ug_characters`', 1, true) then
        characters[#characters + 1] = { identifier = v[1], name = v[2], data = v[3] }
        return { insertId = #characters, affectedRows = 1 }
    end

    if sql:find('SELECT COUNT(*)', 1, true) then
        return { { total = 0 } }
    end

    if sql:find('FROM `ug_characters` WHERE `id` = ? AND `identifier`', 1, true) then
        local row = characters[v[1]]

        return row and row.identifier == v[2] and { { id = v[1], name = row.name, data = row.data, createdAt = 0 } } or {}
    end

    if sql:find('INSERT INTO `ug_inventories`', 1, true) then
        saved[v[1]] = v[2]
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('FROM `ug_inventories`', 1, true) then
        return saved[v[1]] and { { items = saved[v[1]] } } or {}
    end

    if sql:find('INSERT INTO `ug_item_logs`', 1, true) then
        logs[#logs + 1] = {
            inventory = v[1], item = v[2], amount = v[3],
            metadata = v[4] ~= '' and v[4] or nil, reason = v[5] ~= '' and v[5] or nil, related = v[6] ~= '' and v[6] or nil,
        }
        return { insertId = #logs, affectedRows = 1 }
    end

    if sql:find('FROM `ug_item_logs`', 1, true) then
        local rows = {}

        for index = #logs, 1, -1 do
            local entry = logs[index]

            if entry.inventory == v[1] then
                rows[#rows + 1] = { item = entry.item, amount = entry.amount, metadata = entry.metadata, reason = entry.reason, related = entry.related, createdAt = 0 }
            end
        end

        return rows
    end
end

---@param inventoryConfig? string Lua source of config/inventory.lua
local function fresh(inventoryConfig)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'characters', 'items', 'inventory' } }
    H.Net.resources['ug-inventory'] = 'started'

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    if inventoryConfig then
        H.ResourceFiles['config/inventory.lua'] = inventoryConfig
    end

    characters, saved, logs = {}, {}, {}

    H.Capture(function()
        H.LoadManifest('server')
    end)

    H.Db.handler = store
end

---@param fn fun(): ...
---@return table
local function await(fn)
    local result

    H.Capture(function()
        H.Thread(function()
            result = table.pack(fn())
        end)
    end)

    return result
end

---Creates and loads a character for the player.
---@param source integer
---@return integer characterId
local function play(source)
    local id = await(function()
        return UgCore.Characters.Create(source, { name = 'P' .. source })
    end)[2]

    await(function()
        return UgCore.Characters.Load(source, id)
    end)

    return id
end

---@param target integer|string
---@return table<integer, string> slot -> "name x count"
local function layout(target)
    local result = {}

    for _, item in ipairs(UgCore.Inventory.GetItems(target)) do
        result[item.slot] = ('%s x%d'):format(item.name, item.count)
    end

    return result
end

-- Loading

H.Test('Loading a character loads an empty inventory and syncs it to its owner', function()
    fresh()

    local id = play(1)

    H.Equal(UgCore.Inventory.Get(1), { id = 'player:' .. id, slots = 40, maxWeight = 30000, weight = 0 })
    H.Equal(H.ClientEvents('ug-core:InventorySync')[1].args[1], { slots = 40, maxWeight = 30000, items = {} })
    H.Equal(UgCore.Inventory.Get(2), nil)
    H.Equal({ UgCore.Inventory.AddItem(2, 'water', 1) }, { false, 'not_loaded' })
end)

H.Test('Items survive unloading and loading the character', function()
    fresh()

    local id = play(1)

    UgCore.Inventory.AddItem(1, 'water', 3, nil, 'test')

    await(function() return UgCore.Characters.Unload(1) end)
    H.Capture(function() H.Advance(0) end)

    H.Equal(UgCore.Inventory.Get(1), nil)
    H.Assert(saved['player:' .. id] ~= nil, 'inventory not saved')

    await(function() return UgCore.Characters.Load(1, id) end)

    H.Equal(layout(1), { [1] = 'water x3' })
end)

-- Adding and removing

H.Test('AddItem fills stacks first, then empty slots, and stops at maxStack', function()
    fresh()
    play(1)

    H.Equal({ UgCore.Inventory.AddItem(1, 'water', 4) }, { true })
    H.Equal({ UgCore.Inventory.AddItem(1, 'water', 8) }, { true })

    H.Equal(layout(1), { [1] = 'water x10', [2] = 'water x2' })
    H.Equal(UgCore.Inventory.Count(1, 'water'), 12)
    H.Equal(UgCore.Inventory.Get(1).weight, 6000)
end)

H.Test('AddItem is all or nothing on weight, slots and unknown items', function()
    fresh('return { playerSlots = 2, playerWeight = 6000 }')
    play(1)

    H.Equal({ UgCore.Inventory.AddItem(1, 'water', 13) }, { false, 'cannot_carry' })
    H.Equal(layout(1), {})

    H.Equal({ UgCore.Inventory.AddItem(1, 'bread', 21) }, { false, 'cannot_carry' })
    H.Equal({ UgCore.Inventory.AddItem(1, 'gold', 1) }, { false, 'invalid_args' })
    H.Equal(UgCore.Inventory.CanCarry(1, 'water', 12), true)
    H.Equal(UgCore.Inventory.CanCarry(1, 'water', 13), false)

    H.Raises(function()
        UgCore.Inventory.AddItem(1, 'water', 0)
    end, 'count MUST be an integer')
end)

H.Test('Different metadata never stacks, and empty metadata counts as none', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 1, { brand = 'a' })
    UgCore.Inventory.AddItem(1, 'water', 1, { brand = 'b' })
    UgCore.Inventory.AddItem(1, 'water', 1, {})
    UgCore.Inventory.AddItem(1, 'water', 1)

    H.Equal(layout(1), { [1] = 'water x1', [2] = 'water x1', [3] = 'water x2' })
    H.Equal(UgCore.Inventory.Count(1, 'water', { brand = 'b' }), 1)
    H.Equal(UgCore.Inventory.GetSlot(1, 2).metadata, { brand = 'b' })
end)

H.Test('Non-stackable items take one slot each', function()
    fresh()
    UgCore.Items.Register('radio', { label = 'Radio', weight = 300, stack = false })
    play(1)

    UgCore.Inventory.AddItem(1, 'radio', 3)

    H.Equal(layout(1), { [1] = 'radio x1', [2] = 'radio x1', [3] = 'radio x1' })
end)

H.Test('RemoveItem takes from the lowest slots and filters by metadata', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 12)
    UgCore.Inventory.AddItem(1, 'water', 2, { brand = 'a' })

    H.Equal({ UgCore.Inventory.RemoveItem(1, 'water', 11) }, { true })
    H.Equal(layout(1), { [2] = 'water x1', [3] = 'water x2' })

    H.Equal({ UgCore.Inventory.RemoveItem(1, 'water', 2, { brand = 'a' }) }, { true })
    H.Equal({ UgCore.Inventory.RemoveItem(1, 'water', 5) }, { false, 'insufficient_items' })
    H.Equal(layout(1), { [2] = 'water x1' })
end)

H.Test('Events report every added and removed item', function()
    fresh()
    play(1)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Inventory.ItemAdded, function(id, name, count, metadata, reason)
        seen[#seen + 1] = { 'added', name, count, reason }
    end)

    UgCore.Events.On(UgCore.Enums.Events.Inventory.ItemRemoved, function(id, name, count, metadata, reason)
        seen[#seen + 1] = { 'removed', name, count, reason }
    end)

    UgCore.Inventory.AddItem(1, 'bread', 2, nil, 'shop')
    UgCore.Inventory.RemoveFromSlot(1, 1, 1, 'eat')

    H.Equal(seen, { { 'added', 'bread', 2, 'shop' }, { 'removed', 'bread', 1, 'eat' } })
end)

H.Test('Hooks can cancel adding, removing and moving', function()
    fresh()
    play(1)

    local Hooks = UgCore.Enums.Hooks.Inventory

    UgCore.Inventory.AddItem(1, 'water', 2)

    UgCore.Hooks.Register(Hooks.BeforeAdd, function(payload) return payload.name ~= 'bread' end)
    UgCore.Hooks.Register(Hooks.BeforeRemove, function() return false end)
    UgCore.Hooks.Register(Hooks.BeforeMove, function() return false end)

    H.Equal({ UgCore.Inventory.AddItem(1, 'bread', 1) }, { false, 'no_permission' })
    H.Equal({ UgCore.Inventory.RemoveItem(1, 'water', 1) }, { false, 'no_permission' })
    H.Equal({ UgCore.Inventory.Move(1, 1, 1, 5) }, { false, 'no_permission' })
    H.Equal(layout(1), { [1] = 'water x2' })
end)

-- Moving

H.Test('Move splits, merges and swaps inside one inventory', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 6)
    UgCore.Inventory.AddItem(1, 'bread', 1)

    H.Equal({ UgCore.Inventory.Move(1, 1, 1, 5, 2) }, { true })
    H.Equal(layout(1), { [1] = 'water x4', [2] = 'bread x1', [5] = 'water x2' })

    H.Equal({ UgCore.Inventory.Move(1, 5, 1, 1) }, { true })
    H.Equal(layout(1), { [1] = 'water x6', [2] = 'bread x1' })

    H.Equal({ UgCore.Inventory.Move(1, 1, 1, 2) }, { true })
    H.Equal(layout(1), { [1] = 'bread x1', [2] = 'water x6' })

    H.Equal({ UgCore.Inventory.Move(1, 2, 1, 1, 3) }, { false, 'invalid_args' })
    H.Equal({ UgCore.Inventory.Move(1, 9, 1, 1) }, { false, 'not_found' })
    H.Equal({ UgCore.Inventory.Move(1, 1, 1, 41) }, { false, 'invalid_args' })
end)

H.Test('Merging past maxStack fails without changes', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 15)

    H.Equal({ UgCore.Inventory.Move(1, 2, 1, 1) }, { false, 'cannot_carry' })
    H.Equal(layout(1), { [1] = 'water x10', [2] = 'water x5' })
end)

H.Test('Moving between inventories checks the target weight and logs both sides', function()
    fresh('return { playerWeight = 1000 }')
    local first, second = play(1), play(2)

    UgCore.Inventory.AddItem(1, 'water', 2)
    UgCore.Inventory.AddItem(2, 'water', 1)

    H.Equal({ UgCore.Inventory.Move(1, 1, 2, nil, 2) }, { false, 'cannot_carry' })
    H.Equal({ UgCore.Inventory.Move(1, 1, 2, nil, 1, 'give') }, { true })
    H.Equal(layout(2), { [1] = 'water x2' })

    local ok, entries = table.unpack(await(function() return UgCore.Inventory.GetLog(2) end))

    H.Equal(ok, true)
    H.Equal(entries[1].related, 'player:' .. first)
    H.Equal(entries[1].reason, 'give')
    H.Equal(entries[1].amount, 1)
    H.Equal(UgCore.Inventory.GetSource('player:' .. second), 2)
end)

-- Audit log

H.Test('The audit log is written with the inventory, and retried when the write fails', function()
    fresh()
    local id = play(1)

    UgCore.Inventory.AddItem(1, 'bread', 2, nil, 'shop')
    UgCore.Inventory.RemoveItem(1, 'bread', 1, nil, 'eat')

    H.Equal(#logs, 0)

    H.Db.fail = 'ug_item_logs'
    H.Equal(await(function() return UgCore.Inventory.GetLog(1) end)[3], 'internal_error')
    H.Db.fail = nil

    local ok, entries = table.unpack(await(function() return UgCore.Inventory.GetLog(1, 5) end))

    H.Equal(ok, true)
    H.Equal({ entries[1].amount, entries[1].reason, entries[2].amount, entries[2].reason }, { -1, 'eat', 2, 'shop' })
    H.Equal(#logs, 2)
    H.Assert(saved['player:' .. id]:find('"count":1', 1, true) ~= nil, saved['player:' .. id])
end)

H.Test('SetMetadata replaces a slot and logs it with amount 0', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 1)

    H.Equal({ UgCore.Inventory.SetMetadata(1, 1, { brand = 'x' }, 'label') }, { true })
    H.Equal(UgCore.Inventory.GetSlot(1, 1).metadata, { brand = 'x' })
    H.Equal({ UgCore.Inventory.SetMetadata(1, 2, {}) }, { false, 'not_found' })

    local entries = await(function() return UgCore.Inventory.GetLog(1) end)[2]

    H.Equal({ entries[1].amount, entries[1].metadata }, { 0, { brand = 'x' } })
end)

-- Using

H.Test('Use runs the handler with a copy, then consumes', function()
    fresh()
    play(1)

    local calls = {}

    UgCore.Items.RegisterUse('bread', function(source, item)
        calls[#calls + 1] = { source, item.slot, item.name, item.count }
        item.count = 999
        return true
    end, { consume = 1 })

    UgCore.Inventory.AddItem(1, 'bread', 2)

    local used = {}

    UgCore.Events.On(UgCore.Enums.Events.Items.Used, function(source, name, slot)
        used[#used + 1] = { source, name, slot }
    end)

    H.Equal({ UgCore.Inventory.Use(1, 1) }, { true })
    H.Equal(calls, { { 1, 1, 'bread', 2 } })
    H.Equal(layout(1), { [1] = 'bread x1' })
    H.Equal(used, { { 1, 'bread', 1 } })
end)

H.Test('Use refuses unusable items, cooldowns, declined handlers and errors', function()
    fresh()
    play(1)

    local accept = true

    UgCore.Items.RegisterUse('bread', function() return accept end, { consume = 1, cooldown = 1000 })
    UgCore.Items.RegisterUse('bandage', function() error('boom') end)
    UgCore.Inventory.AddItem(1, 'bread', 5)
    UgCore.Inventory.AddItem(1, 'water', 1)
    UgCore.Inventory.AddItem(1, 'bandage', 1)

    H.Equal({ UgCore.Inventory.Use(1, 2) }, { false, 'invalid_args' })
    H.Equal({ UgCore.Inventory.Use(1, 9) }, { false, 'not_found' })

    H.Equal({ UgCore.Inventory.Use(1, 1) }, { true })
    H.Equal({ UgCore.Inventory.Use(1, 1) }, { false, 'rate_limited' })

    H.Advance(1000)
    accept = false
    H.Equal({ UgCore.Inventory.Use(1, 1) }, { false, 'no_permission' })
    H.Equal(UgCore.Inventory.Count(1, 'bread'), 4)

    local lines = H.Capture(function()
        H.Equal({ UgCore.Inventory.Use(1, 3) }, { false, 'internal_error' })
    end)

    H.Equal(#lines, 1)
end)

H.Test('Items:BeforeUse can cancel', function()
    fresh()
    play(1)

    UgCore.Items.RegisterUse('bread', function() return true end, { consume = 1 })
    UgCore.Hooks.Register(UgCore.Enums.Hooks.Items.BeforeUse, function() return false end)
    UgCore.Inventory.AddItem(1, 'bread', 1)

    H.Equal({ UgCore.Inventory.Use(1, 1) }, { false, 'no_permission' })
    H.Equal(UgCore.Inventory.Count(1, 'bread'), 1)
end)

-- Respawn

H.Test('clearOnRespawn empties the inventory except keepOnRespawn items', function()
    fresh('return { clearOnRespawn = true }')
    H.ResourceFiles['config/items.lua'] = [[return {
        water = { label = 'Water', weight = 1 },
        phone = { label = 'Phone', weight = 1, keepOnRespawn = true },
    }]]
    H.Capture(function() H.LoadManifest('server') end)
    H.Db.handler = store
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 3)
    UgCore.Inventory.AddItem(1, 'phone', 1)
    UgCore.Events.Emit(UgCore.Enums.Events.Players.Respawned, 1, vector4(0, 0, 0, 0))

    H.Equal(layout(1), { [2] = 'phone x1' })
end)

H.Test('Items stay on respawn by default', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 3)
    UgCore.Events.Emit(UgCore.Enums.Events.Players.Respawned, 1, vector4(0, 0, 0, 0))

    H.Equal(layout(1), { [1] = 'water x3' })
end)

-- Protocol

---@param name string
---@param source integer
---@param ... any
---@return any value the callback reply
local function ask(name, source, ...)
    local args = table.pack(...)

    H.Net.client = {}
    H.Capture(function()
        H.TriggerNetEvent('__ugcb:ug-core:' .. name, source, 'ug-inventory', 1, table.unpack(args, 1, args.n))
    end)

    local reply = H.ClientEvents('__ugcb:res:ug-inventory')[1]

    return reply and reply.args[3]
end

H.Test('Clients move within their own inventory by reference', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 4)

    H.Equal(ask('InventoryMove', 1, 'player', 1, 'player', 3, 1), true)
    H.Equal(layout(1), { [1] = 'water x3', [3] = 'water x1' })
    H.Equal(ask('InventoryMove', 1, 'player', 7, 'player', 3), 'not_found')
end)

H.Test('Inventory ids and unopened inventories are refused and flagged', function()
    fresh()
    play(1)

    local Violations, Weights = UgCore.Enums.Violations, UgCore.Enums.ViolationWeights

    H.Equal(ask('InventoryMove', 1, 'player', 1, 'player:2', 1), 'invalid_args')
    H.Equal(UgCore.Guard.GetScore(1), Weights[Violations.InvalidPayload])

    H.Equal(ask('InventoryMove', 1, 'player', 1, 'other', 1), 'no_permission')
    H.Equal(UgCore.Guard.GetScore(1), Weights[Violations.InvalidPayload] + Weights[Violations.NoPermission])
end)

H.Test('Clients use items through the server', function()
    fresh()
    play(1)

    UgCore.Items.RegisterUse('bread', function() return true end, { consume = 1 })
    UgCore.Inventory.AddItem(1, 'bread', 2)

    H.Equal(ask('InventoryUse', 1, 1), true)
    H.Equal(UgCore.Inventory.Count(1, 'bread'), 1)
end)

H.Test('Giving needs a nearby, loaded player', function()
    fresh()
    play(1)
    play(2)

    UgCore.Inventory.AddItem(1, 'water', 3)
    H.Net.peds[1], H.Net.peds[2] = 101, 102
    H.Net.coords[101], H.Net.coords[102] = vector3(0, 0, 0), vector3(10, 0, 0)

    H.Equal(ask('InventoryGive', 1, 2, 1, 1), 'no_permission')

    H.Net.coords[102] = vector3(2, 0, 0)

    H.Equal(ask('InventoryGive', 1, 2, 1, 1), true)
    H.Advance(1000)
    H.Equal(ask('InventoryGive', 1, 1, 1, 1), 'invalid_args')
    H.Equal(ask('InventoryGive', 1, 3, 1, 1), 'invalid_args')
    H.Equal(UgCore.Inventory.Count(2, 'water'), 1)
    H.Equal(UgCore.Inventory.Count(1, 'water'), 2)
end)

H.Test('Owners get slot updates', function()
    fresh()
    play(1)

    H.Net.client = {}
    UgCore.Inventory.AddItem(1, 'water', 2)

    H.Equal(H.ClientEvents('ug-core:InventoryUpdate')[1], {
        name = 'ug-core:InventoryUpdate',
        target = 1,
        args = { n = 2, 'player', { { slot = 1, item = { name = 'water', count = 2 } } } },
    })
end)

H.Test('Clients keep their inventory from server events', function()
    fresh()

    local definitions = GlobalState['ug-core:Items']

    H.Capture(function()
        H.LoadManifest('client')
    end)
    H.SetGlobalState('ug-core:Items', definitions)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Inventory.Changed, function(changes)
        seen[#seen + 1] = changes or 'all'
    end)

    H.Capture(function()
        H.TriggerNetEvent('ug-core:InventorySync', nil, { slots = 5, maxWeight = 1000, items = { { slot = 2, name = 'water', count = 1 } } })
        H.TriggerNetEvent('ug-core:InventoryUpdate', nil, 'player', { { slot = 2, item = { name = 'water', count = 3 } }, { slot = 4, item = { name = 'bread', count = 1 } } })
        H.TriggerNetEvent('ug-core:InventoryUpdate', nil, 'player', { { slot = 4 } })
    end)

    H.Equal(UgCore.Inventory.GetItems(), { { slot = 2, name = 'water', count = 3 } })
    H.Equal(UgCore.Inventory.Count('water'), 3)
    H.Equal(UgCore.Inventory.HasItem('bread'), false)
    H.Equal(UgCore.Inventory.GetWeight(), 1500)
    H.Equal(UgCore.Inventory.GetMaxWeight(), 1000)
    H.Equal(#seen, 3)
    H.Equal(seen[1], 'all')
    H.Equal(seen[3], { { slot = 4 } })

    H.Capture(function()
        H.TriggerNetEvent('ug-core:InventorySync', nil, nil)
    end)

    H.Equal(UgCore.Inventory.IsLoaded(), false)
end)

-- Player object and console

H.Test('Player objects manage items', function()
    fresh()
    play(1)

    local player = assert(UgCore.Players.Get(1))

    H.Equal({ player:AddItem('water', 2) }, { true })
    H.Equal(player:GetItemCount('water'), 2)
    H.Equal(player:HasItem('water', 3), false)
    H.Equal(player:CanCarry('water', 1), true)
    H.Equal({ player:RemoveItem('water', 1) }, { true })
    H.Equal(#player:GetItems(), 1)
end)

H.Test('ug inventory lists a player inventory', function()
    fresh()
    local id = play(1)

    UgCore.Inventory.AddItem(1, 'water', 2, { brand = 'a' })

    H.Equal(H.RunCommand('ug', 0, { 'inventory', '1' }), {
        ('player:%d: 1000/30000 g, 40 slots'):format(id),
        '    1  water                    x2      {"brand":"a"}',
    })
    H.Equal(H.RunCommand('ug', 0, { 'inventory', '9' }), { 'No loaded inventory for 9.' })
end)

H.Done()
