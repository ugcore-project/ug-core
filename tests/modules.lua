--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@class TestModule
---@field fields? string Lua source inserted into the definition table
---@field files? table<string, string> path under the module folder -> Lua source
---@field schema? string Lua source of config.schema.lua

---Installs fake modules on a clean disk. Order of `names` is the manifest order.
---@param names string[]
---@param modules table<string, TestModule>
local function install(names, modules)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.Metadata = { ug_module = names }

    for name, module in pairs(modules) do
        local namespace = name:sub(1, 1):upper() .. name:sub(2)

        H.ResourceFiles[('modules/%s/module.lua'):format(name)] = ("return { name = '%s', namespace = '%s', description = 'Module %s.', %s }")
            :format(name, namespace, name, module.fields or '')

        for path, source in pairs(module.files or {}) do
            H.ResourceFiles[('modules/%s/%s'):format(name, path)] = source
        end

        if module.schema then
            H.ResourceFiles[('modules/%s/config.schema.lua'):format(name)] = module.schema
        end
    end
end

---Prints `<hook> <name>` from every hook.
local HOOKS = [[
    Init = function(ctx) print('init ' .. ctx.name) end,
    Start = function(ctx) print('start ' .. ctx.name) end,
    Stop = function(ctx) print('stop ' .. ctx.name) end,
]]

---@param lines string[]
---@param text string
---@return boolean
local function contains(lines, text)
    for index = 1, #lines do
        if lines[index]:find(text, 1, true) then
            return true
        end
    end

    return false
end

