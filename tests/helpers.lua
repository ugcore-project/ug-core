--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Test runner and native mocks. Suites run from the repo root with plain Lua 5.4.
---@class TestHelpers
---@field ResourceFiles table<string, string> in-memory files of the mocked resource
---@field Convars table<string, string>
---@field Clock integer mocked GetGameTimer value in ms
---@field IsServer boolean
---@field Kvp table<string, string> resource KVP, survives LoadManifest like a real reboot
---@field Aces table<string, boolean> keys are "<source>:<ace>"
---@field Metadata table<string, string[]> extra manifest metadata entries by key, such as ug_module
---@field Db TestDatabase in-memory oxmysql, survives LoadManifest like a real database
---@field CurrentResource string what GetCurrentResourceName returns
---@field ResourceMetadata table<string, table<string, string>> manifest entries of other resources: resource -> key -> value
---@field DiskModules boolean when true, `modules/` files missing from ResourceFiles load from disk
---@field HttpResponse TestHttpResponse|false answer of every PerformHttpRequest, given right away. false never answers.
---@field HttpRequests TestHttpRequest[] every PerformHttpRequest, oldest first
local Helpers = {
    HttpResponse = { status = 404 },
    HttpRequests = {},
    ResourceMetadata = {},
    DiskModules = false,
    CurrentResource = 'ug-core',
    Metadata = {},
    ResourceFiles = {},
    Convars = {},
    Kvp = {},
    Aces = {},
    Clock = 0,
    IsServer = true,
}

local RESOURCE_NAME = 'ug-core'
local MANIFEST_PATH = 'fxmanifest.lua'
local MANIFEST_VERSION = '0.0.0-test'

local passed, failed = 0, 0

---@param ... any
---@return string
local function concatArgs(...)
    local parts = {}

    for index = 1, select('#', ...) do
        parts[index] = tostring((select(index, ...)))
    end

    return table.concat(parts, '\t')
end

---@type fun(...: any)
local realPrint = print

---@type string[]?
local captured = nil

