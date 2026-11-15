--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { identifier: string, name: string, data: string }[]
local characters

---@type table<integer, string> character id -> saved JSON
local saved

---In-memory characters and needs.
---@param sql string
---@param params table?
---@return any
local function store(sql, params)
    local v = params or {}

    if sql:find('INSERT INTO `ug_characters`', 1, true) then
        characters[#characters + 1] = {
            identifier = v[1],
            name = v[2],
            data = v[3],
        }
        return {
            insertId = #characters,
            affectedRows = 1,
        }
    end

    if sql:find('SELECT COUNT(*)', 1, true) then
        return {
            {
                total = 0,
            },
        }
    end

    if sql:find('FROM `ug_characters` WHERE `id` = ? AND `identifier`', 1, true) then
        local row = characters[v[1]]

        return row and row.identifier == v[2] and {
            {
                id = v[1],
                name = row.name,
                data = row.data,
                createdAt = 0,
            },
        } or {}
    end

    if sql:find('SELECT `data` FROM `ug_needs`', 1, true) then
        return saved[v[1]] and {
            {
                data = saved[v[1]],
            },
        } or {}
    end

    if sql:find('INSERT INTO `ug_needs`', 1, true) then
        saved[v[1]] = v[2]
        return {
            insertId = 0,
            affectedRows = 1,
        }
    end
end

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = {
        ug_module = { 'identity', 'players', 'characters', 'needs' },
    }

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    characters, saved = {}, {}

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
        return UgCore.Characters.Create(source, {
            name = 'P' .. source,
        })
    end)[2]

    await(function()
        return UgCore.Characters.Load(source, id)
    end)

    return id
end

---@return table? values the last needs sent to the player
local function lastSync()
    local events = H.ClientEvents('ug-core:NeedsSync')

    return events[#events] and events[#events].args[1]
end

H.Test('Loaded characters start with the configured needs and get them privately', function()
    fresh()

    play(1)

    H.Equal(UgCore.Needs.GetAll(1), {
        hunger = 100,
        thirst = 100,
        stress = 0,
    })
    H.Equal(lastSync(), {
        hunger = 100,
        thirst = 100,
        stress = 0,
    })
    H.Equal(H.ClientEvents('ug-core:NeedsSync')[1].target, 1)
    H.Equal(UgCore.Needs.GetAll(2), nil)
end)

H.Test('Set, Add and Remove clamp to 0 and 100 and reject bad input', function()
    fresh()

    play(1)

    H.Equal({ UgCore.Needs.Remove(1, 'hunger', 30) }, { true, 70 })
    H.Equal({ UgCore.Needs.Add(1, 'hunger', 50) }, { true, 100 })
    H.Equal({ UgCore.Needs.Set(1, 'stress', 150) }, { true, 100 })
    H.Equal({ UgCore.Needs.Add(1, 'hunger', -5) }, { false, nil, 'invalid_args' })
    H.Equal({ UgCore.Needs.Set(1, 'hunger', 0 / 0) }, { false, nil, 'invalid_args' })
    H.Equal({ UgCore.Needs.Set(1, 'mana', 5) }, { false, nil, 'not_found' })
    H.Equal({ UgCore.Needs.Set(2, 'hunger', 5) }, { false, nil, 'not_loaded' })
    H.Equal(lastSync().stress, 100)
end)

H.Test('Changes emit an event with the previous value', function()
    fresh()

    play(1)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Needs.Changed, function(source, name, value, previous)
        seen[#seen + 1] = { source, name, value, previous }
    end)

    UgCore.Needs.Set(1, 'thirst', 40)
    UgCore.Needs.Set(1, 'thirst', 40)

    H.Equal(seen, { { 1, 'thirst', 40, 100 } })
end)

H.Test('Ticks drain by rate and damage at 0, but pause while down', function()
    fresh()

    play(1)

    UgCore.Internal.Needs.Tick(60000)

    H.Equal(UgCore.Needs.GetAll(1), {
        hunger = 99.4,
        thirst = 99.1,
        stress = 0,
    })

    UgCore.Needs.Set(1, 'hunger', 0)
    UgCore.Internal.Needs.Tick(10000)

    H.Equal(H.ClientEvents('ug-core:NeedsDamage')[1].args[1], 5)

    await(function()
        return UgCore.Players.Down(1)
    end)
    UgCore.Internal.Needs.Tick(60000)

    H.Equal(UgCore.Needs.Get(1, 'thirst'), 98.95, 'paused while downed')
end)

H.Test('Needs are saved on unload and restored on the next load', function()
    fresh()

    local id = play(1)

    UgCore.Needs.Set(1, 'hunger', 42.5)
    await(function()
        return UgCore.Characters.Unload(1)
    end)

    H.Equal(json.decode(saved[id]).hunger, 42.5)
    H.Equal(UgCore.Needs.GetAll(1), nil)
    H.Equal(lastSync(), {})

    saved[id] = json.encode({
        hunger = 10,
        removedNeed = 5,
    })
    await(function()
        return UgCore.Characters.Load(1, id)
    end)

    H.Equal(UgCore.Needs.GetAll(1), {
        hunger = 10,
        thirst = 100,
        stress = 0,
    })
end)

H.Test('Respawn resets every need', function()
    fresh()

    play(1)
    UgCore.Needs.Set(1, 'hunger', 5)

    H.TriggerEventAs('ug-core', UgCore.Enums.Events.Players.Respawned, 1)

    H.Equal(UgCore.Needs.Get(1, 'hunger'), 100)
end)

H.Test('ug needs prints the values', function()
    fresh()

    play(1)

    H.Equal(H.RunCommand('ug', 0, { 'needs', '1' }), {
        '  hunger           100.00',
        '  stress             0.00',
        '  thirst           100.00',
    })
    H.Equal(H.RunCommand('ug', 0, { 'needs', '2' }), { 'Player 2 has no character loaded.' })
end)

H.Done()
