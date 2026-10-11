--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Generates missing configuration files, runs them in a sandbox and resolves values.
---@class UgCore.Internal.Config.Loader
local Loader = {}
UgCore.Internal.Config.Loader = Loader

local Utils = UgCore.Internal.Utils
local Files = UgCore.Internal.Files
local Logger = UgCore.Logger
local InternalConfig = UgCore.Internal.Config
local Validator = UgCore.Internal.Config.Validator
local Serializer = UgCore.Internal.Config.Serializer

local CONFIG_DIR = 'config/'
local KNOWN_KVP_PREFIX = 'ug-core:Config:Known:'
local REPLICATION_KEY = UgCore.Enums.GlobalState.Config
local CONVAR_UNSET = '__ug-core:unset__'

---@param tbl table
---@return table
local function shallowCopy(tbl)
    local copy = {}

    for key, value in pairs(tbl) do
        copy[key] = value
    end

    return copy
end

---Config files get these globals only. Libraries are copies, so a file cannot change them for ug-core.
---@return table
local function newSandbox()
    return {
        vector2 = vector2,
        vector3 = vector3,
        vector4 = vector4,
        vec2 = vector2,
        vec3 = vector3,
        vec4 = vector4,
        math = shallowCopy(math),
        string = shallowCopy(string),
        table = shallowCopy(table),
        json = json and shallowCopy(json),
        tonumber = tonumber,
        tostring = tostring,
        type = type,
        pairs = pairs,
        ipairs = ipairs,
    }
end

---@param name string
---@return string
local function pathOf(name)
    return CONFIG_DIR .. name .. '.lua'
end

