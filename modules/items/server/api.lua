--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Item definitions from config/items.lua and from resources, and the registry of usable items.
---Definitions replicate to clients through `GlobalState['ug-core:Items']`, without metadata validators.
---@class UgCore.Items
local Items = {}
UgCore.Items = Items

---@class UgCore.Internal.Items
local InternalItems = {}
UgCore.Internal.Items = InternalItems

---@class UgItemDefinition
---@field name string
---@field label string
---@field weight integer grams per unit
---@field stack boolean
---@field maxStack integer 1 when the item does not stack
---@field description? string
---@field keepOnRespawn boolean
---@field usable boolean

---@class UgItemRegistration
---@field label string
---@field weight integer grams per unit
---@field stack? boolean defaults to true
---@field maxStack? integer
---@field description? string
---@field keepOnRespawn? boolean
---@field metadata? UgSchemaRule|fun(metadata: table): boolean, any, string? validates metadata on every write

---@class UgItemUseOptions
---@field consume? integer units removed from the slot after a successful use, defaults to 0
---@field cooldown? integer ms between uses of this item per player, defaults to 0
---@field requireAlive? boolean defaults to true

---@class UgItemUse
---@field handler fun(source: integer, item: UgInventorySlot): boolean?
---@field options UgItemUseOptions
---@field resource string

---@alias UgMetadataValidator fun(metadata: table): boolean, table?, string?

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Schema = UgCore.Schema

local RESOURCE = GetCurrentResourceName()
local REPLICATION_KEY = UgCore.Enums.GlobalState.Items
local MAX_STACK = 1000000
local MAX_CONSUME = 1000
local MAX_METADATA_STRING = 512
local MAX_METADATA_ENTRIES = 128
local MAX_METADATA_DEPTH = 6

---@class UgItemEntry: UgItemDefinition
---@field resource? string registering resource, nil for config items

---@type table<string, UgItemEntry>
local definitions = {}

---@type table<string, { validator: UgMetadataValidator, resource: string }>
local validators = {}

---@type table<string, UgItemUse>
local uses = {}

---@type table<string, fun(metadata: table, inventoryId: string): table>
local fills = {}

---@return fun(entry: any, id: any): boolean, string?
local function configValidator()
    return UgCore.Internal.Config.GetEntry('items').definition.validate
end

---@param name string
---@param entry table
---@param resource? string
---@return UgItemEntry
local function normalize(name, entry, resource)
    local stack = entry.stack ~= false

    return {
        name = name,
        label = entry.label,
        weight = entry.weight,
        stack = stack,
        maxStack = stack and (entry.maxStack or MAX_STACK) or 1,
        description = entry.description,
        keepOnRespawn = entry.keepOnRespawn == true,
        usable = false,
        resource = resource,
    }
end

---@param entry UgItemEntry
---@return UgItemDefinition
local function public(entry)
    return {
        name = entry.name,
        label = entry.label,
        weight = entry.weight,
        stack = entry.stack,
        maxStack = entry.maxStack,
        description = entry.description,
        keepOnRespawn = entry.keepOnRespawn,
        usable = uses[entry.name] ~= nil,
    }
end

local function publish()
    local payload = {}

    for name, entry in pairs(definitions) do
        payload[name] = public(entry)
    end

    GlobalState:set(REPLICATION_KEY, payload, true)
end

---@param value any
---@return boolean
local function isCallable(value)
    if type(value) == 'function' then
        return true
    end

    local meta = type(value) == 'table' and getmetatable(value) or nil

    return type(meta) == 'table' and meta.__call ~= nil
end

---Turns a schema rule or a function into one validator shape.
---@param metadata any
---@return UgMetadataValidator?
local function toValidator(metadata)
    if type(metadata) == 'table' and pcall(Schema.Check, metadata, nil) then
        return function(value)
            local ok, checked, detail = Schema.Check(metadata, value)

            return ok, checked, detail
        end
    end

    if isCallable(metadata) then
        return function(value)
            local ok, second, third = metadata(value)

            if ok == true then
                return true, type(second) == 'table' and second or value, nil
            end

            return false, nil, type(second) == 'string' and second or third
        end
    end

    return nil
