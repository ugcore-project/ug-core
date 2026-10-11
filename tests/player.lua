--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { resource: string?, args: any[] }[]
local calls

---Real identity and players modules, a fake accounts module that records calls, and a disabled jobs module.
local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'accounts', 'jobs' } }

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    H.ResourceFiles['modules/accounts/module.lua'] = [[return {
        name = 'accounts', namespace = 'Accounts', description = 'Accounts.', server = { 'api' },
    }]]
    H.ResourceFiles['modules/accounts/server/api.lua'] = [[
        UgCore.Accounts = {}
        function UgCore.Accounts.Add(source, account, amount, reason)
            TestAccountCalls[#TestAccountCalls + 1] = { resource = GetInvokingResource(), args = { source, account, amount, reason } }
            return true, source * 1000 + amount
        end
    ]]
    H.ResourceFiles['modules/jobs/module.lua'] = "return { name = 'jobs', namespace = 'Jobs', description = 'Jobs.' }"
    H.ResourceFiles['config/modules.lua'] = 'return { jobs = false }'

    calls = {}
    TestAccountCalls = calls

    H.Capture(function()
        H.LoadManifest('server')
    end)
end

H.Test('Get returns a player object with data fields', function()
    fresh()

    local player = UgCore.Players.Get(2)

    H.Assert(player ~= nil, 'player missing')
    ---@cast player -nil
    H.Equal(player.source, 2)
    H.Equal(player.identifier, 'license:2')
    H.Equal(type(player.AddMoney), 'function')
    H.Equal(UgCore.Players.Get(99), nil)
end)

H.Test('GetAll, GetByIdentifier and GetByCharacterId return player objects', function()
    fresh()

    local all = UgCore.Players.GetAll()

    H.Equal(#all, 3)

    for _, player in ipairs(all) do
        H.Equal(type(player.GetDeathState), 'function', 'player ' .. player.source)
    end

    local byIdentifier = UgCore.Players.GetByIdentifier('license:3')

    H.Equal(byIdentifier and type(byIdentifier.Kick), 'function')
end)

H.Test('Methods act on the live player through the module APIs', function()
    fresh()

    local player = assert(UgCore.Players.Get(1))

    H.Equal({ player:SetMetadata('mood', 'happy') }, { true })
    H.Equal(UgCore.Players.GetMetadata(1, 'mood'), 'happy')
    H.Equal(player:GetMetadata('mood'), 'happy')
    H.Equal(player:GetDeathState(), 'Alive')
    H.Equal(player:IsDead(), false)
    H.Equal(player:IsOnline(), true)
    H.Equal(player:IsLoaded(), true)
    H.Equal(player:GetIdentifiers(), { 'license:1' })
end)

H.Test('Methods return the results of the function they call', function()
    fresh()

    local player = assert(UgCore.Players.Get(3))

    H.Equal({ player:AddMoney('cash', 25, 'Paycheck') }, { true, 3025 })
    H.Equal(calls[1].args, { 3, 'cash', 25, 'Paycheck' })
end)

H.Test('Methods of disabled modules raise at the caller line', function()
    fresh()

    local player = assert(UgCore.Players.Get(1))
    local line = debug.getinfo(1, 'l').currentline + 2
    local message = H.Raises(function()
        player:SetJob('police')
    end, 'UgCore.Jobs belongs to disabled module "jobs". Enable it in config/modules.lua.')

    H.Assert(message:find('tests/player.lua:' .. line .. ':', 1, true) ~= nil, message)
end)

H.Test('Consumers get player objects whose methods call through their own proxy', function()
    fresh()

    local Consumer = H.LoadImport('ug-banking', 'server').UgCore
    local player = assert(Consumer.Players.Get(2))

    H.Equal(player.identifier, 'license:2')
    H.Equal({ player:AddMoney('bank', 7) }, { true, 2007 })
    H.Equal(calls[1].resource, 'ug-banking')

    local all = Consumer.Players.GetAll()

    H.Equal(#all, 3)
    H.Equal(type(all[1].RemoveMoney), 'function')
    H.Equal(Consumer.Players.Get(99), nil)
end)

H.Test('Plain data from an export becomes a player object again', function()
    fresh()

    local player = UgCore.Internal.PlayerObject.WrapOne({ source = 1, name = 'A', identifier = 'license:1', joinedAt = 0 })

    H.Equal(player and player:GetMetadata(), {})
    H.Equal(UgCore.Internal.PlayerObject.WrapOne(nil), nil)
    H.Equal(UgCore.Internal.PlayerObject.WrapAll(nil), {})
end)

H.Done()
