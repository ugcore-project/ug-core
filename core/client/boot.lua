--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Client module loader. Loads shared and client files of the modules the server enabled.

local Files = UgCore.Internal.Files
local Logger = UgCore.Logger
local InternalModules = UgCore.Internal.Modules
local States = UgCore.Enums.Lifecycle
local SetState = UgCore.Internal.Lifecycle.SetState
local InternalExports = UgCore.Internal.Exports

local REPLICATION_KEY = UgCore.Enums.GlobalState.Modules

local started = false

---@param path string
---@return boolean ok
local function runFile(path)
    local content = Files.Load(path)

    if content == nil then
        Logger.Error('Modules: missing file %s.', path)
        return false
    end

    local chunk, syntaxError = load(content, '@' .. path, 't')

    if not chunk then
        Logger.Error('Modules: %s', tostring(syntaxError))
        return false
    end

    local ok, err = pcall(chunk)

    if not ok then
        Logger.Error('Modules: %s', tostring(err))
    end

    return ok
end

---The server writes the payload once its modules are configured.
---@param payload any `{ order = string[], files = { [name] = { shared = string[], client = string[] } } }`
local function start(payload)
    if started or type(payload) ~= 'table' or type(payload.order) ~= 'table' or type(payload.files) ~= 'table' then
        return
    end

    started = true

    local order = payload.order

    InternalModules.SetEnabled(order)

    local errors = 0

    for _, name in ipairs(order) do
        local files = payload.files[name] or {}

        for _, side in ipairs({ 'shared', 'client' }) do
            for _, stem in ipairs(files[side] or {}) do
                if not runFile(('modules/%s/%s/%s.lua'):format(name, side, stem)) then
                    errors = errors + 1
                end
            end
        end
    end

    if errors > 0 then
        Logger.Error('Client boot aborted: %d error(s).', errors)
        SetState(States.Stopping)
        SetState(States.Stopped)
        return
    end

    for namespace, module in pairs(type(payload.namespaces) == 'table' and payload.namespaces or {}) do
        if type(module) == 'table' and module.enabled then
            InternalExports.Bind(namespace)
        end
    end

    SetState(States.Ready)
    Logger.Info('ug-core ready. %d modules enabled.', #order)
end

-- Lifecycle like on the server: imports read the state when they load, after ug-core MAY already be Ready.
for _, namespace in ipairs({ 'Config', 'Lifecycle' }) do
    InternalExports.Bind(namespace)
end

start(GlobalState[REPLICATION_KEY])

AddStateBagChangeHandler(REPLICATION_KEY, 'global', function(_, _, value)
    start(value)
end)
