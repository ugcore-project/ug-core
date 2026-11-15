--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Server-to-client net events. Clients only receive net events from the server.
---@class UgCore.Network
local Network = {}
UgCore.Network = Network

---@class UgCore.Internal.Network
local InternalNetwork = {}
UgCore.Internal.Network = InternalNetwork

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local RESOURCE = GetCurrentResourceName()
local NAME_PATTERN = '^[%w_]+$'

---@type table<string, boolean>
local registered = {}

---The only RegisterNetEvent call on the client.
---@param eventName string
---@param handler fun(...: any)
---@return any handle for RemoveEventHandler
function InternalNetwork.Listen(eventName, handler)
    RegisterNetEvent(eventName)

    return AddEventHandler(eventName, handler)
end

---Registers `<resource>:<name>` for events the server sends.
---@param name string
---@param handler fun(...: any)
function Network.Register(name, handler)
    if type(name) ~= 'string' or not name:find(NAME_PATTERN) then
        Utils.Raise(2, 'Network.Register expects a name of letters, digits and underscores')
    end

    if type(handler) ~= 'function' then
        Utils.Raise(2, 'Network.Register expects a handler function')
    end

    local eventName = RESOURCE .. ':' .. name

    if registered[eventName] then
        Utils.Raise(2, 'Network.Register: "%s" is already registered', eventName)
    end

    registered[eventName] = true

    InternalNetwork.Listen(eventName, function(...)
        local ok, err = pcall(handler, ...)

        if not ok then
            Logger.Error('Network: %s failed: %s', eventName, tostring(err))
        end
    end)
end

---The server validates and rate limits every event.
---@param name string full event name, such as `myresource:Deposit`
---@param ... any
function Network.TriggerServer(name, ...)
    if type(name) ~= 'string' or not name:find(':', 1, true) then
        Utils.Raise(2, 'Network.TriggerServer expects a full name such as "myresource:Deposit"')
    end

    TriggerServerEvent(name, ...)
end
