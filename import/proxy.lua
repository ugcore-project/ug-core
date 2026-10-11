--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Import side, in the consumer's runtime. Builds the public `UgCore` root and the bridges local code needs.
---@class UgCore.Internal.Proxy
local Proxy = {}
UgCore.Internal.Proxy = Proxy

local Utils = UgCore.Internal.Utils
local InternalModules = UgCore.Internal.Modules
local InternalLogger = UgCore.Internal.Logger

local CORE = 'ug-core'
local IS_SERVER = IsDuplicityVersion()
local MODULES_KEY = UgCore.Enums.GlobalState.Modules
local CONFIG_KEY = UgCore.Enums.GlobalState.Config
local CATALOG_KEY = UgCore.Enums.GlobalState.Exports
local NOT_READY = "UgCore.%s is not available until ug-core is ready. Wait for UgCore.Lifecycle.Await(UgCore.Enums.Lifecycle.Ready)."

local LOCAL_NAMESPACES = { 'Enums', 'Events', 'Schema', 'Logger', 'Version', 'Callback', 'Network', 'Lifecycle', 'Modules', 'RateLimit' }

---Core namespaces that live in ug-core's runtime on this side.
---@type table<string, boolean>
local PROXIED = IS_SERVER and { Config = true, Guard = true, Hooks = true } or { Config = true }

-- Exports drop metatables, so player data from ug-core becomes a player object again in this runtime.
local WRAPPED_RESULTS = {
    Players = { Get = 'WrapOne', GetByIdentifier = 'WrapOne', GetByCharacterId = 'WrapOne', GetAll = 'WrapAll' },
}

---Schema rules are only valid in the runtime that built them, so a rule becomes a function call back into this one.
---@param name any
---@param definition any
---@return any name
---@return any definition
local function itemRegistration(name, definition)
    local rule = type(definition) == 'table' and definition.metadata or nil

    if type(rule) ~= 'table' or not pcall(UgCore.Schema.Check, rule, nil) then
        return name, definition
    end

    local copy = {}

    for key, value in pairs(definition) do
        copy[key] = value
    end

    copy.metadata = function(metadata)
        return UgCore.Schema.Check(rule, metadata)
    end

    return name, copy
end

-- Arguments rewritten before they cross the export.
local WRAPPED_ARGS = {
    Items = { Register = itemRegistration },
}

local core = exports[CORE]

---@param list any
---@param value string
---@return boolean
local function contains(list, value)
    if type(list) ~= 'table' then
        return true
    end

    for index = 1, #list do
        if list[index] == value then
            return true
        end
    end

    return false
end

---Functions of a namespace, each calling the export `<namespace><Function>`.
---@param namespace string
---@return any
function Proxy.Create(namespace)
    local functions = {}

    return setmetatable({}, {
        __index = function(_, name)
            local cached = functions[name]

            if cached then
                return cached
            end

            if type(name) ~= 'string' then
                return nil
            end

            if IS_SERVER then
                local catalog = GlobalState[CATALOG_KEY]

                if type(catalog) == 'table' and not contains(catalog[namespace], name) then
                    Utils.Raise(2, 'UgCore.%s.%s does not exist.', namespace, name)
                end
            end

            local exportName = namespace .. name
            local wrap = IS_SERVER and WRAPPED_RESULTS[namespace] and WRAPPED_RESULTS[namespace][name]

            local call = function(...)
                return core[exportName](core, ...)
            end

            local rewrite = IS_SERVER and WRAPPED_ARGS[namespace] and WRAPPED_ARGS[namespace][name]

            if wrap then
                call = function(...)
                    return UgCore.Internal.PlayerObject[wrap](core[exportName](core, ...))
                end
            elseif rewrite then
                call = function(...)
                    return core[exportName](core, rewrite(...))
                end
            end

            functions[name] = call

            return call
        end,
        __newindex = function()
            Utils.Raise(2, 'UgCore.%s is read-only.', namespace)
        end,
    })
end

---Stands in for an internal namespace with only the functions local code calls.
---@param functions table
---@return any
function Proxy.Bridge(functions)
    return functions
end

