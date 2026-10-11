--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Boot state of ug-core. States only move forward. A skipped state is never reached.
---@class UgCore.Lifecycle
local Lifecycle = {}
UgCore.Lifecycle = Lifecycle

---@class UgCore.Internal.Lifecycle
local InternalLifecycle = {}
UgCore.Internal.Lifecycle = InternalLifecycle

---@class UgLifecycleEntry
---@field state UgLifecycleState
---@field at integer GetGameTimer value in ms
---@field elapsed integer ms spent in the previous state

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Events = UgCore.Events
local States = UgCore.Enums.Lifecycle
local LifecycleEvents = UgCore.Enums.Events.Lifecycle

---@type UgLifecycleState[]
local ORDER = {
    States.Booting,
    States.Configured,
    States.Initializing,
    States.Starting,
    States.Ready,
    States.Stopping,
    States.Stopped,
}

---@type table<UgLifecycleState, integer>
local rank = {}

for index = 1, #ORDER do
    rank[ORDER[index]] = index
end

local startedAt = GetGameTimer()

---@type UgLifecycleState
local current = States.Booting

---@type table<UgLifecycleState, boolean>
local reached = { [States.Booting] = true }

---@type UgLifecycleEntry[]
local history = { { state = States.Booting, at = startedAt, elapsed = 0 } }

---@type table<UgLifecycleState, fun()[]>
local handlers = {}

---@type table<UgLifecycleState, fun(reached: boolean)[]>
local waiters = {}

---@param state any
---@param caller string
local function checkState(state, caller)
    if rank[state] == nil then
        Utils.Raise(3, 'Lifecycle.%s: unknown state "%s"', caller, tostring(state))
    end
end

---A failing handler MUST NOT stop the transition or other handlers.
---@param state UgLifecycleState
---@param handler fun()
local function runHandler(state, handler)
    local ok, err = pcall(handler)

    if not ok then
        Logger.Error('Lifecycle: %s handler failed: %s', state, tostring(err))
    end
end

---@return UgLifecycleState
function Lifecycle.GetState()
    return current
end

---@return boolean
function Lifecycle.IsReady()
    return current == States.Ready
end

---False for states not reached yet and for skipped states.
---@param state UgLifecycleState
---@return boolean
function Lifecycle.HasReached(state)
    return reached[state] == true
end

---Sticky: runs immediately when `state` was already reached. Never runs when `state` was skipped.
---@param state UgLifecycleState
---@param handler fun()
function Lifecycle.On(state, handler)
    checkState(state, 'On')

    if type(handler) ~= 'function' then
        Utils.Raise(2, 'Lifecycle.On expects a handler function')
    end

    if reached[state] then
        runHandler(state, handler)
        return
    end

    if rank[state] < rank[current] then
        return
    end

    local list = handlers[state] or {}
    list[#list + 1] = handler
    handlers[state] = list
end

---Blocks the current thread until `state` is reached.
---@param state UgLifecycleState
---@param timeout? integer ms, waits forever when nil
---@return boolean reached false on timeout or when `state` was skipped
function Lifecycle.Await(state, timeout)
    checkState(state, 'Await')

    if timeout ~= nil and (math.type(timeout) ~= 'integer' or timeout < 0) then
        Utils.Raise(2, 'Lifecycle.Await: timeout MUST be a non-negative integer')
    end

    if reached[state] then
        return true
    end

    if rank[state] < rank[current] then
        return false
    end

    local pending = promise.new()
    local settled = false

    ---@param result boolean
    local function settle(result)
        if settled then
            return
        end

        settled = true
        pending:resolve(result)
    end

    local list = waiters[state] or {}
    list[#list + 1] = settle
    waiters[state] = list

    if timeout then
        SetTimeout(timeout, function()
            settle(false)
        end)
    end

    return Citizen.Await(pending)
end

---Only the module loader calls this.
---@param state UgLifecycleState
function InternalLifecycle.SetState(state)
    checkState(state, 'SetState')

    if rank[state] <= rank[current] then
        Utils.Raise(2, 'Lifecycle.SetState: cannot move from %s to %s', current, state)
    end

    local previous = current
    local now = GetGameTimer()
    local elapsed = now - history[#history].at

    current = state
    reached[state] = true
    history[#history + 1] = { state = state, at = now, elapsed = elapsed }

    Logger.Info('Lifecycle: %s (%d ms)', state, elapsed)

    -- Handlers and waiters MAY register new ones, so lists are detached before anything runs
    local due = handlers[state] or {}

    ---@type { [1]: fun(reached: boolean), [2]: boolean }[]
    local settles = {}

    for index = 1, rank[state] do
        local passed = ORDER[index]
        local list = waiters[passed]

        handlers[passed] = nil
        waiters[passed] = nil

        for position = 1, list and #list or 0 do
            settles[#settles + 1] = { list[position], passed == state }
        end
    end

    for index = 1, #due do
        runHandler(state, due[index])
    end

    for index = 1, #settles do
        settles[index][1](settles[index][2])
    end

    Events.Emit(LifecycleEvents.Changed, state, previous)

    if state == States.Ready then
        Events.Emit(LifecycleEvents.Ready)
    elseif state == States.Stopping then
        Events.Emit(LifecycleEvents.Stopping)
    end
end

---@return UgLifecycleEntry[]
function InternalLifecycle.GetHistory()
    return Utils.Table.DeepCopy(history)
end
