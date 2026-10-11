--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@param guardConfig? string body of config/guard.lua
local function fresh(guardConfig)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.Metadata = {}
    H.Net.resources['ug-hud'] = 'started'

    if guardConfig then
        H.ResourceFiles['config/guard.lua'] = 'return ' .. guardConfig
    end

    H.LoadManifest('server')
end

---@param overrides? table
---@return UgNetworkOptions
local function options(overrides)
    local S = UgCore.Schema
    local result = {
        schema = S.Define({ S.String({ max = 16 }), S.Optional(S.Integer({ min = 0, max = 100 })) }),
        rate = { max = 5, per = 1000 },
    }

    for key, value in pairs(overrides or {}) do
        result[key] = value
    end

    return result
end

-- Net events

H.Test('Valid net events reach the handler with source and validated args', function()
    fresh()

    local received

    UgCore.Network.Register('Deposit', options(), function(...)
        received = table.pack(...)
    end)

    H.TriggerNetEvent('ug-core:Deposit', 7, 'cash', 50.0)

    H.Equal(received, { n = 3, 7, 'cash', 50 })
    H.Equal(math.type(received[3]), 'integer')
end)

H.Test('Local triggers without a player source are ignored', function()
    fresh()

    local calls = 0

    UgCore.Network.Register('Deposit', options(), function() calls = calls + 1 end)
    H.TriggerNetEvent('ug-core:Deposit', nil, 'cash')

    H.Equal(calls, 0)
end)

H.Test('Invalid payloads are dropped and flagged', function()
    fresh()

    local calls = 0

    UgCore.Network.Register('Deposit', options(), function() calls = calls + 1 end)
    H.Capture(function()
        H.TriggerNetEvent('ug-core:Deposit', 7, { 'not a string' })
        H.TriggerNetEvent('ug-core:Deposit', 7, 'cash', 500)
    end)

    H.Equal(calls, 0)
    H.Equal(UgCore.Guard.GetScore(7), 10)
    H.Assert(UgCore.Internal.Guard.GetFlags(7)[1].detail:find('ug-core:Deposit arg 1: MUST be a string', 1, true) ~= nil)
end)

H.Test('Per-event rate limits drop excess traffic', function()
    fresh()

    local calls = 0

    UgCore.Network.Register('Deposit', options({ rate = { max = 2, per = 1000 } }), function() calls = calls + 1 end)

    for _ = 1, 3 do
        H.TriggerNetEvent('ug-core:Deposit', 7, 'cash')
    end

    H.Equal(calls, 2)
    H.Equal(UgCore.Internal.Guard.GetFlags(7)[1].violation, 'RateLimited')
end)

H.Test('The global budget spans every event', function()
    fresh('{ budgetMax = 3 }')

    local calls = 0
    local count = function() calls = calls + 1 end

    UgCore.Network.Register('A', options(), count)
    UgCore.Network.Register('B', options(), count)

    H.TriggerNetEvent('ug-core:A', 7, 'x')
    H.TriggerNetEvent('ug-core:B', 7, 'x')
    H.TriggerNetEvent('ug-core:A', 7, 'x')
    H.TriggerNetEvent('ug-core:B', 7, 'x')

    H.Equal(calls, 3)
end)

H.Test('requirePlayer and permission are enforced', function()
    fresh()

    local calls = 0
    local count = function() calls = calls + 1 end

    UgCore.Network.Register('Loaded', options({ requirePlayer = true }), count)
    UgCore.Network.Register('Admin', options({ permission = 'ug.admin' }), count)

    H.TriggerNetEvent('ug-core:Loaded', 7, 'x')
    H.TriggerNetEvent('ug-core:Admin', 7, 'x')
    H.Equal(calls, 0)

    local flags = UgCore.Internal.Guard.GetFlags(7)

    H.Equal({ flags[1].violation, flags[2].violation }, { 'NotLoaded', 'NoPermission' })

    H.Net.states[7] = { ['ug-core:Loaded'] = true }
    H.Aces['7:ug.admin'] = true
    H.TriggerNetEvent('ug-core:Loaded', 7, 'x')
    H.TriggerNetEvent('ug-core:Admin', 7, 'x')
    H.Aces['7:ug.admin'] = nil

    H.Equal(calls, 2)
end)

