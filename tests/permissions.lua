--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@type table<string, table<string, string|false>> identifier -> permission -> granted_by
local stored

---@type table<string, table<string, string|false>> identifier -> group -> added_by
local groupMembers = {}

---In-memory `ug_permissions` and `ug_group_members`.
---@param sql string
---@param params table?
---@return any
local function store(sql, params)
    local values = params or {}

    if sql:find('INSERT INTO `ug_group_members`', 1, true) then
        groupMembers[values[1]] = groupMembers[values[1]] or {}
        groupMembers[values[1]][values[2]] = values[3] ~= '' and values[3] or false
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('DELETE FROM `ug_group_members`', 1, true) then
        local existed = groupMembers[values[1]] and groupMembers[values[1]][values[2]] ~= nil

        if existed then
            groupMembers[values[1]][values[2]] = nil
        end

        return { insertId = 0, affectedRows = existed and 1 or 0 }
    end

    if sql:find('FROM `ug_group_members`', 1, true) then
        local rows = {}

        for identifier, groups in pairs(groupMembers) do
            for group in pairs(groups) do
                rows[#rows + 1] = { identifier = identifier, group_name = group }
            end
        end

        return rows
    end

    if sql:find('INSERT INTO `ug_permissions`', 1, true) then
        stored[values[1]] = stored[values[1]] or {}
        stored[values[1]][values[2]] = values[3] ~= '' and values[3] or false
        return { insertId = 0, affectedRows = 1 }
    end

    if sql:find('DELETE FROM `ug_permissions`', 1, true) then
        local existed = stored[values[1]] and stored[values[1]][values[2]] ~= nil

        if existed then
            stored[values[1]][values[2]] = nil
        end

        return { insertId = 0, affectedRows = existed and 1 or 0 }
    end

    if sql:find('FROM `ug_permissions`', 1, true) then
        local rows = {}

        for identifier, permissions in pairs(stored) do
            for permission in pairs(permissions) do
                rows[#rows + 1] = { identifier = identifier, permission = permission }
            end
        end

        return rows
    end
end

---@param initial? table<string, table<string, string|false>>
---@param initialGroups? table<string, table<string, string|false>>
---@param modules? string[]
---@return string[] lines
local function boot(initial, initialGroups, modules)
    stored = initial or {}
    groupMembers = initialGroups or {}
    H.DiskModules = true
    H.Metadata = { ug_module = modules or { 'identity', 'permissions' } }

    return H.LoadManifest('server')
end

local function fresh()
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.ResetAces()
    H.Aces = { ['resource.ug-core:command.add_ace'] = true }
    H.Db.handler = function(sql, params) return store(sql, params) end
    H.Net.identifiers[1] = { 'license:aaa' }
    H.Net.identifiers[2] = { 'license:bbb' }
    H.Net.identifiers[3] = { 'steam:ccc' }

    boot()
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

H.Test('Grant stores the permission and applies the ACE', function()
    fresh()

    H.Equal(UgCore.Permissions.Has(1, 'ug.admin'), false)
    H.Equal(await(function() return UgCore.Permissions.Grant(1, 'ug.admin', 'console') end), { n = 2, true })

    H.Equal(stored['license:aaa'], { ['ug.admin'] = 'console' })
    H.Equal(H.Commands[#H.Commands], 'add_ace identifier.license:aaa ug.admin allow')
    H.Equal(UgCore.Permissions.Has(1, 'ug.admin'), true)
    H.Equal(UgCore.Permissions.Has(2, 'ug.admin'), false)
end)

H.Test('Revoke removes the grant and the ACE', function()
    fresh()

    await(function() return UgCore.Permissions.Grant('license:aaa', 'ug.admin') end)

    H.Equal(await(function() return UgCore.Permissions.Revoke(1, 'ug.admin') end), { n = 3, true, true })
    H.Equal(UgCore.Permissions.Has(1, 'ug.admin'), false)
    H.Equal(await(function() return UgCore.Permissions.Revoke(1, 'ug.admin') end), { n = 3, true, false })
end)

H.Test('GetAll lists granted permissions, sorted', function()
    fresh()

    await(function() return UgCore.Permissions.Grant(1, 'ug.mod') end)
    await(function() return UgCore.Permissions.Grant(1, 'ug.admin') end)

    H.Equal(UgCore.Permissions.GetAll(1), { 'ug.admin', 'ug.mod' })
    H.Equal(UgCore.Permissions.GetAll('license:zzz'), {})
end)

H.Test('Grants are applied again on boot', function()
    fresh()
    H.ResetAces()
    H.Aces = { ['resource.ug-core:command.add_ace'] = true }

    boot({ ['license:bbb'] = { ['ug.admin'] = false } })

    H.Equal(UgCore.Permissions.Has(2, 'ug.admin'), true)
    H.Equal(UgCore.Permissions.GetAll(2), { 'ug.admin' })
end)

H.Test('Network permission options see granted permissions', function()
    fresh()

    local calls = 0
    local S = UgCore.Schema

    UgCore.Network.Register('Admin', { schema = S.Define({}), rate = { max = 5, per = 1000 }, permission = 'ug.admin' }, function()
        calls = calls + 1
    end)

    await(function() return UgCore.Permissions.Grant(1, 'ug.admin') end)
    H.TriggerNetEvent('ug-core:Admin', 1)

    H.Equal(calls, 1)
end)

H.Test('Strings that reach ExecuteCommand are strict', function()
    fresh()

    H.Raises(function()
        UgCore.Permissions.Grant(1, 'ug.admin allow; quit')
    end, 'Permissions.Grant expects a permission of letters, digits, dots, dashes and underscores')

    H.Raises(function()
        UgCore.Permissions.Grant('license:aaa; quit', 'ug.admin')
    end, 'Permissions.Grant expects a player source or an identifier')
end)

H.Test('Players without a primary identifier get not_found', function()
    fresh()

    H.Equal(await(function() return UgCore.Permissions.Grant(3, 'ug.admin') end), { n = 2, false, 'not_found' })
end)

H.Test('A missing add_ace permission is reported at boot', function()
    fresh()
    H.Aces = {}

    local lines = H.LoadManifest('server')
    local found = false

    for _, line in ipairs(lines) do
        found = found or line:find('ug-core cannot run add_ace. Add `add_ace resource.ug-core command allow` to server.cfg.', 1, true) ~= nil
    end

    H.Assert(found, 'missing ACE not reported')
end)

-- Groups

---@param lines string[]
---@param text string
---@return boolean
local function contains(lines, text)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return true
        end
    end

    return false
end

H.Test('Default groups become ACE principals with inheritance', function()
    fresh()

    H.Assert(contains(H.Commands, 'add_ace group.admin ug.admin allow'), 'admin ACE missing')
    H.Assert(contains(H.Commands, 'add_principal group.admin group.moderator'), 'admin inheritance missing')
    H.Assert(contains(H.Commands, 'add_principal group.founder group.admin'), 'founder inheritance missing')
    H.Equal(IsPrincipalAceAllowed('group.founder', 'ug.admin'), true)
    H.Equal(IsPrincipalAceAllowed('group.moderator', 'ug.admin'), false)
end)

H.Test('AddGroup stores, applies the principal and publishes the statebag', function()
    fresh()

    local added = {}

    UgCore.Events.On(UgCore.Enums.Events.Permissions.GroupAdded, function(identifier, group, by)
        added[#added + 1] = { identifier, group, by }
    end)

    H.Equal(await(function() return UgCore.Permissions.AddGroup(1, 'founder', 'console') end), { n = 2, true })

    H.Equal(groupMembers['license:aaa'], { founder = 'console' })
    H.Equal(H.Commands[#H.Commands], 'add_principal identifier.license:aaa group.founder')
    H.Equal(UgCore.Permissions.Has(1, 'ug.admin'), true)
    H.Equal(Player(1).state['ug-core:Groups'], { 'founder' })
    H.Equal(added, { { 'license:aaa', 'founder', 'console' } })

    H.Equal(await(function() return UgCore.Permissions.AddGroup(1, 'founder') end), { n = 2, true })
    H.Equal(#added, 1)
end)

H.Test('AddGroup rejects unknown groups and players without an identifier', function()
    fresh()

    H.Equal(await(function() return UgCore.Permissions.AddGroup(1, 'owner') end), { n = 2, false, 'invalid_args' })
    H.Equal(await(function() return UgCore.Permissions.AddGroup(3, 'admin') end), { n = 2, false, 'not_found' })
    H.Equal(groupMembers, {})

    H.Raises(function()
        UgCore.Permissions.AddGroup(1, H.Any(5))
    end, 'Permissions.AddGroup expects a group name')

    H.Raises(function()
        UgCore.Permissions.AddGroup(1, 'admin', H.Any(5))
    end, 'Permissions.AddGroup: "by" MUST be a string')
end)

H.Test('RemoveGroup removes the principal, the row and the statebag entry', function()
    fresh()

    local removedEvents = 0

    UgCore.Events.On(UgCore.Enums.Events.Permissions.GroupRemoved, function()
        removedEvents = removedEvents + 1
    end)

    await(function() return UgCore.Permissions.AddGroup(2, 'admin') end)

    H.Equal(await(function() return UgCore.Permissions.RemoveGroup('license:bbb', 'admin') end), { n = 3, true, true })
    H.Equal(H.Commands[#H.Commands], 'remove_principal identifier.license:bbb group.admin')
    H.Equal(UgCore.Permissions.Has(2, 'ug.admin'), false)
    H.Equal(Player(2).state['ug-core:Groups'], {})
    H.Equal(removedEvents, 1)

    H.Equal(await(function() return UgCore.Permissions.RemoveGroup(2, 'admin') end), { n = 3, true, false })
    H.Equal(removedEvents, 1)
end)

H.Test('IsInGroup and GetGroups follow inheritance and weight', function()
    fresh()

    await(function() return UgCore.Permissions.AddGroup(1, 'moderator') end)
    await(function() return UgCore.Permissions.AddGroup(1, 'founder') end)
    await(function() return UgCore.Permissions.AddGroup(2, 'moderator') end)

    H.Equal(UgCore.Permissions.GetGroups(1), { 'founder', 'moderator' })
    H.Equal(UgCore.Permissions.IsInGroup(1, 'admin'), true)
    H.Equal(UgCore.Permissions.IsInGroup(2, 'moderator'), true)
    H.Equal(UgCore.Permissions.IsInGroup(2, 'admin'), false)
    H.Equal(UgCore.Permissions.IsInGroup('license:zzz', 'moderator'), false)
end)

H.Test('CanTarget needs a strictly higher weight, and the console outranks everyone', function()
    fresh()

    await(function() return UgCore.Permissions.AddGroup(1, 'founder') end)
    await(function() return UgCore.Permissions.AddGroup(2, 'admin') end)

    H.Equal(UgCore.Permissions.GetWeight(1), 100)
    H.Equal(UgCore.Permissions.GetWeight(3), 0)
    H.Equal(UgCore.Permissions.CanTarget(1, 2), true)
    H.Equal(UgCore.Permissions.CanTarget(2, 1), false)
    H.Equal(UgCore.Permissions.CanTarget(2, 'license:bbb'), false)
    H.Equal(UgCore.Permissions.CanTarget(2, 3), true)
    H.Equal(UgCore.Permissions.CanTarget(0, 1), true)
    H.Equal(UgCore.Permissions.CanTarget(1, 0), false)
end)

H.Test('Hooks can cancel adding and removing', function()
    fresh()

    local Hooks = UgCore.Enums.Hooks.Permissions
    local addHook = UgCore.Hooks.Register(Hooks.BeforeGroupAdd, function(payload)
        return payload.group ~= 'founder'
    end)

    H.Equal(await(function() return UgCore.Permissions.AddGroup(1, 'founder') end), { n = 2, false, 'no_permission' })
    H.Equal(groupMembers, {})
    UgCore.Hooks.Unregister(addHook)

    await(function() return UgCore.Permissions.AddGroup(1, 'admin') end)
    UgCore.Hooks.Register(Hooks.BeforeGroupRemove, function() return false end)

    H.Equal(await(function() return UgCore.Permissions.RemoveGroup(1, 'admin') end), { n = 3, false, nil, 'no_permission' })
    H.Equal(UgCore.Permissions.IsInGroup(1, 'admin'), true)
end)

H.Test('Members are applied again on boot, unknown groups are kept but not applied', function()
    fresh()
    H.ResetAces()
    H.Aces = { ['resource.ug-core:command.add_ace'] = true }

    local lines = boot(nil, { ['license:aaa'] = { admin = false }, ['license:bbb'] = { owner = false } })

    H.Equal(UgCore.Permissions.Has(1, 'ug.admin'), true)
    H.Equal(UgCore.Permissions.GetGroups(2), {})
    H.Assert(not contains(H.Commands, 'group.owner'), 'unknown group applied')
    H.Assert(contains(lines, '1 member(s) of groups missing from config/permissions.lua are kept but not applied.'), 'warning missing')

    H.Equal(await(function() return UgCore.Permissions.RemoveGroup(2, 'owner') end), { n = 3, true, true })
    H.Equal(groupMembers['license:bbb'], {})
end)

H.Test('Players joining get their groups statebag', function()
    fresh()

    groupMembers['license:aaa'] = { moderator = false }
    boot(nil, groupMembers)
    Player(1).state:set('ug-core:Groups', nil, true)

    H.TriggerEvent('playerJoining', 1)

    H.Equal(Player(1).state['ug-core:Groups'], { 'moderator' })
end)

H.Test('Owners define groups in config/permissions.lua', function()
    fresh()
    H.ResourceFiles['config/permissions.lua'] = [[return {
        groups = {
            helper = { label = 'Helper', weight = 5, permissions = { 'my-reports.view' } },
            owner = { label = 'Owner', weight = 900, inherits = 'helper', permissions = { 'ug.admin' } },
        },
    }]]

    boot()

    H.Equal(UgCore.Lifecycle.GetState(), 'Ready')
    H.Equal(UgCore.Permissions.GetGroupDefinition('owner'), { label = 'Owner', weight = 900, inherits = 'helper', permissions = { 'ug.admin' } })
    H.Equal(UgCore.Permissions.GetGroupDefinition('admin'), nil)
    H.Equal(IsPrincipalAceAllowed('group.owner', 'my-reports.view'), true)
end)

H.Test('Invalid groups and inheritance cycles stop boot', function()
    local cases = {
        { 'a = { label = "A", weight = 1, inherits = "b", permissions = {} }, b = { label = "B", weight = 2, inherits = "a", permissions = {} }', 'inheritance cycle: a -> b -> a' },
        { 'Admin = { label = "A", weight = 1, permissions = {} }', 'group names MUST be lowercase' },
        { 'a = { label = "A", weight = 1, inherits = "missing", permissions = {} }', 'group "a" inherits MUST be another group' },
        { 'a = { label = "A", weight = -1, permissions = {} }', 'group "a" weight MUST be an integer' },
        { 'a = { label = "A", weight = 1, permissions = { "ug.admin allow; quit" } }', 'group "a" has an invalid permission' },
        { 'a = { label = "A", weight = 1, permissions = {}, rank = 2 }', 'group "a" has an unknown field "rank"' },
    }

    for _, case in ipairs(cases) do
        fresh()
        H.ResourceFiles['config/permissions.lua'] = 'return { groups = { ' .. case[1] .. ' } }'

        local lines = boot()

        H.Assert(contains(lines, case[2]), 'missing error: ' .. case[2])
        H.Equal(UgCore.Lifecycle.GetState(), 'Stopped', case[2])
    end
end)

H.Test('Player objects manage groups', function()
    fresh()
    boot(nil, nil, { 'identity', 'players', 'permissions' })

    local founder = assert(UgCore.Players.Get(1))
    local other = assert(UgCore.Players.Get(2))

    H.Equal(await(function() return founder:AddGroup('founder') end), { n = 2, true })
    await(function() return other:AddGroup('moderator') end)

    H.Equal(founder:GetGroups(), { 'founder' })
    H.Equal(founder:IsInGroup('moderator'), true)
    H.Equal(founder:GetWeight(), 100)
    H.Equal(founder:CanTarget(other), true)
    H.Equal(other:CanTarget(founder), false)
    H.Equal(other:CanTarget(1), false)
end)

H.Test('ug groups lists groups with their members', function()
    fresh()

    await(function() return UgCore.Permissions.AddGroup(1, 'admin') end)

    H.Equal(H.RunCommand('ug', 0, { 'groups' }), {
        '  founder          Founder              weight 100     0   member(s) inherits admin',
        '  admin            Admin                weight 50      1   member(s) inherits moderator',
        '  moderator        Moderator            weight 10      0   member(s) ',
    })
end)

H.Done()
