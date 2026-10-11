--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Discovers modules, resolves config and dependencies, and drives the lifecycle.
---@class UgCore.Internal.Modules.Loader
local Loader = {}
UgCore.Internal.Modules.Loader = Loader

---@class UgLoadedModule
---@field definition UgModuleDefinition
---@field context UgModuleContext

local Utils = UgCore.Internal.Utils
local Files = UgCore.Internal.Files
local Logger = UgCore.Logger
local InternalLogger = UgCore.Internal.Logger
local InternalModules = UgCore.Internal.Modules
local InternalConfig = UgCore.Internal.Config
local ConfigLoader = UgCore.Internal.Config.Loader
local ConfigValidator = UgCore.Internal.Config.Validator
local Database = UgCore.Internal.Database
local InternalExports = UgCore.Internal.Exports
local States = UgCore.Enums.Lifecycle
local Lifecycle = UgCore.Lifecycle
local InternalLifecycle = UgCore.Internal.Lifecycle

local RESOURCE = GetCurrentResourceName()
local MODULE_METADATA = 'ug_module'
local MODULES_CONFIG = 'modules'
local REPLICATION_KEY = UgCore.Enums.GlobalState.Modules
local NAME_PATTERN = '^[a-z][%w]*$'
local NAMESPACE_PATTERN = '^%u%w*$'
local STEM_PATTERN = '^[%w_]+$'
local VERSION_PATTERN = '^%d+%.%d+%.%d+$'

local RESERVED_NAMES = { core = true, modules = true }

local DEFINITION_FIELDS = {
    'name', 'namespace', 'clientNamespace', 'description', 'required', 'deps', 'optionalDeps',
    'shared', 'server', 'client', 'migrations', 'Init', 'Start', 'Stop',
}

---@type UgModuleStatus[]
local statuses = {}

---Modules whose Init completed, in load order. Stop runs on these in reverse.
---@type UgLoadedModule[]
local initialized = {}

---@return boolean
local function isStopping()
    local state = Lifecycle.GetState()

    return state == States.Stopping or state == States.Stopped
end

---@param name string
---@return string
local function modulePath(name)
    return ('modules/%s/'):format(name)
end

---Runs a Lua file of the resource in the global environment.
---@param path string
---@return boolean ok
---@return any result
---@return string? message
local function runFile(path)
    local content = Files.Load(path)

    if content == nil then
        return false, nil, ('missing file %s'):format(path)
    end

    local chunk, syntaxError = load(content, '@' .. path, 't')

    if not chunk then
        return false, nil, tostring(syntaxError)
    end

    local ok, result = pcall(chunk)

    if not ok then
        return false, nil, tostring(result)
    end

    return true, result, nil
end

---@param value any
---@param pattern string
---@return boolean
local function isNameList(value, pattern)
    if value == nil then
        return true
    end

    if type(value) ~= 'table' then
        return false
    end

    for index = 1, #value do
        if type(value[index]) ~= 'string' or not value[index]:find(pattern) then
            return false
        end
    end

    return Utils.Table.Count(value) == #value
end

---@param name string
---@param definition any
---@return string? problem
local function checkDefinition(name, definition)
    if type(definition) ~= 'table' then
        return 'module.lua MUST return a table'
    end

    for key in pairs(definition) do
        local known = false

        for index = 1, #DEFINITION_FIELDS do
            if DEFINITION_FIELDS[index] == key then
                known = true
                break
            end
        end

        if not known then
            local field = tostring(key)
            local suggestion = type(key) == 'string' and Utils.String.Suggest(field, DEFINITION_FIELDS) or nil
            local hint = suggestion and (' Did you mean "%s"?'):format(suggestion) or ''

            return ('unknown field "%s".%s'):format(field, hint)
        end
    end

    if definition.name ~= name then
        return ('name MUST be "%s", the folder name'):format(name)
    end

    if type(definition.namespace) ~= 'string' or not definition.namespace:find(NAMESPACE_PATTERN) then
        return 'namespace MUST be PascalCase'
    end

    if definition.clientNamespace ~= nil and (type(definition.clientNamespace) ~= 'string' or not definition.clientNamespace:find(NAMESPACE_PATTERN)) then
        return 'clientNamespace MUST be PascalCase'
    end

    if type(definition.description) ~= 'string' or definition.description == '' then
        return 'description MUST be a non-empty string'
    end

    if definition.required ~= nil and type(definition.required) ~= 'boolean' then
        return 'required MUST be a boolean'
    end

    for _, field in ipairs({ 'deps', 'optionalDeps' }) do
        if not isNameList(definition[field], NAME_PATTERN) then
            return ('%s MUST be an array of module names'):format(field)
        end
    end

    for _, field in ipairs({ 'shared', 'server', 'client' }) do
        if not isNameList(definition[field], STEM_PATTERN) then
            return ('%s MUST be an array of file names without extension'):format(field)
        end
    end

    if not isNameList(definition.migrations, VERSION_PATTERN) then
        return 'migrations MUST be an array of versions such as "1.0.0"'
    end

    for _, hook in ipairs({ 'Init', 'Start', 'Stop' }) do
        if definition[hook] ~= nil and type(definition[hook]) ~= 'function' then
            return ('%s MUST be a function'):format(hook)
        end
    end

    return nil
