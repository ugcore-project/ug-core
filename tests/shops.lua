--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { identifier: string, name: string, data: string }[]
local characters

---@type table<string, integer> "<characterId>:<account>" -> balance
local balances

---@type table<string, { stock: integer, restockedAt: integer }> "<shop>:<item>" -> row
local stockRows

---In-memory characters, accounts, ledger and shop stock.
---@param sql string
---@param params table?
---@return any
local function store(sql, params)
    local v = params or {}

    if sql:find('INSERT INTO `ug_characters`', 1, true) then
        characters[#characters + 1] = { identifier = v[1], name = v[2], data = v[3] }
        return { insertId = #characters, affectedRows = 1 }
    end

    if sql:find('SELECT COUNT(*)', 1, true) then
        return { { total = 0 } }
    end

    if sql:find('FROM `ug_characters` WHERE `id` = ? AND `identifier`', 1, true) then
        local row = characters[v[1]]

        return row and row.identifier == v[2] and { { id = v[1], name = row.name, data = row.data, createdAt = 0 } } or {}
    end

    if sql:find('INSERT INTO `ug_accounts`', 1, true) then
        local key = v[1] .. ':' .. v[2]

        balances[key] = sql:find('`balance` + VALUES', 1, true) and (balances[key] or 0) + v[3] or v[3]
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('FROM `ug_accounts` WHERE `character_id`', 1, true) then
        local rows = {}

        for key, balance in pairs(balances) do
            local id, account = key:match('^(%d+):(.+)$')

            if tonumber(id) == v[1] then
                rows[#rows + 1] = { account = account, balance = balance }
            end
        end

        return rows
    end

    if sql:find('INSERT INTO `ug_shop_stock`', 1, true) then
        stockRows[v[1] .. ':' .. v[2]] = { stock = v[3], restockedAt = v[4] }
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('FROM `ug_shop_stock`', 1, true) then
        local rows = {}

        for key, row in pairs(stockRows) do
            local shop, item = key:match('^([^:]+):(.+)$')

            rows[#rows + 1] = { shop = shop, item = item, stock = row.stock, restockedAt = row.restockedAt }
        end

        return rows
    end
end

local SHOP = vector3(50, 0, 0)

---@param shopsConfig? string Lua source of config/shops.lua
---@param rows? table<string, { stock: integer, restockedAt: integer }>
---@return string[] lines
local function fresh(shopsConfig, rows)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.ResetAces()
    H.Aces = { ['resource.ug-core:command.add_ace'] = true }
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'permissions', 'characters', 'accounts', 'items', 'inventory', 'weapons', 'shops' } }
    H.Net.resources['ug-inventory'] = 'started'
    H.ResourceFiles['config/shops.lua'] = shopsConfig or [[return {
        shops = {
            corner = {
                label = 'Corner', coords = { vector3(50, 0, 0), vector3(500, 0, 0) }, account = 'cash',
                items = {
                    { name = 'water', price = 5 },
                    { name = 'bandage', price = 50, stock = 3, restock = 60 },
                    { name = 'weapon_pistol', price = 100, metadata = { ammo = 12 } },
                },
            },
            armory = { label = 'Armory', coords = vector3(50, 0, 0), account = 'bank', groups = { 'admin' }, items = { { name = 'bread', price = 1 } } },
        },
    }]]

    for source = 1, 2 do
        H.Net.identifiers[source] = { 'license:' .. source }
        H.Net.peds[source] = 100 + source
        H.Net.coords[100 + source] = SHOP
    end

    characters, balances, stockRows = {}, {}, rows or {}

    H.Db.handler = store

    return H.LoadManifest('server')
end

---@param fn fun(): ...
---@return table
local function await(fn)
    local result

    H.Capture(function()
        H.Thread(function()
            result = table.pack(fn())
        end)
    end)

    return result
end

---@param source integer
---@return integer characterId
local function play(source)
    local id = await(function()
        return UgCore.Characters.Create(source, { name = 'P' .. source })
    end)[2]

    await(function()
        return UgCore.Characters.Load(source, id)
    end)

    return id
end

---@param shop string
---@param index integer
---@param count integer
---@return table result packed `ok, errorCode`
local function buy(shop, index, count)
    return await(function()
        return UgCore.Shops.Buy(1, shop, index, count)
    end)
end

---@param name string
---@param source integer
---@param ... any
---@return any value the callback reply
local function ask(name, source, ...)
    local args = table.pack(...)

    H.Net.client = {}
    H.Capture(function()
        H.TriggerNetEvent('__ugcb:ug-core:' .. name, source, 'ug-inventory', 1, table.unpack(args, 1, args.n))
    end)

    local reply = H.ClientEvents('__ugcb:res:ug-inventory')[1]

    return reply and reply.args[3]
end

H.Test('Buying charges the account at the server price and gives the items', function()
    fresh()
    play(1)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Shops.Purchased, function(source, shop, item, count, total, account)
        seen[#seen + 1] = { shop, item, count, total, account }
    end)

    H.Equal(buy('corner', 1, 3), { n = 2, true })
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 485)
    H.Equal(UgCore.Inventory.Count(1, 'water'), 3)
    H.Equal(seen, { { 'corner', 'water', 3, 15, 'cash' } })
end)

H.Test('Shop metadata comes with each unit, and weapons get serials', function()
    fresh()
    play(1)

    buy('corner', 3, 1)

    local metadata = assert(assert(UgCore.Inventory.GetSlot(1, 1)).metadata)

    H.Equal(metadata.ammo, 12)
    H.Equal(type(metadata.serial), 'string')
end)

H.Test('Purchases fail without money, room, stock, range or access, and nothing changes', function()
    fresh()
    play(1)

    H.Equal(buy('corner', 3, 6), { n = 2, false, 'insufficient_funds' })
    H.Equal(buy('corner', 2, 4), { n = 2, false, 'insufficient_items' })
    H.Equal(buy('corner', 9, 1), { n = 2, false, 'not_found' })
    H.Equal(buy('nowhere', 1, 1), { n = 2, false, 'not_found' })
    H.Equal(buy('armory', 1, 1), { n = 2, false, 'no_permission' })
    H.Equal(buy('corner', 1, 999), { n = 2, false, 'cannot_carry' })

    H.Net.coords[101] = vector3(0, 0, 0)
    H.Equal(buy('corner', 1, 1), { n = 2, false, 'no_permission' })

    H.Net.coords[101] = vector3(500, 0, 0)
    H.Equal(buy('corner', 1, 1), { n = 2, true })

    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 495)
    H.Equal(UgCore.Shops.Get('corner').stock, { bandage = 3 })
end)