end

---@param value any
---@param depth integer
---@param budget { entries: integer }
---@return boolean
local function isData(value, depth, budget)
    local kind = type(value)

    if kind == 'boolean' then
        return true
    end

    if kind == 'number' then
        return value == value and value ~= math.huge and value ~= -math.huge
    end

    if kind == 'string' then
        return #value <= MAX_METADATA_STRING
    end

    if kind ~= 'table' or depth > MAX_METADATA_DEPTH or getmetatable(value) ~= nil then
        return false
    end

    for key, entry in pairs(value) do
        budget.entries = budget.entries + 1

        if budget.entries > MAX_METADATA_ENTRIES or (type(key) ~= 'string' and math.type(key) ~= 'integer') then
            return false
        end

        if not isData(entry, depth + 1, budget) then
            return false
        end
    end

    return true
end

---Registers an item from a resource. Config items win: their fields stay, only `metadata` is added.
---Items registered by a resource are removed when it stops.
---@param name string lowercase letters, digits and underscores
---@param definition UgItemRegistration
function Items.Register(name, definition)
    if type(definition) ~= 'table' then
        Utils.Raise(2, 'Items.Register expects a definition table')
    end

    local fields = {}

    for key, value in pairs(definition) do
        if key ~= 'metadata' then
            fields[key] = value
        end
    end

    local ok, message = configValidator()(fields, name)

    if not ok then
        Utils.Raise(2, 'Items.Register("%s"): %s', tostring(name), tostring(message))
    end

    local validator = nil

    if definition.metadata ~= nil then
        validator = toValidator(definition.metadata)

        if not validator then
            Utils.Raise(2, 'Items.Register("%s"): metadata MUST be a UgCore.Schema rule or a function', name)
        end
    end

    local resource = GetInvokingResource() or RESOURCE
    local existing = definitions[name]

    if existing and existing.resource and existing.resource ~= resource then
        Utils.Raise(2, 'Items.Register: "%s" is already registered by %s', name, existing.resource)
    end

    if existing and not existing.resource then
        Logger.Warn('Items: %s registers "%s", which config/items.lua defines. The config definition wins.', resource, name)
    else
        definitions[name] = normalize(name, fields, resource)
    end

    validators[name] = validator and { validator = validator, resource = resource } or nil
    publish()
end

---@param name string
---@return UgItemDefinition? definition a copy, nil for unknown items
function Items.Get(name)
    local entry = definitions[name]

    return entry and public(entry) or nil
end

---@return table<string, UgItemDefinition> definitions copies, by name
function Items.GetAll()
    local list = {}

    for name, entry in pairs(definitions) do
        list[name] = public(entry)
    end

    return list
end

---@param name string
---@return boolean
function Items.Exists(name)
    return definitions[name] ~= nil
end