---Lines printed by test modules: no log tags, no banner.
---@param lines string[]
---@return string[]
local function only(lines)
    local result = {}

    for index = 1, #lines do
        local line = lines[index]

        if line ~= '' and line:sub(1, 1) ~= '^' and not line:find('\n', 1, true) then
            result[#result + 1] = line
        end
    end

    return result
end

-- Boot

H.Test('Boot without modules reaches Ready with a summary', function()
    install({}, {})

    local lines = H.LoadManifest('server')

    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    H.Assert(contains(lines, 'ug-core v0.0.0-test ready in '), 'summary missing')
    H.Assert(contains(lines, '. 0 modules enabled.'), 'module count missing')
    H.Assert(H.ResourceFiles['config/modules.lua'] ~= nil, 'config/modules.lua not generated')
    H.Equal(H.RunCommand('ug', 0, { 'modules' }), { 'No modules installed.' })
end)

H.Test('Modules load in dependency order', function()
    install({ 'accounts', 'characters' }, {
        accounts = { fields = "deps = { 'characters' }, " .. HOOKS },
        characters = { fields = HOOKS },
    })

    local lines = H.LoadManifest('server')

    H.Equal(only(lines), { 'init characters', 'init accounts', 'start characters', 'start accounts' })
    H.Equal(UgCore.Modules.GetEnabled(), { 'characters', 'accounts' })
    H.Assert(contains(lines, '. 2 modules enabled.'), 'module count missing')
end)

H.Test('Enabled optional dependencies load first', function()
    install({ 'accounts', 'jobs' }, {
        accounts = { fields = "optionalDeps = { 'jobs' }, " .. HOOKS },
        jobs = { fields = HOOKS },
    })

    local lines = H.LoadManifest('server')

    H.Equal(only(lines), { 'init jobs', 'init accounts', 'start jobs', 'start accounts' })
end)

H.Test('A disabled optional dependency does not block the module', function()
    install({ 'accounts', 'jobs' }, {
        accounts = { fields = "optionalDeps = { 'jobs', 'missing' }, " .. HOOKS },
        jobs = { fields = HOOKS, schema = "return { kind = 'settings', options = {} }" },
    })
    H.ResourceFiles['config/modules.lua'] = 'return { jobs = false }'

    local lines = H.LoadManifest('server')

    H.Equal(only(lines), { 'init accounts', 'start accounts' })
    H.Equal(UgCore.Modules.IsEnabled('jobs'), false)
    H.Equal(H.ResourceFiles['config/jobs.lua'], nil)
end)

H.Test('Required modules are always enabled and not listed in config/modules.lua', function()
    install({ 'identity', 'accounts' }, {
        identity = { fields = 'required = true, ' },
        accounts = {},
    })

    H.LoadManifest('server')

    local generated = H.ResourceFiles['config/modules.lua']

    H.Assert(generated:find('accounts = true', 1, true), 'optional module missing')
    H.Assert(not generated:find('identity', 1, true), 'required module listed')
    H.Equal(H.RunCommand('ug', 0, { 'modules' }), {
        '  accounts       enabled   enabled in config/modules.lua',
        '  identity       enabled   required',
    })
end)

-- Failures

H.Test('An enabled module with a disabled dependency aborts boot', function()
    install({ 'accounts', 'characters' }, {
        accounts = { fields = "deps = { 'characters' }" },
        characters = {},
    })
    H.ResourceFiles['config/modules.lua'] = 'return { characters = false }'

    local lines = H.LoadManifest('server')

    H.Assert(contains(lines, 'accounts requires characters. Enable characters or disable accounts.'), 'dependency error missing')
    H.Assert(contains(lines, 'Boot aborted: 1 error(s).'), 'abort line missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Missing and cyclic dependencies abort boot', function()
    install({ 'accounts' }, { accounts = { fields = "deps = { 'bank' }" } })
    H.Assert(contains(H.LoadManifest('server'), 'accounts requires bank, which is not installed.'), 'missing dependency error')

    install({ 'a', 'b', 'c' }, {
        a = { fields = "deps = { 'b' }" },
        b = { fields = "deps = { 'c' }" },
        c = { fields = "optionalDeps = { 'a' }" },
    })

    local lines = H.LoadManifest('server')

    H.Assert(contains(lines, 'Dependency cycle: a -> b -> c -> a.'), 'cycle error missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Invalid definitions abort boot with a reason', function()
    install({ 'accounts' }, { accounts = { fields = 'Int = function() end' } })
    H.Assert(contains(H.LoadManifest('server'), 'modules/accounts/module.lua: unknown field "Int". Did you mean "Init"?'), 'suggestion missing')

    install({ 'accounts' }, {})
    H.ResourceFiles['modules/accounts/module.lua'] = "return { name = 'bank', namespace = 'Bank', description = 'x' }"
    H.Assert(contains(H.LoadManifest('server'), 'modules/accounts/module.lua: name MUST be "accounts", the folder name'), 'name error missing')

    install({ 'missing' }, {})
    H.Assert(contains(H.LoadManifest('server'), 'missing file modules/missing/module.lua'), 'missing module error')

    install({ 'core' }, {})
    H.Assert(contains(H.LoadManifest('server'), 'fxmanifest.lua: invalid module name "core"'), 'reserved name error')
end)

H.Test('A failing Init aborts boot and stops initialized modules in reverse', function()
    install({ 'a', 'b', 'c' }, {
        a = { fields = HOOKS },
        b = { fields = "deps = { 'a' }, Init = function() error('db down', 0) end, Stop = function() print('stop b') end" },
        c = { fields = HOOKS },
    })

    local lines = H.LoadManifest('server')

    H.Assert(contains(lines, 'b.Init failed: db down'), 'init error missing')
    H.Equal(only(lines), { 'init a', 'stop a' })
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Missing declared files abort boot', function()
    install({ 'accounts' }, { accounts = { fields = "server = { 'api' }" } })

    H.Assert(contains(H.LoadManifest('server'), 'missing file modules/accounts/server/api.lua'), 'missing file error')
end)

-- Module code and context

H.Test('Shared files load before server files, both before Init', function()
    install({ 'accounts' }, {
        accounts = {
            fields = "shared = { 'enums' }, server = { 'api' }, Init = function() print('init accounts') end",
            files = {
                ['shared/enums.lua'] = "print('load shared')",
                ['server/api.lua'] = "print('load server')",
            },
        },
    })

    local lines = H.LoadManifest('server')

    H.Equal(only(lines), { 'load shared', 'load server', 'init accounts' })
end)

H.Test('Enabled module configs are generated and passed to the context', function()
    install({ 'accounts' }, {
        accounts = {
            fields = 'Init = function(ctx) print("cash " .. ctx.config.startingCash) end',
            schema = [[return { kind = 'settings', options = {
                { key = 'startingCash', type = 'integer', default = 500, description = 'Cash.' },
            } }]],
        },
    })

    local lines = H.LoadManifest('server')

    H.Assert(H.ResourceFiles['config/accounts.lua'] ~= nil, 'module config not generated')
    H.Equal(only(lines), { 'cash 500' })
    H.Equal(UgCore.Config.Get('accounts', 'startingCash'), 500)
end)

H.Test('Invalid module config schemas abort boot', function()
    install({ 'accounts' }, { accounts = { schema = "return { kind = 'list' }" } })

    H.Assert(contains(H.LoadManifest('server'), 'modules/accounts/config.schema.lua: kind MUST be "settings" or "data"'), 'schema error missing')
end)

H.Test('The context logger prefixes the module name', function()
    install({ 'accounts' }, { accounts = { fields = "Init = function(ctx) ctx.logger.Info('%d ready', 3) end" } })

    H.Assert(contains(H.LoadManifest('server'), '^5[INFO]^7 [accounts] 3 ready'), 'prefixed line missing')
end)

H.Test('Resource stop runs Stop in reverse order once', function()
    install({ 'accounts', 'characters' }, {
        accounts = { fields = "deps = { 'characters' }, " .. HOOKS },
        characters = { fields = HOOKS },
    })
    H.LoadManifest('server')

    local lines = H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
    end)

    H.Equal(only(lines), { 'stop accounts', 'stop characters' })
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

-- Public API

H.Test('Require raises for disabled modules', function()
    install({ 'accounts', 'jobs' }, { accounts = {}, jobs = {} })
    H.ResourceFiles['config/modules.lua'] = 'return { jobs = false }'
    H.LoadManifest('server')

    UgCore.Modules.Require('accounts')

    H.Raises(function()
        UgCore.Modules.Require('jobs')
    end, '[ug-core] Modules.Require: module "jobs" is not enabled. Enable it in config/modules.lua.')
end)

-- Client

H.Test('Clients load shared and client files of enabled modules, then reach Ready', function()
    install({ 'accounts', 'jobs' }, {
        accounts = {
            fields = "shared = { 'enums' }, client = { 'api' }",
            files = {
                ['shared/enums.lua'] = "print('shared ' .. (IsDuplicityVersion() and 'server' or 'client'))",
                ['client/api.lua'] = "print('client api')",
            },
        },
        jobs = { fields = "client = { 'api' }", files = { ['client/api.lua'] = "print('jobs api')" } },
    })
    H.ResourceFiles['config/modules.lua'] = 'return { jobs = false }'
    H.LoadManifest('server')

    local lines = H.LoadManifest('client')

    H.Equal(only(lines), { 'shared client', 'client api' })
    H.Assert(contains(lines, 'ug-core ready. 1 modules enabled.'), 'F8 ready line missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    H.Equal(UgCore.Modules.IsEnabled('accounts'), true)
    H.Equal(UgCore.Modules.IsEnabled('jobs'), false)
end)

H.Test('Clients stop when a module file fails to load', function()
    install({ 'accounts' }, {
        accounts = {
            fields = "shared = { 'enums' }, client = { 'api', 'broken' }",
            files = { ['shared/enums.lua'] = "print('enums')", ['client/broken.lua'] = "error('boom')" },
        },
    })
    H.LoadManifest('server')

    local lines = H.LoadManifest('client')

    H.Assert(contains(lines, 'missing file modules/accounts/client/api.lua'), 'missing file error')
    H.Assert(contains(lines, 'boom'), 'runtime error missing')
    H.Assert(contains(lines, 'Client boot aborted: 2 error(s).'), 'abort line missing')
    H.Assert(not contains(lines, 'ug-core ready.'), 'client reported ready')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Clients wait for the server to replicate modules', function()
    install({}, {})

    local lines = H.LoadManifest('client')

    H.Assert(not contains(lines, 'ug-core ready.'), 'client started without a payload')
    H.Equal(UgCore.Lifecycle.GetState(), 'Booting')

    lines = H.Capture(function()
        H.SetGlobalState('ug-core:Modules', { order = {}, files = {} })
    end)

    H.Assert(contains(lines, 'ug-core ready. 0 modules enabled.'), 'F8 ready line missing')
end)

-- Connections

---@return table deferrals mock
---@return string[] calls in order, with the ms since creation each happened at
local function newDeferrals()
    local calls = {}
    local start = H.Clock

    return {
        defer = function() calls[#calls + 1] = 'defer@' .. (H.Clock - start) end,
        update = function(message) calls[#calls + 1] = 'update@' .. (H.Clock - start) .. ':' .. message end,
        done = function(reason) calls[#calls + 1] = 'done@' .. (H.Clock - start) .. ':' .. tostring(reason) end,
    }, calls
end

H.Test('Connections wait for Ready', function()
    install({ 'slow' }, { slow = { fields = 'Init = function() Wait(1000) end' } })
    H.LoadManifest('server')

    H.Equal(UgCore.Lifecycle.GetState(), 'Initializing')

    local deferrals, calls = newDeferrals()

    H.Capture(function()
        H.TriggerEvent('playerConnecting', 1, 'player', function() end, deferrals)
        H.Advance(0)
        H.Advance(1000)
        H.Advance(0)
    end)

    H.Equal(calls, {
        'defer@0',
        'update@0:The server is starting. Please wait.',
        'done@1000:nil',
    })
end)

H.Test('Connections are rejected when boot aborted', function()
    install({ 'accounts' }, { accounts = { fields = "deps = { 'bank' }" } })
    H.LoadManifest('server')

    local deferrals, calls = newDeferrals()

    H.Capture(function()
        H.TriggerEvent('playerConnecting', 1, 'player', function() end, deferrals)
        H.Advance(0)
        H.Advance(0)
    end)

    H.Equal(calls[#calls], 'done@0:The server is not ready. Try again later.')
end)

H.Test('Connections pass through once Ready', function()
    install({}, {})
    H.LoadManifest('server')

    local deferrals, calls = newDeferrals()

    H.TriggerEvent('playerConnecting', 1, 'player', function() end, deferrals)

    H.Equal(calls, {})
end)

H.Done()