H.Test('Limited stock goes down, is saved, and restocks on time', function()
    fresh()
    play(1)

    H.Equal(buy('corner', 2, 2), { n = 2, true })
    H.Equal(UgCore.Shops.Get('corner').stock.bandage, 1)

    H.Capture(function() H.Advance(0) end)
    H.Equal(stockRows['corner:bandage'].stock, 1)

    UgCore.Internal.Shops.RestockDue(stockRows['corner:bandage'].restockedAt + 3600)
    H.Equal(UgCore.Shops.Get('corner').stock.bandage, 3)
end)

H.Test('Saved stock survives a restart', function()
    fresh(nil, { ['corner:bandage'] = { stock = 1, restockedAt = os.time() } })

    H.Equal(UgCore.Shops.Get('corner').stock.bandage, 1)
end)

H.Test('The payment is refunded when the items cannot be given', function()
    fresh()
    play(1)

    UgCore.Hooks.Register(UgCore.Enums.Hooks.Inventory.BeforeAdd, function() return false end)

    H.Equal(buy('corner', 2, 1), { n = 2, false, 'no_permission' })
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 500)
    H.Equal(UgCore.Shops.Get('corner').stock.bandage, 3)
end)

H.Test('BeforePurchase can cancel or give a discount, never raise the price', function()
    fresh()
    play(1)

    local mode = 'discount'

    UgCore.Hooks.Register(UgCore.Enums.Hooks.Shops.BeforePurchase, function(payload)
        if mode == 'cancel' then
            return false
        end

        payload.total = mode == 'discount' and payload.total // 2 or payload.total * 10
        return payload
    end)

    buy('corner', 1, 2)
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 495)

    mode = 'raise'
    buy('corner', 1, 2)
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 485)

    mode = 'cancel'
    H.Equal(buy('corner', 1, 1), { n = 2, false, 'no_permission' })
