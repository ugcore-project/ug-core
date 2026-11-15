--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Calls server callbacks, and answers server requests.
---Wire: request `__ugcb:<owner>:<name>` with `(callerResource, requestId, ...)`,
---response `__ugcb:res:<callerResource>` with `(requestId, ok, value)`.
---@class UgCore.Callback
local Callback = {}
UgCore.Callback = Callback

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local InternalNetwork = UgCore.Internal.Network
local Errors = UgCore.Enums.Errors

local RESOURCE = GetCurrentResourceName()
local REQUEST_PREFIX = '__ugcb:'
local RESPONSE_PREFIX = '__ugcb:res:'
local NAME_PATTERN = '^[%w_]+$'
local MAX_REQUEST_ID = 2147483647
local TIMEOUT = 10000

---@type table<integer, fun(ok: boolean, value: any, errorCode: UgErrorCode?)>
local pending = {}

---@type table<string, fun(...: any): any>
local handlers = {}

---@type table<string, boolean>
local listening = {}

local lastRequestId = 0

---Calls a server callback. MUST run in a thread. Late responses are ignored.
---@param name string full name, such as `myresource:GetBalance`
---@param ... any
---@return boolean ok
---@return any value
---@return UgErrorCode? errorCode
function Callback.Await(name, ...)
    if type(name) ~= 'string' or not name:find(':', 1, true) then
        Utils.Raise(2, 'Callback.Await expects a full name such as "myresource:GetBalance"')
    end

    lastRequestId = lastRequestId % MAX_REQUEST_ID + 1

    local requestId = lastRequestId
    local result = promise.new()

    pending[requestId] = function(ok, value, errorCode)
        if pending[requestId] then
            pending[requestId] = nil
            result:resolve({ ok, value, errorCode })
        end
    end

    SetTimeout(TIMEOUT, function()
        local settle = pending[requestId]

        if settle then
            settle(false, nil, Errors.Timeout)
        end
    end)

    TriggerServerEvent(REQUEST_PREFIX .. name, RESOURCE, requestId, ...)

    local outcome = Citizen.Await(result)

    return outcome[1], outcome[2], outcome[3]
end

---Callback form of Await. Runs in its own thread.
---@param name string
---@param callback fun(ok: boolean, value: any, errorCode: UgErrorCode?)
---@param ... any
function Callback.Trigger(name, callback, ...)
    if type(callback) ~= 'function' then
        Utils.Raise(2, 'Callback.Trigger expects a callback function')
    end

    local args = table.pack(...)

    CreateThread(function()
        callback(Callback.Await(name, table.unpack(args, 1, args.n)))
    end)
end

---Answers server requests to `<resource>:<name>`. The handler returns one value with server validation.
---@param name string
---@param handler fun(...: any): any
function Callback.Register(name, handler)
    if type(name) ~= 'string' or not name:find(NAME_PATTERN) then
        Utils.Raise(2, 'Callback.Register expects a name of letters, digits and underscores')
    end

    if type(handler) ~= 'function' then
        Utils.Raise(2, 'Callback.Register expects a handler function')
    end

    if handlers[name] then
        Utils.Raise(2, 'Callback.Register: "%s:%s" is already registered', RESOURCE, name)
    end

    handlers[name] = handler

    if listening[name] then
        return
    end

    listening[name] = true

    InternalNetwork.Listen(REQUEST_PREFIX .. RESOURCE .. ':' .. name, function(serverResource, requestId, ...)
        if type(serverResource) ~= 'string' or math.type(requestId) ~= 'integer' then
            return
        end

        local responseEvent = RESPONSE_PREFIX .. serverResource
        local current = handlers[name]

        if not current then
            TriggerServerEvent(responseEvent, requestId, false, Errors.NotFound)
            return
        end

        local ok, value = pcall(current, ...)

        if not ok then
            Logger.Error('Callback: %s:%s failed: %s', RESOURCE, name, tostring(value))
            TriggerServerEvent(responseEvent, requestId, false, Errors.InternalError)
            return
        end

        TriggerServerEvent(responseEvent, requestId, true, value)
    end)
end

---@param name string
---@return boolean removed
function Callback.Unregister(name)
    if not handlers[name] then
        return false
    end

    handlers[name] = nil

    return true
end

InternalNetwork.Listen(RESPONSE_PREFIX .. RESOURCE, function(requestId, ok, value)
    local settle = pending[requestId]

    if not settle then
        return
    end

    if ok == true then
        settle(true, value, nil)
    else
        settle(false, nil, value)
    end
end)
