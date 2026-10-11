--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---Clean disk, KVP, convars and GlobalState, then a server boot with default config.
local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.LoadManifest('server')
end

---@return boolean ok
---@return string[] errors
---@return string[] lines printed while loading
local function load()
    local ok, errors
    local lines = H.Capture(function()
        ok, errors = UgCore.Internal.Config.Loader.Load()
    end)

    return ok, errors, lines
end

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

---@param options UgConfigOption[]
local function registerAccounts(options)
    UgCore.Internal.Config.Register('accounts', { kind = 'settings', options = options })
end

-- Generation

H.Test('Missing config file is generated and loads back to the defaults', function()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.ResetGlobalState()

    local lines = H.LoadManifest('server')
    local content = H.ResourceFiles['config/core.lua']

    H.Assert(content ~= nil, 'config/core.lua was not generated')
    H.Assert(contains(lines, 'Config: generated config/core.lua.'), 'generation not logged')
    H.Assert(content:find('-- Convar: ug-core:Debug.', 1, true), 'convar hint missing')
    H.Equal(UgCore.Config.Get('core'), { locale = 'en', debug = false })
end)

H.Test('Existing files are never rewritten', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = 'return { debug = true }'

    load()

    H.Equal(H.ResourceFiles['config/core.lua'], 'return { debug = true }')
end)

H.Test('Generated files round-trip every value type', function()
    fresh()

    local defaults = {
        text = "it's \"quoted\"\nline",
        whole = -3,
        fraction = 0.1,
        integral = 2.0,
        flag = true,
        position = vector3(1.5, -2, 3),
        nested = { list = { 'a', 'b' }, ['with space'] = 1, ['end'] = false },
    }

    registerAccounts({
        { key = 'text', type = 'string', default = defaults.text, description = 'Text.' },
        { key = 'whole', type = 'integer', default = defaults.whole, description = 'Whole.' },
        { key = 'fraction', type = 'number', default = defaults.fraction, description = 'Fraction.' },
        { key = 'integral', type = 'number', default = defaults.integral, description = 'Integral float.' },
        { key = 'flag', type = 'boolean', default = defaults.flag, description = 'Flag.' },
        { key = 'position', type = 'vector3', default = defaults.position, description = 'Position.' },
        { key = 'nested', type = 'table', default = defaults.nested, description = 'Multi\nline description.' },
    })

    local ok, errors = load()

    H.Equal(ok, true, table.concat(errors, '; '))
    H.Equal(UgCore.Config.Get('accounts'), defaults)
    H.Equal(math.type(UgCore.Config.Get('accounts', 'integral')), 'float')

    local entry = UgCore.Internal.Config.GetEntry('accounts')

    H.Equal(entry and entry.sources and entry.sources.text, 'file')
end)

H.Test('Data configs are generated with their default', function()
    fresh()
    UgCore.Internal.Config.Register('jobs', {
        kind = 'data',
        description = 'Jobs.',
        default = { police = { label = 'Police' } },
    })

    H.Equal((load()), true)
    H.Equal(UgCore.Config.Get('jobs'), { police = { label = 'Police' } })
end)

-- Owner files

H.Test('Owner files merge per key', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = 'return { debug = true }'

    H.Equal((load()), true)
    H.Equal(UgCore.Config.Get('core'), { locale = 'en', debug = true })
    H.Equal(UgCore.Internal.Config.GetEntry('core').sources, { locale = 'default', debug = 'file' })
end)

H.Test('Unknown owner keys warn with a suggestion and are ignored', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = 'return { Debug = true, zzzzzz = 1 }'

    local ok, _, lines = load()

    H.Equal(ok, true)
    H.Assert(contains(lines, 'config/core.lua: unknown option "Debug" is ignored. Did you mean "debug"?'), 'suggestion missing')
    H.Assert(contains(lines, 'config/core.lua: unknown option "zzzzzz" is ignored.'), 'warning missing')
    H.Equal(UgCore.Config.Get('core', 'debug'), false)
end)

