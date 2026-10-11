--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---After-the-fact notifications over local events, so every resource on the same side receives them.
---Handlers drop `ug-core:*` events that ug-core did not emit.
---@class UgCore.Events
local Events = {}
UgCore.Events = Events

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local CORE_RESOURCE = 'ug-core'
local RESERVED_PREFIX = CORE_RESOURCE .. ':'
local OWN_PREFIX = GetCurrentResourceName() .. ':'

local nextId = 0

---@type table<integer, any>
local handles = {}

---@param name any
---@param handler any
---@param caller string
local function checkSubscription(name, handler, caller)
    if type(name) ~= 'string' or name == '' then
        Utils.Raise(3, 'Events.%s expects a non-empty event name', caller)
    end

    if type(handler) ~= 'function' then
        Utils.Raise(3, 'Events.%s expects a handler function', caller)
    end
end

---@param name string
---@param handler fun(...: any)
---@param once boolean
---@return integer
local function subscribe(name, handler, once)
    nextId = nextId + 1

    local id = nextId
    local reserved = name:sub(1, #RESERVED_PREFIX) == RESERVED_PREFIX

    handles[id] = AddEventHandler(name, function(...)
        if reserved then
            local invoker = GetInvokingResource()

            if invoker ~= CORE_RESOURCE then
                Logger.Debug('Events: dropped %s triggered by %s.', name, tostring(invoker))
                return
            end
        end

        if once then
            Events.Off(id)
        end

        handler(...)
    end)

    return id
end

---@param name UgCoreEvent|string
---@param handler fun(...: any)
---@return integer id for `Off`
function Events.On(name, handler)
    checkSubscription(name, handler, 'On')

    return subscribe(name, handler, false)
end

---The handler runs at most once.
---@param name UgCoreEvent|string
---@param handler fun(...: any)
---@return integer id for `Off`
function Events.Once(name, handler)
    checkSubscription(name, handler, 'Once')

    return subscribe(name, handler, true)
end

---@param id integer
---@return boolean removed false when the id is unknown or already removed
function Events.Off(id)
    local handle = handles[id]

    if handle == nil then
        return false
    end

    handles[id] = nil
    RemoveEventHandler(handle)

    return true
end

---Names MUST start with the emitting resource name.
---@param name UgCoreEvent|string
---@param ... any
function Events.Emit(name, ...)
    if type(name) ~= 'string' or name:sub(1, #OWN_PREFIX) ~= OWN_PREFIX or #name == #OWN_PREFIX then
        Utils.Raise(2, 'Events.Emit: event names MUST start with "%s"', OWN_PREFIX)
    end

    TriggerEvent(name, ...)
end
