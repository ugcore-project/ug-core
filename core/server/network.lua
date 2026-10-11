--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Client-to-server net events with a schema and a rate limit. The only place that calls RegisterNetEvent.
---@class UgCore.Network
local Network = {}
UgCore.Network = Network

---@class UgCore.Internal.Network
local InternalNetwork = {}
UgCore.Internal.Network = InternalNetwork

---@class UgNetworkEntry
---@field name string full event name, for logs
---@field options UgNetworkOptions
---@field limiter UgRateLimiter

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Schema = UgCore.Schema
local Guard = UgCore.Guard
local InternalGuard = UgCore.Internal.Guard
local Lifecycle = UgCore.Lifecycle
local Violations = UgCore.Enums.Violations
local Errors = UgCore.Enums.Errors

local RESOURCE = GetCurrentResourceName()
local NAME_PATTERN = '^[%w_]+$'
local MAX_NAME = 64
local LOADED_KEY = UgCore.Enums.StateBags.Loaded
local DEATH_STATE_KEY = UgCore.Enums.StateBags.DeathState

---@type table<string, boolean>
local registered = {}

---The only RegisterNetEvent call on the server.
---@param eventName string
---@param handler fun(...: any)
---@return any handle for RemoveEventHandler
function InternalNetwork.Listen(eventName, handler)
    RegisterNetEvent(eventName)

    return AddEventHandler(eventName, handler)
end

---Net events from clients carry a positive source. Local triggers of the same name do not.
---@param raw any the global `source`
---@return integer?
function InternalNetwork.GetSource(raw)
    local value = tonumber(raw)

    if value and value > 0 then
        return math.tointeger(value)
    end

    return nil
end

---Checks before the payload: global budget, per-event rate, `requirePlayer`, `requireAlive`, `permission`.
---Rejections are flagged, except `requireAlive`: downed players MAY press keys.
---@param source integer
---@param entry UgNetworkEntry
---@return boolean ok
---@return UgErrorCode? errorCode
function InternalNetwork.Admit(source, entry)
    if not InternalGuard.ConsumeBudget(source) or not entry.limiter:Consume(source) then
        Guard.Flag(source, Violations.RateLimited, entry.name)
        return false, Errors.RateLimited
    end

    local options = entry.options

    if options.requirePlayer and Player(source).state[LOADED_KEY] ~= true then
        Guard.Flag(source, Violations.NotLoaded, entry.name)
        return false, Errors.NotLoaded
    end

    if options.requireAlive then
        local deathState = Player(source).state[DEATH_STATE_KEY]
        -- Read when used: the players module adds this enum after core files load.
        local states = UgCore.Enums.DeathState

        if deathState ~= nil and states and deathState ~= states.Alive then
            return false, Errors.NoPermission
        end
    end

    if options.permission and not IsPlayerAceAllowed(tostring(source), options.permission) then
        Guard.Flag(source, Violations.NoPermission, entry.name)
        return false, Errors.NoPermission
    end

    return true, nil
end

---Raises on invalid options. Shared by net events and callbacks.
---@param api string
---@param name any
---@param options any
---@param handler any
---@return UgNetworkOptions
function InternalNetwork.CheckRegistration(api, name, options, handler)
    if type(name) ~= 'string' or #name > MAX_NAME or not name:find(NAME_PATTERN) then
        Utils.Raise(3, '%s expects a name of letters, digits and underscores, up to %d characters', api, MAX_NAME)
    end

    if type(options) ~= 'table' then
        Utils.Raise(3, '%s expects options { schema, rate }', api)
    end

    if type(options.schema) ~= 'table' or not pcall(Schema.Validate, options.schema) then
        Utils.Raise(3, '%s: "schema" MUST come from UgCore.Schema.Define', api)
    end

    local rate = options.rate

    if type(rate) ~= 'table' or math.type(rate.max) ~= 'integer' or rate.max < 1 or math.type(rate.per) ~= 'integer' or rate.per < 1 then
        Utils.Raise(3, '%s: "rate" MUST be { max, per } with positive integers', api)
    end

    for _, flag in ipairs({ 'requirePlayer', 'requireAlive' }) do
        if options[flag] ~= nil and type(options[flag]) ~= 'boolean' then
            Utils.Raise(3, '%s: "%s" MUST be a boolean', api, flag)
        end
    end

    if options.permission ~= nil and (type(options.permission) ~= 'string' or options.permission == '') then
        Utils.Raise(3, '%s: "permission" MUST be an ACE name', api)
    end

    if type(handler) ~= 'function' then
        Utils.Raise(3, '%s expects a handler function', api)
    end

    return options
end

---Registers `<resource>:<name>`. The handler gets `(source, ...)` with validated arguments.
---@param name string
---@param options UgNetworkOptions
---@param handler fun(source: integer, ...: any)
function Network.Register(name, options, handler)
    InternalNetwork.CheckRegistration('Network.Register', name, options, handler)

    local eventName = RESOURCE .. ':' .. name

    if registered[eventName] then
        Utils.Raise(2, 'Network.Register: "%s" is already registered', eventName)
    end

    registered[eventName] = true

    local entry = { name = eventName, options = options, limiter = UgCore.RateLimit.Create(options.rate) }
    local schema = options.schema

    InternalNetwork.Listen(eventName, function(...)
        if not Lifecycle.IsReady() then
            return
        end

        local src = InternalNetwork.GetSource(source)

        if not src or not InternalNetwork.Admit(src, entry) then
            return
        end

        local valid, args, detail = Schema.Validate(schema, ...)

        if not valid or not args then
            Guard.Flag(src, Violations.InvalidPayload, eventName .. ' ' .. tostring(detail))
            return
        end

        local called, err = pcall(handler, src, table.unpack(args, 1, args.n))

        if not called then
            Logger.Error('Network: %s failed: %s', eventName, tostring(err))
        end
    end)
end

---@param source integer player source, or -1 for every player
---@param name string full event name, such as `ug-hud:Update`
---@param ... any
function Network.TriggerClient(source, name, ...)
    if math.type(source) ~= 'integer' or (source < 1 and source ~= -1) then
        Utils.Raise(2, 'Network.TriggerClient expects a player source or -1')
    end

    if type(name) ~= 'string' or name == '' then
        Utils.Raise(2, 'Network.TriggerClient expects an event name')
    end

    TriggerClientEvent(name, source, ...)
end

---@param name string full event name
---@param ... any
function Network.TriggerClients(name, ...)
    if type(name) ~= 'string' or name == '' then
        Utils.Raise(2, 'Network.TriggerClients expects an event name')
    end

    TriggerClientEvent(name, -1, ...)
end
