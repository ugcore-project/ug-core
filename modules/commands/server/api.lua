--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Chat commands. Arguments are untrusted input: they are typed, bounded and validated before the handler runs.
---Failures from players emit `ug-core:Commands:Failed` for UI resources. ug-core itself shows nothing to players.
---@class UgCore.Commands
local Commands = {}
UgCore.Commands = Commands

---@class UgCommandEntry
---@field info UgCommandInfo
---@field options UgCommandOptions
---@field limiter UgRateLimiter
---@field handler fun(source: integer, args: table<string, any>)

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Events = UgCore.Events
local Schema = UgCore.Schema
local Lifecycle = UgCore.Lifecycle
local Errors = UgCore.Enums.Errors
local CommandEvents = UgCore.Enums.Events.Commands

local NAME_PATTERN = '^%l[%w_]*$'
local GROUP_PATTERN = '^%l[%l%d_]*$'
local MAX_NAME = 32
local MAX_GROUPS = 16
local CONSOLE = 0
local LOADED_KEY = UgCore.Enums.StateBags.Loaded
local DEFAULT_RATE = { max = 3, per = 2000 }
local DEFAULT_MAX = { string = 64, text = 256 }
local TYPES = { string = true, integer = true, number = true, boolean = true, player = true, text = true }
local BOOLEANS = { ['true'] = true, ['1'] = true, ['false'] = false, ['0'] = false }

---@type table<string, UgCommandEntry>
local commands = {}

