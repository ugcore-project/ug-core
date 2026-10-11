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

---@type { inventory: string, item: string, amount: integer, reason: string? }[]
local logs

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

    if sql:find('DELETE FROM `ug_inventories`', 1, true) then
        local existed = saved[v[1]] ~= nil

        saved[v[1]] = nil
        return { insertId = 0, affectedRows = existed and 1 or 0 }
    end

    if sql:find('FROM `ug_inventories`', 1, true) then
        return saved[v[1]] and { { items = saved[v[1]] } } or {}
    end

    if sql:find('INSERT INTO `ug_item_logs`', 1, true) then
        logs[#logs + 1] = { inventory = v[1], item = v[2], amount = v[3], reason = v[5] ~= '' and v[5] or nil }
        return { insertId = #logs, affectedRows = 1 }
    end
end

local POLICE = vector3(100, 0, 0)

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.ResetAces()
    H.Aces = { ['resource.ug-core:command.add_ace'] = true }
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'permissions', 'characters', 'items', 'inventory' } }
    H.Net.resources['ug-inventory'] = 'started'
    H.ResourceFiles['config/inventory.lua'] = [[return {
        stashes = {
            armory = { label = 'Armory', slots = 10, weight = 50000, coords = vector3(100, 0, 0), groups = { 'admin' } },
            locker = { label = 'Locker', slots = 5, weight = 10000, coords = vector3(100, 0, 0), personal = true },
            safe = { label = 'Safe', slots = 5, weight = 10000 },
        },
    }]]

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
        H.Net.peds[source] = 100 + source
        H.Net.coords[100 + source] = vector3(0, 0, 0)
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

---@param source integer
---@param coords vector3
local function place(source, coords)
    H.Net.coords[100 + source] = coords
end

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

---@param target integer|string
---@return table<integer, string>
local function layout(target)
    local result = {}

    for _, item in ipairs(UgCore.Inventory.GetItems(target)) do
        result[item.slot] = ('%s x%d'):format(item.name, item.count)
    end

    return result
end

---@param seconds integer
local function wait(seconds)
    H.Capture(function()
        for _ = 1, seconds do
            H.Advance(1000)
        end
    end)
end

-- Stashes

H.Test('Opening a stash checks access and distance on the server', function()
    fresh()
    play(1)

    H.Equal(ask('InventoryOpen', 1, 'stash', 'armory'), 'no_permission')

    await(function() return UgCore.Permissions.AddGroup(1, 'admin') end)
    H.Equal(ask('InventoryOpen', 1, 'stash', 'armory'), 'no_permission')

    place(1, POLICE)

    H.Equal(ask('InventoryOpen', 1, 'stash', 'armory'), { label = 'Armory', slots = 10, maxWeight = 50000, items = {} })
    H.Equal(UgCore.Inventory.GetOpen(1), 'stash:armory')
    wait(1)
    H.Equal(ask('InventoryOpen', 1, 'stash', 'missing'), 'not_found')
    H.Equal(ask('InventoryOpen', 1, 'stash', 'safe'), 'no_permission')
end)

H.Test('Players move items into an open stash, and it is saved', function()
    fresh()
    play(1)
    place(1, POLICE)
    await(function() return UgCore.Permissions.AddGroup(1, 'admin') end)

    UgCore.Inventory.AddItem(1, 'water', 3)
    ask('InventoryOpen', 1, 'stash', 'armory')

    H.Equal(ask('InventoryMove', 1, 'player', 1, 'other', 4, 2), true)
    H.Equal(layout('stash:armory'), { [4] = 'water x2' })
    H.Equal(H.ClientEvents('ug-core:InventoryUpdate')[2].args[1], 'other')

    wait(30)

    H.Assert(saved['stash:armory'] ~= nil, 'stash not saved')

    -- Each inventory saves its rows in its own transaction. Which one flushes first is not defined.
    local rows = {}

    for _, row in ipairs(logs) do
        rows[row.inventory] = { item = row.item, amount = row.amount }
    end

    H.Equal(rows, {
        ['player:1'] = { item = 'water', amount = -2 },
        ['stash:armory'] = { item = 'water', amount = 2 },
    })
end)