end

---Module names come from `ug_module '<name>'` entries in the manifest.
---@param errors string[]
---@return table<string, UgModuleDefinition> definitions
---@return string[] names sorted
local function discover(errors)
    local definitions = {}
    local names = {}
    local namespaces = {}

    for index = 0, GetNumResourceMetadata(RESOURCE, MODULE_METADATA) - 1 do
        local name = GetResourceMetadata(RESOURCE, MODULE_METADATA, index)

        if type(name) ~= 'string' or not name:find(NAME_PATTERN) or RESERVED_NAMES[name] then
            errors[#errors + 1] = ('fxmanifest.lua: invalid module name %s'):format(ConfigValidator.Describe(name))
        elseif definitions[name] then
            errors[#errors + 1] = ('fxmanifest.lua: module %s is listed twice'):format(name)
        else
            local path = modulePath(name) .. 'module.lua'
            local ok, definition, message = runFile(path)
            local problem = ok and checkDefinition(name, definition) or nil

            if not ok then
                errors[#errors + 1] = message
            elseif problem then
                errors[#errors + 1] = ('%s: %s'):format(path, problem)
            elseif namespaces[definition.namespace] or (definition.clientNamespace and namespaces[definition.clientNamespace]) then
                local taken = namespaces[definition.namespace] and definition.namespace or definition.clientNamespace

                errors[#errors + 1] = ('%s: namespace %s is already used by %s'):format(path, taken, namespaces[taken])
            else
                namespaces[definition.namespace] = name

                if definition.clientNamespace then
                    namespaces[definition.clientNamespace] = name
                end

                definitions[name] = definition
                names[#names + 1] = name
            end
        end
    end

    table.sort(names)

    return definitions, names
end

---Optional modules are listed in config/modules.lua, enabled by default.
---@param definitions table<string, UgModuleDefinition>
---@param names string[]
local function registerModulesConfig(definitions, names)
    local options = {}

    for _, name in ipairs(names) do
        local definition = definitions[name]

        if not definition.required then
            options[#options + 1] = {
                key = name,
                type = 'boolean',
                default = true,
                description = definition.description,
            }
        end
    end

    InternalConfig.Register(MODULES_CONFIG, { kind = 'settings', options = options })
end

---@param definitions table<string, UgModuleDefinition>
---@param names string[]
---@param errors string[]
---@return table<string, boolean> enabled
local function resolveEnabled(definitions, names, errors)
    local switches = InternalConfig.GetEntry(MODULES_CONFIG).values or {}
    local enabled = {}

    statuses = {}

    for _, name in ipairs(names) do
        local required = definitions[name].required == true
        local isEnabled = required or switches[name] == true

        enabled[name] = isEnabled
        statuses[#statuses + 1] = {
            name = name,
            enabled = isEnabled,
            reason = required and 'required' or isEnabled and 'enabled in config/modules.lua' or 'disabled in config/modules.lua',
        }
    end

    for _, name in ipairs(names) do
        if enabled[name] then
            for _, dep in ipairs(definitions[name].deps or {}) do
                if not definitions[dep] then
                    errors[#errors + 1] = ('%s requires %s, which is not installed.'):format(name, dep)
                elseif not enabled[dep] then
                    if definitions[name].required then
                        errors[#errors + 1] = ('%s requires %s. Enable %s.'):format(name, dep, dep)
                    else
                        errors[#errors + 1] = ('%s requires %s. Enable %s or disable %s.'):format(name, dep, dep, name)
                    end
                end
            end
        end
    end

    return enabled
end

---Dependencies and enabled optional dependencies load first. Ties keep alphabetical order.
---@param definitions table<string, UgModuleDefinition>
---@param names string[]
---@param enabled table<string, boolean>
---@param errors string[]
---@return string[] order
local function sortModules(definitions, names, enabled, errors)
    local order = {}
    local state = {}
    local stack = {}

    ---@param name string
    ---@return boolean ok
    local function visit(name)
        if state[name] == 'done' then
            return true
        end

        if state[name] == 'visiting' then
            local cycle = {}
            local start = 1

            for index = 1, #stack do
                if stack[index] == name then
                    start = index
                end
            end

            for index = start, #stack do
                cycle[#cycle + 1] = stack[index]
            end

            cycle[#cycle + 1] = name
            errors[#errors + 1] = ('Dependency cycle: %s.'):format(table.concat(cycle, ' -> '))

            return false
        end

        state[name] = 'visiting'
        stack[#stack + 1] = name

        local definition = definitions[name]
        local edges = {}

        for _, dep in ipairs(definition.deps or {}) do
            edges[#edges + 1] = dep
        end

        for _, dep in ipairs(definition.optionalDeps or {}) do
            edges[#edges + 1] = dep
        end

        for _, dep in ipairs(edges) do
            if enabled[dep] and not visit(dep) then
                return false
            end
        end

        stack[#stack] = nil
        state[name] = 'done'
        order[#order + 1] = name

        return true
    end

    for _, name in ipairs(names) do
        if enabled[name] and not visit(name) then
            return {}
        end
    end

    return order
end

---Registers `config.schema.lua` of enabled modules. Disabled modules get no config file.
---@param order string[]
---@param errors string[]
---@return string[] names of registered module configs
local function registerModuleConfigs(order, errors)
    local registered = {}

    for _, name in ipairs(order) do
        local path = modulePath(name) .. 'config.schema.lua'

        if Files.Exists(path) then
            local ok, definition, message = runFile(path)
            local problem = ok and ConfigValidator.CheckDefinition(name, definition) or nil

            if not ok then
                errors[#errors + 1] = message
            elseif problem then
                errors[#errors + 1] = ('%s: %s'):format(path, problem)
            else
                InternalConfig.Register(name, definition)
                registered[#registered + 1] = name
            end
        end
    end

    return registered
end

---@param name string
---@return UgModuleLogger
local function newLogger(name)
    local prefix = '[' .. name .. '] '
    local logger = {}

    for _, level in ipairs({ 'Debug', 'Info', 'Warn', 'Error' }) do
        local write = Logger[level]

        logger[level] = function(message, ...)
            write(prefix .. tostring(message), ...)
        end
    end

    return logger
end

---@param definition UgModuleDefinition
---@return UgModuleContext
local function newContext(definition)
    local entry = InternalConfig.GetEntry(definition.name)

    return {
        name = definition.name,
        logger = newLogger(definition.name),
        config = entry and Utils.Table.DeepCopy(entry.values) or nil,
        database = Database.Repository,
    }
end

---@param definition UgModuleDefinition
---@param side 'shared'|'server'
---@param errors string[]
local function loadFiles(definition, side, errors)
    for _, stem in ipairs(definition[side] or {}) do
        local ok, _, message = runFile(('%s%s/%s.lua'):format(modulePath(definition.name), side, stem))

        if not ok then
            errors[#errors + 1] = message
        end
    end
end

---@param module UgLoadedModule
---@param hook 'Init'|'Start'|'Stop'
---@return string? message
local function runHook(module, hook)
    local fn = module.definition[hook]

    if not fn then
        return nil
    end

    local ok, err = pcall(fn, module.context)

    if not ok then
        return ('%s.%s failed: %s'):format(module.definition.name, hook, tostring(err))
    end

    return nil
end

---Stops initialized modules in reverse order. Failures are logged, never raised.
local function stopModules()
    for index = #initialized, 1, -1 do
        local message = runHook(initialized[index], 'Stop')

        if message then
            Logger.Error(message)
        end
    end

    initialized = {}
end

---`namespaces` maps every installed module's namespace, so proxies name disabled modules.
---@param definitions table<string, UgModuleDefinition>
---@param order string[]
---@param enabled table<string, boolean>
local function replicate(definitions, order, enabled)
    local files = {}
    local namespaces = {}

    for _, name in ipairs(order) do
        files[name] = { shared = definitions[name].shared or {}, client = definitions[name].client or {} }
    end

    for name, definition in pairs(definitions) do
        namespaces[definition.namespace] = { module = name, enabled = enabled[name] == true }

        if definition.clientNamespace then
            namespaces[definition.clientNamespace] = { module = name, enabled = enabled[name] == true, client = true }
        end
    end

    GlobalState:set(REPLICATION_KEY, { order = order, files = files, namespaces = namespaces }, true)
end

---@param errors string[]
local function abort(errors)
    for index = 1, #errors do
        Logger.Error(errors[index])
    end

    Logger.Error('Boot aborted: %d error(s).', #errors)

    InternalLifecycle.SetState(States.Stopping)
    stopModules()
    Database.Cache.FlushAll()
    InternalModules.SetEnabled({})
    GlobalState:set(REPLICATION_KEY, nil, true)
    InternalLifecycle.SetState(States.Stopped)
end

---@return boolean ok
local function boot()
    local errors = {}
    local definitions, names = discover(errors)

    if #errors > 0 then
        abort(errors)
        return false
    end

    registerModulesConfig(definitions, names)

    local configured
    configured, errors = ConfigLoader.Load({ 'core', 'guard', MODULES_CONFIG })

    if not configured then
        abort(errors)
        return false
    end

    InternalLogger.SetDebug(UgCore.Config.Get('core', 'debug'))

    local enabled = resolveEnabled(definitions, names, errors)
    local order = #errors == 0 and sortModules(definitions, names, enabled, errors) or {}
    local moduleConfigs = #errors == 0 and registerModuleConfigs(order, errors) or {}

    if #errors == 0 and #moduleConfigs > 0 then
        configured, errors = ConfigLoader.Load(moduleConfigs)
    end

    if #errors > 0 then
        abort(errors)
        return false
    end

    InternalModules.SetEnabled(order)
    replicate(definitions, order, enabled)
    InternalLifecycle.SetState(States.Configured)
    InternalLifecycle.SetState(States.Initializing)

    local connected, message = Database.Migrate.Connect()

    if connected then
        connected, message = Database.Migrate.RunCore()
    end

    if not connected then
        abort({ message })
        return false
    end

    for _, name in ipairs(order) do
        local definition = definitions[name]
        local module = { definition = definition, context = newContext(definition) }

        if definition.migrations then
            local migrated, failure = Database.Migrate.Run(name, definition.migrations, modulePath(name) .. 'sql/')

            if not migrated then
                errors[#errors + 1] = failure
            end
        end

        loadFiles(definition, 'shared', errors)
        loadFiles(definition, 'server', errors)

        local failure = #errors == 0 and runHook(module, 'Init') or nil

        if failure then
            errors[#errors + 1] = failure
        end

        if #errors > 0 then
            abort(errors)
            return false
        end

        initialized[#initialized + 1] = module

        -- Bound after Init, which MAY fill the namespace.
        InternalExports.Bind(definition.namespace)
    end

    InternalLifecycle.SetState(States.Starting)

    for _, module in ipairs(initialized) do
        local failure = runHook(module, 'Start')

        if failure then
            abort({ failure })
            return false
        end
    end

    InternalExports.Publish()
    InternalLifecycle.SetState(States.Ready)

    local history = InternalLifecycle.GetHistory()
    local version = GetResourceMetadata(RESOURCE, 'version', 0) or 'unknown'

    Logger.Info('ug-core v%s ready in %d ms. %d modules enabled.', version, history[#history].at - history[1].at, #order)

    return true
end

---Runs the whole boot sequence. Every failure aborts boot with all collected errors.
---MUST run in a thread, so modules MAY wait on the database.
---@return boolean ok
function Loader.Boot()
    local ok, result = pcall(boot)

    if not ok then
        if not isStopping() then
            abort({ 'Boot failed: ' .. tostring(result) })
        end

        return false
    end

    return result
end

---Stops modules in reverse load order. Does nothing once stopping.
function Loader.Shutdown()
    if isStopping() then
        return
    end

    InternalLifecycle.SetState(States.Stopping)
    stopModules()
    Database.Cache.FlushAll()
    GlobalState:set(REPLICATION_KEY, nil, true)
    InternalLifecycle.SetState(States.Stopped)
end

---@return UgModuleStatus[]
function Loader.GetStatuses()
    return Utils.Table.DeepCopy(statuses)
end