H.Test('Invalid owner values are collected', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = "return { debug = 'yes', locale = 'x' }"

    local ok, errors = load()

    H.Equal(ok, false)
    H.Equal(errors, {
        'config/core.lua: locale MUST be at least 2 characters, got 1',
        'config/core.lua: debug MUST be a boolean, got "yes"',
    })
end)

H.Test('Syntax errors, runtime errors and non-table returns are collected', function()
    fresh()

    H.ResourceFiles['config/core.lua'] = 'return {'
    local _, syntax = load()
    H.Assert(syntax[1]:find('config/core.lua:1:', 1, true) == 1, syntax[1])

    H.ResourceFiles['config/core.lua'] = 'local broken = nil return broken.value'
    local _, runtime = load()
    H.Assert(runtime[1]:find("config/core.lua:1: attempt to index a nil value (local 'broken')", 1, true), runtime[1])

    H.ResourceFiles['config/core.lua'] = 'return 5'
    local _, shape = load()
    H.Equal(shape, { 'config/core.lua MUST return a table, got 5' })
end)

H.Test('Owner files run in a sandbox', function()
    fresh()

    H.ResourceFiles['config/core.lua'] = 'os.exit(1)'
    local ok, errors = load()
    H.Equal(ok, false)
    H.Assert(errors[1]:find("global 'os'", 1, true), errors[1])

    H.ResourceFiles['config/core.lua'] = 'print("x") return {}'
    ok = load()
    H.Equal(ok, false)

    H.ResourceFiles['config/core.lua'] = 'string.upper = nil return { locale = vec3(1, 2, 3) and math.floor(1.5) == 1 and "pt" }'
    ok, errors = load()
    H.Equal(ok, true, table.concat(errors, '; '))
    H.Equal(UgCore.Config.Get('core', 'locale'), 'pt')
    H.Equal(('a'):upper(), 'A')
    H.Assert(string.upper ~= nil)
end)

H.Test('Integral floats normalize to integers', function()
    fresh()
    registerAccounts({ { key = 'startingCash', type = 'integer', default = 500, description = 'Cash.' } })
    H.ResourceFiles['config/accounts.lua'] = 'return { startingCash = 750.0 }'

    load()

    H.Equal(math.type(UgCore.Config.Get('accounts', 'startingCash')), 'integer')
end)

H.Test('min, max, values and validate are enforced', function()
    fresh()
    registerAccounts({
        { key = 'cash', type = 'integer', default = 1, min = 0, max = 10, description = 'Cash.' },
        { key = 'mode', type = 'string', default = 'a', values = { 'a', 'b' }, description = 'Mode.' },
        { key = 'list', type = 'table', default = {}, max = 1, description = 'List.' },
        {
            key = 'even',
            type = 'integer',
            default = 2,
            description = 'Even.',
            validate = function(value) return value % 2 == 0, 'MUST be even' end,
        },
    })
    H.ResourceFiles['config/accounts.lua'] = "return { cash = 11, mode = 'c', list = { 1, 2 }, even = 3 }"

    local _, errors = load()

    H.Equal(errors, {
        'config/accounts.lua: cash MUST be at most 10, got 11',
        'config/accounts.lua: mode MUST be one of "a", "b", got "c"',
        'config/accounts.lua: list MUST be at most 1 entries, got 2',
        'config/accounts.lua: even MUST be even',
    })
end)