end)

H.Test('Clients open shops and buy by position', function()
    fresh()
    play(1)

    H.Equal(ask('ShopOpen', 1, 'corner'), {
        label = 'Corner', account = 'cash',
        items = {
            { index = 1, name = 'water', price = 5 },
            { index = 2, name = 'bandage', price = 50, stock = 3 },
            { index = 3, name = 'weapon_pistol', price = 100 },
        },
    })
    H.Equal(ask('ShopOpen', 1, 'armory'), 'no_permission')
    H.Equal(ask('ShopBuy', 1, 'corner', 1, 2), true)
    H.Equal(UgCore.Inventory.Count(1, 'water'), 2)
end)

H.Test('Shop positions replicate for blips', function()
    fresh()

    H.Equal(GlobalState['ug-core:Shops'].armory, { label = 'Armory', coords = { { x = 50, y = 0, z = 0 } } })
end)

H.Test('Resources register shops, checked against items and accounts', function()
    fresh()
    play(1)

    local Garage = H.LoadImport('ug-garage', 'server').UgCore

    Garage.Shops.Register('parts', { label = 'Parts', coords = SHOP, account = 'bank', items = { { name = 'bandage', price = 10 } } })

    H.Equal(buy('parts', 1, 1), { n = 2, true })
    H.Equal(UgCore.Accounts.GetBalance(1, 'bank'), 4990)

    H.Raises(function()
        UgCore.Shops.Register('bad', { label = 'Bad', coords = SHOP, account = 'gold', items = { { name = 'water', price = 1 } } })
    end, 'pays with "gold", which is not in config/accounts.lua')

    H.Raises(function()
        UgCore.Shops.Register('corner', { label = 'X', coords = SHOP, account = 'cash', items = { { name = 'water', price = 1 } } })
    end, '"corner" is defined in config/shops.lua')

    H.TriggerEvent('onResourceStop', nil, 'ug-garage')

    H.Equal(UgCore.Shops.Get('parts'), nil)
end)

H.Test('Shops selling unknown items stop boot', function()
    local lines = fresh([[return { shops = { s = { label = 'S', coords = vector3(0, 0, 0), account = 'cash', items = { { name = 'gold', price = 1 } } } } }]])
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('shop "s" sells "gold", which is not in config/items.lua', 1, true) ~= nil
    end

    H.Assert(found, 'error missing')
    H.Equal(UgCore.Lifecycle.GetState(), 'Stopped')
end)

H.Test('Player objects buy, and ug shops lists shops and stock', function()
    fresh()
    play(1)

    local player = assert(UgCore.Players.Get(1))

    H.Equal(await(function() return player:Buy('corner', 2, 1) end), { n = 2, true })
    H.Equal(H.RunCommand('ug', 0, { 'shops' }), {
        '  armory               Armory               1 item(s), pays with bank',
        '  corner               Corner               3 item(s), pays with cash',
    })
    H.Equal(H.RunCommand('ug', 0, { 'shops', 'corner' }), {
        'corner (Corner), pays with cash:',
        '    1  water                             5  unlimited',
        '    2  bandage                          50  2/3 in stock',
        '    3  weapon_pistol                   100  unlimited',
    })
end)

H.Done()
