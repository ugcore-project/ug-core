--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@class TestBan
---@field id integer
---@field reason string?
---@field by string?
---@field duration integer
---@field revoked boolean
---@field identifiers table<string, boolean>

---@type TestBan[]
local bans

---In-memory `ug_bans`. Expiry is ignored: a ban with a duration is still active.
---@param sql string
---@param params table?
---@return any
local function banStore(sql, params)
    local values = params or {}

    if sql:find('INSERT INTO `ug_bans`', 1, true) then
        local id = #bans + 1

        bans[id] = {
            id = id,
            reason = values[1] ~= '' and values[1] or nil,
            by = values[2] ~= '' and values[2] or nil,
            duration = values[3],
            revoked = false,
            identifiers = {},
        }

        return { insertId = id, affectedRows = 1 }
    end

    if sql:find('INSERT INTO `ug_ban_identifiers`', 1, true) then
        bans[values[1]].identifiers[values[2]] = true
        return { insertId = 0, affectedRows = 1 }
    end

    local matches = {}

    for _, ban in ipairs(bans) do
        if not ban.revoked then
            for _, identifier in ipairs(values) do
                if ban.identifiers[identifier] then
                    matches[#matches + 1] = ban
                    break
                end
            end
        end
    end

    if sql:find('SELECT `b`.`id`', 1, true) then
        local ban = matches[1]

        if not ban then
            return {}
        end

        return { { id = ban.id, reason = ban.reason, expiresAt = ban.duration > 0 and 1900000000 or nil, createdAt = 1800000000 } }
    end

    if sql:find('SET `b`.`revoked_at`', 1, true) then
        for _, ban in ipairs(matches) do
            ban.revoked = true
        end

        return { insertId = 0, affectedRows = #matches }
    end
end

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity' } }
    H.Net.identifiers[1] = { 'license:aaa', 'discord:111', 'ip:1.2.3.4' }
    H.Net.identifiers[2] = { 'license:bbb' }
    H.Net.identifiers[3] = { 'steam:ccc' }

    bans = {}
    H.LoadManifest('server')
    H.Db.handler = banStore
end

---Runs `fn` in a thread and returns its packed results.
---@param fn fun(): ...
---@return table
local function await(fn)
    local result

    H.Capture(function()
        H.Thread(function()
            result = table.pack(fn())
        end)
    end)

    return result
end

---@param source integer
---@return table deferrals mock
---@return string[] calls
local function connect(source)
    local calls = {}
    local deferrals = {
        defer = function() calls[#calls + 1] = 'defer' end,
        update = function(message) calls[#calls + 1] = 'update:' .. message end,
        done = function(reason) calls[#calls + 1] = 'done:' .. tostring(reason) end,
    }

    H.Capture(function()
        H.TriggerEvent('playerConnecting', source, 'player', function() end, deferrals)
        H.Advance(0)
        H.Advance(0)
    end)

    return deferrals, calls
end

-- Identifiers

H.Test('Identity is a required module and boots with its migration', function()
    fresh()

    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    H.Equal(H.Db.migrations.identity, { '1.0.0' })
    H.Equal(H.ResourceFiles['config/modules.lua']:find('identity', 1, true), nil)
end)

H.Test('GetIdentifiers and GetPrimary read the player identifiers', function()
    fresh()

    H.Equal(UgCore.Identity.GetIdentifiers(1), { 'license:aaa', 'discord:111', 'ip:1.2.3.4' })
    H.Equal(UgCore.Identity.GetPrimary(1), 'license:aaa')
    H.Equal(UgCore.Identity.GetPrimary(3), nil)
end)

-- Bans

H.Test('Ban covers every identifier except ip and kicks the player', function()
    fresh()

    local result = await(function()
        return UgCore.Identity.Ban(1, { reason = 'cheating', by = 'admin', duration = 3600 })
    end)

    H.Equal(result, { n = 3, true, 1 })
    H.Equal(bans[1].identifiers, { ['license:aaa'] = true, ['discord:111'] = true })
    H.Equal({ bans[1].reason, bans[1].by, bans[1].duration }, { 'cheating', 'admin', 3600 })
    H.Equal(H.Net.dropped, { { source = '1', reason = 'You are banned from this server.' } })
end)

H.Test('Optional ban fields never reach SQL as nil', function()
    fresh()

    await(function()
        return UgCore.Identity.Ban('license:bbb')
    end)

    H.Equal(H.Db.params[#H.Db.params - 1], { '', '', 0, 0 })
    H.Equal(bans[1].reason, nil)
end)

H.Test('IsBanned finds a ban through any identifier', function()
    fresh()

    await(function()
        return UgCore.Identity.Ban(1, { kick = false })
    end)

    local byDiscord = await(function()
        return UgCore.Identity.IsBanned('discord:111')
    end)

    H.Equal(byDiscord[1], true)
    H.Equal(byDiscord[2].id, 1)
    H.Equal(await(function() return UgCore.Identity.IsBanned(2) end), { n = 3, false })
    H.Equal(#H.Net.dropped, 0)
end)

H.Test('Unban by one identifier lifts the whole ban', function()
    fresh()

    await(function()
        return UgCore.Identity.Ban(1)
    end)

    H.Equal(await(function() return UgCore.Identity.Unban('discord:111') end), { n = 3, true, 1 })
    H.Equal(await(function() return UgCore.Identity.IsBanned('license:aaa') end)[1], false)
end)

H.Test('Identifier arrays work for players already dropped', function()
    fresh()

    local result = await(function()
        return UgCore.Identity.Ban({ 'license:zzz', 'ip:9.9.9.9' })
    end)

    H.Equal(result[1], true)
    H.Equal(bans[1].identifiers, { ['license:zzz'] = true })
end)

H.Test('Wrong targets and options raise', function()
    fresh()

    H.Raises(function()
        UgCore.Identity.Ban(H.Any('not an identifier'))
    end, 'Identity.Ban expects a player source, an identifier such as "license:abc" or an array of them')

    H.Raises(function()
        UgCore.Identity.Ban(1, { duration = 0 })
    end, 'Identity.Ban: "duration" MUST be a positive integer of seconds')
end)

H.Test('Database failures are reported, not raised', function()
    fresh()
    H.Db.fail = '`ug_bans`'

    local result

    H.Capture(function()
        result = await(function()
            return UgCore.Identity.IsBanned(1)
        end)
    end)

    H.Equal(result, { n = 3, false, nil, 'internal_error' })
end)

-- Connections

H.Test('Players without the primary identifier cannot connect', function()
    fresh()

    local _, calls = connect(3)

    H.Equal(calls[#calls], 'done:A license identifier is required to join this server.')
end)

H.Test('Banned players are rejected with a generic message', function()
    fresh()

    await(function()
        return UgCore.Identity.Ban(1, { kick = false })
    end)

    await(function()
        return UgCore.Identity.Ban(2, { kick = false, duration = 60 })
    end)

    local _, permanent = connect(1)
    local _, temporary = connect(2)

    H.Equal(permanent[#permanent], 'done:You are banned from this server.')
    H.Equal(temporary[#temporary], 'done:You are banned from this server until 2030-03-17 17:46 UTC.')
end)

H.Test('Players connect when not banned, and fail closed on database errors', function()
    fresh()

    local _, clean = connect(1)

    H.Equal(clean, { 'defer', 'done:nil' })

    H.Db.fail = '`ug_bans`'

    local _, failed = connect(1)

    H.Equal(failed[#failed], 'done:Your connection could not be verified. Try again later.')
end)

H.Test('Guard bans through identity with the identifiers read before the drop', function()
    fresh()
    H.ResourceFiles['config/guard.lua'] = 'return { banScore = 5 }'
    H.LoadManifest('server')
    H.Db.handler = banStore

    H.Capture(function()
        UgCore.Guard.Flag(1, 'InvalidPayload')
    end)

    H.Equal(H.Net.dropped, { { source = '1', reason = 'You are banned from this server.' } })
    H.Equal(bans[1].identifiers, { ['license:aaa'] = true, ['discord:111'] = true })
    H.Equal(bans[1].by, 'guard')
end)

H.Done()
