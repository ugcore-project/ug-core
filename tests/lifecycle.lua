--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local States = {
    Booting = 'Booting',
    Configured = 'Configured',
    Initializing = 'Initializing',
    Starting = 'Starting',
    Ready = 'Ready',
    Stopping = 'Stopping',
    Stopped = 'Stopped',
}

---Fresh lifecycle per test. The client side has no boot scaffold that changes state.
local function fresh()
    H.LoadManifest('client')

    return UgCore.Lifecycle, UgCore.Internal.Lifecycle
end

H.Test('Starts in Booting', function()
    local Lifecycle, Internal = fresh()

    H.Equal(Lifecycle.GetState(), States.Booting)
    H.Equal(Lifecycle.IsReady(), false)
    H.Equal(#Internal.GetHistory(), 1)
end)

H.Test('SetState logs the time spent in the previous state', function()
    local Lifecycle, Internal = fresh()

    H.Advance(12)

    local lines = H.Capture(function()
        Internal.SetState(States.Configured)
    end)

    H.Equal(Lifecycle.GetState(), States.Configured)
    H.Equal(lines, { '^5[INFO]^7 Lifecycle: Configured (12 ms)' })
end)

H.Test('SetState emits Changed with new and old state', function()
    local _, Internal = fresh()
    local received

    UgCore.Events.On('ug-core:Lifecycle:Changed', function(...)
        received = { ... }
    end)

    H.Capture(function()
        Internal.SetState(States.Initializing)
    end)

    H.Equal(received, { States.Initializing, States.Booting })
end)

H.Test('Ready and Stopping emit their own events', function()
    local Lifecycle, Internal = fresh()
    local seen = {}

    UgCore.Events.On('ug-core:Lifecycle:Ready', function() seen[#seen + 1] = 'Ready' end)
    UgCore.Events.On('ug-core:Lifecycle:Stopping', function() seen[#seen + 1] = 'Stopping' end)

    H.Capture(function()
        Internal.SetState(States.Ready)
        Internal.SetState(States.Stopping)
    end)

    H.Equal(seen, { 'Ready', 'Stopping' })
    H.Equal(Lifecycle.IsReady(), false)
end)

H.Test('SetState only moves forward', function()
    local _, Internal = fresh()

    H.Capture(function()
        Internal.SetState(States.Starting)
    end)

    H.Raises(function()
        Internal.SetState(States.Starting)
    end, '[ug-core] Lifecycle.SetState: cannot move from Starting to Starting')

    H.Raises(function()
        Internal.SetState(States.Configured)
    end, 'cannot move from Starting to Configured')

    H.Raises(function()
        Internal.SetState(H.Any('Running'))
    end, '[ug-core] Lifecycle.SetState: unknown state "Running"')
end)

H.Test('On runs when the state is reached', function()
    local Lifecycle, Internal = fresh()
    local calls = 0

    Lifecycle.On(States.Ready, function() calls = calls + 1 end)

    H.Capture(function()
        Internal.SetState(States.Starting)
    end)

    H.Equal(calls, 0)

    H.Capture(function()
        Internal.SetState(States.Ready)
    end)

    H.Equal(calls, 1)
end)

H.Test('On is sticky for reached states', function()
    local Lifecycle, Internal = fresh()
    local calls = 0

    H.Capture(function()
        Internal.SetState(States.Ready)
    end)

    Lifecycle.On(States.Ready, function() calls = calls + 1 end)
    Lifecycle.On(States.Booting, function() calls = calls + 1 end)

    H.Equal(calls, 2)
end)

H.Test('On never runs for a skipped state', function()
    local Lifecycle, Internal = fresh()
    local calls = 0

    Lifecycle.On(States.Ready, function() calls = calls + 1 end)

    H.Capture(function()
        Internal.SetState(States.Stopping)
    end)

    Lifecycle.On(States.Ready, function() calls = calls + 1 end)

    H.Equal(calls, 0)
end)

H.Test('A failing handler is logged and does not stop others', function()
    local Lifecycle, Internal = fresh()
    local calls = 0

    Lifecycle.On(States.Ready, function() error('boom', 0) end)
    Lifecycle.On(States.Ready, function() calls = calls + 1 end)

    local lines = H.Capture(function()
        Internal.SetState(States.Ready)
    end)

    H.Equal(calls, 1)
    H.Equal(Lifecycle.GetState(), States.Ready)
    H.Equal(lines[2], '^1[ERROR]^7 Lifecycle: Ready handler failed: boom')
end)

H.Test('A handler MAY register more handlers during a transition', function()
    local Lifecycle, Internal = fresh()
    local calls = 0

    Lifecycle.On(States.Starting, function()
        Lifecycle.On(States.Ready, function() calls = calls + 1 end)
        Lifecycle.On(States.Starting, function() calls = calls + 10 end)
    end)

    H.Capture(function()
        Internal.SetState(States.Starting)
        Internal.SetState(States.Ready)
    end)

    H.Equal(calls, 11)
end)

H.Test('Await returns true at once for a reached state', function()
    local Lifecycle = fresh()

    H.Equal(Lifecycle.Await(States.Booting), true)
end)

H.Test('Await blocks until the state is reached', function()
    local Lifecycle, Internal = fresh()
    local thread = H.Thread(function()
        return Lifecycle.Await(States.Ready)
    end)

    H.Equal(thread.done, false)

    H.Capture(function()
        Internal.SetState(States.Starting)
    end)

    H.Equal(thread.done, false)

    H.Capture(function()
        Internal.SetState(States.Ready)
    end)

    H.Equal(thread.done, true)
    H.Equal(thread.result, true)
end)

H.Test('Await returns false when the state is skipped', function()
    local Lifecycle, Internal = fresh()
    local thread = H.Thread(function()
        return Lifecycle.Await(States.Ready)
    end)

    H.Capture(function()
        Internal.SetState(States.Stopping)
    end)

    H.Equal(thread.result, false)
    H.Equal(Lifecycle.Await(States.Ready), false)
end)

H.Test('Await returns false on timeout', function()
    local Lifecycle, Internal = fresh()
    local thread = H.Thread(function()
        return Lifecycle.Await(States.Ready, 1000)
    end)

    H.Advance(999)
    H.Equal(thread.done, false)

    H.Advance(1)
    H.Equal(thread.done, true)
    H.Equal(thread.result, false)

    H.Capture(function()
        Internal.SetState(States.Ready)
    end)

    H.Equal(thread.result, false)
end)

H.Test('Await rejects bad arguments', function()
    local Lifecycle = fresh()

    H.Raises(function()
        Lifecycle.Await(H.Any('Running'))
    end, '[ug-core] Lifecycle.Await: unknown state "Running"')

    H.Raises(function()
        Lifecycle.Await(States.Ready, -1)
    end, 'timeout MUST be a non-negative integer')
end)

H.Test('GetHistory returns a copy with timings', function()
    local _, Internal = fresh()

    H.Advance(5)
    H.Capture(function()
        Internal.SetState(States.Configured)
    end)

    local history = Internal.GetHistory()

    H.Equal(#history, 2)
    H.Equal(history[2].state, States.Configured)
    H.Equal(history[2].elapsed, 5)

    history[2].state = H.Any('Changed')
    H.Equal(Internal.GetHistory()[2].state, States.Configured)
end)

H.Done()
