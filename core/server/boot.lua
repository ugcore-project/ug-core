--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local BANNER_STATE_KEY = UgCore.Enums.GlobalState.BannerShown

local BANNER = [[
  _   _  ____    ____
 | | | |/ ___|  / ___|___  _ __ ___
 | | | | |  _  | |   / _ \| '__/ _ \
 | |_| | |_| | | |__| (_) | | |  __/
  \___/ \____|  \____\___/|_|  \___|]]

-- The info column starts after the widest art line.
local ART_WIDTH = 40
local NAME_MAX = 40
local DOCS = 'ugcore.urging.ch'
-- FXServer's own default, so an unconfigured server is not welcomed by it.
local DEFAULT_HOSTNAME = 'FXServer, but unconfigured'

---A convar as plain text: FiveM color codes removed, trimmed, cut to NAME_MAX characters.
---@param name string
---@return string?
local function plainConvar(name)
    local value = GetConvar(name, ''):gsub('%^%d', ''):match('^%s*(.-)%s*$')

    if value == '' or value == DEFAULT_HOSTNAME then
        return nil
    end

    local cut = utf8.len(value) and utf8.len(value) > NAME_MAX and utf8.offset(value, NAME_MAX + 1)

    return cut and value:sub(1, cut - 1) .. '...' or value
end

---Facts an owner asks for when something goes wrong. Missing ones are left out.
---@return string
local function serverFacts()
    local facts = {}
    -- The `version` convar reads like `FXServer-master SERVER v1.0.0.12345 win32`. Verify on a live server.
    local build = GetConvar('version', ''):match('v%d+%.%d+%.%d+%.(%d+)')
    local slots = GetConvarInt('sv_maxclients', 0)
    local gameBuild = GetConvarInt('sv_enforceGameBuild', 0)

    if build then
        facts[#facts + 1] = 'FXServer ' .. build
    end

    if slots > 0 then
        facts[#facts + 1] = ('%d slots'):format(slots)
    end

    if gameBuild > 0 then
        facts[#facts + 1] = ('game build %d'):format(gameBuild)
    end

    return table.concat(facts, ' · ')
end

---Prints the banner with the version check once per server boot. MUST run in a thread.
---GlobalState outlives resource restarts, so a restart MUST NOT print it again, nor check again.
local function printBanner()
    if GlobalState[BANNER_STATE_KEY] then
        return
    end

    GlobalState:set(BANNER_STATE_KEY, true, false)

    local resource = GetCurrentResourceName()
    local version = GetResourceMetadata(resource, 'version', 0) or 'unknown'
    local update = UgCore.Internal.Updates.Check()
    local name = plainConvar('sv_projectName') or plainConvar('sv_hostname') or 'your server'

    local info = {
        '',
        ('Welcome to ^5%s^7!'):format(name),
        ('%s v%s · %s'):format(resource, version, UgCore.Internal.Updates.Describe(update)),
        serverFacts(),
        ('Type ^5ug^7 here to inspect the framework · %s'):format(DOCS),
    }

    local lines = { '' }
    local row = 0

    for art in BANNER:gmatch('[^\n]+') do
        row = row + 1
        lines[#lines + 1] = ('^5%s^7%s%s'):format(art, (' '):rep(ART_WIDTH - #art), info[row] or ''):gsub('%s+$', '')
    end

    lines[#lines + 1] = ''

    print(table.concat(lines, '\n'))
end

local States = UgCore.Enums.Lifecycle
local Lifecycle = UgCore.Lifecycle
local ModuleLoader = UgCore.Internal.Modules.Loader
local InternalExports = UgCore.Internal.Exports

local CONNECT_TIMEOUT = 60000
local CONNECT_WAITING = 'The server is starting. Please wait.'
local CONNECT_REJECTED = 'The server is not ready. Try again later.'

-- Deferral calls MUST be at least one tick apart (Cfx playerConnecting docs).
AddEventHandler('playerConnecting', function(_, _, deferrals)
    if Lifecycle.IsReady() then
        return
    end

    deferrals.defer()
    Wait(0)
    deferrals.update(UgCore.Internal.Utils.Text('connection.starting', CONNECT_WAITING))

    local ready = Lifecycle.Await(States.Ready, CONNECT_TIMEOUT)

    Wait(0)

    if ready then
        deferrals.done()
    else
        deferrals.done(UgCore.Internal.Utils.Text('connection.notReady', CONNECT_REJECTED))
    end
end)

AddEventHandler('onResourceStop', function(resource)
    if resource == GetCurrentResourceName() then
        ModuleLoader.Shutdown()
    end
end)

for _, namespace in ipairs({ 'Config', 'Guard', 'Hooks', 'Lifecycle' }) do
    InternalExports.Bind(namespace)
end

InternalExports.BindInternal('GuardConsumeBudget', UgCore.Internal.Guard.ConsumeBudget)
InternalExports.Publish()

-- The banner comes first, so boot waits for the version check, at most its timeout.
CreateThread(function()
    printBanner()
    ModuleLoader.Boot()
end)
