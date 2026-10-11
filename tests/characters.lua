--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local PISTOL = GetHashKey('WEAPON_PISTOL')

---@class TestCharacterRow
---@field id integer
---@field identifier string
---@field name string
---@field data string
---@field death string?
---@field position string?
---@field deleted boolean
---@field played boolean

---@type TestCharacterRow[]
local rows

---In-memory `ug_characters`.
---@param sql string
---@param params table?
---@return any
local function store(sql, params)
    local values = params or {}

    if sql:find('INSERT INTO `ug_characters`', 1, true) then
        local id = #rows + 1

        rows[id] = { id = id, identifier = values[1], name = values[2], data = values[3], deleted = false, played = false }

        return { insertId = id, affectedRows = 1 }
    end

    if sql:find('SELECT COUNT(*)', 1, true) then
        local total = 0

        for _, row in ipairs(rows) do
            if row.identifier == values[1] and not row.deleted then
                total = total + 1
            end
        end

        return { { total = total } }
    end

    if sql:find('FROM `ug_characters` WHERE `identifier`', 1, true) then
        local list = {}

        for _, row in ipairs(rows) do
            if row.identifier == values[1] and not row.deleted then
                list[#list + 1] = { id = row.id, name = row.name, data = row.data, position = row.position, death = row.death, createdAt = 1800000000 }
            end
        end

        return list
    end

    if sql:find('FROM `ug_characters` WHERE `id` = ? AND `identifier`', 1, true) then
        local row = rows[values[1]]

        if row and row.identifier == values[2] and not row.deleted then
            return { { id = row.id, name = row.name, data = row.data, position = row.position, createdAt = 1800000000, death = row.death } }
        end

        return {}
    end

    if sql:find('SET `deleted_at`', 1, true) then
        local row = rows[values[1]]

        if row and row.identifier == values[2] and not row.deleted then
            row.deleted = true
            return { insertId = 0, affectedRows = 1 }
        end

        return { insertId = 0, affectedRows = 0 }
    end

    if sql:find('SET `last_played`', 1, true) then
        rows[values[1]].played = true
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('SET `death`', 1, true) then
        rows[values[2]].death = values[1]
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('SET `position`', 1, true) then
        rows[values[2]].position = values[1]
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('SELECT `position` FROM', 1, true) then
        local row = rows[values[1]]

        return row and not row.deleted and { { position = row.position } } or {}
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
    H.Metadata = { ug_module = { 'identity', 'players', 'characters' } }

    for source = 1, 2 do
        H.Net.identifiers[source] = { 'license:' .. source }
        H.Net.peds[source] = 100 + source
        H.Net.owners[100 + source] = source
        H.Net.coords[100 + source] = vector3(0, 0, 0)
    end

    rows = {}

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
---@param name string
---@return integer characterId
local function create(source, name)
    return await(function()
        return UgCore.Characters.Create(source, { name = name, data = { firstName = name } })
    end)[2]
end

H.Test('With characters enabled, players are not loaded until a character loads', function()
    fresh()

    H.Equal(H.Net.states[1]['ug-core:Loaded'], nil)

    local id = create(1, 'Ana')

    H.Equal(await(function() return UgCore.Characters.Load(1, id) end), { n = 2, true })
    H.Equal(H.Net.states[1]['ug-core:Loaded'], true)
    H.Equal(UgCore.Players.Get(1).characterId, id)
    H.Equal(UgCore.Players.GetByCharacterId(id).source, 1)
    H.Equal(UgCore.Characters.GetActive(1).data, { firstName = 'Ana' })
    H.Equal(rows[id].played, true)
end)

H.Test('GetAll lists owned characters only', function()
    fresh()

    create(1, 'Ana')
    create(2, 'Bo')
    create(1, 'Cy')

    local result = await(function()
        return UgCore.Characters.GetAll(1)
    end)

    H.Equal({ result[2][1].name, result[2][2].name, #result[2] }, { 'Ana', 'Cy', 2 })
end)

H.Test('Create validates input and enforces maxCharacters', function()
    fresh()
    H.ResourceFiles['config/characters.lua'] = 'return { maxCharacters = 1 }'
    H.Capture(function()
        H.LoadManifest('server')
    end)
    H.Db.handler = store

    H.Equal(await(function() return UgCore.Characters.Create(1, { name = '' }) end), { n = 3, false, nil, 'invalid_args' })
    H.Equal(await(function() return UgCore.Characters.Create(1, H.Any({ name = 'A', data = 'text' })) end)[3], 'invalid_args')
    H.Equal(await(function() return UgCore.Characters.Create(1, { name = 'Ana' }) end)[2], 1)
    H.Equal(await(function() return UgCore.Characters.Create(1, { name = 'Bo' }) end), { n = 3, false, nil, 'no_permission' })
end)

H.Test('Characters:BeforeCreate can change or cancel creation', function()
    fresh()

    UgCore.Hooks.Register('Characters:BeforeCreate', function(payload)
        if payload.name == 'Blocked' then
            return false
        end

        payload.name = payload.name .. ' Jr'
    end)

    H.Equal(await(function() return UgCore.Characters.Create(1, { name = 'Blocked' }) end)[3], 'no_permission')

    create(1, 'Ana')

    H.Equal(rows[1].name, 'Ana Jr')
end)

H.Test('Delete is soft and refuses the loaded character', function()
    fresh()

    local loaded = create(1, 'Ana')
    local other = create(1, 'Bo')

    await(function() return UgCore.Characters.Load(1, loaded) end)

    H.Equal(await(function() return UgCore.Characters.Delete(1, loaded) end), { n = 2, false, 'invalid_args' })
    H.Equal(await(function() return UgCore.Characters.Delete(2, other) end), { n = 2, false, 'not_found' })
    H.Equal(await(function() return UgCore.Characters.Delete(1, other) end), { n = 2, true })
    H.Equal(rows[other].deleted, true)
    H.Equal(await(function() return UgCore.Characters.Load(1, other) end), { n = 2, false, 'not_found' })
end)

H.Test('Players cannot load characters of others', function()
    fresh()

    local id = create(2, 'Bo')

    H.Equal(await(function() return UgCore.Characters.Load(1, id) end), { n = 2, false, 'not_found' })
end)

H.Test('Unload saves death state and resets the player', function()
    fresh()

    local id = create(1, 'Ana')

    await(function() return UgCore.Characters.Load(1, id) end)

    H.Net.health[101] = 0
    H.Net.causeOfDeath[101] = PISTOL
    H.Capture(function()
        H.TriggerNetEvent('ug-core:PlayersReportFatal', 1, 58271)
    end)

    H.Equal(await(function() return UgCore.Characters.Unload(1) end), { n = 2, true })
    H.Equal(json.decode(rows[id].death).state, 'Downed')
    H.Equal(H.Net.states[1]['ug-core:Loaded'], false)
    H.Equal(UgCore.Players.GetDeathState(1), 'Alive')
    H.Equal(UgCore.Players.Get(1).characterId, nil)
end)

H.Test('Disconnecting while downed comes back downed', function()
    fresh()

    local id = create(1, 'Ana')

    await(function() return UgCore.Characters.Load(1, id) end)

    H.Net.health[101] = 0
    H.Net.causeOfDeath[101] = PISTOL
    H.Capture(function()
        H.TriggerNetEvent('ug-core:PlayersReportFatal', 1, 58271)
        H.TriggerEvent('playerDropped', 1, 'Exiting')
        H.Advance(0)
    end)

    H.Equal(json.decode(rows[id].death).state, 'Downed')

    H.Net.health[101] = 200
    H.Capture(function()
        H.TriggerEvent('playerJoining', 1, 'temp')
    end)

    local listed = await(function()
        return UgCore.Characters.GetAll(1)
    end)[2]

    H.Equal(listed[1].deathState, 'Downed', 'GetAll tells the selection screen before loading')

    await(function() return UgCore.Characters.Load(1, id) end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Downed')
    H.Equal(UgCore.Players.GetInjuries(1)[1].region, 'LeftLeg')
end)

H.Test('The last position is read from the ped on the server and saved on unload and disconnect', function()
    fresh()

    local id = create(1, 'Alex')

    H.Equal(await(function()
        return UgCore.Characters.GetPosition(id)
    end), { true, nil, nil, n = 3 }, 'no position before the first save')

    await(function()
        return UgCore.Characters.Load(1, id)
    end)

    H.Net.coords[101] = vector3(215.756, -810.12, 30.73)
    await(function()
        return UgCore.Characters.Unload(1)
    end)

    local result = await(function()
        return UgCore.Characters.GetPosition(id)
    end)

    H.Equal(result[1], true)
    H.Equal({ result[2].x, result[2].y, result[2].z, result[2].w }, { 215.76, -810.12, 30.73, 0.0 })

    local listed = await(function()
        return UgCore.Characters.GetAll(1)
    end)[2]

    H.Equal(listed[1].position.x, 215.76, 'GetAll returns the position too')

    -- A ped at the map origin has not spawned yet: the saved position stays.
    await(function()
        return UgCore.Characters.Load(1, id)
    end)
    H.Net.coords[101] = vector3(0, 0, 0)
    await(function()
        return UgCore.Characters.Unload(1)
    end)

    H.Equal(await(function()
        return UgCore.Characters.GetPosition(id)
    end)[2].x, 215.76)

    H.Equal(await(function()
        return UgCore.Characters.GetPosition(H.Any('1'))
    end), { false, nil, 'invalid_args', n = 3 })

    await(function() return UgCore.Characters.Load(1, id) end)
    H.Net.coords[101] = vector3(-1037.5, -2737.25, 20.17)
    H.Capture(function()
        H.TriggerEvent('playerDropped', 1, 'Exiting')
        H.Advance(0)
    end)

    H.Equal(json.decode(rows[id].position).x, -1037.5, 'saved on disconnect')
end)

H.Test('Load and Unload emit character events', function()
    fresh()

    local seen = {}

    for _, name in ipairs({ 'Created', 'Loaded', 'Unloaded' }) do
        UgCore.Events.On('ug-core:Characters:' .. name, function(source, characterId)
            seen[#seen + 1] = ('%s %d %d'):format(name, source, characterId)
        end)
    end

    local id = create(1, 'Ana')

    await(function() return UgCore.Characters.Load(1, id) end)
    await(function() return UgCore.Characters.Unload(1) end)

    H.Equal(seen, { 'Created 1 1', 'Loaded 1 1', 'Unloaded 1 1' })
end)

H.Done()
