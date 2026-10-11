--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---Boots ug-core with `accounts` enabled and `jobs` disabled, then imports it into `ug-banking`.
---@param side? 'server'|'client'
---@return table UgCore of the consumer
local function setup(side)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.Net.resources['ug-hud'] = 'started'
    H.Metadata = { ug_module = { 'accounts', 'jobs' } }

    H.ResourceFiles['modules/accounts/module.lua'] = [[return {
        name = 'accounts', namespace = 'Accounts', description = 'Accounts.',
        server = { 'api' }, client = { 'api' },
    }]]
    H.ResourceFiles['modules/accounts/server/api.lua'] = [[
        UgCore.Accounts = {}
        function UgCore.Accounts.GetBalance(source) return source * 10 end
    ]]
    H.ResourceFiles['modules/accounts/client/api.lua'] = [[
        UgCore.Accounts = {}
        function UgCore.Accounts.GetCash() return 7 end
    ]]
    H.ResourceFiles['modules/jobs/module.lua'] = "return { name = 'jobs', namespace = 'Jobs', description = 'Jobs.' }"
    H.ResourceFiles['config/modules.lua'] = 'return { jobs = false }'

    H.LoadManifest('server')

    if side == 'client' then
        H.LoadManifest('client')
        return H.LoadImport('ug-hud', 'client').UgCore
    end

    return H.LoadImport('ug-banking', 'server').UgCore
end

-- Root

H.Test('Module namespaces proxy to ug-core exports', function()
    local UgCore = setup()

    H.Equal(UgCore.Accounts.GetBalance(5), 50)
end)

H.Test('Disabled, unknown and private namespaces raise', function()
    local UgCore = setup()

    H.Raises(function()
        return UgCore.Jobs
    end, '[ug-core] UgCore.Jobs belongs to disabled module "jobs". Enable it in config/modules.lua.')

    H.Raises(function()
        return UgCore.Bank
    end, 'UgCore.Bank is not a ug-core namespace.')

    H.Raises(function()
        return UgCore.Internal
    end, 'UgCore.Internal is private to ug-core.')
end)

H.Test('Proxy errors point to the consumer line', function()
    local UgCore = setup()
    local line = debug.getinfo(1, 'l').currentline + 2
    local message = H.Raises(function()
        return UgCore.Jobs
    end)

    H.Assert(message:find('tests/import.lua:' .. line .. ':', 1, true) ~= nil, message)
end)

H.Test('Unknown functions of a proxied namespace raise on the server', function()
    local UgCore = setup()

    H.Raises(function()
        return UgCore.Guard.Falg
    end, 'UgCore.Guard.Falg does not exist.')

    H.Raises(function()
        return UgCore.Accounts.GetBalanse
    end, 'UgCore.Accounts.GetBalanse does not exist.')
end)

H.Test('The root and proxies are read-only', function()
    local UgCore = setup()

    H.Raises(function()
        UgCore.Accounts = {}
    end, 'UgCore is read-only. Cannot set UgCore.Accounts.')

    H.Raises(function()
        UgCore.Guard.Flag = function() end
    end, 'UgCore.Guard is read-only.')
end)

H.Test('Namespaces are unavailable before ug-core replicates modules', function()
    local UgCore = setup()

    rawset(GlobalState, 'ug-core:Modules', nil)

    H.Raises(function()
        return UgCore.Accounts
    end, "UgCore.Accounts is not available until ug-core is ready. Wait for UgCore.Lifecycle.Await(UgCore.Enums.Lifecycle.Ready).")
end)

-- Core namespaces

H.Test('Guard, Config and Hooks reach the central state in ug-core', function()
    local Consumer = setup()

    Consumer.Guard.Flag(3, 'InvalidPayload', 'from ug-banking')
    H.Equal(UgCore.Guard.GetScore(3), 5)
    H.Equal(Consumer.Guard.GetScore(3), 5)

    H.Equal(Consumer.Config.Get('core', 'debug'), false)

    Consumer.Hooks.Register('Guard:BeforeAction', function() end)
    H.Equal(UgCore.Internal.Hooks.GetRegistered()[1].resource, 'ug-banking')
end)

