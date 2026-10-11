--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Stashes, vehicle trunks and gloveboxes, and ground drops: what they are, where they are, and who may reach them.
---Reach is always measured on the server, from the player's ped and the entity or position of the inventory.
---@class UgCore.Inventory
local Inventory = UgCore.Inventory

---@class UgCore.Internal.InventoryContainers
local Containers = {}
UgCore.Internal.InventoryContainers = Containers

---Who MAY use a stash or a shop. Any listed job, gang or group gives access. None listed means everyone.
---@class UgAccessRules
---@field jobs? table<string, integer> job name -> minimum grade
---@field gangs? table<string, integer> gang name -> minimum grade
---@field groups? string[] permission groups
---@field check? fun(source: integer): boolean extra check, after jobs, gangs and groups

---@class UgStashOptions: UgAccessRules
---@field label string
---@field slots integer
---@field weight integer grams
---@field coords? vector3 where players open it themselves. Without coords, only `Inventory.Open` opens it.
---@field distance? number meters, defaults to 2.0
---@field personal? boolean one inventory per character

---@class UgStashDefinition: UgStashOptions
---@field name string
---@field resource? string registering resource, nil for config stashes

---@class UgInventoryReach
---@field kind 'direct'|'stash'|'trunk'|'glovebox'|'drop'
---@field name? string stash name
---@field netId? integer vehicle network id
---@field plate? string normalized plate
---@field id? string drop id

---@class UgDrop
---@field coords vector3
---@field expiresAt integer GetGameTimer ms

local Utils = UgCore.Internal.Utils
local Errors = UgCore.Enums.Errors
local Store = UgCore.Internal.InventoryStore
local InternalInventory = UgCore.Internal.Inventory

local RESOURCE = GetCurrentResourceName()
local DROPS_KEY = UgCore.Enums.GlobalState.Drops
local PLATE_PATTERN = '^[%w_]+$'
local MAX_PLATE = 12
local STASH_DISTANCE = 2.0
local TRUNK_DISTANCE = 4.0
local DROP_DISTANCE = 2.5
local DROP_MERGE_DISTANCE = 1.5
local VEHICLE_TYPE = 2
local SWEEP_INTERVAL = 10000
local IDLE_INTERVAL = 60000
local IDLE_UNLOAD = 300000
local UNLOCKED = { [0] = true, [1] = true }

---@type table<string, UgStashDefinition>
local stashes = {}

---@type table<string, UgDrop>
local drops = {}

local nextDrop = 0

---@type table
local config = {}

---@param value any
---@return boolean
local function isCallable(value)
    if type(value) == 'function' then
        return true
    end

    local meta = type(value) == 'table' and getmetatable(value) or nil

    return type(meta) == 'table' and meta.__call ~= nil
end

---@return fun(value: table): boolean, string?
local function stashValidator()
    for _, option in ipairs(UgCore.Internal.Config.GetEntry('inventory').definition.options) do
        if option.key == 'stashes' then
            return option.validate
        end
    end

    error('inventory config has no stashes option', 0)
end

---Trimmed, upper case, inner spaces as underscores. Nil when it cannot be a plate.
---@param plate any
---@return string?
function Containers.NormalizePlate(plate)
    if type(plate) ~= 'string' then
        return nil
    end

    local normalized = plate:match('^%s*(.-)%s*$'):upper():gsub('%s+', '_')

    if normalized == '' or #normalized > MAX_PLATE or not normalized:find(PLATE_PATTERN) then
        return nil
    end

    return normalized
end

---@param source integer
---@return integer? characterId
local function characterOf(source)
    local id = InternalInventory.GetPlayerId(source)

    return id and math.tointeger(tonumber(id:match('^player:(%d+)$'))) or nil
end

---@param definition UgStashDefinition
---@param characterId? integer
---@return string? id nil for a personal stash without a character
local function stashId(definition, characterId)
    if not definition.personal then
        return 'stash:' .. definition.name
    end

    return characterId and ('stash:%s:%d'):format(definition.name, characterId) or nil
end

---@param assignment UgAssignment?
---@param required table<string, integer>?
---@return boolean
local function hasGrade(assignment, required)
    if not required or not assignment then
        return false
    end

    local minimum = required[assignment.name]

    return minimum ~= nil and assignment.grade >= minimum
end

