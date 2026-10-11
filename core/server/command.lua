--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- `ug` console command for inspecting the framework. Output goes to the server console only.
-- Allowed from the server console and for players with the `ug.admin` ACE.

local InternalConfig = UgCore.Internal.Config
local Serializer = UgCore.Internal.Config.Serializer
local Validator = UgCore.Internal.Config.Validator
local InternalLifecycle = UgCore.Internal.Lifecycle
local ModuleLoader = UgCore.Internal.Modules.Loader
local Database = UgCore.Internal.Database
local InternalGuard = UgCore.Internal.Guard
local InternalHooks = UgCore.Internal.Hooks
local Updates = UgCore.Internal.Updates

local COMMAND = 'ug'
local ACE = 'ug.admin'
local USAGE = 'Usage: ug <config|database|groups|guard|hooks|inventory|items|lifecycle|modules|shops|version|weapon>'

---@param name string
---@param key string
---@param source UgConfigSource
---@return string
local function sourceLabel(name, key, source)
    if source == 'convar' then
        return 'convar ' .. Validator.ConvarName(name, key)
    end

    return source
end

---@type table<string, fun(args: string[])>
local subcommands = {}

---@param args string[]
subcommands.config = function(args)
    local name = args[1]

    if not name then
        local names = {}

        for _, entry in ipairs(InternalConfig.GetEntries()) do
            names[#names + 1] = entry.name
        end

        print('Usage: ug config <name>. Configs: ' .. table.concat(names, ', ') .. '.')
        return
    end

    local entry = InternalConfig.GetEntry(name)

    if not entry or not entry.values or not entry.sources then
        print(('Unknown config "%s".'):format(name))
        return
    end

    print(('config/%s.lua'):format(name))

    if entry.definition.kind == 'data' then
        local count = 0

        for _ in pairs(entry.values) do
            count = count + 1
        end

        print(('  %d entries'):format(count))
        return
    end

    for _, option in ipairs(entry.definition.options) do
        local key = option.key

        print(('  %s = %s (%s)'):format(
            key,
            Serializer.Inline(entry.values[key]),
            sourceLabel(name, key, entry.sources[key])
        ))
    end
end

subcommands.modules = function()
    local statuses = ModuleLoader.GetStatuses()

    if #statuses == 0 then
        print('No modules installed.')
        return
    end

    for _, status in ipairs(statuses) do
        print(('  %-14s %-9s %s'):format(status.name, status.enabled and 'enabled' or 'disabled', status.reason))
    end
end

subcommands.database = function()
    local server, applied = Database.Migrate.GetState()

    print('  server   ' .. (server or 'not connected'))

    local scopes = {}

    for scope in pairs(applied) do
        scopes[#scopes + 1] = scope
    end

    table.sort(scopes)

    for _, scope in ipairs(scopes) do
        local versions = applied[scope]

        print(('  %-8s %s'):format(scope, #versions > 0 and table.concat(versions, ', ') or 'no migrations'))
    end

    for _, stats in ipairs(Database.Cache.GetStats()) do
        print(('  cache    %s: %d entries, %d dirty'):format(stats.name, stats.entries, stats.dirty))
    end
end

---@param args string[]
subcommands.guard = function(args)
    local target = math.tointeger(tonumber(args[1]))

    if not target or target < 1 then
        print('Usage: ug guard <player id>')
        return
    end

    print(('  player %d score %d'):format(target, math.floor(UgCore.Guard.GetScore(target))))

    local now = GetGameTimer()

    for _, flag in ipairs(InternalGuard.GetFlags(target)) do
        print(('  %5ds ago  %-20s %s'):format((now - flag.at) // 1000, flag.violation, flag.detail or ''))
    end
end

subcommands.hooks = function()
    local hooks = InternalHooks.GetRegistered()

    if #hooks == 0 then
        print('No hooks registered.')
        return
    end

    for _, hook in ipairs(hooks) do
        print(('  %-24s %-20s priority %d'):format(hook.name, hook.resource, hook.priority))
    end
end

subcommands.groups = function()
    local groups = UgCore.Internal.Groups and UgCore.Internal.Groups.GetSummary() or {}

    if #groups == 0 then
        print('No groups. Define them in config/permissions.lua.')
        return
    end

    for _, group in ipairs(groups) do
        local inherits = group.inherits and ('inherits ' .. group.inherits) or ''

        print(('  %-16s %-20s weight %-7d %-3d member(s) %s'):format(group.name, group.label, group.weight, group.members, inherits))
    end
end

---@param args string[]
subcommands.inventory = function(args)
    local Inventory = UgCore.Modules.IsEnabled('inventory') and UgCore.Inventory or nil

    if not Inventory then
        print('The inventory module is disabled.')
        return
    end

    local target = math.tointeger(tonumber(args[1])) or args[1]

    if not target or not (math.type(target) == 'integer' or UgCore.Internal.InventoryStore.IsId(target)) then
        print('Usage: ug inventory <player id|inventory id>')
        return
    end

    local info = Inventory.Get(target)

    if not info then
        print(('No loaded inventory for %s.'):format(tostring(target)))
        return
    end

    print(('%s: %d/%d g, %d slots'):format(info.id, info.weight, info.maxWeight, info.slots))

    for _, item in ipairs(Inventory.GetItems(target)) do
        print(('  %3d  %-24s x%-6d %s'):format(item.slot, item.name, item.count, item.metadata and json.encode(item.metadata) or ''))
    end
end

---@param args string[]
subcommands.items = function(args)
    if not UgCore.Modules.IsEnabled('items') then
        print('The items module is disabled.')
        return
    end

    local definitions = UgCore.Items.GetAll()
    local name = args[1]

    if name then
        local item = definitions[name]

        if not item then
            print(('Unknown item "%s".'):format(name))
            return
        end

        print(('%s: %s, %d g, %s, %s'):format(name, item.label, item.weight, item.stack and ('stacks to ' .. item.maxStack) or 'does not stack',
            item.usable and 'usable' or 'not usable'))
        return
    end

    local names = {}

    for itemName in pairs(definitions) do
        names[#names + 1] = itemName
    end

    table.sort(names)
    print(('%d item(s):'):format(#names))

    for _, itemName in ipairs(names) do
        local item = definitions[itemName]
        local weapon = UgCore.Modules.IsEnabled('weapons') and UgCore.Weapons.IsWeapon(itemName)

        print(('  %-24s %-24s %7d g  %s%s'):format(itemName, item.label, item.weight, item.usable and 'usable' or '', weapon and ' weapon' or ''))
    end
end

---@param args string[]
subcommands.shops = function(args)
    if not UgCore.Modules.IsEnabled('shops') then
        print('The shops module is disabled.')
        return
    end

    local name = args[1]

    if not name then
        -- The client GetAll returns positions by name. This is the server one: names.
        for _, shopName in ipairs(UgCore.Shops.GetAll() --[[@as string[] ]]) do
            local shop = assert(UgCore.Shops.Get(shopName))

            print(('  %-20s %-20s %d item(s), pays with %s'):format(shopName, shop.label, #shop.items, shop.account))
        end

        return
    end

    local shop = UgCore.Shops.Get(name)

    if not shop then
        print(('Unknown shop "%s".'):format(name))
        return
    end

    print(('%s (%s), pays with %s:'):format(name, shop.label, shop.account))

    for index, item in ipairs(shop.items) do
        local stock = shop.stock[item.name]

        print(('  %3d  %-24s %10d  %s'):format(index, item.name, item.price, stock and ('%d/%d in stock'):format(stock, item.stock) or 'unlimited'))
    end
end

---@param args string[]
subcommands.weapon = function(args)
    if not UgCore.Modules.IsEnabled('weapons') then
        print('The weapons module is disabled.')
        return
    end

    local source = math.tointeger(tonumber(args[1]))

    if not source then
        print('Usage: ug weapon <player id>')
        return
    end

    local weapon = UgCore.Weapons.GetEquipped(source)

    if not weapon then
        print(('Player %d has no weapon equipped.'):format(source))
        return
    end

    print(('Player %d: %s, serial %s, %d rounds, %.1f%% durability'):format(source, weapon.name, weapon.serial, weapon.ammo, weapon.durability))
end

-- Asks GitHub again. The answer prints when it arrives.
subcommands.version = function()
    CreateThread(function()
        local result = Updates.Check()

        print(('ug-core v%s. %s'):format(result.current, Updates.Describe(result)))
    end)
end

subcommands.lifecycle = function()
    for _, step in ipairs(InternalLifecycle.GetHistory()) do
        print(('  %-12s +%d ms'):format(step.state, step.elapsed))
    end
end

RegisterCommand(COMMAND, function(source, args)
    if source ~= 0 and not IsPlayerAceAllowed(tostring(source), ACE) then
        return
    end

    local handler = args[1] and subcommands[args[1]]

    if not handler then
        print(USAGE)
        return
    end

    handler({ table.unpack(args, 2) })
end, false)
