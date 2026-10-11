--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@alias UgUpdateStatus 'latest'|'outdated'|'ahead'|'unknown'|'disabled'

---@class UgUpdateResult
---@field status UgUpdateStatus
---@field current string
---@field latest? string latest release version, without the `v` prefix
---@field url? string release page of the latest version

---@class UgCore.Internal.Updates
local Updates = {}
UgCore.Internal.Updates = Updates

local InternalVersion = UgCore.Internal.Version

local RELEASES_URL = 'https://api.github.com/repos/ugcore-project/ug-core/releases/latest'
local CONVAR = 'ug-core:VersionCheck'
local DISABLED = { ['false'] = true, ['0'] = true }
local DEFAULT_TIMEOUT = 3000

---@type UgUpdateResult?
local last = nil

---@return boolean
function Updates.IsEnabled()
    return not DISABLED[GetConvar(CONVAR, 'true'):lower()]
end

---@param current string
---@param status integer
---@param body string?
---@return UgUpdateResult
local function evaluate(current, status, body)
    if status ~= 200 or type(body) ~= 'string' then
        return { status = 'unknown', current = current }
    end

    local ok, release = pcall(json.decode, body)

    if not ok or type(release) ~= 'table' or type(release.tag_name) ~= 'string' then
        return { status = 'unknown', current = current }
    end

    local latest = release.tag_name:gsub('^v', '')
    local order = InternalVersion.Compare(current, latest)

    if not order then
        return { status = 'unknown', current = current }
    end

    local url = type(release.html_url) == 'string' and release.html_url or nil
    local result = order < 0 and 'outdated' or order > 0 and 'ahead' or 'latest'

    return { status = result, current = current, latest = latest, url = url }
end

---Asks GitHub for the latest release. MUST run in a thread. Never raises.
---@param timeout? integer ms, defaults to 3000
---@return UgUpdateResult
function Updates.Check(timeout)
    local current = UgCore.Version.Get()

    if not Updates.IsEnabled() then
        last = { status = 'disabled', current = current }
        return last
    end

    local response = promise.new()
    local settled = false

    ---@param outcome { status: integer, body: string? }
    local function settle(outcome)
        if not settled then
            settled = true
            response:resolve(outcome)
        end
    end

    SetTimeout(timeout or DEFAULT_TIMEOUT, function()
        settle({ status = 0 })
    end)

    PerformHttpRequest(RELEASES_URL, function(status, body)
        settle({ status = status, body = body })
    end, 'GET', '', {
        ['Accept'] = 'application/vnd.github+json',
        ['User-Agent'] = 'ug-core/' .. current,
    })

    local outcome = Citizen.Await(response)

    last = evaluate(current, outcome.status, outcome.body)

    return last
end

---@return UgUpdateResult? result of the last check, nil before the first one
function Updates.GetLast()
    return last
end

---One line for the console, with color codes.
---@param result UgUpdateResult
---@return string
function Updates.Describe(result)
    if result.status == 'latest' then
        return '^2Up to date.^7'
    end

    if result.status == 'outdated' then
        return ('^3Update available: v%s -> v%s. %s^7'):format(result.current, result.latest, result.url or '')
    end

    if result.status == 'ahead' then
        return ('^5Ahead of the latest release v%s.^7'):format(result.latest)
    end

    if result.status == 'disabled' then
        return 'Version check disabled.'
    end

    return 'Version check unavailable.'
end