---@param info UgCommandInfo
---@return string
local function usage(info)
    local parts = { '/' .. info.name }

    for _, argument in ipairs(info.args) do
        parts[#parts + 1] = (argument.optional and '[%s]' or '<%s>'):format(argument.name)
    end

    return table.concat(parts, ' ')
end

---@param argument UgCommandArgument
---@param raw string
---@return boolean ok
---@return any value
local function parseValue(argument, raw)
    local kind = argument.type

    if kind == 'string' or kind == 'text' then
        local ok, value = Schema.Check(Schema.String({ max = argument.max or DEFAULT_MAX[kind] }), raw)

        return ok, value
    end

    if kind == 'boolean' then
        local value = BOOLEANS[raw:lower()]

        return value ~= nil, value
    end

    local number = tonumber(raw)

    if not number or number ~= number or number == math.huge or number == -math.huge then
        return false, nil
    end

    if kind == 'number' then
        return true, number
    end

    local integer = math.tointeger(number)

    if kind == 'player' then
        return integer ~= nil and UgCore.Players.Get(integer) ~= nil, integer
    end

    return integer ~= nil, integer
end

---@param info UgCommandInfo
---@param raw string[]
---@return boolean ok
---@return table<string, any>? args
---@return integer? failedIndex
local function parse(info, raw)
    local args = {}
    local count = #info.args

    for index, argument in ipairs(info.args) do
        ---@type string?
        local value = raw[index]

        if argument.type == 'text' then
            value = #raw >= index and table.concat(raw, ' ', index) or nil
        end

        if value == nil or value == '' then
            if not argument.optional then
                return false, nil, index
            end
        else
            local ok, parsed = parseValue(argument, value)

            if not ok then
                return false, nil, index
            end

            args[argument.name] = parsed
        end
    end

    local last = info.args[count]

    if #raw > count and not (last and last.type == 'text') then
        return false, nil, count + 1
    end

    return true, args, nil
end

---@param entry UgCommandEntry
---@param source integer
---@param errorCode UgErrorCode
---@param failedIndex? integer
local function fail(entry, source, errorCode, failedIndex)
    if source == CONSOLE then
        print(('%s: %s. Usage: %s'):format(entry.info.name, errorCode, usage(entry.info)))
        return
    end

    Events.Emit(CommandEvents.Failed, source, entry.info.name, errorCode, failedIndex)
end

---`permission` and `groups` MUST both pass when both are set. Any one of `groups` is enough, inheritance included.
---@param entry UgCommandEntry
---@param source integer
---@return boolean
local function allowed(entry, source)
    local options = entry.options

    if options.permission and not IsPlayerAceAllowed(tostring(source), options.permission) then
        return false
    end

    local groups = entry.info.groups

    if not groups then
        return true
    end

    for _, group in ipairs(groups) do
        if UgCore.Permissions.IsInGroup(source, group) then
            return true
        end
    end

    return false
end

---@param entry UgCommandEntry
---@param source integer
---@param raw string[]
local function run(entry, source, raw)
    local options = entry.options

    if source == CONSOLE then
        if options.console == false then
            print(('%s is not available from the server console.'):format(entry.info.name))
            return
        end
    else
        if not Lifecycle.IsReady() or not entry.limiter:Consume(source) then
            return
        end

        if options.requirePlayer and Player(source).state[LOADED_KEY] ~= true then
            fail(entry, source, Errors.NotLoaded)
            return
        end

        if not allowed(entry, source) then
            fail(entry, source, Errors.NoPermission)
            return
        end
    end

    local ok, args, failedIndex = parse(entry.info, raw)

    if not ok or not args then
        fail(entry, source, Errors.InvalidArgs, failedIndex)
        return
    end

    local called, err = pcall(entry.handler, source, args)

    if not called then
        Logger.Error('Commands: /%s failed: %s', entry.info.name, tostring(err))
        fail(entry, source, Errors.InternalError)
    end
end

---@param args any
---@return UgCommandArgument[]
local function checkArguments(args)
    if args == nil then
        return {}
    end

    if type(args) ~= 'table' then
        Utils.Raise(3, 'Commands.Register: args MUST be an array')
    end

    local seenOptional = false

    for index, argument in ipairs(args) do
        if type(argument) ~= 'table' or type(argument.name) ~= 'string' or not TYPES[argument.type] then
            Utils.Raise(3, 'Commands.Register: argument %d MUST have a name and a type of string, integer, number, boolean, player or text', index)
        end

        if argument.max ~= nil and (math.type(argument.max) ~= 'integer' or argument.max < 1) then
            Utils.Raise(3, 'Commands.Register: argument %d max MUST be a positive integer', index)
        end

        if argument.type == 'text' and index ~= #args then
            Utils.Raise(3, 'Commands.Register: a text argument MUST be last')
        end

        if argument.optional then
            seenOptional = true
        elseif seenOptional then
            Utils.Raise(3, 'Commands.Register: optional arguments MUST be trailing')
        end
    end

    return Utils.Table.DeepCopy(args)
end

---@param name string
---@param groups any
---@return string[]? groups nil when the command has no group restriction
local function checkGroups(name, groups)
    if groups == nil then
        return nil
    end

    if type(groups) ~= 'table' or #groups == 0 or #groups > MAX_GROUPS or Utils.Table.Count(groups) ~= #groups then
        Utils.Raise(3, 'Commands.Register: groups MUST be an array of 1 to %d group names', MAX_GROUPS)
    end

    for _, group in ipairs(groups) do
        if type(group) ~= 'string' or #group > MAX_NAME or not group:find(GROUP_PATTERN) then
            Utils.Raise(3, 'Commands.Register: groups MUST hold lowercase group names such as "admin"')
        end

        -- A warning, not an error: owners rename groups, and that MUST NOT break other resources.
        if not UgCore.Permissions.GetGroupDefinition(group) then
            Logger.Warn('Commands: /%s allows group "%s", which is not in config/permissions.lua. Nobody matches it.', name, group)
        end
    end

    return Utils.Table.DeepCopy(groups)
end

---Registers a chat command `/name`. The handler gets `(source, args)` with args keyed by name. Source 0 is the console.
---@param name string
---@param options UgCommandOptions
---@param handler fun(source: integer, args: table<string, any>)
function Commands.Register(name, options, handler)
    if type(name) ~= 'string' or #name > MAX_NAME or not name:find(NAME_PATTERN) then
        Utils.Raise(2, 'Commands.Register expects a lowercase name of up to %d characters', MAX_NAME)
    end

    if commands[name] then
        Utils.Raise(2, 'Commands.Register: /%s is already registered', name)
    end

    options = options or {}

    if type(options) ~= 'table' or type(handler) ~= 'function' then
        Utils.Raise(2, 'Commands.Register expects options and a handler function')
    end

    if options.permission ~= nil and (type(options.permission) ~= 'string' or options.permission == '') then
        Utils.Raise(2, 'Commands.Register: permission MUST be an ACE name')
    end

    local entry = {
        info = {
            name = name,
            help = options.help,
            permission = options.permission,
            groups = checkGroups(name, options.groups),
            args = checkArguments(options.args),
        },
        options = options,
        limiter = UgCore.RateLimit.Create(options.rate or DEFAULT_RATE),
        handler = handler,
    }

    commands[name] = entry

    RegisterCommand(name, function(source, raw)
        if commands[name] == entry then
            run(entry, math.tointeger(tonumber(source)) or CONSOLE, type(raw) == 'table' and raw or {})
        end
    end, false)
end

---True when the player passes the command's `permission` and `groups`. For chat suggestions and menus.
---Rate limits, `requirePlayer` and arguments are not checked. Unknown commands return false.
---@param source integer player source, or 0 for the console
---@param name string command name without the slash
---@return boolean
function Commands.CanUse(source, name)
    if math.type(source) ~= 'integer' or source < 0 then
        Utils.Raise(2, 'Commands.CanUse expects a player source or 0 for the console')
    end

    local entry = type(name) == 'string' and commands[name] or nil

    if not entry then
        return false
    end

    if source == CONSOLE then
        return entry.options.console ~= false
    end

    return allowed(entry, source)
end

---Commands sorted by name, for chat suggestions. Filter them per player with CanUse.
---@return UgCommandInfo[]
function Commands.GetAll()
    local list = {}

    for _, entry in pairs(commands) do
        list[#list + 1] = Utils.Table.DeepCopy(entry.info)
    end

    table.sort(list, function(a, b)
        return a.name < b.name
    end)

    return list
end
