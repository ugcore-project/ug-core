--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Client-to-server callbacks, and server-to-client requests whose results are untrusted.
---Wire: request `__ugcb:<owner>:<name>` with `(callerResource, requestId, ...)`,
---response `__ugcb:res:<callerResource>` with `(requestId, ok, value)`.
---@class UgCore.Callback
local Callback = {}
UgCore.Callback = Callback

---@class UgCallbackEntry : UgNetworkEntry
---@field handler fun(source: integer, ...: any): any

---@class UgPendingRequest
---@field source integer
---@field schema UgSchemaRule
---@field settle fun(ok: boolean, value: any, errorCode: UgErrorCode?)

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Schema = UgCore.Schema
local Guard = UgCore.Guard
local InternalGuard = UgCore.Internal.Guard
local InternalNetwork = UgCore.Internal.Network
local Lifecycle = UgCore.Lifecycle
local Violations = UgCore.Enums.Violations
local Errors = UgCore.Enums.Errors

local RESOURCE = GetCurrentResourceName()
local REQUEST_PREFIX = '__ugcb:'
local RESPONSE_PREFIX = '__ugcb:res:'
local MAX_INFLIGHT = 4
local MAX_REQUEST_ID = 2147483647
local MAX_RESOURCE_NAME = 64
local RESOURCE_PATTERN = '^[%w_%-%.]+$'
local DEFAULT_TIMEOUT = 10000

---@type table<string, UgCallbackEntry>
local callbacks = {}

---@type table<string, boolean>
local listening = {}

---@type table<integer, integer>
local inflight = {}

---@type table<integer, UgPendingRequest>
local pending = {}

local lastRequestId = 0

---@type table<string, boolean>
local knownErrors = {}

for _, code in pairs(Errors) do
    knownErrors[code] = true
end

---@param value any
---@return boolean
local function isRequestId(value)
    return math.type(value) == 'integer' and value >= 1 and value <= MAX_REQUEST_ID
end

---@param value any
---@return boolean
local function isResourceName(value)
    return type(value) == 'string' and #value <= MAX_RESOURCE_NAME and value:find(RESOURCE_PATTERN) ~= nil
        and GetResourceState(value) == 'started'
end

---Pipeline order: exists, concurrency, rate limits, requirePlayer, permission, schema, handler, reply.
---@param name string
---@param src integer
---@param callerResource any
---@param requestId any
---@param ... any
local function handleRequest(name, src, callerResource, requestId, ...)
    local wire = REQUEST_PREFIX .. RESOURCE .. ':' .. name

    if not isRequestId(requestId) or not isResourceName(callerResource) then
        Guard.Flag(src, Violations.InvalidPayload, wire .. ' malformed request')
        return
    end

    local responseEvent = RESPONSE_PREFIX .. callerResource

    ---@param ok boolean
    ---@param value any
    local function reply(ok, value)
        TriggerClientEvent(responseEvent, src, requestId, ok, value)
    end

    local entry = callbacks[name]

    if not entry then
        Guard.Flag(src, Violations.UnknownCallback, wire)
        reply(false, Errors.NotFound)
        return
    end

    if (inflight[src] or 0) >= MAX_INFLIGHT then
        Guard.Flag(src, Violations.ConcurrencyExceeded, wire)
        reply(false, Errors.RateLimited)
        return
    end

    local admitted, errorCode = InternalNetwork.Admit(src, entry)

    if not admitted then
        reply(false, errorCode)
        return
    end

    local valid, args, detail = Schema.Validate(entry.options.schema, ...)

    if not valid or not args then
        Guard.Flag(src, Violations.InvalidPayload, wire .. ' ' .. tostring(detail))
        reply(false, Errors.InvalidArgs)
        return
    end

    inflight[src] = (inflight[src] or 0) + 1

    local called, result = pcall(entry.handler, src, table.unpack(args, 1, args.n))

    if inflight[src] then
        inflight[src] = inflight[src] > 1 and inflight[src] - 1 or nil
    end

    if not called then
        Logger.Error('Callback: %s failed: %s', wire, tostring(result))
        reply(false, Errors.InternalError)
        return
    end

    reply(true, result)
end