---Any listed job, gang or group gives access. None listed means everyone. `check` MUST pass too.
---@param source integer
---@param definition UgAccessRules
---@return boolean
local function hasAccess(source, definition)
    local restricted = definition.jobs or definition.gangs or definition.groups
    local allowed = not restricted

    if not allowed and definition.jobs and UgCore.Modules.IsEnabled('jobs') then
        allowed = hasGrade(UgCore.Jobs.Get(source), definition.jobs)
    end

    if not allowed and definition.gangs and UgCore.Modules.IsEnabled('gangs') then
        allowed = hasGrade(UgCore.Gangs.Get(source), definition.gangs)
    end

    for _, group in ipairs(not allowed and definition.groups or {}) do
        allowed = allowed or UgCore.Permissions.IsInGroup(source, group)
    end

    if allowed and definition.check then
        local called, result = pcall(definition.check, source)

        allowed = called and result == true
    end

    return allowed
end

---Shared with shops, which restrict access the same way.
Containers.HasAccess = hasAccess

---@param netId any
---@return integer? vehicle
local function vehicleOf(netId)
    if math.type(netId) ~= 'integer' then
        return nil
    end

    local vehicle = NetworkGetEntityFromNetworkId(netId)

    if not vehicle or vehicle == 0 or not DoesEntityExist(vehicle) or GetEntityType(vehicle) ~= VEHICLE_TYPE then
        return nil
    end

    return vehicle
end

---@param source integer
---@param vehicle integer
---@param kind 'trunk'|'glovebox'
---@return boolean
local function canReachVehicle(source, vehicle, kind)
    local ped = GetPlayerPed(tostring(source))

    if not ped or ped == 0 then
        return false
    end

    if kind == 'glovebox' then
        return GetVehiclePedIsIn(ped, false) == vehicle
    end

    return UNLOCKED[GetVehicleDoorLockStatus(vehicle)] == true and UgCore.Guard.IsNear(source, GetEntityCoords(vehicle), TRUNK_DISTANCE)
end

---True while the player MAY still act on an inventory opened with this reach.
---@param source integer
---@param reach UgInventoryReach
---@return boolean
function Containers.CanReach(source, reach)
    if reach.kind == 'direct' then
        return true
    end

    if reach.kind == 'stash' then
        local definition = stashes[reach.name]

        return definition ~= nil and definition.coords ~= nil and hasAccess(source, definition)
            and UgCore.Guard.IsNear(source, definition.coords, definition.distance or STASH_DISTANCE)
    end

    if reach.kind == 'drop' then
        local drop = drops[reach.id]

        return drop ~= nil and UgCore.Guard.IsNear(source, drop.coords, DROP_DISTANCE)
    end

    local vehicle = vehicleOf(reach.netId)

    return vehicle ~= nil and Containers.NormalizePlate(GetVehicleNumberPlateText(vehicle)) == reach.plate
        and canReachVehicle(source, vehicle, reach.kind --[[@as 'trunk'|'glovebox']])
end

---@param kind 'trunk'|'glovebox'
---@param plate string normalized
---@return UgInventoryContainer? container nil when the database failed
local function loadVehicle(kind, plate)
    local size = config[kind]
    local label = kind == 'trunk' and 'Trunk' or 'Glovebox'

    return Store.Load(('%s:%s'):format(kind, plate), size.slots, size.weight, nil, label, true)
end

---What a player asks to open, checked like every later action. MUST run in a thread.
---@param source integer
---@param kind string `stash`, `trunk`, `glovebox` or `drop`
---@param key any stash name, vehicle network id or drop id
---@return UgInventoryContainer? container
---@return UgInventoryReach? reach
---@return UgErrorCode? errorCode
function Containers.Request(source, kind, key)
    if kind == 'stash' then
        local definition = type(key) == 'string' and stashes[key] or nil

        if not definition then
            return nil, nil, Errors.NotFound
        end

        local reach = { kind = 'stash', name = definition.name }

        if not Containers.CanReach(source, reach) then
            return nil, nil, Errors.NoPermission
        end

        local id = stashId(definition, characterOf(source))

        if not id then
            return nil, nil, Errors.NotLoaded
        end

        local container = Store.Load(id, definition.slots, definition.weight, nil, definition.label)

        return container, container and reach or nil, container and nil or Errors.InternalError
    end

    if kind == 'trunk' or kind == 'glovebox' then
        local vehicle = vehicleOf(key)
        local plate = vehicle and Containers.NormalizePlate(GetVehicleNumberPlateText(vehicle))

        if not vehicle or not plate then
            return nil, nil, Errors.NotFound
        end

        local reach = { kind = kind, netId = key, plate = plate }

        if not Containers.CanReach(source, reach) then
            return nil, nil, Errors.NoPermission
        end

        local container = loadVehicle(kind, plate)

        return container, container and reach or nil, container and nil or Errors.InternalError
    end

    if kind == 'drop' then
        local container = type(key) == 'string' and drops[key] and Store.Get(key) or nil

        if not container then
            return nil, nil, Errors.NotFound
        end

        local reach = { kind = 'drop', id = key }

        if not Containers.CanReach(source, reach) then
            return nil, nil, Errors.NoPermission
        end

        return container, reach, nil
    end

    return nil, nil, Errors.InvalidArgs