H.Test('Walking away closes the stash without a flag', function()
    fresh()
    play(1)
    place(1, POLICE)

    UgCore.Inventory.AddItem(1, 'water', 1)
    ask('InventoryOpen', 1, 'stash', 'locker')
    place(1, vector3(0, 0, 0))

    H.Equal(ask('InventoryMove', 1, 'player', 1, 'other', 1), 'no_permission')
    H.Equal(#H.ClientEvents('ug-core:InventoryClosed'), 1)
    H.Equal(UgCore.Inventory.GetOpen(1), nil)
    H.Equal(UgCore.Guard.GetScore(1), 0)
end)

H.Test('Personal stashes have one inventory per character', function()
    fresh()
    local first, second = play(1), play(2)

    place(1, POLICE)
    place(2, POLICE)
    ask('InventoryOpen', 1, 'stash', 'locker')
    ask('InventoryOpen', 2, 'stash', 'locker')

    H.Equal(UgCore.Inventory.GetOpen(1), 'stash:locker:' .. first)
    H.Equal(UgCore.Inventory.GetOpen(2), 'stash:locker:' .. second)
    H.Equal(UgCore.Inventory.GetStashId('locker', 1), 'stash:locker:' .. first)
    H.Equal(UgCore.Inventory.GetStashId('armory'), 'stash:armory')
end)

H.Test('Resources register stashes with their own check, removed when they stop', function()
    fresh()
    play(1)

    local Housing = H.LoadImport('ug-housing', 'server').UgCore
    local owner = 2

    Housing.Inventory.RegisterStash('house_1', {
        label = 'House', slots = 5, weight = 10000, coords = vector3(0, 0, 0),
        check = function(source) return source == owner end,
    })

    H.Equal(ask('InventoryOpen', 1, 'stash', 'house_1'), 'no_permission')
    owner = 1
    H.Equal(type(ask('InventoryOpen', 1, 'stash', 'house_1')), 'table')
    H.Equal(UgCore.Inventory.GetStash('house_1').resource, 'ug-housing')

    H.Raises(function()
        UgCore.Inventory.RegisterStash('armory', { label = 'X', slots = 1, weight = 1 })
    end, '"armory" is defined in config/inventory.lua')

    H.Raises(function()
        UgCore.Inventory.RegisterStash('bad', { label = 'X', slots = 0, weight = 1 })
    end, 'stash "bad" slots MUST be an integer')

    H.TriggerEvent('onResourceStop', nil, 'ug-housing')

    H.Equal(UgCore.Inventory.GetStash('house_1'), nil)
end)

H.Test('Server code opens any inventory for a player, after BeforeOpen', function()
    fresh()
    play(1)

    H.Equal(await(function() return UgCore.Inventory.Open(1, 'stash:safe') end), { n = 2, true })
    H.Equal(H.ClientEvents('ug-core:InventoryOpened')[1].args[1].label, 'Safe')
    H.Equal(ask('InventoryMove', 1, 'other', 1, 'player', 1), 'not_found')

    UgCore.Hooks.Register(UgCore.Enums.Hooks.Inventory.BeforeOpen, function() return false end)

    H.Equal(await(function() return UgCore.Inventory.Open(1, 'stash:armory') end), { n = 2, false, 'no_permission' })
    H.Equal(await(function() return UgCore.Inventory.Open(1, 'stash:nope') end), { n = 2, false, 'not_found' })
end)

H.Test('Offline inventories load by id and unload when idle', function()
    fresh()
    local id = play(1)

    await(function() return UgCore.Characters.Unload(1) end)
    wait(1)

    H.Equal({ UgCore.Inventory.AddItem('player:' .. id, 'water', 1) }, { false, 'not_found' })
    H.Equal(await(function() return UgCore.Inventory.Load('player:' .. id) end), { n = 2, true })
    H.Equal({ UgCore.Inventory.AddItem('player:' .. id, 'water', 1) }, { true })

    wait(370)

    H.Equal(UgCore.Inventory.Get('player:' .. id), nil)
    H.Assert(saved['player:' .. id]:find('water', 1, true) ~= nil, 'offline change not saved')
end)

-- Vehicles

---@param plate string
---@param lock? integer
local function spawnVehicle(plate, lock)
    H.Net.vehicles[500] = { plate = plate, lock = lock }
    H.Net.coords[500] = vector3(2, 0, 0)
    H.Net.netEntities[77] = 500
end

H.Test('Trunks open near an unlocked vehicle, keyed by its plate', function()
    fresh()
    play(1)
    spawnVehicle(' ab 123  ', 2)

    H.Equal(ask('InventoryOpen', 1, 'trunk', nil, 77), 'no_permission')

    H.Net.vehicles[500].lock = 0

    H.Equal(ask('InventoryOpen', 1, 'trunk', nil, 77), { label = 'Trunk', slots = 20, maxWeight = 50000, items = {} })
    H.Equal(UgCore.Inventory.GetOpen(1), 'trunk:AB_123')
    wait(1)
    H.Equal(ask('InventoryOpen', 1, 'trunk', nil, 78), 'not_found')

    place(1, vector3(30, 0, 0))
    H.Equal(ask('InventoryOpen', 1, 'trunk', nil, 77), 'no_permission')
end)

H.Test('Gloveboxes need the player inside the vehicle', function()
    fresh()
    play(1)
    spawnVehicle('XYZ')

    H.Equal(ask('InventoryOpen', 1, 'glovebox', nil, 77), 'no_permission')

    H.Net.vehicles[500].driver = 101

    H.Equal(type(ask('InventoryOpen', 1, 'glovebox', nil, 77)), 'table')
end)

H.Test('Vehicle inventories are temporary until marked persistent', function()
    fresh()
    play(1)
    spawnVehicle('TEMP1')

    ask('InventoryOpen', 1, 'trunk', nil, 77)
    UgCore.Inventory.AddItem('trunk:TEMP1', 'water', 2)
    wait(31)

    H.Equal(saved['trunk:TEMP1'], nil)

    H.Equal(await(function() return UgCore.Inventory.SetPersistent('temp1', true) end), { n = 2, true })
    H.Assert(saved['trunk:TEMP1']:find('water', 1, true) ~= nil, 'trunk not saved')
    H.Assert(saved['glovebox:TEMP1'] ~= nil, 'glovebox not saved')

    H.Equal(await(function() return UgCore.Inventory.SetPersistent('TEMP1', false) end), { n = 2, true })
    H.Equal(saved['trunk:TEMP1'], nil)
end)

H.Test('Temporary vehicle inventories leave with their vehicle', function()
    fresh()
    play(1)
    spawnVehicle('GONE')

    ask('InventoryOpen', 1, 'trunk', nil, 77)
    UgCore.Inventory.AddItem('trunk:GONE', 'water', 1)
    ask('InventoryClose', 1)

    H.Net.vehicles[500] = nil
    wait(10)

    H.Equal(UgCore.Inventory.Get('trunk:GONE'), nil)
end)

-- Drops

H.Test('Dropping creates a drop at the player, and nearby drops merge', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 3)
    UgCore.Inventory.AddItem(1, 'bread', 1)

    H.Equal(ask('InventoryDrop', 1, 1, 2), true)

    local drops = UgCore.Inventory.GetDrops()
    local id = assert(next(drops))

    H.Equal(drops[id], vector3(0, 0, 0))
    H.Equal(GlobalState['ug-core:Drops'][id], { x = 0, y = 0, z = 0 })
    H.Equal(layout(id), { [1] = 'water x2' })

    place(1, vector3(1, 0, 0))
    wait(1)
    H.Equal(ask('InventoryDrop', 1, 2), true)
    H.Equal(layout(id), { [1] = 'water x2', [2] = 'bread x1' })
    H.Equal(logs[#logs].reason, 'drop')
end)

H.Test('Empty drops disappear, others expire', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'water', 2)
    ask('InventoryDrop', 1, 1, 1)

    local id = next(UgCore.Inventory.GetDrops())

    H.Equal(type(ask('InventoryOpen', 1, 'drop', id)), 'table')
    H.Equal(ask('InventoryMove', 1, 'other', 1, 'player', 5), true)
    wait(1)

    H.Equal(UgCore.Inventory.GetDrops(), {})
    H.Equal(#H.ClientEvents('ug-core:InventoryClosed'), 1)

    local ok, other = table.unpack({ UgCore.Inventory.CreateDrop(vector3(5, 5, 5), { { name = 'bread', count = 1 } }) })

    H.Equal(ok, true)
    wait(15 * 60 + 10)
    H.Equal(UgCore.Inventory.GetDrops()[other], nil)
    H.Equal(logs[#logs].reason, 'expired')
end)

H.Test('CreateDrop is all or nothing', function()
    fresh()

    H.Equal({ UgCore.Inventory.CreateDrop(vector3(0, 0, 0), { { name = 'water', count = 999 } }) }, { false, nil, 'cannot_carry' })
    H.Equal(UgCore.Inventory.GetDrops(), {})

    H.Raises(function()
        UgCore.Inventory.CreateDrop(H.Any({ 1, 2, 3 }))
    end, 'Inventory.CreateDrop expects coords as a vector3')
end)

-- Sessions

H.Test('Unloading a character closes what it had open, and what others had open of it', function()
    fresh()
    local id = play(1)
    play(2)

    await(function() return UgCore.Inventory.Open(1, 'stash:safe') end)
    await(function() return UgCore.Inventory.Open(2, 'player:' .. id) end)
    await(function() return UgCore.Characters.Unload(1) end)

    H.Equal(UgCore.Inventory.GetOpen(1), nil)
    H.Equal(UgCore.Inventory.GetOpen(2), nil)
end)

H.Test('Clients track the open inventory', function()
    fresh()

    local definitions = GlobalState['ug-core:Items']

    H.Capture(function()
        H.LoadManifest('client')
    end)
    H.SetGlobalState('ug-core:Items', definitions)

    local events = {}

    UgCore.Events.On(UgCore.Enums.Events.Inventory.Opened, function(opened) events[#events + 1] = { 'opened', opened.label } end)
    UgCore.Events.On(UgCore.Enums.Events.Inventory.Closed, function() events[#events + 1] = { 'closed' } end)

    H.Capture(function()
        H.TriggerNetEvent('ug-core:InventoryOpened', nil, { label = 'Safe', slots = 5, maxWeight = 100, items = { { slot = 1, name = 'water', count = 1 } } })
        H.TriggerNetEvent('ug-core:InventoryUpdate', nil, 'other', { { slot = 2, item = { name = 'bread', count = 2 } } })
    end)

    H.Equal(UgCore.Inventory.GetOther(), {
        label = 'Safe', slots = 5, maxWeight = 100,
        items = { { slot = 1, name = 'water', count = 1 }, { slot = 2, name = 'bread', count = 2 } },
    })

    H.Capture(function()
        H.TriggerNetEvent('ug-core:InventoryClosed', nil)
    end)

    H.Equal(UgCore.Inventory.GetOther(), nil)
    H.Equal(events, { { 'opened', 'Safe' }, { 'closed' } })
end)

H.Done()