H.Test('Local namespaces run in the consumer runtime', function()
    local Consumer = setup()

    H.Assert(Consumer.Schema ~= UgCore.Schema, 'Schema is shared with ug-core')
    H.Equal(Consumer.Modules.IsEnabled('accounts'), true)
    H.Equal(Consumer.Modules.IsEnabled('jobs'), false)
    H.Equal(Consumer.Enums.Errors.InvalidArgs, 'invalid_args')
    H.Assert(Consumer.RateLimit ~= nil, 'RateLimit missing on the server')

    local received

    Consumer.Events.On('ug-banking:Paid', function(amount) received = amount end)
    Consumer.Events.Emit('ug-banking:Paid', 5)
    H.Equal(received, 5)

    H.Raises(function()
        Consumer.Events.Emit('ug-core:Lifecycle:Ready')
    end, 'event names MUST start with "ug-banking:"')
end)

H.Test('The lifecycle mirror follows ug-core', function()
    local Consumer = setup()
    local calls = 0

    H.Equal(Consumer.Lifecycle.GetState(), 'Ready')
    H.Equal(Consumer.Lifecycle.IsReady(), true)

    Consumer.Lifecycle.On('Ready', function() calls = calls + 1 end)
    Consumer.Lifecycle.On('Stopped', function() calls = calls + 10 end)
    H.Equal(calls, 1)

    H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
    end)

    H.Equal(Consumer.Lifecycle.GetState(), 'Stopped')
    H.Equal(calls, 11)
end)

-- Network and callbacks in the consumer

H.Test('Consumer net events use the central budget and Guard', function()
    local Consumer = setup()
    local S = Consumer.Schema
    local received

    Consumer.Network.Register('Deposit', {
        schema = S.Define({ S.Integer({ min = 1, max = 1000 }) }),
        rate = { max = 5, per = 1000 },
    }, function(source, amount)
        received = { source, amount }
    end)

    H.TriggerNetEvent('ug-banking:Deposit', 4, 100)
    H.Equal(received, { 4, 100 })

    H.Capture(function()
        H.TriggerNetEvent('ug-banking:Deposit', 4, 'lots')
    end)

    H.Equal(UgCore.Guard.GetScore(4), 5)
end)

H.Test('Consumer callbacks reply to the caller resource', function()
    local Consumer = setup()
    local S = Consumer.Schema

    Consumer.Callback.Register('GetBalance', {
        schema = S.Define({}),
        rate = { max = 5, per = 1000 },
    }, function(source)
        return Consumer.Accounts.GetBalance(source)
    end)

    H.TriggerNetEvent('__ugcb:ug-banking:GetBalance', 2, 'ug-hud', 1)

    H.Equal(H.ClientEvents('__ugcb:res:ug-hud')[1].args, { n = 3, 1, true, 20 })
end)

H.Test('Enums of enabled modules load in the consumer', function()
    H.ResourceFiles = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'accounts', 'characters' } }
    H.ResourceFiles['config/modules.lua'] = 'return { accounts = false }'
    H.Capture(function()
        H.LoadManifest('server')
    end)

    local Consumer = H.LoadImport('ug-banking', 'server').UgCore

    H.Equal(Consumer.Enums.DeathState.Downed, 'Downed')
    H.Equal(Consumer.Enums.Events.Characters.Loaded, 'ug-core:Characters:Loaded')
    H.Equal(rawget(Consumer.Enums.Events, 'Accounts'), nil)

    H.DiskModules = false
end)

-- Client

H.Test('Client imports reach client exports and send callbacks as themselves', function()
    local Consumer = setup('client')

    H.Equal(Consumer.Accounts.GetCash(), 7)
    H.Equal(Consumer.Config.Get('core', 'locale'), 'en')
    H.Raises(function()
        return Consumer.RateLimit
    end, 'UgCore.RateLimit is not a ug-core namespace.')

    H.Thread(function()
        Consumer.Callback.Await('ug-banking:GetBalance')
    end)

    local request = H.Net.server[#H.Net.server]

    H.Equal({ request.name, request.args[1] }, { '__ugcb:ug-banking:GetBalance', 'ug-hud' })
end)

H.Test('A client import loaded after ug-core is ready starts ready', function()
    local Consumer = setup('client')

    H.Equal(Consumer.Lifecycle.GetState(), 'Ready')
    H.Equal(Consumer.Lifecycle.HasReached('Ready'), true)
end)

H.Done()