H.Test('A failing handler is logged and does not reach the client', function()
    fresh()

    UgCore.Network.Register('Crash', options(), function() error('secret detail', 0) end)

    local lines = H.Capture(function()
        H.TriggerNetEvent('ug-core:Crash', 7, 'x')
    end)

    H.Equal(lines, { '^1[ERROR]^7 Network: ug-core:Crash failed: secret detail' })
    H.Equal(#H.Net.client, 0)
end)

H.Test('Events are dropped before Ready', function()
    H.ResetDb()
    H.Db.ready = false
    H.LoadManifest('server')

    local calls = 0

    UgCore.Network.Register('Early', options(), function() calls = calls + 1 end)
    H.TriggerNetEvent('ug-core:Early', 7, 'x')

    H.Equal(calls, 0)
    H.Equal(UgCore.Guard.GetScore(7), 0)
    H.Db.ready = true
end)

H.Test('Register rejects missing schema or rate and duplicates', function()
    fresh()

    local Network = UgCore.Network

    H.Raises(function()
        Network.Register('A', H.Any({ rate = { max = 1, per = 1 } }), function() end)
    end, '[ug-core] Network.Register: "schema" MUST come from UgCore.Schema.Define')

    H.Raises(function()
        Network.Register('A', H.Any({ schema = UgCore.Schema.Define({}) }), function() end)
    end, 'Network.Register: "rate" MUST be { max, per } with positive integers')

    H.Raises(function()
        Network.Register('bad:name', options(), function() end)
    end, 'Network.Register expects a name of letters, digits and underscores')

    Network.Register('A', options(), function() end)

    H.Raises(function()
        Network.Register('A', options(), function() end)
    end, '"ug-core:A" is already registered')
end)

H.Test('TriggerClient and TriggerClients send to the right targets', function()
    fresh()

    UgCore.Network.TriggerClient(3, 'ug-hud:Update', 1)
    UgCore.Network.TriggerClients('ug-hud:Update', 2)

    H.Equal(H.Net.client[1], { name = 'ug-hud:Update', target = 3, args = { n = 1, 1 } })
    H.Equal(H.Net.client[2].target, -1)

    H.Raises(function()
        UgCore.Network.TriggerClient(0, 'ug-hud:Update')
    end, 'Network.TriggerClient expects a player source or -1')
end)

-- Server callbacks

---@param requestId integer
---@return TestNetworkRecord?
local function reply(requestId)
    for _, record in ipairs(H.ClientEvents('__ugcb:res:ug-hud')) do
        if record.args[1] == requestId then
            return record
        end
    end

    return nil
end

H.Test('Callbacks reply on the caller resource with the handler value', function()
    fresh()

    UgCore.Callback.Register('GetBalance', options(), function(source, account)
        return { source = source, account = account, balance = 50 }
    end)

    H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, 'ug-hud', 1, 'cash')

    H.Equal(reply(1), {
        name = '__ugcb:res:ug-hud',
        target = 7,
        args = { n = 3, 1, true, { source = 7, account = 'cash', balance = 50 } },
    })
end)

H.Test('Malformed requests are flagged and get no reply', function()
    fresh()

    UgCore.Callback.Register('GetBalance', options(), function() return 1 end)

    H.Capture(function()
        H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, 'ug-hud', 'one', 'cash')
        H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, 'not-running', 2, 'cash')
        H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, string.rep('a', 100), 3, 'cash')
    end)

    H.Equal(#H.Net.client, 0)
    H.Equal(UgCore.Guard.GetScore(7), 15)
end)