---@param namespace string
---@return table? module `{ module, enabled }` from the replicated module payload
---@return boolean known false before ug-core replicated its modules
local function findModule(namespace)
    local payload = GlobalState[MODULES_KEY]
    local namespaces = type(payload) == 'table' and payload.namespaces or nil

    if type(namespaces) ~= 'table' then
        return nil, false
    end

    return namespaces[namespace], true
end

---The consumer's `UgCore`. Unknown, disabled and private namespaces raise.
---@return table
function Proxy.CreateRoot()
    local locals = {}
    local proxies = {}

    for _, namespace in ipairs(LOCAL_NAMESPACES) do
        locals[namespace] = UgCore[namespace]
    end

    ---@param namespace string
    ---@return any
    local function proxyOf(namespace)
        local proxy = proxies[namespace]

        if not proxy then
            proxy = Proxy.Create(namespace)
            proxies[namespace] = proxy
        end

        return proxy
    end

    local root = setmetatable({}, {
        __index = function(_, namespace)
            local value = locals[namespace]

            if value ~= nil then
                return value
            end

            if type(namespace) ~= 'string' then
                return nil
            end

            if namespace == 'Internal' then
                Utils.Raise(2, 'UgCore.Internal is private to ug-core.')
            end

            if PROXIED[namespace] then
                return proxyOf(namespace)
            end

            local module, known = findModule(namespace)

            if not known then
                Utils.Raise(2, NOT_READY, namespace)
            end

            if not module then
                Utils.Raise(2, 'UgCore.%s is not a ug-core namespace.', namespace)
            end

            ---@cast module -nil

            if module.client and IS_SERVER then
                Utils.Raise(2, 'UgCore.%s exists on clients only.', namespace)
            end

            if not module.enabled then
                Utils.Raise(2, 'UgCore.%s belongs to disabled module "%s". Enable it in config/modules.lua.', namespace, module.module)
            end

            return proxyOf(namespace)
        end,
        __newindex = function(_, namespace)
            Utils.Raise(2, 'UgCore is read-only. Cannot set UgCore.%s.', tostring(namespace))
        end,
    })

    -- Player object methods call module namespaces, which only exist on this root.
    if UgCore.Internal.PlayerObject then
        UgCore.Internal.PlayerObject.SetRoot(root)
    end

    return root
end

---@type table<string, boolean>
local loadedEnums = {}

---Loads `shared/enums.lua` of enabled modules once, so module enums exist in the consumer too.
---@param payload table
local function loadModuleEnums(payload)
    local files = type(payload.files) == 'table' and payload.files or {}

    for _, name in ipairs(payload.order) do
        local shared = type(files[name]) == 'table' and files[name].shared or {}

        for _, stem in ipairs(type(shared) == 'table' and shared or {}) do
            if stem == 'enums' and not loadedEnums[name] then
                loadedEnums[name] = true

                local path = ('modules/%s/shared/enums.lua'):format(name)
                local content = LoadResourceFile(CORE, path)
                local chunk = content and load(content, ('@@%s/%s'):format(CORE, path), 't', _ENV)

                if chunk then
                    chunk()
                end
            end
        end
    end
end

---@param payload any
local function syncModules(payload)
    local order = type(payload) == 'table' and payload.order or nil

    InternalModules.SetEnabled(type(order) == 'table' and order or {})

    if type(order) == 'table' then
        ---@cast payload table
        loadModuleEnums(payload)
    end
end

---@param payload any
local function syncDebug(payload)
    local config = type(payload) == 'table' and payload.core or nil
    local values = type(config) == 'table' and config.values or nil

    InternalLogger.SetDebug(type(values) == 'table' and values.debug == true)
end

syncModules(GlobalState[MODULES_KEY])
syncDebug(GlobalState[CONFIG_KEY])

AddStateBagChangeHandler(MODULES_KEY, 'global', function(_, _, value)
    syncModules(value)
end)

AddStateBagChangeHandler(CONFIG_KEY, 'global', function(_, _, value)
    syncDebug(value)
end)

-- Local network and callback code reads Guard and the global budget from ug-core.
if IS_SERVER then
    UgCore.Guard = Proxy.Create('Guard')
    UgCore.Internal.Guard = Proxy.Bridge({
        ConsumeBudget = function(source)
            return core:GuardConsumeBudget(source)
        end,
    })
end
