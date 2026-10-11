--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

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

---@param list string[]
---@param text string
---@return integer count
local function count(list, text)
    local found = 0

    for index = 1, #list do
        if list[index]:find(text, 1, true) then
            found = found + 1
        end
    end

    return found
end

---Clean disk and database, optionally with one module. Returns the boot output.
---@param module? { fields: string, files: table<string, string>?, fail: string? }
---@return string[]
local function boot(module)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.Db.fail = module and module.fail
    H.Metadata = { ug_module = module and { 'accounts' } or {} }

    if module then
        H.ResourceFiles['modules/accounts/module.lua'] = "return { name = 'accounts', namespace = 'Accounts', description = 'Accounts.', "
            .. module.fields .. ' }'

        for path, source in pairs(module.files or {}) do
            H.ResourceFiles['modules/accounts/' .. path] = source
        end
    end

    return H.LoadManifest('server')
end

-- Repository

H.Test('Query passes SQL and params and returns rows', function()
    boot()
    H.Db.handler = function(sql) if sql:find('FROM `characters`', 1, true) then return { { id = 1 }, { id = 2 } } end end

    local ok, rows = UgCore.Internal.Database.Repository.Query('SELECT `id` FROM `characters` WHERE `owner` = ?', { 'license:abc' })

    H.Equal(ok, true)
    H.Equal(rows, { { id = 1 }, { id = 2 } })
    H.Equal(H.Db.params[#H.Db.params], { 'license:abc' })
end)

H.Test('Single, Scalar, Insert and Update shape their results', function()
    boot()

    local Repository = UgCore.Internal.Database.Repository

    H.Db.handler = function(sql)
        if sql:find('SELECT `name`', 1, true) then return { { name = 'Ana' }, { name = 'Bo' } } end
        if sql:find('SELECT COUNT', 1, true) then return { { total = 7 } } end
        if sql:find('INSERT', 1, true) then return { insertId = 42, affectedRows = 1 } end
        if sql:find('UPDATE', 1, true) then return { insertId = 0, affectedRows = 3 } end
        if sql:find('SELECT `none`', 1, true) then return {} end
    end

    H.Equal({ Repository.Single('SELECT `name` FROM `t`') }, { true, { name = 'Ana' } })
    H.Equal({ Repository.Single('SELECT `none` FROM `t`') }, { true })
    H.Equal({ Repository.Scalar('SELECT COUNT(*) AS `total` FROM `t`') }, { true, 7 })
    H.Equal({ Repository.Insert('INSERT INTO `t` (`a`) VALUES (?)', { 1 }) }, { true, 42 })
    H.Equal({ Repository.Update('UPDATE `t` SET `a` = ?', { 2 }) }, { true, 3 })
end)

H.Test('Failed queries are logged and return false', function()
    boot()
    H.Db.fail = 'broken'

    local ok, rows
    local lines = H.Capture(function()
        ok, rows = UgCore.Internal.Database.Repository.Query('SELECT broken')
    end)

    H.Equal(ok, false)
    H.Equal(rows, nil)
    H.Assert(contains(lines, 'Database: query failed: mock failure: broken'), 'error not logged')
end)

H.Test('Wrong arguments raise, including nested params', function()
    boot()

    local Repository = UgCore.Internal.Database.Repository

    H.Raises(function()
        Repository.Query(H.Any(nil))
    end, '[ug-core] Database.Query expects a SQL string')

    H.Raises(function()
        Repository.Insert('INSERT INTO `t` VALUES (?)', H.Any({ { 1 }, { 2 } }))
    end, 'Database.Insert params MUST be flat. Nested tables run as a batch')

    H.Raises(function()
        Repository.Transaction({})
    end, 'Database.Transaction expects a non-empty array')
end)

H.Test('Transaction runs every query or reports failure', function()
    boot()

    local Repository = UgCore.Internal.Database.Repository
    local queries = {
        { query = 'UPDATE `a` SET `v` = ?', values = { 1 } },
        { query = 'UPDATE `b` SET `v` = ?', values = { 2 } },
    }

    H.Equal(Repository.Transaction(queries), true)

    H.Db.fail = '`b`'

    H.Capture(function()
        H.Equal(Repository.Transaction(queries), false)
    end)
end)

-- Connection

H.Test('Boot connects and creates ug_migrations', function()
    local lines = boot()

    H.Assert(contains(lines, 'Database: connected to MariaDB 10.11.6.'), 'connection line missing')
    H.Equal(count(H.Db.executed, 'CREATE TABLE IF NOT EXISTS `ug_migrations`'), 1)
    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
end)

H.Test('Supported server versions', function()
    for version, supported in pairs({
        ['8.0.35'] = true,
        ['8.4.0'] = true,
        ['5.7.44'] = false,
        ['10.6.16-MariaDB'] = true,
        ['11.2.2-MariaDB'] = true,
        ['10.5.23-MariaDB'] = false,
    }) do
        H.ResetDb()
        H.Db.version = version

        H.Capture(function()
            H.Equal(UgCore.Internal.Database.Migrate.Connect(), supported, version)
        end)
    end
end)

H.Test('An old server aborts boot', function()
    H.ResetDb()
    H.Db.version = '5.7.44'
    H.ResourceFiles = {}

    local lines = H.LoadManifest('server')

    H.Assert(contains(lines, 'Database: MySQL 8.0 or MariaDB 10.6+ is required, found MySQL 5.7.44'), 'version error missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('No connection after 30 s aborts boot', function()
    H.ResetDb()
    H.Db.ready = false

    H.LoadManifest('server')
    H.Equal(UgCore.Lifecycle.GetState(), 'Initializing')

    local lines = H.Capture(function()
        H.Advance(30000)
    end)

    H.Assert(contains(lines, 'Database: no connection after 30 s. Check oxmysql and mysql_connection_string'), 'timeout error missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
    H.Db.ready = true
end)

-- Migrations

H.Test('Module migrations run in semver order and are recorded once', function()
    local lines = boot({
        fields = "migrations = { '1.10.0', '1.2.0', '1.0.0' }",
        files = {
            ['sql/v1.0.0.sql'] = 'CREATE TABLE `one` (`id` INT);',
            ['sql/v1.2.0.sql'] = 'CREATE TABLE `two` (`id` INT);',
            ['sql/v1.10.0.sql'] = 'CREATE TABLE `ten` (`id` INT);',
        },
    })

    local created = {}

    for _, sql in ipairs(H.Db.executed) do
        local name = sql:match('^CREATE TABLE `(%a+)`')

        if name then
            created[#created + 1] = name
        end
    end

    H.Equal(created, { 'one', 'two', 'ten' })
    H.Equal(H.Db.migrations.accounts, { '1.0.0', '1.2.0', '1.10.0' })
    H.Assert(contains(lines, 'Database: applied accounts v1.10.0.'), 'applied line missing')

    local executed = #H.Db.executed

    H.LoadManifest('server')

    H.Equal(count({ table.unpack(H.Db.executed, executed + 1) }, 'CREATE TABLE `'), 0)
end)

H.Test('Migration files split into statements and skip comments', function()
    boot({
        fields = "migrations = { '1.0.0' }",
        files = {
            ['sql/v1.0.0.sql'] = table.concat({
                '-- accounts tables',
                'CREATE TABLE `accounts` (',
                '    `id` INT NOT NULL',
                ');',
                '',
                'CREATE INDEX `owner` ON `accounts` (`id`);',
            }, '\n'),
        },
    })

    H.Equal(count(H.Db.executed, 'CREATE TABLE `accounts` (\n`id` INT NOT NULL\n)'), 1)
    H.Equal(count(H.Db.executed, 'CREATE INDEX `owner` ON `accounts` (`id`)'), 1)
    H.Equal(count(H.Db.executed, '--'), 0)
end)

H.Test('A failing migration aborts boot and is not recorded', function()
    local lines = boot({
        fail = 'BROKEN',
        fields = "migrations = { '1.0.0' }",
        files = { ['sql/v1.0.0.sql'] = 'CREATE TABLE `BROKEN` (`id` INT);' },
    })

    H.Assert(contains(lines, 'accounts migration 1.0.0 failed: mock failure: BROKEN'), 'migration error missing')
    H.Equal(H.Db.migrations.accounts, nil)
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Missing migration files and invalid versions abort boot', function()
    H.Assert(contains(boot({ fields = "migrations = { '1.0.0' }" }), 'accounts migration 1.0.0 failed: missing file modules/accounts/sql/v1.0.0.sql'), 'missing file error')
    H.Assert(contains(boot({ fields = "migrations = { 'v1' }" }), 'migrations MUST be an array of versions such as "1.0.0"'), 'version error')
end)

H.Test('Modules query through ctx.database', function()
    local lines = boot({ fields = "Init = function(ctx) local ok = ctx.database.Query('SELECT 1') print('query ' .. tostring(ok)) end" })

    H.Assert(contains(lines, 'query true'), 'ctx.database query failed')
end)

H.Test('ug database shows the server, migrations and caches', function()
    boot({
        fields = "migrations = { '1.0.0' }",
        files = { ['sql/v1.0.0.sql'] = 'CREATE TABLE `a` (`id` INT);' },
    })

    UgCore.Internal.Database.Cache.Create({ name = 'characters', flush = function() return true end }):Set(1, {})

    H.Equal(H.RunCommand('ug', 0, { 'database' }), {
        '  server   MariaDB 10.11.6',
        '  accounts 1.0.0',
        '  core     no migrations',
        '  cache    characters: 1 entries, 1 dirty',
    })
end)

-- Cache

---@return UgCache cache
---@return table[] writes every flushed { key, value }
local function newCache(options)
    local writes = {}
    local cache = UgCore.Internal.Database.Cache.Create({
        name = 'test',
        interval = options and options.interval,
        flush = options and options.flush or function(key, value)
            writes[#writes + 1] = { key, value.money }
            return true
        end,
    })

    return cache, writes
end

H.Test('Put is clean, Set and MarkDirty are flushed once', function()
    boot()

    local cache, writes = newCache()

    cache:Put(1, { money = 10 })
    cache:Set(2, { money = 20 })
    cache:Get(1).money = 15

    H.Equal(cache:MarkDirty(1), true)
    H.Equal(cache:MarkDirty(99), false)
    H.Equal(cache:Flush(), true)
    table.sort(writes, function(a, b) return a[1] < b[1] end)
    H.Equal(writes, { { 1, 15 }, { 2, 20 } })

    cache:Flush()
    H.Equal(#writes, 2)
end)

H.Test('A failed write stays dirty and retries', function()
    boot()

    local attempts = 0
    local cache = newCache({
        flush = function()
            attempts = attempts + 1
            return attempts > 1
        end,
    })

    cache:Set(1, { money = 1 })

    local lines = H.Capture(function()
        H.Equal(cache:Flush(), false)
    end)

    H.Assert(contains(lines, 'Cache test: flush of 1 failed: writer returned false'), 'failure not logged')
    H.Equal(cache:IsDirty(1), true)
    H.Equal(cache:Flush(), true)
    H.Equal(cache:IsDirty(1), false)
end)

H.Test('Edits made while writing stay dirty', function()
    boot()

    local cache
    cache = newCache({
        flush = function(_, value)
            value.money = value.money + 1
            cache:MarkDirty(1)
            return true
        end,
    })

    cache:Set(1, { money = 1 })
    cache:Flush()

    H.Equal(cache:IsDirty(1), true)
end)

H.Test('Evict flushes first and keeps the entry when the write fails', function()
    boot()

    local cache, writes = newCache()

    cache:Set(1, { money = 5 })
    H.Equal(cache:Evict(1), true)
    H.Equal(writes, { { 1, 5 } })
    H.Equal(cache:Get(1), nil)

    local failing = newCache({ flush = function() return false end })

    failing:Set(1, { money = 5 })

    H.Capture(function()
        H.Equal(failing:Evict(1), false)
    end)

    H.Assert(failing:Get(1) ~= nil)
end)

H.Test('Dirty entries flush on the interval', function()
    boot()

    local cache, writes = newCache({ interval = 5000 })

    cache:Set(1, { money = 1 })
    H.Advance(4000)
    H.Equal(#writes, 0)

    H.Advance(1000)
    H.Equal(writes, { { 1, 1 } })
end)

H.Test('Player drop flushes and evicts that player only', function()
    boot()

    local cache, writes = newCache()

    cache:Set('a', { money = 1 }, 7)
    cache:Set('b', { money = 2 }, 8)

    H.TriggerEvent('playerDropped', 7, 'Exiting')

    H.Equal(writes, { { 'a', 1 } })
    H.Equal(cache:Get('a'), nil)
    H.Assert(cache:Get('b') ~= nil)
end)

H.Test('Resource stop flushes every cache after module Stop', function()
    boot({ fields = "Stop = function() print('stop accounts') end" })

    local cache, writes = newCache()

    cache:Set(1, { money = 9 })

    H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
    end)

    H.Equal(writes, { { 1, 9 } })
end)

H.Test('Cache.Create rejects bad options', function()
    boot()

    H.Raises(function()
        UgCore.Internal.Database.Cache.Create(H.Any({ flush = function() return true end }))
    end, 'Cache.Create expects options with a name')

    H.Raises(function()
        UgCore.Internal.Database.Cache.Create({ name = 'x', flush = function() return true end, interval = 10 })
    end, '"interval" MUST be an integer of at least 1000 ms')
end)

H.Done()