H.Test('Data owner files replace the default and entries are validated', function()
    fresh()
    UgCore.Internal.Config.Register('jobs', {
        kind = 'data',
        description = 'Jobs.',
        default = { police = { label = 'Police' } },
        validate = function(entry) return type(entry.label) == 'string', 'MUST have a label' end,
    })
    H.ResourceFiles['config/jobs.lua'] = "return { mechanic = { label = 'Mechanic' } }"

    H.Equal((load()), true)
    H.Equal(UgCore.Config.Get('jobs'), { mechanic = { label = 'Mechanic' } })
    H.Equal(UgCore.Config.Get('jobs', 'police'), nil)

    H.ResourceFiles['config/jobs.lua'] = 'return { taxi = {} }'

    local ok, errors = load()

    H.Equal(ok, false)
    H.Equal(errors, { 'config/jobs.lua: entry "taxi" MUST have a label' })
end)

-- Convars

H.Test('Convars override owner files', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = 'return { debug = false }'
    H.Convars['ug-core:Debug'] = 'true'

    load()

    H.Equal(UgCore.Config.Get('core', 'debug'), true)
    H.Equal(UgCore.Internal.Config.GetEntry('core').sources.debug, 'convar')
end)

H.Test('Convar names are ug-core:<Config>:<Key> outside core', function()
    fresh()
    registerAccounts({ { key = 'startingCash', type = 'integer', default = 500, description = 'Cash.' } })
    H.Convars['ug-core:Accounts:StartingCash'] = '900'

    load()

    H.Equal(UgCore.Config.Get('accounts', 'startingCash'), 900)
end)

H.Test('Invalid and unsupported convars are collected', function()
    fresh()
    registerAccounts({
        { key = 'cash', type = 'integer', default = 1, description = 'Cash.' },
        { key = 'spawn', type = 'vector3', default = vector3(0, 0, 0), description = 'Spawn.' },
    })
    H.Convars['ug-core:Accounts:Cash'] = 'lots'
    H.Convars['ug-core:Accounts:Spawn'] = '1,2,3'

    local ok, errors = load()

    H.Equal(ok, false)
    H.Equal(errors, {
        'convar ug-core:Accounts:Cash: MUST be an integer, got "lots"',
        'convar ug-core:Accounts:Spawn: cannot be set by convar, type vector3 is not supported',
    })
end)

-- New options

H.Test('Options added by an update are logged once', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = "return { locale = 'en' }"
    H.Kvp['ug-core:Config:Known:core'] = 'locale'

    local _, _, first = load()
    local _, _, second = load()

    H.Assert(contains(first, 'core.debug is new. Using default false. Add it to config/core.lua to change it.'), 'new option not logged')
    H.Assert(not contains(second, 'is new'), 'new option logged twice')
    H.Equal(H.Kvp['ug-core:Config:Known:core'], 'locale,debug')
end)

H.Test('New options already in the owner file are not reported', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = 'return { debug = true }'
    H.Kvp['ug-core:Config:Known:core'] = 'locale'

    local _, _, lines = load()

    H.Assert(not contains(lines, 'is new'), 'reported an option the owner already set')
end)

-- Get

H.Test('Get returns deep copies', function()
    fresh()
    registerAccounts({ { key = 'list', type = 'table', default = { 1, 2 }, description = 'List.' } })
    load()

    local list = UgCore.Config.Get('accounts', 'list')
    list[1] = 99

    H.Equal(UgCore.Config.Get('accounts', 'list'), { 1, 2 })
end)

H.Test('Get raises on unknown names and keys', function()
    fresh()

    H.Raises(function()
        UgCore.Config.Get('acounts')
    end, '[ug-core] Config.Get: unknown config "acounts"')

    H.Raises(function()
        UgCore.Config.Get('core', 'debgu')
    end, 'Config.Get: unknown option "core.debgu". Did you mean "debug"?')
end)

-- Definitions

