--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local Events = UgCore.Events
local Lifecycle = UgCore.Enums.Events.Lifecycle

H.Test('On receives emitted arguments', function()
    local received
    Events.On(Lifecycle.Changed, function(...)
        received = { ... }
    end)

    Events.Emit(Lifecycle.Changed, 'Ready', 'Starting')

    H.Equal(received, { 'Ready', 'Starting' })
end)

H.Test('On returns a unique id per subscription', function()
    local first = Events.On('ug-core:Test:A', function() end)
    local second = Events.On('ug-core:Test:A', function() end)

    H.Assert(math.type(first) == 'integer')
    H.Assert(first ~= second)
end)

H.Test('Every handler of an event runs', function()
    local calls = 0
    Events.On('ug-core:Test:Many', function() calls = calls + 1 end)
    Events.On('ug-core:Test:Many', function() calls = calls + 1 end)

    Events.Emit('ug-core:Test:Many')

    H.Equal(calls, 2)
end)

H.Test('Once runs a single time', function()
    local calls = 0
    Events.Once('ug-core:Test:Once', function() calls = calls + 1 end)

    Events.Emit('ug-core:Test:Once')
    Events.Emit('ug-core:Test:Once')

    H.Equal(calls, 1)
end)

H.Test('Off stops delivery and reports unknown ids', function()
    local calls = 0
    local id = Events.On('ug-core:Test:Off', function() calls = calls + 1 end)

    H.Equal(Events.Off(id), true)
    Events.Emit('ug-core:Test:Off')

    H.Equal(calls, 0)
    H.Equal(Events.Off(id), false)
    H.Equal(Events.Off(999999), false)
end)

H.Test('Off of a fired Once is false', function()
    local id = Events.Once('ug-core:Test:OnceOff', function() end)

    Events.Emit('ug-core:Test:OnceOff')

    H.Equal(Events.Off(id), false)
end)

H.Test('Handler can remove another handler while the event runs', function()
    local calls = 0
    local second

    Events.On('ug-core:Test:Remove', function()
        Events.Off(second)
    end)

    second = Events.On('ug-core:Test:Remove', function() calls = calls + 1 end)

    Events.Emit('ug-core:Test:Remove')
    Events.Emit('ug-core:Test:Remove')

    H.Equal(calls, 0)
end)

H.Test('ug-core events from another resource are dropped', function()
    local calls = 0
    Events.On(Lifecycle.Ready, function() calls = calls + 1 end)

    H.TriggerEventAs('evil-resource', Lifecycle.Ready)
    H.Equal(calls, 0)

    H.TriggerEvent(Lifecycle.Ready, 1)
    H.Equal(calls, 0)

    Events.Emit(Lifecycle.Ready)
    H.Equal(calls, 1)
end)

H.Test('A dropped event does not consume a Once', function()
    local calls = 0
    Events.Once('ug-core:Test:Spoofed', function() calls = calls + 1 end)

    H.TriggerEventAs('evil-resource', 'ug-core:Test:Spoofed')
    Events.Emit('ug-core:Test:Spoofed')

    H.Equal(calls, 1)
end)

H.Test('Other resources events are delivered', function()
    local received
    Events.On('ug-banking:Paid', function(amount) received = amount end)

    H.TriggerEventAs('ug-banking', 'ug-banking:Paid', 50)

    H.Equal(received, 50)
end)

H.Test('Emit requires the own resource prefix', function()
    H.Raises(function()
        Events.Emit('ug-banking:Paid')
    end, '[ug-core] Events.Emit: event names MUST start with "ug-core:"')

    H.Raises(function()
        Events.Emit('ug-core:')
    end, 'MUST start with "ug-core:"')

    H.Raises(function()
        Events.Emit(H.Any(nil))
    end, 'MUST start with "ug-core:"')
end)

H.Test('On and Once reject bad arguments', function()
    H.Raises(function()
        Events.On('', function() end)
    end, '[ug-core] Events.On expects a non-empty event name')

    H.Raises(function()
        Events.Once('ug-core:Test:X', H.Any(nil))
    end, '[ug-core] Events.Once expects a handler function')
end)

H.Done()
