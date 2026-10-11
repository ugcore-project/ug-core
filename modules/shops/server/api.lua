--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Shops sell items for an account at prices from the server. Clients pick an item by its position and a count,
---nothing else. Stock is reserved before paying, and the payment is refunded when the items cannot be given.
---@class UgCore.Shops
local Shops = {}
UgCore.Shops = Shops

---@class UgCore.Internal.Shops
local InternalShops = {}
UgCore.Internal.Shops = InternalShops

---@class UgShopItem
---@field name string
---@field price integer per unit
---@field stock? integer most units in stock. Without it, the item never runs out.
---@field restock? integer minutes between refills to `stock`
---@field metadata? table given with each unit, such as a loaded weapon

---@class UgShopOptions: UgAccessRules
---@field label string
---@field coords vector3|vector3[] where players buy
---@field distance? number meters, defaults to 2.5
---@field account string account that pays
---@field items UgShopItem[]

---@class UgShopDefinition: UgShopOptions
---@field name string
---@field coords vector3[]
---@field resource? string registering resource, nil for config shops

---@class UgShopListing
---@field label string
---@field account string
---@field items { index: integer, name: string, price: integer, stock?: integer }[]

---@class UgShopStock
---@field stock integer
---@field restockedAt integer Unix seconds

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local Repository = UgCore.Internal.Database.Repository
local InternalHooks = UgCore.Internal.Hooks
local InternalItems = UgCore.Internal.Items
local Containers = UgCore.Internal.InventoryContainers
local Inventory = UgCore.Inventory
local ShopEvents = UgCore.Enums.Events.Shops
local ShopHooks = UgCore.Enums.Hooks.Shops

local RESOURCE = GetCurrentResourceName()
local REPLICATION_KEY = UgCore.Enums.GlobalState.Shops
local DEFAULT_DISTANCE = 2.5
local MAX_COUNT = 1000
local RESTOCK_INTERVAL = 60000

---@type table<string, UgShopDefinition>
local shops = {}

---@type table<string, table<string, UgShopStock>> shop -> item -> stock
local stocks = {}

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
local function shopValidator()
    for _, option in ipairs(UgCore.Internal.Config.GetEntry('shops').definition.options) do
        if option.key == 'shops' then
            return option.validate
        end
    end

    error('shops config has no shops option', 0)
end

---Items and accounts live in other configs, so they are checked here.
---@param name string
---@param shop table
---@return string? problem
local function checkReferences(name, shop)
    local accounts = UgCore.Config.Get('accounts', 'accounts')

    if not accounts[shop.account] then
        return ('shop "%s" pays with "%s", which is not in config/accounts.lua'):format(name, shop.account)
    end

    for _, item in ipairs(shop.items) do
        if not InternalItems.GetDefinition(item.name) then
            return ('shop "%s" sells "%s", which is not in config/items.lua'):format(name, item.name)
        end

        local ok, _, detail = InternalItems.CheckMetadata(item.name, item.metadata)

        if not ok then
            return ('shop "%s" item "%s" has invalid metadata: %s'):format(name, item.name, tostring(detail))
        end
    end

    return nil
end

---@param name string
---@param options table
---@param resource? string
---@return UgShopDefinition
local function normalize(name, options, resource)
    local definition = Utils.Table.DeepCopy(options)

    definition.name = name
    definition.coords = type(options.coords) == 'vector3' and { options.coords } or Utils.Table.DeepCopy(options.coords)
    definition.distance = options.distance or DEFAULT_DISTANCE
    definition.check = options.check
    definition.resource = resource

    return definition
end

local function publish()
    local payload = {}

    for name, shop in pairs(shops) do
        local points = {}

        for index, point in ipairs(shop.coords) do
            points[index] = { x = point.x, y = point.y, z = point.z }
        end

        payload[name] = { label = shop.label, coords = points }
    end

    GlobalState:set(REPLICATION_KEY, payload, true)
end

---@param shop string
---@param item string
---@param state UgShopStock
local function saveStock(shop, item, state)
    local stock, restockedAt = state.stock, state.restockedAt

    CreateThread(function()
        Repository.Update([[
            INSERT INTO `ug_shop_stock` (`shop`, `item`, `stock`, `restocked_at`) VALUES (?, ?, ?, ?)
            ON DUPLICATE KEY UPDATE `stock` = VALUES(`stock`), `restocked_at` = VALUES(`restocked_at`)
        ]], { shop, item, stock, restockedAt })
    end)
