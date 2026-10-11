--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@param modules string[]
---@param files? table<string, string>
---@return string[] lines
local function fresh(modules, files)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = modules }
    H.Net.identifiers[1] = { 'license:1' }

    for path, content in pairs(files or {}) do
        H.ResourceFiles[path] = content
    end

    local lines = {}

    H.Capture(function()
        lines = H.LoadManifest('server')
    end)

    return lines
end

H.Test('Get reads locales/en.json with dotted keys and placeholders', function()
    fresh({ 'identity', 'players', 'locale' })

    H.Equal(UgCore.Locale.Get('connection.starting'), 'The server is starting. Please wait.')
    H.Equal(UgCore.Locale.Get('identity.bannedUntil', { date = '2030-01-01 00:00' }), 'You are banned from this server until 2030-01-01 00:00 UTC.')
    H.Equal(UgCore.Locale.Get('missing.key'), 'missing.key')
    H.Equal(UgCore.Locale.GetCode(), 'en')
end)

H.Test('The configured locale overrides English, missing keys fall back', function()
    fresh({ 'identity', 'players', 'locale' }, {
        ['config/core.lua'] = "return { locale = 'pt' }",
        ['locales/pt.json'] = '{ "players": { "kicked": "Foste desligado do servidor." } }',
    })

    H.Equal(UgCore.Locale.Get('players.kicked'), 'Foste desligado do servidor.')
    H.Equal(UgCore.Locale.Get('guard.kicked'), 'You were disconnected from the server.')
end)

H.Test('A missing locale file warns and uses English', function()
    local lines = fresh({ 'identity', 'players', 'locale' }, { ['config/core.lua'] = "return { locale = 'de' }" })
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('Locale: locales/de.json is missing. Using en.', 1, true) ~= nil
    end

    H.Assert(found, 'missing locale not reported')
    H.Equal(UgCore.Locale.Get('players.kicked'), 'You were disconnected from the server.')
end)

H.Test('Player-facing core text follows the locale', function()
    fresh({ 'identity', 'players', 'locale' }, {
        ['config/core.lua'] = "return { locale = 'pt' }",
        ['locales/pt.json'] = '{ "players": { "kicked": "Foste desligado." } }',
    })

    UgCore.Players.Kick(1)

    H.Equal(H.Net.dropped[1].reason, 'Foste desligado.')
end)

H.Test('Without the locale module, core text stays English', function()
    fresh({ 'identity', 'players' })

    UgCore.Players.Kick(1)

    H.Equal(H.Net.dropped[1].reason, 'You were disconnected from the server.')
    H.Equal(UgCore.Internal.Utils.Text('x.y', 'Hello {name}', { name = 'Ana' }), 'Hello Ana')
end)

H.Done()