H.Test('Rejections reply with an error code only', function()
    fresh()

    UgCore.Callback.Register('Admin', options({ permission = 'ug.admin' }), function() return 1 end)
    UgCore.Callback.Register('Crash', options(), function() error('secret detail', 0) end)

    H.TriggerNetEvent('__ugcb:ug-core:Admin', 7, 'ug-hud', 1, 'x')
    H.TriggerNetEvent('__ugcb:ug-core:Admin', 7, 'ug-hud', 2, { 'bad' })

    H.Capture(function()
        H.TriggerNetEvent('__ugcb:ug-core:Crash', 7, 'ug-hud', 3, 'x')
    end)

    H.Equal(reply(1).args, { n = 3, 1, false, 'no_permission' })
    H.Equal(reply(2).args, { n = 3, 2, false, 'no_permission' })
    H.Equal(reply(3).args, { n = 3, 3, false, 'internal_error' })
end)

H.Test('Invalid arguments reply invalid_args', function()
    fresh()

    UgCore.Callback.Register('GetBalance', options(), function() return 1 end)
    H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, 'ug-hud', 1, 5)

    H.Equal(reply(1).args, { n = 3, 1, false, 'invalid_args' })
    H.Equal(UgCore.Internal.Guard.GetFlags(7)[1].violation, 'InvalidPayload')
end)

H.Test('Unregistered callbacks reply not_found and flag', function()
    fresh()

    UgCore.Callback.Register('GetBalance', options(), function() return 1 end)
    H.Equal(UgCore.Callback.Unregister('GetBalance'), true)
    H.Equal(UgCore.Callback.Unregister('GetBalance'), false)

    H.TriggerNetEvent('__ugcb:ug-core:GetBalance', 7, 'ug-hud', 1, 'cash')

    H.Equal(reply(1).args, { n = 3, 1, false, 'not_found' })
    H.Equal(UgCore.Internal.Guard.GetFlags(7)[1].violation, 'UnknownCallback')
end)

H.Test('At most 4 callbacks run at once per player', function()
    fresh('{ kickScore = 0 }')

    UgCore.Callback.Register('Slow', options({ rate = { max = 10, per = 1000 } }), function()
        Wait(100)
        return 'done'
    end)

    for requestId = 1, 5 do
        H.TriggerNetEvent('__ugcb:ug-core:Slow', 7, 'ug-hud', requestId, 'x')
    end

    H.Equal(reply(5).args, { n = 3, 5, false, 'rate_limited' })
    H.Equal(reply(1), nil)
    H.Equal(UgCore.Internal.Guard.GetFlags(7)[1].violation, 'ConcurrencyExceeded')

    H.Advance(100)

    H.Equal(reply(1).args, { n = 3, 1, true, 'done' })

    H.TriggerNetEvent('__ugcb:ug-core:Slow', 7, 'ug-hud', 6, 'x')
    H.Equal(reply(6), nil)
end)

-- Server to client

H.Test('Server Await validates the client result', function()
    fresh()

    local thread = H.Thread(function()
        return table.pack(UgCore.Callback.Await(7, 'ug-hud:GetSettings', { schema = UgCore.Schema.Integer({ min = 0 }) }, 'volume'))
    end)

    local request = H.ClientEvents('__ugcb:ug-hud:GetSettings')[1]

    H.Equal(request.target, 7)
    H.Equal({ request.args[1], request.args[3] }, { 'ug-core', 'volume' })

    H.TriggerNetEvent('__ugcb:res:ug-core', 8, request.args[2], true, 5)
    H.Equal(thread.done, false)

    H.TriggerNetEvent('__ugcb:res:ug-core', 7, request.args[2], true, 5.0)
    H.Equal(thread.result, { n = 3, true, 5 })
end)

