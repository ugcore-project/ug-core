--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type { identifier: string, name: string, data: string }[]
local characters

---@type table<string, { item: string, characterId: integer? }>
local serials

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

    if sql:find('INSERT INTO `ug_weapon_serials`', 1, true) then
        serials[v[1]] = { item = v[2], characterId = v[3] ~= 0 and v[3] or nil }
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('FROM `ug_weapon_serials`', 1, true) then
        local row = serials[v[1]]

        return row and { { serial = v[1], item = row.item, characterId = row.characterId, createdAt = 0 } } or {}
    end
end

local PISTOL = GetHashKey('WEAPON_PISTOL')
local SUPPRESSOR = GetHashKey('COMPONENT_AT_PI_SUPP_02')
local PED = 101

---@param weaponsConfig? string Lua source of config/weapons.lua
---@return string[] lines
local function fresh(weaponsConfig)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'characters', 'items', 'inventory', 'weapons' } }
    H.Net.resources['ug-inventory'] = 'started'

    if weaponsConfig then
        H.ResourceFiles['config/weapons.lua'] = weaponsConfig
    end

    for source = 1, 2 do
        H.Net.identifiers[source] = { 'license:' .. source }
        H.Net.peds[source] = 100 + source
        H.Net.coords[100 + source] = vector3(0, 0, 0)
    end

    characters, serials = {}, {}

    local lines = H.LoadManifest('server')

    H.Db.handler = store

    return lines
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

---@param seconds number
local function wait(seconds)
    H.Capture(function()
        for _ = 1, math.ceil(seconds * 4) do
            H.Advance(250)
        end
    end)
end

---@param slot integer
---@return table metadata of player 1's slot
local function meta(slot)
    return assert(assert(UgCore.Inventory.GetSlot(1, slot)).metadata)
end

---@param source integer
---@param ammo integer
local function report(source, ammo)
    H.Capture(function()
        H.TriggerNetEvent('ug-core:WeaponAmmo', source, ammo)
    end)
end

