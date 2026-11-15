--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type table[]
local failures

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.ResetAces()
    H.Aces = {
        ['resource.ug-core:command.add_ace'] = true,
    }
    H.DiskModules = true
    H.Metadata = {
        ug_module = { 'identity', 'players', 'permissions', 'commands' },
    }

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    H.Capture(function()
        H.LoadManifest('server')
    end)

    failures = {}

    UgCore.Events.On('ug-core:Commands:Failed', function(...)
        failures[#failures + 1] = table.pack(...)
    end)
end

---@param args? UgCommandArgument[]
---@param options? table
---@return table calls received args, one entry per call
local function register(args, options)
    local calls = {}
    local merged = {
        args = args,
    }

    for key, value in pairs(options or {}) do
        merged[key] = value
    end

    UgCore.Commands.Register('give', merged, function(source, parsed)
        calls[#calls + 1] = { source, parsed }
    end)

    return calls
end

H.Test('Arguments are parsed by type and passed by name', function()
    fresh()

    local calls = register({
        {
            name = 'target',
            type = 'player',
        },
        {
            name = 'amount',
            type = 'integer',
        },
        {
            name = 'note',
            type = 'text',
            optional = true,
        },
    })

    H.RunCommand('give', 1, { '2', '500', 'for', 'the', 'car' })
    H.RunCommand('give', 1, { '3', '7' })

    H.Equal(calls, {
        {
            1,
            {
                target = 2,
                amount = 500,
                note = 'for the car',
            },
        },
        {
            1,
            {
                target = 3,
                amount = 7,
            },
        },
    })
end)

H.Test('Invalid arguments emit Failed with the argument index', function()
    fresh()

    local calls = register({
        {
            name = 'target',
            type = 'player',
        },
        {
            name = 'amount',
            type = 'integer',
        },
    }, {
        rate = {
            max = 10,
            per = 1000,
        },
    })

    H.RunCommand('give', 1, { '9', '5' })
    H.RunCommand('give', 1, { '2', '5.5' })
    H.RunCommand('give', 1, { '2' })
    H.RunCommand('give', 1, { '2', '5', 'extra' })

    H.Equal(#calls, 0)
    H.Equal(failures, {
        {
            n = 4,
            1,
            'give',
            'invalid_args',
            1,
        },
        {
            n = 4,
            1,
            'give',
            'invalid_args',
            2,
        },
        {
            n = 4,
            1,
            'give',
            'invalid_args',
            2,
        },
        {
            n = 4,
            1,
            'give',
            'invalid_args',
            3,
        },
    })
end)

H.Test('Strings are bounded and control characters rejected', function()
    fresh()

    local calls = register({
        {
            name = 'name',
            type = 'string',
            max = 4,
        },
    })

    H.RunCommand('give', 1, { 'abcd' })
    H.RunCommand('give', 1, { 'abcde' })
    H.RunCommand('give', 1, { 'a\0b' })

    H.Equal(#calls, 1)
    H.Equal(#failures, 2)
end)

H.Test('Permissions and loaded checks emit Failed', function()
    fresh()

    local calls = register({}, {
        permission = 'ug.admin',
        requirePlayer = true,
    })

    H.Net.states[1]['ug-core:Loaded'] = false
    H.RunCommand('give', 1, {})
    H.Equal(failures[1][3], 'not_loaded')

    H.Net.states[1]['ug-core:Loaded'] = true
    H.RunCommand('give', 1, {})
    H.Equal(failures[2][3], 'no_permission')

    H.Aces['1:ug.admin'] = true
    H.RunCommand('give', 1, {})
    H.Equal(#calls, 1)
end)

H.Test('Players are rate limited per command', function()
    fresh()

    local calls = register({}, {
        rate = {
            max = 2,
            per = 1000,
        },
    })

    for _ = 1, 4 do
        H.RunCommand('give', 1, {})
    end

    H.RunCommand('give', 2, {})

    H.Equal(#calls, 3)
end)

H.Test('The console skips player checks and prints usage on errors', function()
    fresh()

    local calls = register({
        {
            name = 'amount',
            type = 'integer',
        },
    }, {
        permission = 'ug.admin',
    })

    H.RunCommand('give', 0, { '5' })
    H.Equal(calls[1], {
        0,
        {
            amount = 5,
        },
    })
    H.Equal(H.RunCommand('give', 0, { 'x' }), { 'give: invalid_args. Usage: /give <amount>' })

    UgCore.Commands.Register('players', {
        console = false,
    }, function() end)
    H.Equal(H.RunCommand('players', 0, {}), { 'players is not available from the server console.' })
end)

H.Test('Handler errors are logged and reported as internal_error', function()
    fresh()

    UgCore.Commands.Register('crash', {}, function() error('secret', 0) end)

    local lines = H.RunCommand('crash', 1, {})

    H.Equal(lines, { '^1[ERROR]^7 Commands: /crash failed: secret' })
    H.Equal(failures[1][3], 'internal_error')
end)

H.Test('Register rejects bad definitions', function()
    fresh()

    H.Raises(function()
        UgCore.Commands.Register('Give', {}, function() end)
    end, 'Commands.Register expects a lowercase name')

    H.Raises(function()
        UgCore.Commands.Register('a', {
            args = {
                {
                    name = 'x',
                    type = 'text',
                },
                {
                    name = 'y',
                    type = 'string',
                },
            },
        }, function() end)
    end, 'a text argument MUST be last')

    H.Raises(function()
        UgCore.Commands.Register('b', {
            args = {
                {
                    name = 'x',
                    type = 'string',
                    optional = true,
                },
                {
                    name = 'y',
                    type = 'string',
                },
            },
        }, function() end)
    end, 'optional arguments MUST be trailing')

    H.Raises(function()
        UgCore.Commands.Register('c', {
            args = {
                {
                    name = 'x',
                    type = H.Any('vector'),
                },
            },
        }, function() end)
    end, 'argument 1 MUST have a name and a type')
end)

H.Test('GetAll lists commands for chat suggestions', function()
    fresh()

    register({
        {
            name = 'amount',
            type = 'integer',
            help = 'How much',
        },
    }, {
        help = 'Give money',
        permission = 'ug.admin',
    })

    H.Equal(UgCore.Commands.GetAll(), {
        {
            name = 'give',
            help = 'Give money',
            permission = 'ug.admin',
            args = {
                {
                    name = 'amount',
                    type = 'integer',
                    help = 'How much',
                },
            },
        },
    })
end)

-- Groups

---@param source integer
---@param group string
local function join(source, group)
    H.Capture(function()
        H.Thread(function()
            UgCore.Permissions.AddGroup(source, group)
        end)
    end)
end

H.Test('Any listed group allows the command, inheritance included', function()
    fresh()

    local calls = register({}, {
        groups = { 'moderator', 'admin' },
    })

    join(1, 'moderator')
    join(2, 'founder')

    H.RunCommand('give', 1, {})
    H.RunCommand('give', 2, {})
    H.RunCommand('give', 3, {})

    H.Equal(#calls, 2)
    H.Equal(#failures, 1)
    H.Equal(failures[1][1], 3)
    H.Equal(failures[1][3], 'no_permission')
end)

H.Test('Permission and groups MUST both pass', function()
    fresh()

    local calls = register({}, {
        permission = 'my-admin.ban',
        groups = { 'admin' },
    })

    join(1, 'admin')
    H.RunCommand('give', 1, {})
    H.Equal(failures[1][3], 'no_permission')

    H.Aces['2:my-admin.ban'] = true
    H.RunCommand('give', 2, {})
    H.Equal(failures[2][3], 'no_permission')

    H.Aces['1:my-admin.ban'] = true
    H.RunCommand('give', 1, {})
    H.Equal(#calls, 1)
end)

H.Test('The console ignores groups', function()
    fresh()

    local calls = register({}, {
        groups = { 'founder' },
    })

    H.RunCommand('give', 0, {})

    H.Equal(#calls, 1)
end)

H.Test('Register validates groups and warns about unknown ones', function()
    fresh()

    H.Raises(function()
        UgCore.Commands.Register('a', {
            groups = {},
        }, function() end)
    end, 'groups MUST be an array of 1 to 16 group names')

    H.Raises(function()
        UgCore.Commands.Register('b', {
            groups = H.Any('admin'),
        }, function() end)
    end, 'groups MUST be an array of 1 to 16 group names')

    H.Raises(function()
        UgCore.Commands.Register('c', {
            groups = { 'Admin' },
        }, function() end)
    end, 'groups MUST hold lowercase group names')

    H.Raises(function()
        UgCore.Commands.Register('d', {
            permission = H.Any(5),
        }, function() end)
    end, 'permission MUST be an ACE name')

    local lines = H.Capture(function()
        UgCore.Commands.Register('e', {
            groups = { 'owner' },
        }, function() end)
    end)

    H.Equal(lines, {
        '^3[WARN]^7 Commands: /e allows group "owner", which is not in config/permissions.lua. Nobody matches it.',
    })
    H.Equal(UgCore.Commands.CanUse(0, 'e'), true)
end)

H.Test('CanUse checks permission and groups for menus and suggestions', function()
    fresh()

    register({}, {
        groups = { 'admin' },
    })
    UgCore.Commands.Register('local', {
        console = false,
    }, function() end)

    join(1, 'founder')

    H.Equal(UgCore.Commands.CanUse(1, 'give'), true)
    H.Equal(UgCore.Commands.CanUse(2, 'give'), false)
    H.Equal(UgCore.Commands.CanUse(2, 'missing'), false)
    H.Equal(UgCore.Commands.CanUse(0, 'give'), true)
    H.Equal(UgCore.Commands.CanUse(0, 'local'), false)
    H.Equal(UgCore.Commands.GetAll()[1].groups, { 'admin' })

    H.Raises(function()
        UgCore.Commands.CanUse(H.Any('1'), 'give')
    end, 'Commands.CanUse expects a player source')
end)

H.Test('A handler from another resource may be a callable table', function()
    fresh()

    local calls = {}
    local handler = setmetatable({}, {
        __call = function(_, source, parsed)
            calls[#calls + 1] = { source, parsed }
        end,
    })

    UgCore.Commands.Register('heal', {
        args = {
            {
                name = 'target',
                type = 'player',
            },
        },
    }, H.Any(handler))
    H.RunCommand('heal', 1, { '2' })

    H.Equal(calls, {
        {
            1,
            {
                target = 2,
            },
        },
    })
end)

H.Test('Commands of a stopped resource are removed and may be registered again', function()
    fresh()

    local first, second = {}, {}

    AddEventHandler('test:register', function()
        UgCore.Commands.Register('heal', {}, function(source)
            first[#first + 1] = source
        end)
    end)

    H.TriggerEventAs('ug-admin', 'test:register')
    H.TriggerEvent('onResourceStop', nil, 'other-resource')
    H.RunCommand('heal', 1, {})
    H.Equal(first, { 1 })

    H.TriggerEvent('onResourceStop', nil, 'ug-admin')
    H.RunCommand('heal', 1, {})
    H.Equal(first, { 1 })
    H.Equal(UgCore.Commands.CanUse(1, 'heal'), false)

    UgCore.Commands.Register('heal', {}, function(source)
        second[#second + 1] = source
    end)

    H.RunCommand('heal', 2, {})
    H.Equal(second, { 2 })
end)

-- Chat suggestions

---@param name string
---@param target integer
---@return any[] arguments of each client event with that name sent to that player
local function sentTo(name, target)
    local found = {}

    for _, record in ipairs(H.ClientEvents(name)) do
        if record.target == target then
            found[#found + 1] = record.args[1]
        end
    end

    return found
end

local REPORT = {
    name = '/report',
    help = 'Ask staff',
    params = {
        {
            name = 'message',
            help = 'text',
        },
    },
}
local HEAL = {
    name = '/heal',
    help = 'Heal a player',
    params = {
        {
            name = '[target]',
            help = 'Player id',
        },
    },
}

---@param run fun()
local function frame(run)
    H.Capture(function()
        H.Thread(run)
        H.Advance(0)
    end)
end

H.Test('Players get chat suggestions for the commands they may use, with argument hints', function()
    fresh()
    H.Net.resources.chat = 'started'

    frame(function()
        UgCore.Commands.Register('heal', {
            help = 'Heal a player',
            groups = { 'moderator' },
            args = {
                {
                    name = 'target',
                    type = 'player',
                    optional = true,
                    help = 'Player id',
                },
            },
        }, function() end)
        UgCore.Commands.Register('report', {
            help = 'Ask staff',
            args = {
                {
                    name = 'message',
                    type = 'text',
                },
            },
        }, function() end)
    end)

    -- Both commands in one batch, and only what the player may use.
    H.Equal(sentTo('chat:addSuggestions', 1), { { REPORT } })

    frame(function()
        UgCore.Permissions.AddGroup(1, 'moderator')
    end)
    H.Equal(sentTo('chat:addSuggestions', 1)[2], { HEAL, REPORT })
    H.Equal(sentTo('chat:addSuggestions', 2)[2], { REPORT })

    frame(function()
        UgCore.Permissions.RemoveGroup(1, 'moderator')
    end)
    H.Equal(sentTo('chat:removeSuggestion', 1), { '/heal' })
    H.Equal(sentTo('chat:removeSuggestion', 2), {})
end)

H.Test('Suggestions follow a stopped resource, and wait for the chat resource', function()
    fresh()

    AddEventHandler('test:register', function()
        UgCore.Commands.Register('heal', {}, function() end)
    end)

    frame(function()
        H.TriggerEventAs('ug-admin', 'test:register')
    end)
    H.Equal(#H.ClientEvents('chat:addSuggestions'), 0)

    H.Net.resources.chat = 'started'
    H.Capture(function()
        H.TriggerEvent('onResourceStart', nil, 'chat')
        H.Advance(2000)
        H.Advance(0)
    end)
    H.Equal(#sentTo('chat:addSuggestions', 1), 1)

    frame(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-admin')
    end)
    H.Equal(sentTo('chat:removeSuggestion', 1), { '/heal' })
end)

H.Done()