---Makes an item usable. The handler gets `(source, item)` and runs after every check. Return false to refuse the use:
---nothing is consumed. Handlers registered by a resource are removed when it stops.
---@param name string an existing item
---@param handler fun(source: integer, item: UgInventorySlot): boolean?
---@param options? UgItemUseOptions
function Items.RegisterUse(name, handler, options)
    if not definitions[name] then
        Utils.Raise(2, 'Items.RegisterUse: unknown item "%s"', tostring(name))
    end

    if not isCallable(handler) then
        Utils.Raise(2, 'Items.RegisterUse expects a handler function')
    end

    options = options or {}

    if type(options) ~= 'table' then
        Utils.Raise(2, 'Items.RegisterUse: options MUST be a table')
    end

    if options.consume ~= nil and (math.type(options.consume) ~= 'integer' or options.consume < 0 or options.consume > MAX_CONSUME) then
        Utils.Raise(2, 'Items.RegisterUse: consume MUST be an integer from 0 to %d', MAX_CONSUME)
    end

    if options.cooldown ~= nil and (math.type(options.cooldown) ~= 'integer' or options.cooldown < 0) then
        Utils.Raise(2, 'Items.RegisterUse: cooldown MUST be a non-negative integer of ms')
    end

    if options.requireAlive ~= nil and type(options.requireAlive) ~= 'boolean' then
        Utils.Raise(2, 'Items.RegisterUse: requireAlive MUST be a boolean')
    end

    local resource = GetInvokingResource() or RESOURCE
    local existing = uses[name]

    if existing and existing.resource ~= resource then
        Utils.Raise(2, 'Items.RegisterUse: "%s" is already usable through %s', name, existing.resource)
    end

    uses[name] = {
        handler = handler,
        options = { consume = options.consume or 0, cooldown = options.cooldown or 0, requireAlive = options.requireAlive ~= false },
        resource = resource,
    }

    publish()
end

---@param name string
---@return boolean
function Items.IsUsable(name)
    return uses[name] ~= nil
end

---Gives every new unit of a non-stackable item its own metadata, such as a weapon serial.
---`fill` gets a copy of the checked metadata, or an empty table, and returns the metadata to store.
---@param name string
---@param fill fun(metadata: table, inventoryId: string): table
function InternalItems.SetFill(name, fill)
    local definition = definitions[name]

    if not definition or definition.stack then
        Utils.Raise(2, 'Items: only existing non-stackable items get a fill, "%s" is not one', tostring(name))
    end

    fills[name] = fill
end

---@param name string
---@return (fun(metadata: table, inventoryId: string): table)?
function InternalItems.GetFill(name)
    return fills[name]
end

---Internal definition for hot paths. MUST NOT be changed or handed out.
---@param name string
---@return UgItemEntry?
function InternalItems.GetDefinition(name)
    return definitions[name]
end

---@param name string
---@return UgItemUse?
function InternalItems.GetUse(name)
    return uses[name]
end

---Bounded data, then the item's validator. Empty tables become nil, so they stack with no metadata.
---@param name string
---@param metadata any
---@return boolean ok
---@return table? metadata a fresh copy to store
---@return string? detail for server logs
function InternalItems.CheckMetadata(name, metadata)
    if metadata == nil then
        return true, nil, nil
    end

    if not isData(metadata, 1, { entries = 0 }) or type(metadata) ~= 'table' then
        return false, nil, 'metadata MUST be a table of booleans, finite numbers, short strings and bounded tables'
    end

    local copy = Utils.Table.DeepCopy(metadata)

    if next(copy) == nil then
        return true, nil, nil
    end

    local entry = validators[name]

    if not entry then
        return true, copy, nil
    end

    local called, ok, checked, detail = pcall(entry.validator, copy)

    if not called then
        return false, nil, 'metadata validator failed: ' .. tostring(ok)
    end

    if not ok then
        return false, nil, tostring(detail or 'metadata rejected')
    end

    return true, type(checked) == 'table' and Utils.Table.DeepCopy(checked) or copy, nil
end

---@param ctx UgModuleContext
function InternalItems.Init(ctx)
    definitions = {}

    for name, entry in pairs(UgCore.Config.Get('items')) do
        definitions[name] = normalize(name, entry, nil)
    end

    publish()

    AddEventHandler('onResourceStop', function(resource)
        local changed = false

        for name, entry in pairs(definitions) do
            if entry.resource == resource then
                definitions[name] = nil
                changed = true
            end
        end

        for name, entry in pairs(validators) do
            if entry.resource == resource then
                validators[name] = nil
            end
        end

        for name, use in pairs(uses) do
            if use.resource == resource or not definitions[name] then
                uses[name] = nil
                changed = true
            end
        end

        if changed then
            publish()
        end
    end)

    ctx.logger.Debug('%d item(s) defined.', Utils.Table.Count(definitions))
end
