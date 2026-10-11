--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local RELEASES_URL = 'https://api.github.com/repos/ugcore-project/ug-core/releases/latest'

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

---Boots like a fresh server, so the banner and its check run.
---@param version string
---@param response TestHttpResponse|false
---@return string[] lines
local function boot(version, response)
    H.ResourceMetadata['ug-core'] = { version = version }
    H.HttpResponse = response
    H.HttpRequests = {}
    H.ResetGlobalState()

    return H.LoadManifest('server')
end

---@param tag string
---@return TestHttpResponse
local function release(tag)
    return {
        status = 200,
        body = json.encode({ tag_name = tag, html_url = 'https://github.com/ugcore-project/ug-core/releases/tag/' .. tag }),
    }
end

local function restore()
    H.ResourceMetadata['ug-core'] = nil
    H.HttpResponse = { status = 404 }
    H.Convars['ug-core:VersionCheck'] = nil
end

H.Test('Banner says up to date on the latest release', function()
    local lines = boot('1.2.0', release('v1.2.0'))

    H.Assert(contains(lines, 'Up to date.'), 'status missing from banner')
    H.Equal(UgCore.Internal.Updates.GetLast(), { status = 'latest', current = '1.2.0', latest = '1.2.0', url = 'https://github.com/ugcore-project/ug-core/releases/tag/v1.2.0' })
    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    restore()
end)

H.Test('Banner shows the newer release and its link', function()
    local lines = boot('1.2.0', release('v1.10.0'))

    H.Assert(contains(lines, 'Update available: v1.2.0 -> v1.10.0. https://github.com/ugcore-project/ug-core/releases/tag/v1.10.0'), 'update line missing')
    H.Equal(UgCore.Internal.Updates.GetLast().status, 'outdated')
    restore()
end)

H.Test('A build newer than the latest release is ahead', function()
    local lines = boot('2.0.0', release('v1.9.9'))

    H.Assert(contains(lines, 'Ahead of the latest release v1.9.9.'), 'ahead line missing')
    restore()
end)

H.Test('The request asks the GitHub releases API with a user agent', function()
    boot('1.2.0', release('v1.2.0'))

    H.Equal(#H.HttpRequests, 1)
    H.Equal(H.HttpRequests[1].url, RELEASES_URL)
    H.Equal(H.HttpRequests[1].method, 'GET')
    H.Equal(H.HttpRequests[1].headers['User-Agent'], 'ug-core/1.2.0')
    restore()
end)

H.Test('Missing releases, errors and bad bodies are unknown and never stop boot', function()
    local responses = {
        { status = 404 },
        { status = 500, body = 'oops' },
        { status = 200, body = 'not json' },
        { status = 200, body = json.encode({ tag_name = 'nightly' }) },
        { status = 200, body = json.encode({ name = 'v1.0.0' }) },
    }

    for index, response in ipairs(responses) do
        local lines = boot('1.2.0', response)

        H.Assert(contains(lines, 'Version check unavailable.'), 'unknown line missing for response ' .. index)
        H.Equal(UgCore.Internal.Updates.GetLast().status, 'unknown', 'response ' .. index)
        H.Equal(UgCore.Lifecycle.GetState(), 'Ready', 'response ' .. index)
    end

    restore()
end)

H.Test('Boot waits for the check at most 3 seconds', function()
    local lines = boot('1.2.0', false)

    H.Assert(not contains(lines, 'ug-core v1.2.0'), 'banner printed before the check')
    H.Equal(UgCore.Lifecycle.GetState(), 'Booting')

    lines = H.Capture(function()
        H.Advance(2999)
    end)

    H.Equal(UgCore.Lifecycle.GetState(), 'Booting')

    lines = H.Capture(function()
        H.Advance(1)
    end)

    H.Assert(contains(lines, 'Version check unavailable.'), 'banner missing after the timeout')
    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    restore()
end)

H.Test('VersionCheck convar false or 0 skips the request', function()
    for _, raw in ipairs({ 'false', '0', 'FALSE' }) do
        H.Convars['ug-core:VersionCheck'] = raw

        local lines = boot('1.2.0', release('v9.0.0'))

        H.Equal(#H.HttpRequests, 0, raw)
        H.Assert(contains(lines, 'Version check disabled.'), 'disabled line missing for ' .. raw)
        H.Equal(UgCore.Lifecycle.GetState(), 'Ready', raw)
    end

    restore()
end)

H.Test('A restart neither prints the banner nor checks again', function()
    boot('1.2.0', release('v1.2.0'))

    H.HttpRequests = {}

    local lines = H.LoadManifest('server')

    H.Equal(#H.HttpRequests, 0)
    H.Assert(not contains(lines, 'Up to date.'), 'banner printed again')
    restore()
end)

H.Test('ug version checks again and prints the result', function()
    boot('1.2.0', release('v1.2.0'))

    H.HttpResponse = release('v1.3.0')

    local lines = H.RunCommand('ug', 0, { 'version' })

    H.Assert(contains(lines, 'ug-core v1.2.0. ^3Update available: v1.2.0 -> v1.3.0.'), 'version output missing')
    H.Equal(UgCore.Internal.Updates.GetLast().latest, '1.3.0')
    restore()
end)

H.Test('Compare orders versions numerically and rejects malformed ones', function()
    H.LoadManifest('server')

    local Compare = UgCore.Internal.Version.Compare

    H.Equal(Compare('1.2.0', '1.10.0'), -1)
    H.Equal(Compare('2.0.0', '1.99.99'), 1)
    H.Equal(Compare('1.2.0', '1.2.0-beta.1'), 0)
    H.Equal(Compare('1.2', '1.2.0'), nil)
    H.Equal(Compare('nightly', '1.0.0'), nil)
end)

H.Done()