print = function(...)
    if captured then
        captured[#captured + 1] = concatArgs(...)
    else
        realPrint(...)
    end
end

---@return string
function GetCurrentResourceName()
    return Helpers.CurrentResource
end

---@return boolean
function IsDuplicityVersion()
    return Helpers.IsServer
end

---@param resource string
---@param path string
---@return string?
function LoadResourceFile(resource, path)
    if resource ~= RESOURCE_NAME then
        return nil
    end

    local content = Helpers.ResourceFiles[path]

    if content == nil and (path:find('^core/') or path:find('^import') or path:find('^locales/') or (Helpers.DiskModules and path:find('^modules/'))) then
        local file = io.open(path, 'rb')

        if file then
            content = file:read('a')
            file:close()
        end
    end

    return content
end

---@param resource string
---@param path string
---@param data string
---@param length integer
---@return boolean
function SaveResourceFile(resource, path, data, length)
    if resource ~= RESOURCE_NAME then
        return false
    end

    Helpers.ResourceFiles[path] = data:sub(1, length)

    return true
end

---@param resource string
---@param key string
---@param index integer
---@return string?
function GetResourceMetadata(resource, key, index)
    if resource ~= RESOURCE_NAME then
        local entries = Helpers.ResourceMetadata[resource]

        return index == 0 and entries and entries[key] or nil
    end

    if key == 'version' and index == 0 then
        return (Helpers.ResourceMetadata[RESOURCE_NAME] or {}).version or MANIFEST_VERSION
    end

    local entries = Helpers.Metadata[key]

    return entries and entries[index + 1] or nil
end

---@param resource string
---@param key string
---@return integer
function GetNumResourceMetadata(resource, key)
    if resource ~= RESOURCE_NAME then
        return 0
    end

    return #(Helpers.Metadata[key] or {})
end

---@param name string
---@param default string
---@return string
function GetConvar(name, default)
    local value = Helpers.Convars[name]

    if value == nil then
        return default
    end

    return value
end

---@param name string
---@param default integer
---@return integer
function GetConvarInt(name, default)
    return math.tointeger(tonumber(Helpers.Convars[name])) or default
end

---@param key string
---@return string?
function GetResourceKvpString(key)
    return Helpers.Kvp[key]
end

---@param key string
---@param value string
function SetResourceKvp(key, value)
    Helpers.Kvp[key] = value
end

---@type table<string, fun(source: integer, args: string[], raw: string)>
local commands = {}

---@param name string
---@param handler fun(source: integer, args: string[], raw: string)
---@param restricted boolean
function RegisterCommand(name, handler, restricted)
    commands[name] = handler
end

---@type table<string, table<string, boolean>> principal -> aces added with ExecuteCommand
local principalAces = {}

---@type table<string, table<string, boolean>> child principal -> parent principals added with ExecuteCommand
local principalParents = {}

---@type string[]
Helpers.Commands = {}

---Records the command. `add_ace`, `remove_ace`, `add_principal` and `remove_principal` change the ACL like FXServer does.
---@param command string
function ExecuteCommand(command)
    Helpers.Commands[#Helpers.Commands + 1] = command

    local verb, principal, ace = command:match('^(%a+_ace) (%S+) (%S+) allow$')

    if verb == 'add_ace' then
        principalAces[principal] = principalAces[principal] or {}
        principalAces[principal][ace] = true
    elseif verb == 'remove_ace' and principalAces[principal] then
        principalAces[principal][ace] = nil
    end

    local principalVerb, child, parent = command:match('^(%a+_principal) (%S+) (%S+)$')

    if principalVerb == 'add_principal' then
        principalParents[child] = principalParents[child] or {}
        principalParents[child][parent] = true
    elseif principalVerb == 'remove_principal' and principalParents[child] then
        principalParents[child][parent] = nil
    end
end

---Follows parent principals, like FXServer ACE checks.
---@param principal string
---@param ace string
---@param seen? table<string, boolean>
---@return boolean
local function principalAllowed(principal, ace, seen)
    if Helpers.Aces[principal .. ':' .. ace] == true or (principalAces[principal] or {})[ace] == true then
        return true
    end

    seen = seen or {}

    if seen[principal] then
        return false
    end

    seen[principal] = true

    for parent in pairs(principalParents[principal] or {}) do
        if principalAllowed(parent, ace, seen) then
            return true
        end
    end

    return false
end

---@param principal string
---@param ace string
---@return boolean
function IsPrincipalAceAllowed(principal, ace)
    return principalAllowed(principal, ace)
end

---@param source string
---@param ace string
---@return boolean
function IsPlayerAceAllowed(source, ace)
    if Helpers.Aces[source .. ':' .. ace] == true then
        return true
    end

    for _, identifier in ipairs(Helpers.Net.identifiers[math.tointeger(tonumber(source)) or 0] or {}) do
        if principalAllowed('identifier.' .. identifier, ace) then
            return true
        end
    end

    return false
end

---Clears ACEs and principals added with ExecuteCommand and the command log, like a server restart.
function Helpers.ResetAces()
    principalAces = {}
    principalParents = {}
    Helpers.Commands = {}
end

---@type { key: string, bag: string?, handler: fun(bagName: string, key: string, value: any) }[]
local stateBagHandlers = {}

---@param key string
---@param bagName string
---@param handler fun(bagName: string, key: string, value: any)
---@return integer
function AddStateBagChangeHandler(key, bagName, handler)
    stateBagHandlers[#stateBagHandlers + 1] = { key = key, bag = bagName, handler = handler }

    return #stateBagHandlers
end

---@return integer
function GetGameTimer()
    return Helpers.Clock
end

GlobalState = {
    ---@param self table
    ---@param key string
    ---@param value any
    ---@param _ boolean?
    set = function(self, key, value, _)
        rawset(self, key, value)
    end,
}

---@class TestEventHandle
---@field key integer
---@field name string
---@field handler fun(...: any)
---@field removed boolean

---@type TestEventHandle[]
local eventHandlers = {}

local nextEventKey = 0

---@type string?
local invokingResource = nil

---@class TestTimer
---@field at integer
---@field callback fun()

---@type TestTimer[]
local timers = {}

---Fires on the first Helpers.Advance that reaches it, never during the Advance that created it.
---@param ms integer
---@param callback fun()
function SetTimeout(ms, callback)
    timers[#timers + 1] = { at = Helpers.Clock + ms, callback = callback }
end

---@class TestPromise
---@field settled boolean
---@field value any
---@field waiting thread[]
local TestPromise = {}
TestPromise.__index = TestPromise

---@param value any
function TestPromise:resolve(value)
    if self.settled then
        return
    end

    self.settled = true
    self.value = value

    for index = 1, #self.waiting do
        local ok, err = coroutine.resume(self.waiting[index])

        if not ok then
            error(err, 0)
        end
    end
end

promise = {
    ---@return TestPromise
    new = function()
        return setmetatable({ settled = false, waiting = {} }, TestPromise)
    end,
}

Citizen = {
    ---Yields the running Helpers.Thread until `p` settles.
    ---@param p TestPromise
    ---@return any
    Await = function(p)
        if p.settled then
            return p.value
        end

        local co, isMain = coroutine.running()

        if isMain then
            error('Citizen.Await called outside a thread', 2)
        end

        p.waiting[#p.waiting + 1] = co
        coroutine.yield()

        return p.value
    end,
}

---@type thread[]
local threads = {}

---@param name string
---@param handler fun(...: any)
---@return TestEventHandle
function AddEventHandler(name, handler)
    nextEventKey = nextEventKey + 1

    local handle = { key = nextEventKey, name = name, handler = handler, removed = false }
    eventHandlers[#eventHandlers + 1] = handle

    return handle
end

---@param handle TestEventHandle
function RemoveEventHandler(handle)
    handle.removed = true

    for index = #eventHandlers, 1, -1 do
        if eventHandlers[index] == handle then
            table.remove(eventHandlers, index)
        end
    end
end

---@return string?
function GetInvokingResource()
    return invokingResource
end

---Runs the handlers of `name` like FiveM: a snapshot of the current handlers, each as a thread, with `source` and the invoking resource set.
---@param name string
---@param invoker string?
---@param eventSource integer?
---@param ... any
local function dispatch(name, invoker, eventSource, ...)
    local snapshot = {}

    for index = 1, #eventHandlers do
        if eventHandlers[index].name == name then
            snapshot[#snapshot + 1] = eventHandlers[index]
        end
    end

    local previousSource, previousInvoker = source, invokingResource
    source, invokingResource = eventSource, invoker

    for index = 1, #snapshot do
        if not snapshot[index].removed then
            local co = coroutine.create(snapshot[index].handler)
            local ok, err = coroutine.resume(co, ...)

            if not ok then
                source, invokingResource = previousSource, previousInvoker
                error(err, 0)
            end
        end
    end

    source, invokingResource = previousSource, previousInvoker
end

---Local event from this resource. Arguments are passed as-is, without msgpack copies.
---@param name string
---@param ... any
function TriggerEvent(name, ...)
    dispatch(name, RESOURCE_NAME, nil, ...)
end

---Runs `fn` as a coroutine right away, until its first Wait. Errors surface like in FiveM: printed, not raised.
---@param fn fun()
function CreateThread(fn)
    local co = coroutine.create(fn)
    threads[#threads + 1] = co

    local ok, err = coroutine.resume(co)

    if not ok then
        realPrint('thread error: ' .. tostring(err))
    end
end

---Yields the running thread until Helpers.Advance reaches `ms` from now.
---@param ms integer
function Wait(ms)
    local co, isMain = coroutine.running()

    if isMain then
        error('Wait(' .. tostring(ms) .. ') called outside a thread', 2)
    end

    SetTimeout(ms, function()
        local ok, err = coroutine.resume(co)

        if not ok then
            realPrint('thread error: ' .. tostring(err))
        end
    end)

    coroutine.yield()
end

---@type fun(value: any): string
local rawType = type

---@type table<table, string>
local vectorKinds = setmetatable({}, { __mode = 'k' })

---Mocks the CfxLua `type`, which names vectors instead of returning "userdata".
---@param value any
---@return string
type = function(value)
    return rawType(value) == 'table' and vectorKinds[value] or rawType(value)
end

local VECTOR_KEYS = { 'x', 'y', 'z', 'w' }

local VectorMeta = {
    __sub = function(a, b)
        local result = {}

        for _, key in ipairs(VECTOR_KEYS) do
            if a[key] ~= nil then
                result[key] = a[key] - b[key]
            end
        end

        vectorKinds[result] = vectorKinds[a]

        return setmetatable(result, getmetatable(a))
    end,
    __len = function(a)
        local sum = 0

        for _, key in ipairs(VECTOR_KEYS) do
            if a[key] ~= nil then
                sum = sum + a[key] * a[key]
            end
        end

        return math.sqrt(sum)
    end,
}

---@param kind string
---@param components table
---@return table
local function newVector(kind, components)
    vectorKinds[components] = kind

    return setmetatable(components, VectorMeta)
end

---@param x number
---@param y number
---@return vector2
function vector2(x, y)
    return newVector('vector2', { x = x, y = y })
end

---@param x number
---@param y number
---@param z number
---@return vector3
function vector3(x, y, z)
    return newVector('vector3', { x = x, y = y, z = z })
end

---@param x number
---@param y number
---@param z number
---@param w number
---@return vector4
function vector4(x, y, z, w)
    return newVector('vector4', { x = x, y = y, z = z, w = w })
end

---@type table<string, table<string, table<string, function>>> side -> resource -> export name -> function
local exported = { server = {}, client = {} }

---@return string
local function sideName()
    return Helpers.IsServer and 'server' or 'client'
end

---Like FiveM: `exports(name, fn)` registers for the current resource on this side,
---`exports[resource]:Name(...)` calls it with the caller as invoking resource.
exports = setmetatable({}, {
    __call = function(_, name, fn)
        local bySide = exported[sideName()]
        local own = bySide[Helpers.CurrentResource] or {}

        own[name] = fn
        bySide[Helpers.CurrentResource] = own
    end,
    __index = function(_, resource)
        local caller = Helpers.CurrentResource
        local side = sideName()

        return setmetatable({}, {
            -- Like FiveM, a missing export raises when it is looked up, not when it is called.
            __index = function(_, name)
                if not (exported[side][resource] or {})[name] then
                    error(('No such export %s in resource %s'):format(name, resource), 2)
                end

                return function(_, ...)
                    local fn = (exported[side][resource] or {})[name]
                    local previousResource, previousInvoker = Helpers.CurrentResource, invokingResource
                    Helpers.CurrentResource, invokingResource = resource, caller

                    local results = table.pack(pcall(fn, ...))

                    Helpers.CurrentResource, invokingResource = previousResource, previousInvoker

                    if not results[1] then
                        error(results[2], 0)
                    end

                    return table.unpack(results, 2, results.n)
                end
            end,
        })
    end,
})

---Loads `@ug-core/import.lua` as another resource would, in its own global environment.
---@param resource string
---@param side 'server'|'client'
---@return table env the consumer's globals, with `UgCore`
---@return string[] lines printed while loading
function Helpers.LoadImport(resource, side)
    local previousResource, previousServer = Helpers.CurrentResource, Helpers.IsServer
    local env = setmetatable({}, { __index = _G })

    Helpers.CurrentResource, Helpers.IsServer = resource, side == 'server'

    local chunk, err = loadfile('import.lua', 't', env)

    if not chunk then
        error(err, 0)
    end

    local ok, lines = pcall(Helpers.Capture, chunk)

    Helpers.CurrentResource, Helpers.IsServer = previousResource, previousServer

    if not ok then
        error(lines, 0)
    end

    return env, lines
end

---Event raised by FiveM itself, such as playerDropped. There is no invoking resource.
---@param name string
---@param eventSource integer?
---@param ... any
function Helpers.TriggerEvent(name, eventSource, ...)
    dispatch(name, nil, eventSource, ...)
end

---@type table<string, boolean>
local netEvents = {}

---@class TestNetworkRecord
---@field name string
---@field target integer? player source for client events
---@field args table packed arguments

---@class TestNetwork
---@field client TestNetworkRecord[] TriggerClientEvent calls
---@field server TestNetworkRecord[] TriggerServerEvent calls
---@field dropped { source: string, reason: string }[]
---@field states table<integer, table> Player(source).state
---@field peds table<integer, integer> source -> ped
---@field coords table<integer, vector3> ped -> coords
---@field resources table<string, string> resource -> state, ug-core is always started
---@field identifiers table<integer, string[]> source -> identifiers
---@field names table<integer, string> source -> player name
---@field health table<integer, integer> entity -> health, 200 when unset
---@field causeOfDeath table<integer, integer> ped -> weapon hash
---@field sourceOfDeath table<integer, integer> ped -> killer ped
---@field owners table<integer, integer> player ped -> owner source, also marks the ped as a player
---@field netEntities table<integer, integer> network id -> entity
---@field lastBone table<integer, integer> ped -> bone tag
---@field damagedBy table<integer, integer> ped -> weapon hash
---@field disabled table<integer, boolean> disabled controls
---@field calls string[] resurrect, animation and task calls on the client
---@field buckets table<integer, integer> source -> routing bucket
---@field bucketSettings table<integer, { lockdown: string?, population: boolean? }>
---@field vehicles table<integer, TestVehicle> vehicle entity -> state. Their coords live in `coords`.
---@field weapons table<integer, table<integer, TestWeapon>> ped -> weapon hash -> state
---@field current table<integer, integer> ped -> weapon hash in hand
---@field tints table<integer, integer> weapon hash -> tint applied on the client

---@class TestWeapon
---@field ammo integer
---@field components table<integer, boolean>

---@class TestVehicle
---@field plate string as the game pads it, up to 8 characters
---@field lock? integer door lock status, 0 when unset
---@field driver? integer ped inside

---@return TestNetwork
local function newNetwork()
    return { client = {}, server = {}, dropped = {}, states = {}, peds = {}, coords = {}, resources = {}, identifiers = {}, names = {},
        health = {}, causeOfDeath = {}, sourceOfDeath = {}, owners = {}, netEntities = {}, lastBone = {}, damagedBy = {},
        disabled = {}, calls = {}, buckets = {}, bucketSettings = {}, vehicles = {}, weapons = {}, current = {}, tints = {} }
end

---@type TestNetwork
Helpers.Net = newNetwork()

function Helpers.ResetNetwork()
    Helpers.Net = newNetwork()
end

---@param name string
function RegisterNetEvent(name)
    netEvents[name] = true
end

---@param name string
---@param target integer
---@param ... any
function TriggerClientEvent(name, target, ...)
    table.insert(Helpers.Net.client, { name = name, target = target, args = table.pack(...) })
end

---@param name string
---@param ... any
function TriggerServerEvent(name, ...)
    table.insert(Helpers.Net.server, { name = name, args = table.pack(...) })
end

---@param source integer|string
---@return { state: table }
function Player(source)
    local id = math.tointeger(tonumber(source)) or 0
    local state = Helpers.Net.states[id] or {}

    if getmetatable(state) == nil then
        setmetatable(state, {
            __index = {
                set = function(self, key, value)
                    rawset(self, key, value)
                    Helpers.NotifyStateBag('player:' .. id, key, value)
                end,
            },
        })
    end

    Helpers.Net.states[id] = state

    return { state = state }
end

---@class TestHttpResponse
---@field status integer
---@field body? string

---@class TestHttpRequest
---@field url string
---@field method string
---@field headers table<string, string>

---Answers synchronously with Helpers.HttpResponse, or never when it is false.
---@param url string
---@param callback fun(status: integer, body?: string, headers: table<string, string>, errorData?: string)
---@param method? string
---@param data? string
---@param headers? table<string, string>
function PerformHttpRequest(url, callback, method, data, headers)
    Helpers.HttpRequests[#Helpers.HttpRequests + 1] = { url = url, method = method or 'GET', headers = headers or {} }

    local response = Helpers.HttpResponse

    if response then
        callback(response.status, response.body, {}, nil)
    end
end

---Minimal json like the CfxLua one: objects, arrays, strings, numbers, booleans. Empty tables encode as `[]`.
json = {}

---@param value any
---@return string
function json.encode(value)
    local kind = type(value)

    if kind == 'nil' then
        return 'null'
    end

    if kind == 'boolean' then
        return tostring(value)
    end

    if kind == 'number' then
        return math.type(value) == 'integer' and tostring(value) or ('%.17g'):format(value)
    end

    if kind == 'string' then
        return '"' .. value:gsub('[%c"\\]', function(char)
            return ('\\u%04x'):format(char:byte())
        end) .. '"'
    end

    if kind ~= 'table' then
        error('cannot encode a ' .. kind, 2)
    end

    local count = 0

    for _ in pairs(value) do
        count = count + 1
    end

    local parts = {}

    if count == #value then
        for index = 1, #value do
            parts[index] = json.encode(value[index])
        end

        return '[' .. table.concat(parts, ',') .. ']'
    end

    local keys = {}

    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end

    table.sort(keys)

    for index, key in ipairs(keys) do
        local entry = value[key]

        if entry == nil then
            entry = value[tonumber(key)]
        end

        parts[index] = json.encode(key) .. ':' .. json.encode(entry)
    end

    return '{' .. table.concat(parts, ',') .. '}'
end

---@param text string
---@return any
function json.decode(text)
    local position = 1

    local function skip()
        position = text:find('[^%s]', position) or #text + 1
    end

    local parse

    local function parseString()
        local result = {}

        position = position + 1

        while true do
            local char = text:sub(position, position)

            if char == '"' then
                position = position + 1
                return table.concat(result)
            end

            if char == '\\' then
                local escape = text:sub(position + 1, position + 1)

                if escape == 'u' then
                    result[#result + 1] = utf8.char(tonumber(text:sub(position + 2, position + 5), 16))
                    position = position + 6
                else
                    result[#result + 1] = ({ n = '\n', t = '\t', r = '\r' })[escape] or escape
                    position = position + 2
                end
            else
                result[#result + 1] = char
                position = position + 1
            end
        end
    end

    parse = function()
        skip()

        local char = text:sub(position, position)

        if char == '{' then
            local result = {}

            position = position + 1
            skip()

            if text:sub(position, position) == '}' then
                position = position + 1
                return result
            end

            while true do
                skip()

                local key = parseString()

                skip()
                position = position + 1
                result[key] = parse()
                skip()

                local separator = text:sub(position, position)

                position = position + 1

                if separator == '}' then
                    return result
                end
            end
        end

        if char == '[' then
            local result = {}

            position = position + 1
            skip()

            if text:sub(position, position) == ']' then
                position = position + 1
                return result
            end

            while true do
                result[#result + 1] = parse()
                skip()

                local separator = text:sub(position, position)

                position = position + 1

                if separator == ']' then
                    return result
                end
            end
        end

        if char == '"' then
            return parseString()
        end

        for literal, value in pairs({ ['true'] = true, ['false'] = false, ['null'] = json }) do
            if text:sub(position, position + #literal - 1) == literal then
                position = position + #literal

                if value == json then
                    return nil
                end

                return value
            end
        end

        local number = text:match('^-?%d+%.?%d*[eE]?[-+]?%d*', position)

        position = position + #number

        return math.tointeger(tonumber(number)) or tonumber(number)
    end

    return parse()
end

---@type integer server id of the local player on the mocked client
Helpers.LocalSource = 1

LocalPlayer = setmetatable({}, {
    __index = function(_, key)
        if key == 'state' then
            return Player(Helpers.LocalSource).state
        end

        return nil
    end,
})

---Jenkins one-at-a-time over the lowercase name, as signed 32-bit, like GET_HASH_KEY.
---@param name string
---@return integer
function GetHashKey(name)
    local hash = 0

    for index = 1, #name do
        hash = (hash + name:lower():byte(index)) & 0xFFFFFFFF
        hash = (hash + (hash << 10)) & 0xFFFFFFFF
        hash = hash ~ (hash >> 6)
    end

    hash = (hash + (hash << 3)) & 0xFFFFFFFF
    hash = hash ~ (hash >> 11)
    hash = (hash + (hash << 15)) & 0xFFFFFFFF

    return hash >= 0x80000000 and hash - 0x100000000 or hash
end

---@param entity integer
---@return integer
function GetEntityHealth(entity)
    return Helpers.Net.health[entity] or 200
end

---@param entity integer
---@param health integer
function SetEntityHealth(entity, health)
    Helpers.Net.health[entity] = health
end

---@param ped integer
---@return integer
function GetPedCauseOfDeath(ped)
    return Helpers.Net.causeOfDeath[ped] or 0
end

---@param ped integer
---@return integer
function GetPedSourceOfDeath(ped)
    return Helpers.Net.sourceOfDeath[ped] or 0
end

---@param ped integer
---@return boolean
function IsPedAPlayer(ped)
    return Helpers.Net.owners[ped] ~= nil
end

---@param entity integer
---@return integer
function NetworkGetEntityOwner(entity)
    return Helpers.Net.owners[entity] or -1
end

---@param netId integer
---@return integer
function NetworkGetEntityFromNetworkId(netId)
    return Helpers.Net.netEntities[netId] or 0
end

---@param entity integer
---@return boolean
function DoesEntityExist(entity)
    return Helpers.Net.vehicles[entity] ~= nil or Helpers.Net.coords[entity] ~= nil
end

---@param entity integer
---@return integer type 2 for vehicles, 1 for peds
function GetEntityType(entity)
    return Helpers.Net.vehicles[entity] and 2 or 1
end

---@param vehicle integer
---@return string
function GetVehicleNumberPlateText(vehicle)
    return (Helpers.Net.vehicles[vehicle] or {}).plate or ''
end

---@param vehicle integer
---@return integer
function GetVehicleDoorLockStatus(vehicle)
    return (Helpers.Net.vehicles[vehicle] or {}).lock or 0
end

---@param ped integer
---@param lastVehicle boolean
---@return integer
function GetVehiclePedIsIn(ped, lastVehicle)
    for vehicle, state in pairs(Helpers.Net.vehicles) do
        if state.driver == ped then
            return vehicle
        end
    end

    return 0
end

---@param ped integer
---@param hash integer
---@return TestWeapon
local function weaponOf(ped, hash)
    Helpers.Net.weapons[ped] = Helpers.Net.weapons[ped] or {}
    Helpers.Net.weapons[ped][hash] = Helpers.Net.weapons[ped][hash] or { ammo = 0, components = {} }

    return Helpers.Net.weapons[ped][hash]
end

---@param ped integer
---@param hash integer
---@param ammo integer
---@param hidden boolean
---@param inHand boolean
function GiveWeaponToPed(ped, hash, ammo, hidden, inHand)
    weaponOf(ped, hash).ammo = ammo

    if inHand then
        Helpers.Net.current[ped] = hash
    end
end

---@param ped integer
---@param hash integer
function RemoveWeaponFromPed(ped, hash)
    if Helpers.Net.weapons[ped] then
        Helpers.Net.weapons[ped][hash] = nil
    end

    if Helpers.Net.current[ped] == hash then
        Helpers.Net.current[ped] = nil
    end
end

---@param ped integer
---@param hash integer
---@param ammo integer
function SetPedAmmo(ped, hash, ammo)
    weaponOf(ped, hash).ammo = ammo
end

---@param ped integer
---@param hash integer
---@param component integer
function GiveWeaponComponentToPed(ped, hash, component)
    weaponOf(ped, hash).components[component] = true
end

---@param ped integer
---@param hash integer
---@param component integer
function RemoveWeaponComponentFromPed(ped, hash, component)
    weaponOf(ped, hash).components[component] = nil
end

---@param ped integer
---@param hash integer
---@param inHand boolean
function SetCurrentPedWeapon(ped, hash, inHand)
    Helpers.Net.current[ped] = hash
end

---@param ped integer
---@return integer
function GetCurrentPedWeapon(ped)
    return Helpers.Net.current[ped] or GetHashKey('WEAPON_UNARMED')
end

---@param ped integer
---@param hash integer
---@return integer
function GetAmmoInPedWeapon(ped, hash)
    return weaponOf(ped, hash).ammo
end

---@param ped integer
---@param hash integer
---@param tint integer
function SetPedWeaponTintIndex(ped, hash, tint)
    Helpers.Net.tints[hash] = tint
end

---@return integer[]
function GetAllVehicles()
    local list = {}

    for vehicle in pairs(Helpers.Net.vehicles) do
        list[#list + 1] = vehicle
    end

    return list
end

---@return integer
function PlayerId()
    return 0
end

---@param player integer
---@return integer
function GetPlayerServerId(player)
    return player == 0 and Helpers.LocalSource or 0
end

---@return integer
function PlayerPedId()
    return Helpers.Net.peds[Helpers.LocalSource] or 0
end

---@param ped integer
---@return boolean
function IsPedFatallyInjured(ped)
    return GetEntityHealth(ped) < 100
end

---@param ped integer
---@return boolean
---@return integer
function GetPedLastDamageBone(ped)
    local bone = Helpers.Net.lastBone[ped]

    return bone ~= nil, bone or 0
end

---@param entity integer
---@return number
function GetEntityHeading(entity)
    return 0.0
end

function NetworkResurrectLocalPlayer(x, y, z, heading, invincibility, leaveDeadPed)
    table.insert(Helpers.Net.calls, ('resurrect %g %g %g %g'):format(x, y, z, heading))
    Helpers.Net.health[PlayerPedId()] = 200
end

function TaskPlayAnim(ped, dict, name, ...)
    table.insert(Helpers.Net.calls, ('anim %s %s'):format(dict, name))
end

function IsEntityPlayingAnim(entity, dict, name, flag)
    return false
end

function RequestAnimDict(dict) end

function HasAnimDictLoaded(dict)
    return true
end

function DisableControlAction(group, control, disable)
    Helpers.Net.disabled[control] = true
end

function ClearPedTasks(ped)
    table.insert(Helpers.Net.calls, 'clear tasks')
end

function HasEntityBeenDamagedByWeapon(entity, weapon, kind)
    return Helpers.Net.damagedBy[entity] == weapon
end

function ClearEntityLastDamageEntity(entity)
    Helpers.Net.damagedBy[entity] = nil
end

---@param source string
---@return integer
function GetPlayerPed(source)
    return Helpers.Net.peds[math.tointeger(tonumber(source)) or 0] or 0
end

---@param ped integer
---@return vector3
function GetEntityCoords(ped)
    return Helpers.Net.coords[ped] or vector3(0, 0, 0)
end

---@param source string
---@param reason string
function DropPlayer(source, reason)
    table.insert(Helpers.Net.dropped, { source = source, reason = reason })
end

---@param source string
---@return integer
function GetNumPlayerIdentifiers(source)
    return #(Helpers.Net.identifiers[math.tointeger(tonumber(source)) or 0] or {})
end

---@param source string
---@param index integer
---@return string?
function GetPlayerIdentifier(source, index)
    return (Helpers.Net.identifiers[math.tointeger(tonumber(source)) or 0] or {})[index + 1]
end

---@param source string
---@param kind string
---@return string?
function GetPlayerIdentifierByType(source, kind)
    for _, identifier in ipairs(Helpers.Net.identifiers[math.tointeger(tonumber(source)) or 0] or {}) do
        if identifier:sub(1, #kind + 1) == kind .. ':' then
            return identifier
        end
    end

    return nil
end

---@param source string
---@return string
function GetPlayerName(source)
    return Helpers.Net.names[math.tointeger(tonumber(source)) or 0] or ('Player ' .. tostring(source))
end

---@return string[]
function GetPlayers()
    local players = {}

    for source in pairs(Helpers.Net.identifiers) do
        players[#players + 1] = tostring(source)
    end

    table.sort(players)

    return players
end

---@param source string
---@param bucket integer
function SetPlayerRoutingBucket(source, bucket)
    Helpers.Net.buckets[math.tointeger(tonumber(source)) or 0] = bucket
end

---@param source string
---@return integer
function GetPlayerRoutingBucket(source)
    return Helpers.Net.buckets[math.tointeger(tonumber(source)) or 0] or 0
end

---@param bucket integer
---@param mode string
function SetRoutingBucketEntityLockdownMode(bucket, mode)
    Helpers.Net.bucketSettings[bucket] = Helpers.Net.bucketSettings[bucket] or {}
    Helpers.Net.bucketSettings[bucket].lockdown = mode
end

---@param bucket integer
---@param enabled boolean
function SetRoutingBucketPopulationEnabled(bucket, enabled)
    Helpers.Net.bucketSettings[bucket] = Helpers.Net.bucketSettings[bucket] or {}
    Helpers.Net.bucketSettings[bucket].population = enabled
end

---@param resource string
---@return string
function GetResourceState(resource)
    if resource == RESOURCE_NAME then
        return 'started'
    end

    return Helpers.Net.resources[resource] or 'missing'
end

---Net event from a client (on the server) or from the server (on a client). Only names passed to RegisterNetEvent receive it.
---@param name string
---@param eventSource integer?
---@param ... any
function Helpers.TriggerNetEvent(name, eventSource, ...)
    if netEvents[name] then
        dispatch(name, nil, eventSource, ...)
    end
end

---Records of client events with this name, oldest first.
---@param name string
---@return TestNetworkRecord[]
function Helpers.ClientEvents(name)
    local found = {}

    for _, record in ipairs(Helpers.Net.client) do
        if record.name == name then
            found[#found + 1] = record
        end
    end

    return found
end

---Local event triggered by another resource.
---@param resource string
---@param name string
---@param ... any
function Helpers.TriggerEventAs(resource, name, ...)
    dispatch(name, resource, nil, ...)
end

---@class TestDatabase
---@field version string `SELECT VERSION()` result
---@field ready boolean MySQL.ready.await blocks while false
---@field migrations table<string, string[]> applied versions by scope
---@field executed string[] SQL of every query, in order
---@field params table[] params of every query, in order
---@field fail string? queries containing this text throw
---@field handler (fun(sql: string, params: table?): any)? custom result, nil falls back to the defaults

---@return TestDatabase
local function newDatabase()
    return { version = '10.11.6-MariaDB', ready = true, migrations = {}, executed = {}, params = {} }
end

Helpers.Db = newDatabase()

---Fresh database: no tables, no migrations, no recorded queries.
function Helpers.ResetDb()
    Helpers.Db = newDatabase()
end

---@param sql string
---@param params table?
---@return any
local function runQuery(sql, params)
    local db = Helpers.Db
    local values = params or {}

    db.executed[#db.executed + 1] = sql
    db.params[#db.params + 1] = values

    if db.fail and sql:find(db.fail, 1, true) then
        error('mock failure: ' .. db.fail, 0)
    end

    if db.handler then
        local result = db.handler(sql, params)

        if result ~= nil then
            return result
        end
    end

    if sql:find('SELECT VERSION()', 1, true) then
        return { { version = db.version } }
    end

    if sql:find('FROM `ug_migrations`', 1, true) then
        local rows = {}

        for _, version in ipairs(db.migrations[values[1]] or {}) do
            rows[#rows + 1] = { version = version }
        end

        return rows
    end

    if sql:find('INSERT INTO `ug_migrations`', 1, true) then
        local list = db.migrations[values[1]] or {}
        list[#list + 1] = values[2]
        db.migrations[values[1]] = list

        return { insertId = 0, affectedRows = 1 }
    end

    if sql:match('^%s*SELECT') then
        return {}
    end

    return { insertId = 0, affectedRows = 0 }
end

MySQL = {
    ready = {
        await = function()
            while not Helpers.Db.ready do
                Wait(50)
            end
        end,
    },
    rawExecute = { await = runQuery },
    query = { await = runQuery },
    transaction = {
        ---@param queries { query: string, values: table? }[]
        ---@return boolean
        await = function(queries)
            for index = 1, #queries do
                if not pcall(runQuery, queries[index].query, queries[index].values) then
                    return false
                end
            end

            return true
        end,
    },
}

---Sets a GlobalState key from the server and runs client change handlers, like replication does.
---@param key string
---@param value any
function Helpers.SetGlobalState(key, value)
    rawset(GlobalState, key, value)
    Helpers.NotifyStateBag('global', key, value)
end

---Runs change handlers registered for this bag and key, like replication does.
---@param bag string such as `global` or `player:1`
---@param key string
---@param value any
function Helpers.NotifyStateBag(bag, key, value)
    for index = 1, #stateBagHandlers do
        local entry = stateBagHandlers[index]

        if entry.key == key and (entry.bag == nil or entry.bag == bag) then
            entry.handler(bag, key, value)
        end
    end
end

---Clears GlobalState, like a server restart.
function Helpers.ResetGlobalState()
    for key in pairs(GlobalState) do
        if key ~= 'set' then
            rawset(GlobalState, key, nil)
        end
    end
end

---Runs a registered command and returns what it printed.
---@param name string
---@param source integer
---@param args string[]
---@return string[]
function Helpers.RunCommand(name, source, args)
    local handler = commands[name]

    if not handler then
        error('command "' .. name .. '" is not registered', 2)
    end

    return Helpers.Capture(function()
        handler(source, args, name .. ' ' .. table.concat(args, ' '))
    end)
end

---Runs `fn` and returns everything it printed, one entry per print call.
---@param fn fun()
---@return string[]
function Helpers.Capture(fn)
    local previous = captured
    local lines = {}
    captured = lines

    local ok, err = pcall(fn)
    captured = previous

    if not ok then
        error(err, 0)
    end

    return lines
end

---Hides the type of `value`, so a test can pass a wrong type on purpose.
---@param value any
---@return any
function Helpers.Any(value)
    return value
end

---@param ms integer
function Helpers.Advance(ms)
    Helpers.Clock = Helpers.Clock + ms

    -- One frame: timers due now fire in order. Timers they create wait for the next Advance, like Wait(0).
    local due, pending = {}, {}

    for _, timer in ipairs(timers) do
        if timer.at <= Helpers.Clock then
            due[#due + 1] = timer
        else
            pending[#pending + 1] = timer
        end
    end

    timers = pending

    table.sort(due, function(a, b)
        return a.at < b.at
    end)

    for _, timer in ipairs(due) do
        timer.callback()
    end
end

---@class TestThread
---@field done boolean
---@field result any
---@field error string?

---Runs `fn` as a coroutine, like a FiveM thread. Citizen.Await yields it until the promise settles.
---@param fn fun(): any
---@return TestThread
function Helpers.Thread(fn)
    local thread = { done = false }
    local co = coroutine.create(function()
        thread.result = fn()
        thread.done = true
    end)

    local ok, err = coroutine.resume(co)

    if not ok then
        thread.error = tostring(err)
        thread.done = true
    end

    return thread
end

---Reads the manifest and returns the script list for one side, shared scripts first.
---@param side 'server'|'client'
---@return string[]
local function readManifestScripts(side)
    local lists = { shared = {}, server = {}, client = {} }

    local env = setmetatable({}, {
        __index = function(_, directive)
            return function(value)
                local scope = type(directive) == 'string' and directive:match('^(%a+)_scripts?$')

                if not scope or not lists[scope] then
                    return
                end

                local entries = type(value) == 'table' and value or { value }

                for index = 1, #entries do
                    table.insert(lists[scope], entries[index])
                end
            end
        end,
    })

    local chunk, err = loadfile(MANIFEST_PATH, 't', env)

    if not chunk then
        error('cannot read manifest: ' .. tostring(err), 0)
    end

    chunk()

    local scripts = {}

    for _, scope in ipairs({ 'shared', side }) do
        for _, path in ipairs(lists[scope]) do
            if path:find('*', 1, true) then
                error('manifest globs are not supported in tests: ' .. path, 0)
            end

            if path:sub(1, 1) ~= '@' then
                scripts[#scripts + 1] = path
            end
        end
    end

    return scripts
end

---Loads ug-core scripts in manifest order for one side. Everything printed while loading is returned.
---@param side 'server'|'client'
---@return string[]
function Helpers.LoadManifest(side)
    Helpers.IsServer = side == 'server'
    Helpers.CurrentResource = RESOURCE_NAME
    UgCore = nil
    exported[side] = {}
    eventHandlers = {}
    threads = {}
    timers = {}
    commands = {}
    stateBagHandlers = {}
    netEvents = {}

    local scripts = readManifestScripts(side)

    return Helpers.Capture(function()
        for index = 1, #scripts do
            dofile(scripts[index])
        end
    end)
end

---@param name string
---@param fn fun()
function Helpers.Test(name, fn)
    local ok, err = xpcall(fn, function(message)
        return debug.traceback(tostring(message), 2)
    end)

    if ok then
        passed = passed + 1
        realPrint('  ok    ' .. name)
    else
        failed = failed + 1
        realPrint('  FAIL  ' .. name .. '\n        ' .. tostring(err):gsub('\n', '\n        '))
    end
end

---@param condition any
---@param message? string
function Helpers.Assert(condition, message)
    if not condition then
        error(message or 'assertion failed', 2)
    end
end

---@param actual any
---@param expected any
---@param path string
---@param seen table<table, table>
---@return string?
local function compare(actual, expected, path, seen)
    if type(actual) ~= type(expected) then
        return ('%s: expected %s, got %s'):format(path, type(expected), type(actual))
    end

    if type(expected) ~= 'table' and not vectorKinds[expected] then
        if actual ~= expected and not (actual ~= actual and expected ~= expected) then
            return ('%s: expected %s, got %s'):format(path, tostring(expected), tostring(actual))
        end

        return nil
    end

    if seen[actual] == expected then
        return nil
    end

    seen[actual] = expected

    for key, value in pairs(expected) do
        local problem = compare(actual[key], value, ('%s.%s'):format(path, tostring(key)), seen)

        if problem then
            return problem
        end
    end

    for key in pairs(actual) do
        if expected[key] == nil then
            return ('%s.%s: unexpected key'):format(path, tostring(key))
        end
    end

    return nil
end

---Deep comparison. Tables are equal when they hold equal keys and values.
---@param actual any
---@param expected any
---@param message? string
function Helpers.Equal(actual, expected, message)
    local problem = compare(actual, expected, 'value', {})

    if problem then
        error((message and message .. ': ' or '') .. problem, 2)
    end
end

---Asserts that `fn` raises. When `pattern` is given, the message MUST contain it as plain text.
---@param fn fun(): any
---@param pattern? string
---@return string message
function Helpers.Raises(fn, pattern)
    local ok, err = pcall(fn)

    if ok then
        error('expected an error, none was raised', 2)
    end

    local message = tostring(err)

    if pattern and not message:find(pattern, 1, true) then
        error(('expected an error containing "%s", got "%s"'):format(pattern, message), 2)
    end

    return message
end

---Prints the summary and exits with code 1 if any test failed.
function Helpers.Done()
    realPrint(('\n%d passed, %d failed'):format(passed, failed))
    os.exit(failed == 0 and 0 or 1)
end

return Helpers
