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

    local tableName = sql:match('`(ug_character_%a+)`')

    if tableName and sql:find('INSERT INTO', 1, true) then
        roles[tableName] = roles[tableName] or {}
        roles[tableName][v[1]] = {
            name = v[2],
            grade = v[3],
        }
        return {
            insertId = 0,
            affectedRows = 1,
        }
    end

    if tableName and sql:find('SELECT', 1, true) then
        local role = (roles[tableName] or {})[v[1]]

        return role and {
            {
                name = role.name,
                grade = role.grade,
            },
        } or {}
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
    H.Metadata = {
        ug_module = { 'identity', 'players', 'characters', 'jobs', 'gangs' },
    }
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
        return UgCore.Characters.Create(source, {
            name = 'P' .. source,
        })
    end)[2]

    await(function()
        return UgCore.Characters.Load(source, id)
    end)

    return id
end

H.Test('New characters start unemployed and without a gang', function()
    fresh()

    local id = play(1)

    H.Equal(roles.ug_character_jobs[id], {
        name = 'unemployed',
        grade = 1,
    })
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

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police', 2) end), {
        n = 2,
        true,
    })
    H.Equal(roles.ug_character_jobs[id], {
        name = 'police',
        grade = 2,
    })
    H.Equal(H.Net.states[1]['ug-core:Job'], {
        name = 'police', label = 'Police', grade = 2, gradeName = 'officer', gradeLabel = 'Officer',
        salary = 150, boss = false, onDuty = false,
    })
    H.Equal(seen, { 1, 'police', 'unemployed' })
end)

H.Test('Unknown jobs and grades return invalid_args', function()
    fresh()

    play(1)

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'pilot') end), {
        n = 2,
        false,
        'invalid_args',
    })
    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police', 9) end), {
        n = 2,
        false,
        'invalid_args',
    })
    H.Equal(UgCore.Jobs.Exists('police', 4), true)
    H.Equal(UgCore.Jobs.Exists('police', 5), false)
    H.Equal(UgCore.Jobs.GetDefinition('police').grades[4].boss, true)
end)

H.Test('SetGrade keeps the job', function()
    fresh()

    play(1)
    await(function() return UgCore.Jobs.Set(1, 'police', 1) end)

    H.Equal(await(function() return UgCore.Jobs.SetGrade(1, 4) end), {
        n = 2,
        true,
    })
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

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'police') end), {
        n = 2,
        false,
        'no_permission',
    })
end)

H.Test('Players without a loaded character get not_loaded', function()
    fresh()

    H.Equal(await(function() return UgCore.Jobs.Set(2, 'police') end), {
        n = 2,
        false,
        'not_loaded',
    })
    H.Equal(UgCore.Jobs.Get(2), nil)
    H.Equal({ UgCore.Jobs.SetDuty(2, true) }, { false, 'not_loaded' })
end)

H.Test('A removed job falls back to unemployed with a warning', function()
    fresh()

    local id = play(1)

    await(function() return UgCore.Characters.Unload(1) end)
    roles.ug_character_jobs[id] = {
        name = 'mechanic',
        grade = 1,
    }

    local result = await(function() return UgCore.Characters.Load(1, id) end)

    H.Equal(result[1], true)
    H.Equal(UgCore.Jobs.Get(1).name, 'unemployed')
    H.Equal(roles.ug_character_jobs[id].name, 'mechanic', 'the saved job is kept for a resource that registers it later')
end)

local AMBULANCE = {
    label = 'EMS',
    defaultDuty = false,
    grades = {
        {
            name = 'emt',
            label = 'EMT',
            salary = 100,
        },
        {
            name = 'chief',
            label = 'Chief',
            salary = 300,
            boss = true,
        },
    },
}

---Registers a job through the flat export, as another resource does.
---@param resource string
---@param name string
---@param definition table
---@return boolean registered
local function registerAs(resource, name, definition)
    local previous = H.CurrentResource

    H.CurrentResource = resource

    local ok, result = pcall(function()
        return exports['ug-core']:JobsRegister(name, definition)
    end)

    H.CurrentResource = previous

    assert(ok, result)

    return result
end

H.Test('Resources register jobs; they work like config jobs and say where they come from', function()
    fresh()
    play(1)

    local seen

    UgCore.Events.On('ug-core:Jobs:Registered', function(name, resource)
        seen = { name, resource }
    end)

    H.Equal(registerAs('ug-ambulance', 'ambulance', AMBULANCE), true)
    H.Equal(seen, { 'ambulance', 'ug-ambulance' })
    H.Equal(UgCore.Jobs.Exists('ambulance', 2), true)
    H.Equal(UgCore.Jobs.GetDefinition('ambulance').grades[2].boss, true)
    H.Equal(UgCore.Jobs.GetAll().ambulance.label, 'EMS')
    H.Equal(UgCore.Jobs.GetAll().police.label, 'Police')
    H.Equal(UgCore.Internal.Jobs.Source('ambulance'), 'ug-ambulance')
    H.Equal(UgCore.Internal.Jobs.Source('police'), 'config')
    H.Equal(UgCore.Internal.Jobs.Source('pilot'), nil)

    H.Equal(await(function() return UgCore.Jobs.Set(1, 'ambulance', 2) end), {
        n = 2,
        true,
    })
    H.Equal(UgCore.Jobs.Get(1).gradeLabel, 'Chief')

    UgCore.Jobs.GetDefinition('ambulance').label = 'changed'
    H.Equal(UgCore.Jobs.GetDefinition('ambulance').label, 'EMS', 'callers get copies')
end)

