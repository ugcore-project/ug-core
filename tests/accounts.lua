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
local stored

---@type { characterId: integer, account: string, amount: integer, balance: integer, reason: string?, related: integer? }[]
local ledger

---In-memory characters, accounts and ledger.
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

    if sql:find('SELECT `id` FROM `ug_characters`', 1, true) then
        return characters[v[1]] and { { id = v[1] } } or {}
    end

    if sql:find('INSERT INTO `ug_accounts`', 1, true) then
        local key = v[1] .. ':' .. v[2]

        if sql:find('`balance` + VALUES', 1, true) then
            stored[key] = (stored[key] or 0) + v[3]
        else
            stored[key] = v[3]
        end

        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('INSERT INTO `ug_ledger`', 1, true) then
        if sql:find('SELECT ?', 1, true) then
            ledger[#ledger + 1] = { characterId = v[1], account = v[2], amount = v[3], balance = stored[v[6] .. ':' .. v[7]], reason = v[4] ~= '' and v[4] or nil, related = v[5] }
        else
            ledger[#ledger + 1] = { characterId = v[1], account = v[2], amount = v[3], balance = v[4], reason = v[5] ~= '' and v[5] or nil, related = v[6] ~= 0 and v[6] or nil }
        end

        return { insertId = #ledger, affectedRows = 1 }
    end

    if sql:find('FROM `ug_accounts` WHERE `character_id`', 1, true) then
        local rows = {}

        for key, balance in pairs(stored) do
            local id, account = key:match('^(%d+):(.+)$')

            if tonumber(id) == v[1] then
                rows[#rows + 1] = { account = account, balance = balance }
            end
        end

        return rows
    end

    if sql:find('FROM `ug_ledger`', 1, true) then
        local rows = {}

        for index = #ledger, 1, -1 do
            local entry = ledger[index]

            if entry.characterId == v[1] and entry.account == v[2] then
                rows[#rows + 1] = { amount = entry.amount, balanceAfter = entry.balance, reason = entry.reason, createdAt = 0 }
            end
        end

        return rows
    end
end

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'characters', 'accounts' } }

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
    end

    characters, stored, ledger = {}, {}, {}

    H.Capture(function()
        H.LoadManifest('server')
    end)

    H.Db.handler = store
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

---Creates and loads a character for the player.
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

H.Test('New characters get starting balances with ledger rows', function()
    fresh()

    local id = play(1)

    H.Equal(UgCore.Accounts.GetAll(1), { cash = 500, bank = 5000 })
    H.Equal(stored[id .. ':bank'], 5000)
    H.Equal(#ledger, 2)
    H.Equal(ledger[1].reason, 'Starting balance')
    H.Equal(H.ClientEvents('ug-core:AccountsSync')[1].args[1], { cash = 500, bank = 5000 })
end)

H.Test('Add and Remove change memory, database and ledger together', function()
    fresh()

    local id = play(1)

    H.Equal(await(function() return UgCore.Accounts.Add(1, 'cash', 250, 'Paycheck') end), { n = 3, true, 750 })
    H.Equal(await(function() return UgCore.Accounts.Remove(1, 'cash', 50) end), { n = 3, true, 700 })

    H.Equal(stored[id .. ':cash'], 700)
    H.Equal(ledger[#ledger], { characterId = id, account = 'cash', amount = -50, balance = 700 })
    H.Equal(ledger[#ledger - 1].reason, 'Paycheck')
    H.Equal(H.ClientEvents('ug-core:AccountsChanged')[2].args, { n = 2, 'cash', 700 })
end)

H.Test('Remove refuses to overdraw', function()
    fresh()

    play(1)

    H.Equal(await(function() return UgCore.Accounts.Remove(1, 'cash', 501) end), { n = 3, false, nil, 'insufficient_funds' })
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 500)
end)

H.Test('A failed write reverts the change', function()
    fresh()

    play(1)
    H.Db.fail = 'INSERT INTO `ug_ledger`'

    H.Equal(await(function() return UgCore.Accounts.Add(1, 'cash', 100) end), { n = 3, false, nil, 'internal_error' })
    H.Equal(UgCore.Accounts.GetBalance(1, 'cash'), 500)
end)

H.Test('Set records the difference in the ledger', function()
    fresh()

    play(1)

    H.Equal(await(function() return UgCore.Accounts.Set(1, 'bank', 1000, 'Admin') end), { n = 3, true, 1000 })
    H.Equal(ledger[#ledger].amount, -4000)
end)

H.Test('Transfers to loaded characters update both sides', function()
    fresh()

    local sender = play(1)
    local target = play(2)

    H.Equal(await(function() return UgCore.Accounts.Transfer(1, target, 'bank', 1000, 'Rent') end), { n = 3, true, 4000 })
    H.Equal(UgCore.Accounts.GetBalance(2, 'bank'), 6000)
    H.Equal(ledger[#ledger], { characterId = target, account = 'bank', amount = 1000, balance = 6000, reason = 'Rent', related = sender })
end)

H.Test('Transfers to offline characters use the database balance', function()
    fresh()

    local target = play(2)

    await(function() return UgCore.Characters.Unload(2) end)
    play(1)

    H.Equal(await(function() return UgCore.Accounts.Transfer(1, target, 'bank', 300) end)[1], true)
    H.Equal(stored[target .. ':bank'], 5300)
    H.Equal(ledger[#ledger].balance, 5300)
    H.Equal(await(function() return UgCore.Accounts.Transfer(1, 99, 'bank', 1) end), { n = 3, false, nil, 'not_found' })
end)

H.Test('Accounts:BeforeRemove can cancel a removal', function()
    fresh()

    play(1)

    UgCore.Hooks.Register('Accounts:BeforeRemove', function(payload)
        return payload.amount < 100
    end)

    H.Equal(await(function() return UgCore.Accounts.Remove(1, 'cash', 200) end)[3], 'no_permission')
    H.Equal(await(function() return UgCore.Accounts.Remove(1, 'cash', 50) end)[2], 450)
end)

H.Test('Players without a loaded character get not_loaded', function()
    fresh()

    H.Equal(await(function() return UgCore.Accounts.Add(3, 'cash', 1) end), { n = 3, false, nil, 'not_loaded' })
    H.Equal(UgCore.Accounts.GetBalance(3, 'cash'), nil)
end)

H.Test('Wrong API usage raises', function()
    fresh()

    H.Raises(function()
        UgCore.Accounts.Add(1, 'crypto', 1)
    end, 'Accounts.Add: unknown account "crypto"')

    H.Raises(function()
        UgCore.Accounts.Add(1, 'cash', 1.5)
    end, 'Accounts.Add: amount MUST be an integer from 1 to 1000000000000')

    H.Raises(function()
        UgCore.Accounts.Set(1, 'cash', -1)
    end, 'Accounts.Set: balance MUST be an integer from 0 to 1000000000000')
end)

H.Test('GetLedger returns the newest entries first', function()
    fresh()

    play(1)
    await(function() return UgCore.Accounts.Add(1, 'cash', 10) end)

    local result = await(function()
        return UgCore.Accounts.GetLedger(1, 'cash', 5)
    end)

    H.Equal({ result[2][1].amount, result[2][2].amount }, { 10, 500 })
end)

H.Test('Clients keep their own balances from server events', function()
    fresh()

    play(1)
    await(function() return UgCore.Accounts.Add(1, 'cash', 5) end)

    local sync = H.ClientEvents('ug-core:AccountsSync')[1].args[1]
    local changed = H.ClientEvents('ug-core:AccountsChanged')[1].args

    H.Capture(function()
        H.LoadManifest('client')
        H.TriggerNetEvent('ug-core:AccountsSync', nil, sync)
        H.TriggerNetEvent('ug-core:AccountsChanged', nil, changed[1], changed[2])
    end)

    H.Equal(UgCore.Accounts.GetAll(), { cash = 505, bank = 5000 })
end)

H.Test('Clients emit Changed for their own balances', function()
    fresh()

    H.Capture(function()
        H.LoadManifest('client')
    end)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Accounts.Changed, function(account, balance, delta)
        seen[#seen + 1] = { account, balance, delta }
    end)

    H.Capture(function()
        H.TriggerNetEvent('ug-core:AccountsSync', nil, { cash = 500 })
        H.TriggerNetEvent('ug-core:AccountsChanged', nil, 'cash', 450)
        H.TriggerNetEvent('ug-core:AccountsChanged', nil, 'cash', 450)
        H.TriggerNetEvent('ug-core:AccountsSync', nil, {})
    end)

    H.Equal(seen, {
        { 'cash', 500, 500 },
        { 'cash', 450, -50 },
        { 'cash', nil, -450 },
    })
    H.Equal(UgCore.Accounts.GetAll(), {})
end)

H.Done()