H.Test('Register rejects invalid definitions', function()
    fresh()

    local Register = UgCore.Internal.Config.Register

    H.Raises(function()
        Register('bad', H.Any({ kind = 'settings', options = { { key = 'cash', type = 'integer', default = 'x', description = 'C.' } } }))
    end, 'Config.Register("bad"): option "cash" default fails its own validation: MUST be an integer, got "x"')

    H.Raises(function()
        Register('bad', H.Any({ kind = 'settings', options = { { key = 'cash', type = 'money', default = 1, description = 'C.' } } }))
    end, 'option "cash" type MUST be one of')

    H.Raises(function()
        Register('bad', H.Any({ kind = 'settings', options = {
            { key = 'cash', type = 'integer', default = 1, description = 'C.' },
            { key = 'cash', type = 'integer', default = 1, description = 'C.' },
        } }))
    end, 'option "cash" is declared twice')

    H.Raises(function()
        Register('bad', H.Any({ kind = 'settings', options = { { key = 'cash', type = 'integer', default = 1, description = 'C.', mx = 5 } } }))
    end, 'option "cash" has an unknown field "mx". Did you mean "max"?')

    H.Raises(function()
        Register('Bad', { kind = 'settings', options = {} })
    end, 'config names MUST be camelCase')

    H.Raises(function()
        Register('core', { kind = 'settings', options = {} })
    end, '"core" is already registered')
end)

-- Replication

H.Test('Only client and shared values replicate', function()
    fresh()
    registerAccounts({
        { key = 'secret', type = 'string', default = 's', description = 'Server only.' },
        { key = 'shown', type = 'integer', default = 1, side = 'client', description = 'Client.' },
    })
    load()

    H.Equal(GlobalState['ug-core:Config'], {
        core = { kind = 'settings', values = { locale = 'en', debug = false } },
        accounts = { kind = 'settings', values = { shown = 1 } },
    })
end)

H.Test('Clients read replicated values and follow updates', function()
    fresh()

    local lines = H.LoadManifest('client')

    H.Assert(contains(lines, 'Config: received 1 config(s).'), 'F8 line missing')
    H.Equal(UgCore.Config.Get('core', 'debug'), false)

    H.Capture(function()
        H.SetGlobalState('ug-core:Config', { core = { kind = 'settings', values = { locale = 'pt', debug = true } } })
    end)

    H.Equal(UgCore.Config.Get('core', 'locale'), 'pt')
    H.Equal(UgCore.Internal.Logger.IsDebug(), true)
end)

H.Test('Clients cannot read server-only configs', function()
    fresh()
    H.LoadManifest('client')

    H.Raises(function()
        UgCore.Config.Get('accounts')
    end, 'Config.Get: unknown or server-only config "accounts"')

    H.Raises(function()
        UgCore.Config.Get('core', 'secret')
    end, 'Config.Get: unknown or server-only option "core.secret"')
end)

-- ug command

H.Test('ug config shows values with their source', function()
    fresh()
    H.ResourceFiles['config/core.lua'] = "return { locale = 'pt' }"
    H.Convars['ug-core:Debug'] = 'true'
    load()

    H.Equal(H.RunCommand('ug', 0, { 'config', 'core' }), {
        'config/core.lua',
        "  locale = 'pt' (file)",
        '  debug = true (convar ug-core:Debug)',
    })
end)

H.Test('ug lifecycle shows the state history', function()
    fresh()

    local lines = H.RunCommand('ug', 0, { 'lifecycle' })

    H.Equal(#lines, 5)
    H.Assert(lines[5]:find('Ready', 1, true), lines[5])
end)

H.Test('ug is limited to the console and ug.admin', function()
    fresh()

    H.Equal(H.RunCommand('ug', 5, { 'lifecycle' }), {})

    H.Aces['5:ug.admin'] = true
    H.Equal(#H.RunCommand('ug', 5, { 'lifecycle' }), 5)
    H.Aces['5:ug.admin'] = nil

    H.Equal(H.RunCommand('ug', 0, { 'nope' }), { 'Usage: ug <config|database|groups|guard|hooks|inventory|items|lifecycle|modules|shops|version|weapon>' })
    H.Equal(H.RunCommand('ug', 0, { 'config', 'nope' }), { 'Unknown config "nope".' })
end)

H.Done()