end

---Stock of every limited item, from saved rows or full.
---@param definition UgShopDefinition
---@param saved table<string, UgShopStock>?
local function initStock(definition, saved)
    local state = {}

    for _, item in ipairs(definition.items) do
        if item.stock then
            local row = saved and saved[item.name]

            state[item.name] = row and { stock = math.min(row.stock, item.stock), restockedAt = row.restockedAt }
                or { stock = item.stock, restockedAt = os.time() }
        end
    end

    stocks[definition.name] = state
end

---@param source integer
---@param shop UgShopDefinition
---@return boolean
local function canUse(source, shop)
    if not Containers.HasAccess(source, shop) then
        return false
    end

    for _, point in ipairs(shop.coords) do
        if UgCore.Guard.IsNear(source, point, shop.distance) then
            return true
        end
    end

    return false
end

---What a player sees when they open a shop, checked like a purchase.
---@param source integer
---@param name string
---@return UgShopListing? listing
---@return UgErrorCode? errorCode
function InternalShops.Open(source, name)
    local shop = shops[name]

    if not shop then
        return nil, Errors.NotFound
    end

    if not canUse(source, shop) then
        return nil, Errors.NoPermission
    end

    local items = {}

    for index, item in ipairs(shop.items) do
        local state = stocks[name][item.name]

        items[index] = { index = index, name = item.name, price = item.price, stock = state and state.stock or nil }
    end

    return { label = shop.label, account = shop.account, items = items }, nil
end

---Buys `count` units of the item at `index` in the shop. MUST run in a thread.
---@param source integer
---@param name string shop name
---@param index integer position of the item in the shop
---@param count integer 1 to 1000
---@return boolean ok
---@return UgErrorCode? errorCode `not_found`, `no_permission`, `insufficient_items` when out of stock, `cannot_carry`, `insufficient_funds`, `not_loaded`
function Shops.Buy(source, name, index, count)
    if math.type(index) ~= 'integer' or math.type(count) ~= 'integer' or count < 1 or count > MAX_COUNT then
        Utils.Raise(2, 'Shops.Buy expects an item index and a count from 1 to %d', MAX_COUNT)
    end

    local shop = shops[name]
    local item = shop and shop.items[index]

    if not shop or not item then
        return false, Errors.NotFound
    end

    if not canUse(source, shop) then
        return false, Errors.NoPermission
    end

    if not Inventory.Get(source) then
        return false, Errors.NotLoaded
    end

    local state = stocks[name][item.name]

    if state and state.stock < count then
        return false, Errors.InsufficientItems
    end

    if not Inventory.CanCarry(source, item.name, count, item.metadata) then
        return false, Errors.CannotCarry
    end

    local total = item.price * count
    local proceed, payload = InternalHooks.Run(ShopHooks.BeforePurchase, {
        source = source, shop = name, item = item.name, count = count, price = item.price, total = total, account = shop.account,
    })

    if not proceed then
        return false, Errors.NoPermission
    end

    -- A hook MAY give a discount, never raise the price.
    local discounted = math.tointeger(payload.total)

    if discounted and discounted >= 0 and discounted < total then
        total = discounted
    end

    -- The hook MAY have yielded: stock is checked again, then reserved before paying.
    if state and state.stock < count then
        return false, Errors.InsufficientItems
    end

    if state then
        state.stock = state.stock - count
    end

    local reason = 'shop:' .. name

    if total > 0 then
        local paid, _, errorCode = UgCore.Accounts.Remove(source, shop.account, total, reason)

        if not paid then
            if state then
                state.stock = state.stock + count
            end

            return false, errorCode
        end
    end

    local given, errorCode = Inventory.AddItem(source, item.name, count, item.metadata, reason)

    if not given then
        if total > 0 then
            UgCore.Accounts.Add(source, shop.account, total, reason .. ':refund')
        end

        if state then
            state.stock = state.stock + count
        end

        return false, errorCode
    end

    if state then
        saveStock(name, item.name, state)
    end

    Events.Emit(ShopEvents.Purchased, source, name, item.name, count, total, shop.account)

    return true, nil
end

