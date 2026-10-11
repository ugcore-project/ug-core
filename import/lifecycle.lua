--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Import side. Mirrors ug-core's lifecycle from `ug-core:Lifecycle:Changed`, so `On` and `Await` run locally.
---@class UgCore.Lifecycle
local Lifecycle = {}
UgCore.Lifecycle = Lifecycle

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

local core = exports['ug-core']

---@param method string
---@param ... any
---@return any
local function remote(method, ...)
    local args = table.pack(...)

    -- Indexing a missing export raises too, so the lookup MUST happen inside the pcall.
    local ok, result = pcall(function()
        return core[method](core, table.unpack(args, 1, args.n))
    end)

    return ok and result or nil
end

---@type UgLifecycleState
local current = remote('LifecycleGetState') or States.Booting

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

---@param state UgLifecycleState
---@return boolean
function Lifecycle.HasReached(state)
    checkState(state, 'HasReached')

    return remote('LifecycleHasReached', state) == true
end

---Sticky: runs immediately when ug-core already reached `state`. Never runs when it was skipped.
---@param state UgLifecycleState
---@param handler fun()
function Lifecycle.On(state, handler)
    checkState(state, 'On')

    if type(handler) ~= 'function' then
        Utils.Raise(2, 'Lifecycle.On expects a handler function')
    end

    if remote('LifecycleHasReached', state) == true then
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

---Blocks the current thread until ug-core reaches `state`.
---@param state UgLifecycleState
---@param timeout? integer ms, waits forever when nil
---@return boolean reached false on timeout or when `state` was skipped
function Lifecycle.Await(state, timeout)
    checkState(state, 'Await')

    if timeout ~= nil and (math.type(timeout) ~= 'integer' or timeout < 0) then
        Utils.Raise(2, 'Lifecycle.Await: timeout MUST be a non-negative integer')
    end

    if remote('LifecycleHasReached', state) == true then
        return true
    end

    if rank[state] < rank[current] then
        return false
    end

    local pending = promise.new()
    local settled = false

    ---@param result boolean
    local function settle(result)
        if not settled then
            settled = true
            pending:resolve(result)
        end
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

Events.On(LifecycleEvents.Changed, function(state)
    if rank[state] == nil then
        return
    end

    current = state

    local due = handlers[state] or {}
    local settles = {}

    for index = 1, rank[state] do
        local passed = ORDER[index]

        for _, settle in ipairs(waiters[passed] or {}) do
            settles[#settles + 1] = { settle, passed == state }
        end

        handlers[passed] = nil
        waiters[passed] = nil
    end

    for index = 1, #due do
        runHandler(state, due[index])
    end

    for index = 1, #settles do
        settles[index][1](settles[index][2])
    end
end)