---@param entry UgConfigEntry
---@param errors string[]
---@return boolean generated
local function ensureFile(entry, errors)
    local path = pathOf(entry.name)

    if Files.Exists(path) then
        return false
    end

    if not Files.Save(path, Serializer.Generate(entry.name, entry.definition)) then
        errors[#errors + 1] = ('cannot write %s'):format(path)
        return false
    end

    Logger.Info('Config: generated %s.', path)

    return true
end

---@param path string
---@return boolean ok
---@return table? result
---@return string? message
local function runFile(path)
    local content = Files.Load(path)

    if content == nil then
        return false, nil, ('cannot read %s'):format(path)
    end

    local chunk, syntaxError = load(content, '@' .. path, 't', newSandbox())

    if not chunk then
        return false, nil, tostring(syntaxError)
    end

    local ok, result = pcall(chunk)

    if not ok then
        return false, nil, tostring(result)
    end

    if type(result) ~= 'table' then
        return false, nil, ('%s MUST return a table, got %s'):format(path, Validator.Describe(result))
    end

    return true, result, nil
end

---@param tbl table
---@return any[]
local function sortedKeys(tbl)
    local keys = {}

    for key in pairs(tbl) do
        keys[#keys + 1] = key
    end

    table.sort(keys, function(a, b)
        return tostring(a) < tostring(b)
    end)

    return keys
end

---Logs options added since the last boot once. Known keys persist in resource KVP.
---@param entry UgConfigEntry
---@param owner table
---@param generated boolean
local function reportNewOptions(entry, owner, generated)
    local options = entry.definition.options
    local kvpKey = KNOWN_KVP_PREFIX .. entry.name
    local stored = GetResourceKvpString(kvpKey)
    local keys = {}

    for index = 1, #options do
        keys[index] = options[index].key
    end

    if stored and not generated then
        local known = {}

        for key in stored:gmatch('[^,]+') do
            known[key] = true
        end

        for index = 1, #options do
            local option = options[index]

            if not known[option.key] and owner[option.key] == nil then
                Logger.Info(
                    '%s.%s is new. Using default %s. Add it to %s to change it.',
                    entry.name, option.key, Serializer.Inline(option.default), pathOf(entry.name)
                )
            end
        end
    end

    local current = table.concat(keys, ',')

    if stored ~= current then
        SetResourceKvp(kvpKey, current)
    end
end

---@param entry UgConfigEntry
---@param owner table
---@param errors string[]
local function resolveSettings(entry, owner, errors)
    local path = pathOf(entry.name)
    local options = entry.definition.options
    local byKey = {}
    local keys = {}

    for index = 1, #options do
        byKey[options[index].key] = options[index]
        keys[index] = options[index].key
    end

    for _, key in ipairs(sortedKeys(owner)) do
        if not byKey[key] then
            local name = tostring(key)
            local suggestion = type(key) == 'string' and Utils.String.Suggest(name, keys) or nil
            local hint = suggestion and (' Did you mean "%s"?'):format(suggestion) or ''

            Logger.Warn('%s: unknown option "%s" is ignored.%s', path, name, hint)
        end
    end

    local values, sources = {}, {}

    for index = 1, #options do
        local option = options[index]
        local key = option.key
        local value, source = Utils.Table.DeepCopy(option.default), 'default'
        local ownerValue = owner[key]

        if ownerValue ~= nil then
            local ok, checked, message = Validator.CheckValue(option, ownerValue)

            if ok then
                value, source = checked, 'file'
            else
                errors[#errors + 1] = ('%s: %s %s'):format(path, key, message)
            end
        end

        local convar = Validator.ConvarName(entry.name, key)
        local raw = GetConvar(convar, CONVAR_UNSET)

        if raw ~= CONVAR_UNSET then
            local ok, parsed, message = Validator.ParseConvar(option, raw)

            if ok then
                value, source = parsed, 'convar'
            else
                errors[#errors + 1] = ('convar %s: %s'):format(convar, message)
            end
        end

        values[key] = value
        sources[key] = source
    end

    entry.values = values
    entry.sources = sources
end

---@param entry UgConfigEntry
---@param owner table
---@param errors string[]
local function resolveData(entry, owner, errors)
    local definition = entry.definition --[[@as UgConfigDataDefinition]]
    local problem = Validator.CheckEntries(definition, owner)

    if problem then
        errors[#errors + 1] = ('%s: %s'):format(pathOf(entry.name), problem)
    end

    entry.values = Utils.Table.DeepCopy(owner)
    entry.sources = {}
end

---@param declaration { side?: UgConfigSide } an option or a data definition
---@return boolean
local function replicates(declaration)
    return declaration.side == 'client' or declaration.side == 'shared'
end

---Client and shared values replicate through `GlobalState['ug-core:Config']`.
local function replicate()
    local payload = {}

    for _, entry in ipairs(InternalConfig.GetEntries()) do
        local definition = entry.definition

        if not entry.values then
            goto continue
        end

        if definition.kind == 'settings' then
            local values = {}

            for _, option in ipairs(definition.options) do
                if replicates(option) then
                    values[option.key] = entry.values[option.key]
                end
            end

            if next(values) then
                payload[entry.name] = { kind = 'settings', values = values }
            end
        elseif replicates(definition) then
            payload[entry.name] = { kind = 'data', values = entry.values }
        end

        ::continue::
    end

    GlobalState:set(REPLICATION_KEY, payload, true)
end

---Resolves registered configs. Errors are collected and never raised.
---@param names? string[] only these configs, every registered config when nil
---@return boolean ok
---@return string[] errors
function Loader.Load(names)
    local errors = {}
    local only = nil

    if names then
        only = {}

        for index = 1, #names do
            only[names[index]] = true
        end
    end

    for _, entry in ipairs(InternalConfig.GetEntries()) do
        if only and not only[entry.name] then
            goto continue
        end

        local path = pathOf(entry.name)
        local generated = ensureFile(entry, errors)
        local ok, owner, message = runFile(path)

        if not ok or not owner then
            errors[#errors + 1] = message or ('cannot load %s'):format(path)
        elseif entry.definition.kind == 'settings' then
            resolveSettings(entry, owner, errors)
            reportNewOptions(entry, owner, generated)
        else
            resolveData(entry, owner, errors)
        end

        ::continue::
    end

    if #errors == 0 then
        replicate()
    end

    return #errors == 0, errors
end
