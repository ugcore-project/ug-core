--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'sessions' } }

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    H.Capture(function()
        H.LoadManifest('server')
    end)
end

---@return integer sessionId
local function create(options)
    local _, sessionId = UgCore.Sessions.Create(options)

    return H.Any(sessionId)
end

H.Test('Create allocates a bucket from 1000 with strict lockdown and no population', function()
    fresh()

    local first = create({ name = 'Race' })
    local second = create({ lockdown = 'relaxed', population = true })

    H.Equal(UgCore.Sessions.Get(first), { id = first, name = 'Race', bucket = 1000, lockdown = 'strict', population = false, persistent = false, members = {} })
    H.Equal(UgCore.Sessions.Get(second).bucket, 1001)
    H.Equal(H.Net.bucketSettings[1000], { lockdown = 'strict', population = false })
    H.Equal(H.Net.bucketSettings[1001], { lockdown = 'relaxed', population = true })
end)

H.Test('Join moves the player and sets the statebag', function()
    fresh()

    local sessionId = create()

    H.Equal({ UgCore.Sessions.Join(1, sessionId) }, { true })
    H.Equal(H.Net.buckets[1], 1000)
    H.Equal(H.Net.states[1]['ug-core:Session'], sessionId)
    H.Equal(UgCore.Sessions.GetMembers(sessionId), { 1 })
    H.Equal(UgCore.Sessions.GetSession(1), sessionId)
end)

H.Test('Joining another session leaves the current one', function()
    fresh()

    local first = create({ persistent = true })
    local second = create()

    UgCore.Sessions.Join(1, first)
    UgCore.Sessions.Join(1, second)

    H.Equal(UgCore.Sessions.GetMembers(first), {})
    H.Equal(H.Net.buckets[1], 1001)
end)

H.Test('The last member leaving destroys a session unless persistent', function()
    fresh()

    local temporary = create()
    local persistent = create({ persistent = true })
    local destroyed = {}

    UgCore.Events.On('ug-core:Sessions:Destroyed', function(sessionId)
        destroyed[#destroyed + 1] = sessionId
    end)

    UgCore.Sessions.Join(1, temporary)
    UgCore.Sessions.Join(2, persistent)
    UgCore.Sessions.Leave(1)
    UgCore.Sessions.Leave(2)

    H.Equal(H.Net.buckets[1], 0)
    H.Equal(UgCore.Sessions.Get(temporary), nil)
    H.Assert(UgCore.Sessions.Get(persistent) ~= nil)
    H.Equal(destroyed, { temporary })
end)

H.Test('Destroy returns every member to the shared world, once', function()
    fresh()

    local sessionId = create()
    local destroyed = 0

    UgCore.Events.On('ug-core:Sessions:Destroyed', function()
        destroyed = destroyed + 1
    end)

    UgCore.Sessions.Join(1, sessionId)
    UgCore.Sessions.Join(2, sessionId)

    H.Equal({ UgCore.Sessions.Destroy(sessionId) }, { true })
    H.Equal({ H.Net.buckets[1], H.Net.buckets[2] }, { 0, 0 })
    H.Equal(destroyed, 1)
    H.Equal({ UgCore.Sessions.Destroy(sessionId) }, { false, 'not_found' })
end)

H.Test('Dropped players leave their session', function()
    fresh()

    local sessionId = create({ persistent = true })

    UgCore.Sessions.Join(3, sessionId)
    H.TriggerEvent('playerDropped', 3, 'Exiting')

    H.Equal(UgCore.Sessions.GetMembers(sessionId), {})
end)

H.Test('Sessions:BeforeJoin can refuse a join', function()
    fresh()

    local sessionId = create()

    UgCore.Hooks.Register('Sessions:BeforeJoin', function(payload)
        return payload.source ~= 2
    end)

    H.Equal({ UgCore.Sessions.Join(2, sessionId) }, { false, 'no_permission' })
    H.Equal({ UgCore.Sessions.Join(1, sessionId) }, { true })
end)

H.Test('Unknown sessions and players are reported', function()
    fresh()

    local sessionId = create()

    H.Equal({ UgCore.Sessions.Join(1, 99) }, { false, 'not_found' })
    H.Equal({ UgCore.Sessions.Join(42, sessionId) }, { false, 'not_loaded' })
    H.Equal({ UgCore.Sessions.Leave(1) }, { false, 'not_found' })

    H.Raises(function()
        UgCore.Sessions.Create({ lockdown = H.Any('open') })
    end, 'Sessions.Create: lockdown MUST be "strict", "relaxed" or "inactive"')
end)

H.Done()