H.Test('Server Await maps bad results, errors and timeouts', function()
    fresh()

    local schema = { schema = UgCore.Schema.Integer() }

    ---@param respond fun(requestId: integer)
    ---@return table
    local function run(respond)
        local thread = H.Thread(function()
            return table.pack(UgCore.Callback.Await(7, 'ug-hud:Get', schema))
        end)
        local requests = H.ClientEvents('__ugcb:ug-hud:Get')

        respond(requests[#requests].args[2])

        return thread.result
    end

    H.Equal(run(function(id) H.TriggerNetEvent('__ugcb:res:ug-core', 7, id, true, 'text') end), { n = 3, false, nil, 'invalid_args' })
    H.Equal(run(function(id) H.TriggerNetEvent('__ugcb:res:ug-core', 7, id, false, 'not_found') end), { n = 3, false, nil, 'not_found' })
    H.Equal(run(function(id) H.TriggerNetEvent('__ugcb:res:ug-core', 7, id, false, 'made up') end), { n = 3, false, nil, 'internal_error' })
    H.Equal(run(function() H.Advance(10000) end), { n = 3, false, nil, 'timeout' })
    H.Equal(run(function() H.TriggerEvent('playerDropped', 7, 'Exiting') end), { n = 3, false, nil, 'timeout' })
end)

-- Client side

---Fresh client runtime.
local function client()
    H.ResetNetwork()
    H.LoadManifest('client')
end

H.Test('Client Await sends the caller resource and resolves on the reply', function()
    client()

    local thread = H.Thread(function()
        return table.pack(UgCore.Callback.Await('ug-banking:GetBalance', 'cash'))
    end)

    local request = H.Net.server[1]

    H.Equal(request.name, '__ugcb:ug-banking:GetBalance')
    H.Equal({ request.args[1], request.args[3] }, { 'ug-core', 'cash' })

    H.TriggerNetEvent('__ugcb:res:ug-core', nil, request.args[2], true, 50)

    H.Equal(thread.result, { n = 3, true, 50 })
end)

H.Test('Client Await returns error codes and times out after 10 s', function()
    client()

    local failed = H.Thread(function()
        return table.pack(UgCore.Callback.Await('ug-banking:GetBalance'))
    end)

    H.TriggerNetEvent('__ugcb:res:ug-core', nil, H.Net.server[1].args[2], false, 'rate_limited')
    H.Equal(failed.result, { n = 3, false, nil, 'rate_limited' })

    local slow = H.Thread(function()
        return table.pack(UgCore.Callback.Await('ug-banking:GetBalance'))
    end)

    H.Advance(10000)
    H.Equal(slow.result, { n = 3, false, nil, 'timeout' })

    H.TriggerNetEvent('__ugcb:res:ug-core', nil, H.Net.server[2].args[2], true, 1)
    H.Equal(slow.result, { n = 3, false, nil, 'timeout' })
end)

H.Test('Client callbacks answer server requests', function()
    client()

    UgCore.Callback.Register('GetSettings', function(key) return key .. '!' end)
    UgCore.Callback.Register('Crash', function() error('client detail', 0) end)

    H.TriggerNetEvent('__ugcb:ug-core:GetSettings', nil, 'ug-banking', 4, 'volume')

    H.Capture(function()
        H.TriggerNetEvent('__ugcb:ug-core:Crash', nil, 'ug-banking', 5)
    end)

    UgCore.Callback.Unregister('GetSettings')
    H.TriggerNetEvent('__ugcb:ug-core:GetSettings', nil, 'ug-banking', 6, 'volume')

    H.Equal(H.Net.server, {
        { name = '__ugcb:res:ug-banking', args = { n = 3, 4, true, 'volume!' } },
        { name = '__ugcb:res:ug-banking', args = { n = 3, 5, false, 'internal_error' } },
        { name = '__ugcb:res:ug-banking', args = { n = 3, 6, false, 'not_found' } },
    })
end)

H.Test('Client net events and TriggerServer', function()
    client()

    local received

    UgCore.Network.Register('Update', function(...) received = { ... } end)
    H.TriggerNetEvent('ug-core:Update', nil, 1, 2)
    UgCore.Network.TriggerServer('ug-banking:Deposit', 'cash', 5)

    H.Equal(received, { 1, 2 })
    H.Equal(H.Net.server[1], { name = 'ug-banking:Deposit', args = { n = 2, 'cash', 5 } })
end)

H.Done()
