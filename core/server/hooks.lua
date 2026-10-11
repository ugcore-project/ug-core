--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Before-the-fact extension points. Handlers MAY cancel or replace the payload.
---Hooks belong to the resource that registered them and are removed when it stops.
---@class UgCore.Hooks
local Hooks = {}
UgCore.Hooks = Hooks

---@class UgCore.Internal.Hooks
local InternalHooks = {}
UgCore.Internal.Hooks = InternalHooks

---@class UgHookEntry
---@field id integer
---@field name UgHookName
---@field handler UgHookHandler
---@field priority integer
---@field resource string

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local RESOURCE = GetCurrentResourceName()

---Hook names from every group in `UgCore.Enums.Hooks`, including groups modules added after this file loaded.
---@return table<string, boolean>
local function knownHooks()
    local known = {}

    for _, group in pairs(UgCore.Enums.Hooks) do
        for _, name in pairs(group) do
            known[name] = true
        end
    end

    return known
end

---@type table<string, UgHookEntry[]> sorted by priority, then registration
local byName = {}

---@type table<integer, UgHookEntry>
local byId = {}

local lastId = 0

---@param a UgHookEntry
---@param b UgHookEntry
---@return boolean
local function before(a, b)
    if a.priority ~= b.priority then
        return a.priority < b.priority
    end

    return a.id < b.id
end

---@param name UgHookName
---@param handler UgHookHandler
---@param options? UgHookOptions
---@return integer id for `Unregister`
function Hooks.Register(name, handler, options)
    local known = knownHooks()

    if not known[name] then
        local names = {}

        for hook in pairs(known) do
            names[#names + 1] = hook
        end

        local suggestion = type(name) == 'string' and Utils.String.Suggest(name, names) or nil
        local hint = suggestion and (' Did you mean "%s"?'):format(suggestion) or ''

        Utils.Raise(2, 'Hooks.Register: unknown hook "%s".%s', tostring(name), hint)
    end

    if type(handler) ~= 'function' and not (type(handler) == 'table' and getmetatable(handler) and getmetatable(handler).__call) then
        Utils.Raise(2, 'Hooks.Register expects a handler function')
    end

    local priority = options and options.priority or 0

    if math.type(priority) ~= 'integer' then
        Utils.Raise(2, 'Hooks.Register: "priority" MUST be an integer')
    end

    lastId = lastId + 1

    local entry = {
        id = lastId,
        name = name,
        handler = handler,
        priority = priority,
        resource = GetInvokingResource() or RESOURCE,
    }

    local list = byName[name] or {}

    list[#list + 1] = entry
    table.sort(list, before)
    byName[name] = list
    byId[entry.id] = entry

    return entry.id
end

---@param id integer
---@return boolean removed false when the id is unknown or already removed
function Hooks.Unregister(id)
    local entry = byId[id]

    if not entry then
        return false
    end

    byId[id] = nil

    local list = byName[entry.name]

    for index = #list, 1, -1 do
        if list[index] == entry then
            table.remove(list, index)
        end
    end

    return true
end

---Runs handlers in order. A failing handler is logged and skipped. It never cancels.
---@param name UgHookName
---@param payload table
---@return boolean proceed false when a handler cancelled
---@return table payload the last payload, replaced by handlers that returned a table
function InternalHooks.Run(name, payload)
    local list = byName[name]

    if not list or #list == 0 then
        return true, payload
    end

    local snapshot = { table.unpack(list) }

    for index = 1, #snapshot do
        local entry = snapshot[index]

        if byId[entry.id] then
            local ok, result = pcall(entry.handler, payload)

            if not ok then
                Logger.Error('Hooks: %s handler from %s failed: %s', name, entry.resource, tostring(result))
            elseif result == false then
                Logger.Debug('Hooks: %s cancelled by %s.', name, entry.resource)
                return false, payload
            elseif type(result) == 'table' then
                payload = result
            end
        end
    end

    return true, payload
end

---@return UgHookInfo[] every registered hook, by name then order
function InternalHooks.GetRegistered()
    local names = {}

    for name in pairs(byName) do
        names[#names + 1] = name
    end

    table.sort(names)

    local result = {}

    for _, name in ipairs(names) do
        for _, entry in ipairs(byName[name]) do
            result[#result + 1] = { name = entry.name, resource = entry.resource, priority = entry.priority }
        end
    end

    return result
end

AddEventHandler('onResourceStop', function(resource)
    if resource == RESOURCE then
        return
    end

    for id, entry in pairs(byId) do
        if entry.resource == resource then
            Hooks.Unregister(id)
        end
    end
end)