H.Test('The owner config wins, and the first resource keeps a name', function()
    fresh()

    H.Equal(registerAs('ug-police', 'police', AMBULANCE), false)
    H.Equal(UgCore.Jobs.GetDefinition('police').label, 'Police')

    H.Equal(registerAs('ug-ambulance', 'ambulance', AMBULANCE), true)

    local lines = H.Capture(function()
        H.Equal(registerAs('other-ems', 'ambulance', {
            label = 'Other',
            grades = AMBULANCE.grades,
        }), false)
    end)
    local warned = false

    for _, line in ipairs(lines) do
        warned = warned or line:find('other-ems registers jobs "ambulance", which ug-ambulance registered first', 1, true) ~= nil
    end

    H.Assert(warned, 'clash not reported')
    H.Equal(UgCore.Jobs.GetDefinition('ambulance').label, 'EMS')

    -- The same resource, after a restart, replaces its own definition.
    H.Equal(registerAs('ug-ambulance', 'ambulance', {
        label = 'Ambulance',
        grades = AMBULANCE.grades,
    }), true)
    H.Equal(UgCore.Jobs.GetDefinition('ambulance').label, 'Ambulance')
end)

H.Test('A malformed registration raises', function()
    fresh()

    H.Raises(function()
        UgCore.Jobs.Register('Bad Name', AMBULANCE)
    end, 'Jobs.Register("Bad Name")')
    H.Raises(function()
        UgCore.Jobs.Register('ambulance', H.Any({
            label = 'EMS',
            grades = {},
        }))
    end, 'MUST have 1 to 32 grades')
    H.Equal(UgCore.Jobs.Exists('ambulance'), false)
end)

H.Test('A character whose job a resource registers later gets it back', function()
    fresh()

    local id = play(1)

    await(function() return UgCore.Characters.Unload(1) end)
    roles.ug_character_jobs[id] = {
        name = 'ambulance',
        grade = 2,
    }
    await(function() return UgCore.Characters.Load(1, id) end)
    H.Equal(UgCore.Jobs.Get(1).name, 'unemployed')

    local seen

    UgCore.Events.On('ug-core:Jobs:Changed', function(source, job, previous)
        seen = { source, job.name, job.grade, previous.name }
    end)

    registerAs('ug-ambulance', 'ambulance', AMBULANCE)

    H.Equal(UgCore.Jobs.Get(1).name, 'ambulance')
    H.Equal(UgCore.Jobs.Get(1).grade, 2)
    H.Equal(H.Net.states[1]['ug-core:Job'].name, 'ambulance')
    H.Equal(seen, { 1, 'ambulance', 2, 'unemployed' })
    H.Equal(roles.ug_character_jobs[id], {
        name = 'ambulance',
        grade = 2,
    })
end)

H.Test('Gangs register like jobs; ug jobs and ug gangs list every role with its source', function()
    fresh()

    local previous = H.CurrentResource

    H.CurrentResource = 'ug-gangs'
    exports['ug-core']:GangsRegister('ballas', {
        label = 'Ballas',
        grades = {
            {
                name = 'member',
                label = 'Member',
                salary = 0,
            },
        },
    })
    H.CurrentResource = previous
    registerAs('ug-ambulance', 'ambulance', AMBULANCE)

    H.Equal(UgCore.Gangs.Exists('ballas', 1), true)

    local jobs = table.concat(H.RunCommand('ug', 0, { 'jobs' }), '\n')
    local gangs = table.concat(H.RunCommand('ug', 0, { 'gangs' }), '\n')

    H.Assert(jobs:find('ambulance%s+EMS%s+2 grade%(s%)%s+ug%-ambulance') ~= nil, jobs)
    H.Assert(jobs:find('police%s+Police%s+4 grade%(s%)%s+config') ~= nil, jobs)
    H.Assert(gangs:find('ballas%s+Ballas%s+1 grade%(s%)%s+ug%-gangs') ~= nil, gangs)
end)

H.Test('A jobs config without unemployed aborts boot', function()
    local lines = fresh({
        jobs = "return { police = { label = 'Police', grades = { { name = 'a', label = 'A', salary = 0 } } } }",
    })
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('config/jobs.lua MUST define "unemployed"', 1, true) ~= nil
    end

    H.Assert(found, 'missing default not reported')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Invalid job definitions are config errors', function()
    local lines = fresh({
        jobs = "return { unemployed = { label = 'U', grades = {} } }",
    })
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('config/jobs.lua: entry "unemployed" MUST have 1 to 32 grades', 1, true) ~= nil
    end

    H.Assert(found, 'invalid definition not reported')
end)

H.Test('Gangs set and persist like jobs, without duty', function()
    fresh()

    local id = play(1)

    H.Equal(await(function() return UgCore.Gangs.Set(1, 'none') end), {
        n = 2,
        true,
    })
    H.Equal(roles.ug_character_gangs[id], {
        name = 'none',
        grade = 1,
    })
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
