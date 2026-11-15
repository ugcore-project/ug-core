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

H.Test('Server passes through every boot state to Ready', function()
    H.LoadManifest('server')

    local states = {}

    for index, step in ipairs(UgCore.Internal.Lifecycle.GetHistory()) do
        states[index] = step.state
    end

    H.Equal(states, { 'Booting', 'Configured', 'Initializing', 'Starting', 'Ready' })
end)

H.Test('Debug is off by default', function()
    H.Convars['ug-core:Debug'] = nil
    H.LoadManifest('server')

    H.Equal(UgCore.Internal.Logger.IsDebug(), false)
end)

H.Test('Debug convar enables debug logging', function()
    for _, raw in ipairs({ 'true', '1' }) do
        H.Convars['ug-core:Debug'] = raw
        H.LoadManifest('server')
        H.Convars['ug-core:Debug'] = nil

        H.Equal(UgCore.Internal.Logger.IsDebug(), true, raw)
    end
end)

H.Test('Debug convar 0 and false keep debug off', function()
    for _, raw in ipairs({ 'false', '0' }) do
        H.Convars['ug-core:Debug'] = raw
        H.LoadManifest('server')
        H.Convars['ug-core:Debug'] = nil

        H.Equal(UgCore.Internal.Logger.IsDebug(), false, raw)
        H.Equal(UgCore.Lifecycle.GetState(), 'Ready', raw)
    end
end)

H.Test('Invalid convar aborts boot', function()
    H.Convars['ug-core:Debug'] = 'yes'

    local lines = H.LoadManifest('server')

    H.Convars['ug-core:Debug'] = nil

    H.Assert(contains(lines, 'convar ug-core:Debug: MUST be true, false, 1 or 0, got "yes"'), 'convar error missing')
    H.Assert(contains(lines, 'Boot aborted: 1 error(s).'), 'abort line missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Stopping ug-core moves to Stopped, other resources do not', function()
    H.LoadManifest('server')

    H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-banking')
    end)

    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')

    H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
    end)

    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Stopping after an aborted boot does nothing', function()
    H.Convars['ug-core:Debug'] = 'yes'
    H.LoadManifest('server')
    H.Convars['ug-core:Debug'] = nil

    H.Capture(function()
        H.TriggerEvent('onResourceStop', nil, 'ug-core')
    end)

    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Client loads shared scripts', function()
    H.LoadManifest('client')

    H.Assert(UgCore.Internal.Utils.Table ~= nil)
    H.Assert(UgCore.Internal.Files ~= nil)
    H.Assert(UgCore.Logger ~= nil)
end)

H.Done()
