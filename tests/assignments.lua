--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { identifier: string, name: string, data: string }[]
local characters

---@type table<string, table<integer, { name: string, grade: integer }>> table -> characterId -> role
local roles

---In-memory characters, jobs and gangs.
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

    local tableName = sql:match('`(ug_character_%a+)`')

    if tableName and sql:find('INSERT INTO', 1, true) then
        roles[tableName] = roles[tableName] or {}
        roles[tableName][v[1]] = { name = v[2], grade = v[3] }
        return { insertId = 0, affectedRows = 1 }
    end

    if tableName and sql:find('SELECT', 1, true) then
        local role = (roles[tableName] or {})[v[1]]

        return role and { { name = role.name, grade = role.grade } } or {}
    end
end

---@param config? table<string, string> config file bodies by name
local function fresh(config)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'characters', 'jobs', 'gangs' } }
    H.Net.identifiers[1] = { 'license:1' }
    H.Net.identifiers[2] = { 'license:2' }

    for name, body in pairs(config or {}) do
        H.ResourceFiles['config/' .. name .. '.lua'] = body
    end

    characters, roles = {}, {}

    local lines = H.LoadManifest('server')

    H.Db.handler = store

    return lines
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

H.Test('New characters start unemployed and without a gang', function()
    fresh()

    local id = play(1)

    H.Equal(roles.ug_character_jobs[id], { name = 'unemployed', grade = 1 })
    H.Equal(UgCore.Jobs.Get(1).label, 'Unemployed')
    H.Equal(UgCore.Gangs.Get(1).name, 'none')
    H.Equal(H.Net.states[1]['ug-core:Job'].name, 'unemployed')
end)

H.Test('Set persists the job, publishes the statebag and emits Changed', function()
    fresh()

    local id = play(1)
    local seen

    UgCore.Events.On('ug-core:Jobs:Changed', function(source, job, previous)
        seen = { source, job.name, previous.name }
    end)

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police', 2) end), { n = 2, true })
    H.Equal(roles.ug_character_jobs[id], { name = 'police', grade = 2 })
    H.Equal(H.Net.states[1]['ug-core:Job'], {
        name = 'police', label = 'Police', grade = 2, gradeName = 'officer', gradeLabel = 'Officer',
        salary = 150, boss = false, onDuty = false,
    })
    H.Equal(seen, { 1, 'police', 'unemployed' })
end)

H.Test('Unknown jobs and grades return invalid_args', function()
    fresh()

    play(1)

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'pilot') end), { n = 2, false, 'invalid_args' })
    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police', 9) end), { n = 2, false, 'invalid_args' })
    H.Equal(UgCore.Jobs.Exists('police', 4), true)
    H.Equal(UgCore.Jobs.Exists('police', 5), false)
    H.Equal(UgCore.Jobs.GetDefinition('police').grades[4].boss, true)
end)

H.Test('SetGrade keeps the job', function()
    fresh()

    play(1)
    await(function() return UgCore.Jobs.Set(1, 'police', 1) end)

    H.Equal(await(function() return UgCore.Jobs.SetGrade(1, 4) end), { n = 2, true })
    H.Equal(UgCore.Jobs.Get(1).boss, true)
end)

H.Test('A new grade keeps duty, a new job resets it', function()
    fresh()

    play(1)
    await(function() return UgCore.Jobs.Set(1, 'police', 1) end)
    UgCore.Jobs.SetDuty(1, true)

    await(function() return UgCore.Jobs.SetGrade(1, 2) end)
    H.Equal(UgCore.Jobs.IsOnDuty(1), true)

    await(function() return UgCore.Jobs.Set(1, 'police', 3) end)
    H.Equal(UgCore.Jobs.IsOnDuty(1), true)

    await(function() return UgCore.Jobs.Set(1, 'unemployed') end)
    H.Equal(UgCore.Jobs.IsOnDuty(1), false)
end)

H.Test('Duty is session state with its own event', function()
    fresh()

    play(1)
    await(function() return UgCore.Jobs.Set(1, 'police') end)

    local seen = {}

    UgCore.Events.On('ug-core:Jobs:DutyChanged', function(source, onDuty)
        seen[#seen + 1] = { source, onDuty }
    end)

    H.Equal({ UgCore.Jobs.SetDuty(1, true) }, { true })
    UgCore.Jobs.SetDuty(1, true)

    H.Equal(UgCore.Jobs.IsOnDuty(1), true)
    H.Equal(H.Net.states[1]['ug-core:Job'].onDuty, true)
    H.Equal(seen, { { 1, true } })
end)

H.Test('Jobs:BeforeSet can cancel', function()
    fresh()

    play(1)

    UgCore.Hooks.Register('Jobs:BeforeSet', function(payload)
        return payload.name ~= 'police'
    end)

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police') end), { n = 2, false, 'no_permission' })
end)

H.Test('Players without a loaded character get not_loaded', function()
    fresh()

    H.Equal(await(function() return UgCore.Jobs.Set(2, 'police') end), { n = 2, false, 'not_loaded' })
    H.Equal(UgCore.Jobs.Get(2), nil)
    H.Equal({ UgCore.Jobs.SetDuty(2, true) }, { false, 'not_loaded' })
end)

H.Test('A removed job falls back to unemployed with a warning', function()
    fresh()

    local id = play(1)

    await(function() return UgCore.Characters.Unload(1) end)
    roles.ug_character_jobs[id] = { name = 'mechanic', grade = 1 }

    local result = await(function() return UgCore.Characters.Load(1, id) end)

    H.Equal(result[1], true)
    H.Equal(UgCore.Jobs.Get(1).name, 'unemployed')
end)

H.Test('A jobs config without unemployed aborts boot', function()
    local lines = fresh({ jobs = "return { police = { label = 'Police', grades = { { name = 'a', label = 'A', salary = 0 } } } }" })
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('config/jobs.lua MUST define "unemployed"', 1, true) ~= nil
    end

    H.Assert(found, 'missing default not reported')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Invalid job definitions are config errors', function()
    local lines = fresh({ jobs = "return { unemployed = { label = 'U', grades = {} } }" })
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('config/jobs.lua: entry "unemployed" MUST have 1 to 32 grades', 1, true) ~= nil
    end

    H.Assert(found, 'invalid definition not reported')
end)

H.Test('Gangs set and persist like jobs, without duty', function()
    fresh()

    local id = play(1)

    H.Equal(await(function() return UgCore.Gangs.Set(1, 'none') end), { n = 2, true })
    H.Equal(roles.ug_character_gangs[id], { name = 'none', grade = 1 })
    H.Equal(UgCore.Gangs.Get(1).onDuty, nil)
    H.Equal(rawget(UgCore.Gangs, 'SetDuty'), nil)
end)

H.Test('Clients read their own job from the statebag', function()
    fresh()

    play(1)
    await(function() return UgCore.Jobs.Set(1, 'police') end)
    UgCore.Jobs.SetDuty(1, true)

    H.Capture(function()
        H.LoadManifest('client')
    end)

    H.Equal(UgCore.Jobs.Get().name, 'police')
    H.Equal(UgCore.Jobs.IsOnDuty(), true)
    H.Equal(UgCore.Gangs.Get().name, 'none')
end)

H.Done()