---Registers a shop from a resource, removed when it stops. Its stock stays saved.
---@param name string
---@param options UgShopOptions
function Shops.Register(name, options)
    if type(options) ~= 'table' then
        Utils.Raise(2, 'Shops.Register expects options')
    end

    local fields = {}

    for key, value in pairs(options) do
        if key ~= 'check' then
            fields[key] = value
        end
    end

    local ok, problem = shopValidator()({ [name] = fields })

    if ok then
        problem = checkReferences(name, fields)
    end

    if problem then
        Utils.Raise(2, 'Shops.Register: %s', tostring(problem))
    end

    if options.check ~= nil and not isCallable(options.check) then
        Utils.Raise(2, 'Shops.Register: check MUST be a function')
    end

    local resource = GetInvokingResource() or RESOURCE
    local existing = shops[name]

    if existing and not existing.resource then
        Utils.Raise(2, 'Shops.Register: "%s" is defined in config/shops.lua', name)
    end

    if existing and existing.resource ~= resource then
        Utils.Raise(2, 'Shops.Register: "%s" is already registered by %s', name, existing.resource)
    end

    local definition = normalize(name, fields, resource)

    definition.check = options.check
    shops[name] = definition
    initStock(definition, stocks[name])
    publish()
end

---@param name string
---@return { label: string, coords: vector3[], distance: number, account: string, items: UgShopItem[], stock: table<string, integer> }? shop a copy
function Shops.Get(name)
    local shop = shops[name]

    if not shop then
        return nil
    end

    local stock = {}

    for item, state in pairs(stocks[name]) do
        stock[item] = state.stock
    end

    return {
        label = shop.label,
        coords = Utils.Table.DeepCopy(shop.coords),
        distance = shop.distance,
        account = shop.account,
        items = Utils.Table.DeepCopy(shop.items),
        stock = stock,
    }
end

---@return string[] names sorted by name
function Shops.GetAll()
    local names = {}

    for name in pairs(shops) do
        names[#names + 1] = name
    end

    table.sort(names)

    return names
end

---Refills limited items to their stock. Without `item`, every item of the shop.
---@param name string
---@param item? string
---@return boolean ok false for unknown shops or items without stock
function Shops.Restock(name, item)
    local shop = shops[name]

    if not shop then
        return false
    end

    local refilled = false

    for _, entry in ipairs(shop.items) do
        local state = stocks[name][entry.name]

        if state and (item == nil or item == entry.name) then
            state.stock = entry.stock
            state.restockedAt = os.time()
            saveStock(name, entry.name, state)
            refilled = true
        end
    end

    return refilled
end

---@param now integer Unix seconds
function InternalShops.RestockDue(now)
    for name, shop in pairs(shops) do
        for _, item in ipairs(shop.items) do
            local state = stocks[name][item.name]

            if state and item.restock and now - state.restockedAt >= item.restock * 60 then
                state.stock = item.stock
                state.restockedAt = now
                saveStock(name, item.name, state)
            end
        end
    end
end

---@param ctx UgModuleContext
function InternalShops.Init(ctx)
    local problems = {}

    shops = {}

    for name, options in pairs((ctx.config or {}).shops or {}) do
        local problem = checkReferences(name, options)

        if problem then
            problems[#problems + 1] = problem
        end

        shops[name] = normalize(name, options, nil)
    end

    if #problems > 0 then
        error(table.concat(problems, '; '), 0)
    end

    local ok, rows = Repository.Query('SELECT `shop`, `item`, `stock`, `restocked_at` AS `restockedAt` FROM `ug_shop_stock`')

    if not ok or not rows then
        error('cannot load ug_shop_stock', 0)
    end

    local saved = {}

    for _, row in ipairs(rows) do
        saved[row.shop] = saved[row.shop] or {}
        saved[row.shop][row.item] = { stock = math.tointeger(row.stock) or 0, restockedAt = math.tointeger(row.restockedAt) or 0 }
    end

    for name, definition in pairs(shops) do
        initStock(definition, saved[name])
    end

    publish()

    CreateThread(function()
        while true do
            Wait(RESTOCK_INTERVAL)
            InternalShops.RestockDue(os.time())
        end
    end)

    AddEventHandler('onResourceStop', function(resource)
        local changed = false

        for name, definition in pairs(shops) do
            if definition.resource == resource then
                shops[name] = nil
                changed = true
            end
        end

        if changed then
            publish()
        end
    end)

    ctx.logger.Debug('%d shop(s).', Utils.Table.Count(shops))
end
