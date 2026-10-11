--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local BEFORE_ACTION = 'Guard:BeforeAction'
local BEFORE_DOWN = 'Players:BeforeDown'

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

---@param guardConfig? string body of config/guard.lua
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

---@param payload table
---@return boolean proceed
---@return table payload
local function run(payload)
    return UgCore.Internal.Hooks.Run(H.Any(BEFORE_DOWN), payload)
end

-- Registration and order

H.Test('Register accepts known hooks only', function()
    fresh()

    H.Assert(math.type(UgCore.Hooks.Register(BEFORE_DOWN, function() end)) == 'integer')

    H.Raises(function()
        UgCore.Hooks.Register(H.Any('Players:BeforeDwn'), function() end)
    end, '[ug-core] Hooks.Register: unknown hook "Players:BeforeDwn". Did you mean "Players:BeforeDown"?')

    H.Raises(function()
        UgCore.Hooks.Register(BEFORE_DOWN, function() end, { priority = H.Any(1.5) })
    end, '"priority" MUST be an integer')
end)

H.Test('Run without handlers proceeds with the same payload', function()
    fresh()

    local payload = { source = 1 }
    local proceed, result = run(payload)

    H.Equal(proceed, true)
    H.Assert(result == payload)
end)

H.Test('Handlers run by priority, then registration order', function()
    fresh()

    local order = {}

    UgCore.Hooks.Register(BEFORE_DOWN, function() order[#order + 1] = 'b' end)
    UgCore.Hooks.Register(BEFORE_DOWN, function() order[#order + 1] = 'c' end)
    UgCore.Hooks.Register(BEFORE_DOWN, function() order[#order + 1] = 'a' end, { priority = -1 })

    run({})

    H.Equal(order, { 'a', 'b', 'c' })
end)

-- Results

H.Test('Returning false cancels and stops later handlers', function()
    fresh()

    local later = false

    UgCore.Hooks.Register(BEFORE_DOWN, function() return false end)
    UgCore.Hooks.Register(BEFORE_DOWN, function() later = true end)

    H.Equal((run({})), false)
    H.Equal(later, false)
end)

H.Test('Handlers edit the payload in place or return a replacement', function()
    fresh()

    UgCore.Hooks.Register(BEFORE_DOWN, function(payload) payload.duration = 10 end)
    UgCore.Hooks.Register(BEFORE_DOWN, function(payload) return { duration = payload.duration * 2 } end)
    UgCore.Hooks.Register(BEFORE_DOWN, function(payload) return payload.duration == 20 end)

    local proceed, payload = run({ duration = 1 })

    H.Equal(proceed, true)
    H.Equal(payload, { duration = 20 })
end)

H.Test('A failing handler is logged and skipped, never cancels', function()
    fresh()

    local later = false

    UgCore.Hooks.Register(BEFORE_DOWN, function() error('broken', 0) end)
    UgCore.Hooks.Register(BEFORE_DOWN, function() later = true end)

    local proceed
    local lines = H.Capture(function()
        proceed = run({})
    end)

    H.Equal(proceed, true)
    H.Equal(later, true)
    H.Assert(contains(lines, 'Hooks: Players:BeforeDown handler from ug-core failed: broken'), 'error not logged')
end)

H.Test('Unregister removes a handler, also while hooks run', function()
    fresh()

    local calls = 0
    local second

    UgCore.Hooks.Register(BEFORE_DOWN, function() UgCore.Hooks.Unregister(second) end)
    second = UgCore.Hooks.Register(BEFORE_DOWN, function() calls = calls + 1 end)

    run({})

    H.Equal(calls, 0)
    H.Equal(UgCore.Hooks.Unregister(second), false)
end)

H.Test('Hooks of a stopped resource are removed', function()
    fresh()

    AddEventHandler('test:register', function()
        UgCore.Hooks.Register(BEFORE_DOWN, function() return false end)
    end)

    H.TriggerEventAs('my-anticheat', 'test:register')
    H.Equal((run({})), false)

    H.TriggerEvent('onResourceStop', nil, 'other-resource')
    H.Equal((run({})), false)

    H.TriggerEvent('onResourceStop', nil, 'my-anticheat')
    H.Equal((run({})), true)
end)

-- Guard:BeforeAction

H.Test('A hook can cancel a Guard kick', function()
    fresh('{ kickScore = 5 }')

    local seen

    UgCore.Hooks.Register(BEFORE_ACTION, function(payload)
        seen = payload
        return false
    end)

    local lines = H.Capture(function()
        UgCore.Guard.Flag(3, 'InvalidPayload', 'detail')
    end)

    H.Equal(#H.Net.dropped, 0)
    H.Equal({ seen.source, seen.action, seen.score, seen.flags[1].violation }, { 3, UgCore.Enums.GuardActions.Kick, 5, 'InvalidPayload' })
    H.Assert(contains(lines, 'Guard: kick of player 3 cancelled by a hook.'), 'cancel not logged')
end)

H.Test('A hook can pick a milder action, never a harsher one', function()
    fresh('{ banScore = 5, kickScore = 0, warnScore = 0 }')

    UgCore.Hooks.Register(BEFORE_ACTION, function(payload)
        payload.action = UgCore.Enums.GuardActions.Warn
    end)

    local lines = H.Capture(function()
        UgCore.Guard.Flag(3, 'InvalidPayload')
    end)

    H.Equal(#H.Net.dropped, 0)
    H.Assert(contains(lines, 'Guard: player 3 reached score 5.'), 'downgrade to warn missing')

    fresh('{ warnScore = 5, kickScore = 0 }')

    UgCore.Hooks.Register(BEFORE_ACTION, function(payload)
        return { action = UgCore.Enums.GuardActions.Ban }
    end)

    H.Capture(function()
        UgCore.Guard.Flag(3, 'InvalidPayload')
    end)

    H.Equal(#H.Net.dropped, 0)
end)

-- Command

H.Test('ug hooks lists registered hooks', function()
    fresh()

    H.Equal(H.RunCommand('ug', 0, { 'hooks' }), { 'No hooks registered.' })

    UgCore.Hooks.Register(BEFORE_ACTION, function() end, { priority = 5 })

    H.Equal(H.RunCommand('ug', 0, { 'hooks' }), { '  Guard:BeforeAction       ug-core              priority 5' })
end)

H.Done()