---Registers `<resource>:<name>`. The handler gets `(source, ...)` with validated arguments and returns one value.
---@param name string
---@param options UgNetworkOptions
---@param handler fun(source: integer, ...: any): any
function Callback.Register(name, options, handler)
    InternalNetwork.CheckRegistration('Callback.Register', name, options, handler)

    if callbacks[name] then
        Utils.Raise(2, 'Callback.Register: "%s:%s" is already registered', RESOURCE, name)
    end

    callbacks[name] = {
        name = RESOURCE .. ':' .. name,
        options = options,
        limiter = UgCore.RateLimit.Create(options.rate),
        handler = handler,
    }

    if listening[name] then
        return
    end

    listening[name] = true

    InternalNetwork.Listen(REQUEST_PREFIX .. RESOURCE .. ':' .. name, function(callerResource, requestId, ...)
        if not Lifecycle.IsReady() then
            return
        end

        local src = InternalNetwork.GetSource(source)

        if src then
            handleRequest(name, src, callerResource, requestId, ...)
        end
    end)
end

---Later requests get `not_found` and flag `UnknownCallback`.
---@param name string
---@return boolean removed
function Callback.Unregister(name)
    if not callbacks[name] then
        return false
    end

    callbacks[name] = nil

    return true
end

---Asks a client. MUST run in a thread. The value is validated with `options.schema`.
---@param source integer
---@param name string full callback name, such as `ug-hud:GetSettings`
---@param options UgClientCallbackOptions
---@param ... any
---@return boolean ok
---@return any value
---@return UgErrorCode? errorCode
function Callback.Await(source, name, options, ...)
    if math.type(source) ~= 'integer' or source < 1 then
        Utils.Raise(2, 'Callback.Await expects a player source')
    end

    if type(name) ~= 'string' or not name:find(':', 1, true) then
        Utils.Raise(2, 'Callback.Await expects a full name such as "ug-hud:GetSettings"')
    end

    if type(options) ~= 'table' or not pcall(Schema.Check, options.schema, nil) then
        Utils.Raise(2, 'Callback.Await: "schema" MUST be a UgCore.Schema rule')
    end

    local timeout = options.timeout or DEFAULT_TIMEOUT

    if math.type(timeout) ~= 'integer' or timeout < 1 then
        Utils.Raise(2, 'Callback.Await: "timeout" MUST be a positive integer')
    end

    lastRequestId = lastRequestId % MAX_REQUEST_ID + 1

    local requestId = lastRequestId
    local result = promise.new()

    pending[requestId] = {
        source = source,
        schema = options.schema,
        settle = function(ok, value, errorCode)
            if pending[requestId] then
                pending[requestId] = nil
                result:resolve({ ok, value, errorCode })
            end
        end,
    }

    SetTimeout(timeout, function()
        local request = pending[requestId]

        if request then
            request.settle(false, nil, Errors.Timeout)
        end
    end)

    TriggerClientEvent(REQUEST_PREFIX .. name, source, RESOURCE, requestId, ...)

    local outcome = Citizen.Await(result)

    return outcome[1], outcome[2], outcome[3]
end

---Callback form of Await. Runs in its own thread.
---@param source integer
---@param name string
---@param options UgClientCallbackOptions
---@param callback fun(ok: boolean, value: any, errorCode: UgErrorCode?)
---@param ... any
function Callback.Trigger(source, name, options, callback, ...)
    if type(callback) ~= 'function' then
        Utils.Raise(2, 'Callback.Trigger expects a callback function')
    end

    local args = table.pack(...)

    CreateThread(function()
        callback(Callback.Await(source, name, options, table.unpack(args, 1, args.n)))
    end)
end

InternalNetwork.Listen(RESPONSE_PREFIX .. RESOURCE, function(requestId, ok, value)
    local src = InternalNetwork.GetSource(source)

    if not src then
        return
    end

    if not InternalGuard.ConsumeBudget(src) then
        Guard.Flag(src, Violations.RateLimited, 'callback response')
        return
    end

    if not isRequestId(requestId) then
        Guard.Flag(src, Violations.InvalidPayload, 'callback response without a request id')
        return
    end

    local request = pending[requestId]

    if not request or request.source ~= src then
        return
    end

    if ok ~= true then
        request.settle(false, nil, knownErrors[value] and value or Errors.InternalError)
        return
    end

    local valid, checked, detail = Schema.Check(request.schema, value)

    if not valid then
        Guard.Flag(src, Violations.InvalidPayload, 'callback response ' .. tostring(detail))
        request.settle(false, nil, Errors.InvalidArgs)
        return
    end

    request.settle(true, checked, nil)
end)

AddEventHandler('playerDropped', function()
    local dropped = InternalNetwork.GetSource(source)

    if not dropped then
        return
    end

    inflight[dropped] = nil

    for _, request in pairs(pending) do
        if request.source == dropped then
            request.settle(false, nil, Errors.Timeout)
        end
    end
end)