H.Test('Every new weapon gets its own serial, registered to the character', function()
    fresh()
    local id = play(1)

    H.Equal({ UgCore.Inventory.AddItem(1, 'weapon_pistol', 2, nil, 'shop') }, { true })
    H.Capture(function() H.Advance(0) end)

    local first, second = meta(1), meta(2)

    H.Equal({ first.ammo, first.durability }, { 0, 100 })
    H.Assert(type(first.serial) == 'string' and #first.serial == 10, 'serial missing')
    H.Assert(first.serial ~= second.serial, 'serials are not unique')

    local ok, record = table.unpack(await(function() return UgCore.Weapons.GetBySerial(first.serial) end))

    H.Equal(ok, true)
    H.Equal({ record.item, record.characterId }, { 'weapon_pistol', id })
end)

H.Test('Using a weapon equips it on the server, and again puts it away', function()
    fresh()
    play(1)

    local seen = {}

    UgCore.Events.On(UgCore.Enums.Events.Weapons.Equipped, function(source, name) seen[#seen + 1] = { 'equipped', name } end)
    UgCore.Events.On(UgCore.Enums.Events.Weapons.Unequipped, function(source, name) seen[#seen + 1] = { 'unequipped', name } end)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)

    H.Equal({ UgCore.Inventory.Use(1, 1) }, { true })
    H.Equal(H.Net.current[PED], PISTOL)
    H.Equal(assert(UgCore.Weapons.GetEquipped(1)).name, 'weapon_pistol')
    H.Equal(H.ClientEvents('ug-core:WeaponEquipped')[1].args[1].hash, PISTOL)

    H.Advance(500)
    H.Equal({ UgCore.Inventory.Use(1, 1) }, { true })
    H.Equal(H.Net.current[PED], nil)
    H.Equal(UgCore.Weapons.GetEquipped(1), nil)
    H.Equal(seen, { { 'equipped', 'weapon_pistol' }, { 'unequipped', 'weapon_pistol' } })
end)

H.Test('Broken weapons and other items do not equip, and BeforeEquip can cancel', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1, { durability = 0 })
    UgCore.Inventory.AddItem(1, 'water', 1)
    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)

    H.Equal({ UgCore.Weapons.Equip(1, 1) }, { false, 'invalid_args' })
    H.Equal({ UgCore.Weapons.Equip(1, 2) }, { false, 'invalid_args' })
    H.Equal({ UgCore.Weapons.Equip(1, 9) }, { false, 'not_found' })

    UgCore.Hooks.Register(UgCore.Enums.Hooks.Weapons.BeforeEquip, function() return false end)

    H.Equal({ UgCore.Weapons.Equip(1, 3) }, { false, 'no_permission' })
end)

H.Test('Reload loads ammo items up to capacity, Unload gives them back', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Weapons.Equip(1, 1)

    H.Equal({ UgCore.Weapons.Reload(1) }, { false, 'insufficient_items' })

    UgCore.Inventory.AddItem(1, 'ammo_9mm', 100)

    H.Equal({ UgCore.Weapons.Reload(1) }, { true })
    H.Equal(UgCore.Inventory.Count(1, 'ammo_9mm'), 40)
    H.Equal(H.Net.weapons[PED][PISTOL].ammo, 60)
    H.Equal(meta(1).ammo, 60)

    H.Equal({ UgCore.Weapons.Unload(1) }, { true })
    H.Equal(UgCore.Inventory.Count(1, 'ammo_9mm'), 100)
    H.Equal(H.Net.weapons[PED][PISTOL].ammo, 0)
end)

H.Test('Using ammo reloads the equipped weapon that takes it', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Inventory.AddItem(1, 'ammo_9mm', 10)

    H.Equal({ UgCore.Inventory.Use(1, 2) }, { false, 'no_permission' })

    UgCore.Weapons.Equip(1, 1)

    H.Equal({ UgCore.Inventory.Use(1, 2) }, { true })
    H.Equal(assert(UgCore.Weapons.GetEquipped(1)).ammo, 10)
end)

H.Test('Shots reported by the client wear the weapon', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1, { ammo = 60 })
    UgCore.Weapons.Equip(1, 1)

    report(1, 40)

    local metadata = meta(1)

    H.Equal(metadata.ammo, 40)
    H.Equal(metadata.durability, 99)
    H.Equal(UgCore.Guard.GetScore(1), 0)
end)

H.Test('More ammo than the server gave is flagged and reverted', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1, { ammo = 10 })
    UgCore.Weapons.Equip(1, 1)

    report(1, 250)

    H.Equal(assert(UgCore.Weapons.GetEquipped(1)).ammo, 10)
    H.Equal(H.Net.weapons[PED][PISTOL].ammo, 10)
    H.Equal(UgCore.Guard.GetScore(1), UgCore.Enums.ViolationWeights[UgCore.Enums.Violations.WeaponMismatch])
end)

H.Test('A worn out weapon breaks and is put away', function()
    fresh([[return { weapons = { weapon_pistol = { hash = 'WEAPON_PISTOL', ammo = 'ammo_9mm', capacity = 60, wear = 50 } } }]])
    play(1)

    local broken = {}

    UgCore.Events.On(UgCore.Enums.Events.Weapons.Broken, function(source, name) broken[#broken + 1] = name end)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1, { ammo = 5 })
    UgCore.Weapons.Equip(1, 1)
    report(1, 3)

    H.Equal(broken, { 'weapon_pistol' })
    H.Equal(UgCore.Weapons.GetEquipped(1), nil)
    H.Equal(meta(1).durability, 0)

    H.Equal({ UgCore.Weapons.Repair(1, 1) }, { true })
    H.Equal({ UgCore.Weapons.Equip(1, 1) }, { true })
end)

H.Test('Attachments are used up into the weapon, and components come back off', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Inventory.AddItem(1, 'pistol_suppressor', 2)
    UgCore.Inventory.AddItem(1, 'weapon_tint_gold', 1)
    UgCore.Inventory.AddItem(1, 'water', 1)
    UgCore.Weapons.Equip(1, 1)

    H.Equal({ UgCore.Weapons.Attach(1, 1, 2) }, { true })
    H.Equal(UgCore.Inventory.Count(1, 'pistol_suppressor'), 1)
    H.Equal(meta(1).components, { 'pistol_suppressor' })
    H.Equal(H.Net.weapons[PED][PISTOL].components[SUPPRESSOR], true)

    H.Equal({ UgCore.Weapons.Attach(1, 1, 2) }, { false, 'invalid_args' })
    H.Equal({ UgCore.Weapons.Attach(1, 1, 4) }, { false, 'invalid_args' })

    H.Equal({ UgCore.Weapons.Attach(1, 1, 3) }, { true })
    H.Equal(meta(1).tint, 2)
    H.Equal(H.ClientEvents('ug-core:WeaponTint')[1].args, { n = 2, PISTOL, 2 })

    H.Equal({ UgCore.Weapons.Detach(1, 1, 'pistol_suppressor') }, { true })
    H.Equal(UgCore.Inventory.Count(1, 'pistol_suppressor'), 2)
    H.Equal(H.Net.weapons[PED][PISTOL].components[SUPPRESSOR], nil)
    H.Equal({ UgCore.Weapons.Detach(1, 1, 'pistol_suppressor') }, { false, 'not_found' })
end)

H.Test('Equipping restores components from the item', function()
    fresh()
    play(1)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1, { components = { 'pistol_suppressor' } })
    UgCore.Weapons.Equip(1, 1)

    H.Equal(H.Net.weapons[PED][PISTOL].components[SUPPRESSOR], true)
end)

H.Test('A weapon leaving the inventory leaves the hands', function()
    fresh()
    play(1)
    play(2)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Weapons.Equip(1, 1)
    UgCore.Inventory.Move(1, 1, 2, nil)

    H.Equal(UgCore.Weapons.GetEquipped(1), nil)
    H.Equal(H.Net.current[PED], nil)

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Weapons.Equip(1, 1)
    UgCore.Inventory.RemoveItem(1, 'weapon_pistol', 1)

    H.Equal(UgCore.Weapons.GetEquipped(1), nil)
end)

H.Test('Weapons not equipped from the inventory are taken away and flagged', function()
    fresh([[return { allowed = { 'WEAPON_PETROLCAN' } }]])
    play(1)

    H.Net.current[PED] = GetHashKey('WEAPON_RPG')
    wait(2)

    local weight = UgCore.Enums.ViolationWeights[UgCore.Enums.Violations.WeaponMismatch]

    H.Equal(H.Net.current[PED], nil)
    H.Equal(UgCore.Guard.GetScore(1), weight)

    H.Net.current[PED] = GetHashKey('WEAPON_PETROLCAN')
    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    wait(2)

    H.Equal(H.Net.current[PED], GetHashKey('WEAPON_PETROLCAN'))

    UgCore.Weapons.Equip(1, 1)
    wait(2)

    H.Equal(H.Net.current[PED], PISTOL)
    -- Only the first flag: the score has decayed a little since.
    H.Assert(UgCore.Guard.GetScore(1) <= weight, 'flagged again')
end)

H.Test('Weapons must be non-stackable items', function()
    local cases = {
        { [[return { weapons = { weapon_rifle = { hash = 'WEAPON_CARBINERIFLE' } } }]], 'weapon "weapon_rifle" is not in config/items.lua' },
        { [[return { weapons = { water = { hash = 'WEAPON_PISTOL' } } }]], 'weapon "water" MUST have stack = false' },
        { [[return { weapons = { weapon_pistol = { hash = 'pistol' } } }]], 'hash MUST be a weapon name' },
        { [[return { weapons = { weapon_pistol = { hash = 'WEAPON_PISTOL', ammo = 'ammo_9mm' } } }]], 'capacity MUST be an integer' },
    }

    for _, case in ipairs(cases) do
        local lines = fresh(case[1])
        local found = false

        for _, line in ipairs(lines) do
            found = found or line:find(case[2], 1, true) ~= nil
        end

        H.Assert(found, 'missing error: ' .. case[2])
        H.Equal(UgCore.Lifecycle.GetState(), 'Stopped', case[2])
    end
end)

H.Test('The client applies the tint and reports shots', function()
    fresh()
    H.LocalSource = 1

    H.Capture(function()
        H.LoadManifest('client')
        H.TriggerNetEvent('ug-core:WeaponEquipped', nil, { hash = PISTOL, ammo = 30, tint = 2 })
    end)

    H.Equal(H.Net.tints[PISTOL], 2)
    H.Equal(UgCore.Weapons.GetEquipped(), { hash = PISTOL, ammo = 30, tint = 2 })

    H.Net.weapons[PED] = { [PISTOL] = { ammo = 27, components = {} } }
    wait(0.25)

    H.Equal(H.Net.server[#H.Net.server], { name = 'ug-core:WeaponAmmo', args = { n = 1, 27 } })

    H.Capture(function()
        H.TriggerNetEvent('ug-core:WeaponUnequipped', nil)
    end)

    H.Net.server = {}
    H.Net.weapons[PED][PISTOL].ammo = 10
    wait(1)

    H.Equal(H.Net.server, {})
    H.Equal(UgCore.Weapons.GetEquipped(), nil)
end)

H.Test('Player objects equip, reload and read weapons, and ug weapon shows them', function()
    fresh()
    play(1)

    local player = assert(UgCore.Players.Get(1))

    UgCore.Inventory.AddItem(1, 'weapon_pistol', 1)
    UgCore.Inventory.AddItem(1, 'ammo_9mm', 10)

    H.Equal({ player:EquipWeapon(1) }, { true })
    H.Equal(await(function() return player:ReloadWeapon() end), { n = 2, true })

    local weapon = assert(player:GetEquippedWeapon())

    H.Equal({ weapon.name, weapon.ammo }, { 'weapon_pistol', 10 })
    H.Equal(H.RunCommand('ug', 0, { 'weapon', '1' }), {
        ('Player 1: weapon_pistol, serial %s, 10 rounds, 100.0%% durability'):format(weapon.serial),
    })

    H.Equal(player:UnequipWeapon(), true)
    H.Equal(H.RunCommand('ug', 0, { 'weapon', '1' }), { 'Player 1 has no weapon equipped.' })
end)

H.Done()