end

---Loads any saved kind of inventory by id, for server code. MUST run in a thread.
---@param id string
---@return UgInventoryContainer? container
---@return UgErrorCode? errorCode
function Containers.LoadById(id)
    local loaded = Store.Get(id)

    if loaded then
        return loaded, nil
    end

    local kind, rest = id:match('^(%l+):(.+)$')
    local container = nil

    if kind == 'player' and math.tointeger(tonumber(rest)) then
        container = Store.Load(id, config.playerSlots, config.playerWeight, nil, nil)
    elseif kind == 'stash' then
        local name, characterId = rest:match('^([%l%d_]+):(%d+)$')
        local definition = stashes[name or rest]

        if not definition or (definition.personal and not characterId) or (not definition.personal and characterId) then
            return nil, Errors.NotFound
        end

        container = Store.Load(id, definition.slots, definition.weight, nil, definition.label)
    elseif (kind == 'trunk' or kind == 'glovebox') and Containers.NormalizePlate(rest) == rest then
        container = loadVehicle(kind, rest)
    else
        return nil, Errors.NotFound
    end

    if not container then
        return nil, Errors.InternalError
    end

    return container, nil
end

local function publishDrops()
    local payload = {}

    for id, drop in pairs(drops) do
        payload[id] = { x = drop.coords.x, y = drop.coords.y, z = drop.coords.z }
    end

    GlobalState:set(DROPS_KEY, payload, true)
end

---Forgets a drop and its items. Viewers are closed first.
---@param id string
---@param reason string
function Containers.RemoveDrop(id, reason)
    local container = Store.Get(id)

    if not drops[id] then
        return
    end

    drops[id] = nil

    if container then
        UgCore.Internal.InventorySessions.CloseAll(id)
        InternalInventory.Clear(container, reason, nil)
        Store.Unload(id)
    end

    publishDrops()
end

---@param id string
---@return boolean
function Containers.IsDrop(id)
    return drops[id] ~= nil
end

---Nearest drop with room around a position, to merge drops of one spot.
---@param coords vector3
---@return string? id
function Containers.FindDrop(coords)
    local best, bestDistance = nil, DROP_MERGE_DISTANCE

    for id, drop in pairs(drops) do
        local distance = #(drop.coords - coords)
        local container = Store.Get(id)

        if distance <= bestDistance and container and Utils.Table.Count(container.items) < container.slots then
            best, bestDistance = id, distance
        end
    end

    return best
end

---Registers a stash from a resource. Removed when the resource stops; its items stay saved.
---@param name string lowercase letters, digits and underscores
---@param options UgStashOptions
function Inventory.RegisterStash(name, options)
    if type(options) ~= 'table' then
        Utils.Raise(2, 'Inventory.RegisterStash expects options')
    end

    local fields = {}

    for key, value in pairs(options) do
        if key ~= 'check' then
            fields[key] = value
        end
    end

    local ok, problem = stashValidator()({ [name] = fields })

    if not ok then
        Utils.Raise(2, 'Inventory.RegisterStash: %s', tostring(problem))
    end

    if options.check ~= nil and not isCallable(options.check) then
        Utils.Raise(2, 'Inventory.RegisterStash: check MUST be a function')
    end

    local resource = GetInvokingResource() or RESOURCE
    local existing = stashes[name]

    if existing and not existing.resource then
        Utils.Raise(2, 'Inventory.RegisterStash: "%s" is defined in config/inventory.lua', name)
    end

    if existing and existing.resource ~= resource then
        Utils.Raise(2, 'Inventory.RegisterStash: "%s" is already registered by %s', name, existing.resource)
    end

    local definition = Utils.Table.DeepCopy(fields)

    definition.name = name
    definition.check = options.check
    definition.resource = resource
    stashes[name] = definition
end

---@param name string
---@return UgStashDefinition? definition a copy without `check`, nil for unknown stashes
function Inventory.GetStash(name)
    local definition = stashes[name]

    if not definition then
        return nil
    end

    local copy = {}

    for key, value in pairs(definition) do
        if key ~= 'check' then
            copy[key] = Utils.Table.DeepCopy(value)
        end
    end

    return copy
end

