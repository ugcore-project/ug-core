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

---Clean server boot. `guardConfig` is the body of config/guard.lua.
---@param guardConfig? string
local function fresh(guardConfig)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.Metadata = {}

    if guardConfig then
        H.ResourceFiles['config/guard.lua'] = 'return ' .. guardConfig
    end

    H.LoadManifest('server')
end

---@param source integer
---@param violation string
---@param times integer
---@return string[] lines printed
local function flag(source, violation, times)
    return H.Capture(function()
        for _ = 1, times do
            UgCore.Guard.Flag(source, H.Any(violation))
        end
    end)
end

-- Scoring

H.Test('Flag adds the violation weight and emits Flagged', function()
    fresh()

    local received

    UgCore.Events.On('ug-core:Guard:Flagged', function(...)
        received = { ... }
    end)

    UgCore.Guard.Flag(3, 'InvalidPayload', 'arg 1: MUST be a string')

    H.Equal(UgCore.Guard.GetScore(3), 5)
    H.Equal(received, { 3, 'InvalidPayload', 5 })
    H.Equal(UgCore.Guard.GetScore(99), 0)
end)

H.Test('Flag rejects unknown violations and non-player sources', function()
    fresh()

    H.Raises(function()
        UgCore.Guard.Flag(1, H.Any('Speeding'))
    end, '[ug-core] Guard.Flag: unknown violation "Speeding"')

    H.Raises(function()
        UgCore.Guard.Flag(0, 'RateLimited')
    end, 'Guard.Flag expects a player source')
end)

H.Test('Scores decay per minute', function()
    fresh('{ decayPerMinute = 2 }')

    UgCore.Guard.Flag(1, 'InvalidPayload')
    H.Advance(60000)

    H.Equal(UgCore.Guard.GetScore(1), 3)

    H.Advance(600000)

    H.Equal(UgCore.Guard.GetScore(1), 0)
end)

H.Test('Recent flags are capped and details truncated', function()
    fresh('{ kickScore = 0, warnScore = 0 }')

    for index = 1, 12 do
        UgCore.Guard.Flag(1, 'RateLimited', index == 12 and string.rep('x', 500) or nil)
    end

    local flags = UgCore.Internal.Guard.GetFlags(1)

    H.Equal(#flags, 10)
    H.Equal(#flags[10].detail, 203)
end)

-- Actions

H.Test('Warn logs once with recent flags, again after decaying below', function()
    fresh('{ warnScore = 10, kickScore = 0, decayPerMinute = 10 }')

    local first = flag(1, 'InvalidPayload', 3)

    H.Assert(contains(first, 'Guard: player 1 reached score 10. Recent: InvalidPayload, InvalidPayload.'), 'warning missing')
    H.Equal(#H.Net.dropped, 0)

    local repeated = flag(1, 'InvalidPayload', 1)

    H.Assert(not contains(repeated, 'reached score'), 'warned twice')

    H.Advance(120000)
    flag(1, 'RateLimited', 1)

    H.Assert(contains(flag(1, 'InvalidPayload', 2), 'reached score'), 'no warning after decay')
end)

H.Test('Kick uses a generic message, details stay in logs', function()
    fresh('{ kickScore = 10 }')

    local lines = H.Capture(function()
        UgCore.Guard.Flag(4, 'OutOfRange', 'shop 12 at 80 m')
        UgCore.Guard.Flag(4, 'OutOfRange', 'shop 12 at 80 m')
    end)

    H.Equal(H.Net.dropped, { { source = '4', reason = 'You were disconnected from the server.' } })
    H.Assert(contains(lines, 'Guard: kicking player 4 at score 10. Recent: OutOfRange, OutOfRange.'), 'kick log missing')
end)

H.Test('Ban without the identity module kicks and logs an error', function()
    fresh('{ banScore = 5, kickScore = 0 }')

    local lines = flag(2, 'InvalidPayload', 1)

    H.Assert(contains(lines, 'Guard: banning needs the identity module. Kicking player 2 instead.'), 'fallback error missing')
    H.Equal(H.Net.dropped[1].reason, 'You were disconnected from the server.')
end)

H.Test('Player drop clears the score', function()
    fresh()

    UgCore.Guard.Flag(6, 'InvalidPayload')
    H.TriggerEvent('playerDropped', 6, 'Exiting')

    H.Equal(UgCore.Guard.GetScore(6), 0)
end)

-- IsNear

H.Test('IsNear reads the server-side ped position', function()
    fresh()
    H.Net.peds[1] = 100
    H.Net.coords[100] = vector3(10, 0, 0)

    H.Equal(UgCore.Guard.IsNear(1, vector3(13, 4, 0), 5), true)
    H.Equal(UgCore.Guard.IsNear(1, vector3(20, 0, 0), 5), false)
    H.Equal(UgCore.Guard.IsNear(2, vector3(0, 0, 0), 5), false)
end)

H.Test('IsNear rejects bad arguments', function()
    fresh()

    H.Raises(function()
        UgCore.Guard.IsNear(1, H.Any({ x = 0, y = 0, z = 0 }), 5)
    end, 'Guard.IsNear expects coords as a vector3')

    H.Raises(function()
        UgCore.Guard.IsNear(1, vector3(0, 0, 0), -1)
    end, 'Guard.IsNear expects a non-negative maxDistance')
end)

-- Budget and command

H.Test('The global budget comes from config/guard.lua', function()
    fresh('{ budgetMax = 3 }')

    local Internal = UgCore.Internal.Guard

    H.Equal(Internal.ConsumeBudget(1), true)
    H.Equal(Internal.ConsumeBudget(1), true)
    H.Equal(Internal.ConsumeBudget(1), true)
    H.Equal(Internal.ConsumeBudget(1), false)
    H.Equal(Internal.ConsumeBudget(2), true)
end)

H.Test('ug guard shows the score and recent flags', function()
    fresh()

    UgCore.Guard.Flag(1, 'NoPermission', 'admin:Spawn')

    local lines = H.RunCommand('ug', 0, { 'guard', '1' })

    H.Equal(lines[1], '  player 1 score 3')
    H.Assert(lines[2]:find('NoPermission%s+admin:Spawn') ~= nil, lines[2])
    H.Equal(H.RunCommand('ug', 0, { 'guard' }), { 'Usage: ug guard <player id>' })
end)

H.Done()