---The inventory id of a stash. Personal stashes need the player, for their character.
---@param name string
---@param source? integer
---@return string? id nil for unknown stashes, or a personal stash without a loaded character
function Inventory.GetStashId(name, source)
    local definition = stashes[name]

    if not definition then
        return nil
    end

    return stashId(definition, source and characterOf(source) or nil)
end

---Loads a saved inventory by id: player, stash, trunk or glovebox. MUST run in a thread.
---@param id string
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` for unknown ids
function Inventory.Load(id)
    if not Store.IsId(id) then
        Utils.Raise(2, 'Inventory.Load expects an inventory id such as "stash:police_locker"')
    end

    local container, errorCode = Containers.LoadById(id)

    return container ~= nil, errorCode
end

---Starts or stops saving the trunk and glovebox of a plate. A garage resource does this for owned vehicles.
---Stopping deletes the saved items. MUST run in a thread.
---@param plate string
---@param persistent boolean
---@return boolean ok
---@return UgErrorCode? errorCode
function Inventory.SetPersistent(plate, persistent)
    local normalized = Containers.NormalizePlate(plate)

    if not normalized or type(persistent) ~= 'boolean' then
        Utils.Raise(2, 'Inventory.SetPersistent expects a plate and a boolean')
    end

    ---@cast normalized string

    for _, kind in ipairs({ 'trunk', 'glovebox' }) do
        local container = loadVehicle(kind --[[@as 'trunk'|'glovebox']], normalized)

        if not container or not Store.SetPersistent(container.id, persistent) then
            return false, Errors.InternalError
        end
    end

    return true, nil
end

---Creates a ground drop. With `items`, every item MUST fit, or no drop is created.
---@param coords vector3
---@param items? { name: string, count: integer, metadata?: table }[]
---@param reason? string stored in the audit log
---@return boolean ok
---@return string? id
---@return UgErrorCode? errorCode
function Inventory.CreateDrop(coords, items, reason)
    if type(coords) ~= 'vector3' then
        Utils.Raise(2, 'Inventory.CreateDrop expects coords as a vector3')
    end

    nextDrop = nextDrop + 1

    local id = 'drop:' .. nextDrop
    local size = config.drops

    Store.Create(id, size.slots, size.weight, 'Ground')
    drops[id] = { coords = coords, expiresAt = GetGameTimer() + size.lifetime * 60000 }

    for _, item in ipairs(items or {}) do
        local ok, errorCode = Inventory.AddItem(id, item.name, item.count, item.metadata, reason)

        if not ok then
            drops[id] = nil
            Store.Unload(id)
            return false, nil, errorCode
        end
    end

    publishDrops()

    return true, id, nil
end

---@return table<string, vector3> drops by id
function Inventory.GetDrops()
    local list = {}

    for id, drop in pairs(drops) do
        list[id] = drop.coords
    end

    return list
end

---Removes expired drops, and temporary vehicle inventories whose vehicle is gone.
---@param now integer GetGameTimer ms
function Containers.Sweep(now)
    for id, drop in pairs(drops) do
        local container = Store.Get(id)

        if now >= drop.expiresAt or not container or next(container.items) == nil then
            Containers.RemoveDrop(id, 'expired')
        end
    end

    local plates = nil

    for id, container in pairs(Store.All()) do
        local plate = not container.persistent and next(container.viewers) == nil and id:match('^%l+:(.+)$')

        if plate and (id:find('^trunk:') or id:find('^glovebox:')) then
            if not plates then
                plates = {}

                -- The server native returns a list of handles. The GTAV client definition shadows its type.
                for _, vehicle in ipairs(GetAllVehicles() --[[@as integer[] ]]) do
                    local normalized = Containers.NormalizePlate(GetVehicleNumberPlateText(vehicle))

                    if normalized then
                        plates[normalized] = true
                    end
                end
            end

            if not plates[plate] then
                Store.Unload(id)
            end
        end
    end
end

---@param ctx UgModuleContext
function Containers.Init(ctx)
    config = ctx.config or {}
    stashes = {}

    for name, stash in pairs(config.stashes or {}) do
        local definition = Utils.Table.DeepCopy(stash)

        definition.name = name
        stashes[name] = definition
    end

    publishDrops()

    CreateThread(function()
        local lastIdle = GetGameTimer()

        while true do
            Wait(SWEEP_INTERVAL)

            local now = GetGameTimer()

            Containers.Sweep(now)

            if now - lastIdle >= IDLE_INTERVAL then
                Store.Sweep(now, IDLE_UNLOAD)
                lastIdle = now
            end
        end
    end)

    AddEventHandler('onResourceStop', function(resource)
        for name, definition in pairs(stashes) do
            if definition.resource == resource then
                stashes[name] = nil
            end
        end
    end)
end
