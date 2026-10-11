--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Staff groups from config/permissions.lua. Each group is the ACE principal `group.<name>`, so every ACE check agrees,
---including other resources and groups from server.cfg. Members are stored in `ug_group_members` and applied with
---`add_principal identifier.<id> group.<name>`. Weights rank groups for moderation checks.
---@class UgCore.Permissions
local Permissions = UgCore.Permissions

---@class UgCore.Internal.Groups
local Groups = {}
UgCore.Internal.Groups = Groups

---@class UgGroupDefinition
---@field label string
---@field weight integer higher outranks lower
---@field inherits? string group whose permissions this group also has
---@field permissions string[]

---@class UgGroupSummary
---@field name string
---@field label string
---@field weight integer
---@field inherits? string
---@field members integer

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Repository = UgCore.Internal.Database.Repository
local InternalPermissions = UgCore.Internal.Permissions
local InternalHooks = UgCore.Internal.Hooks
local Events = UgCore.Events
local Errors = UgCore.Enums.Errors
local GroupEvents = UgCore.Enums.Events.Permissions
local GroupHooks = UgCore.Enums.Hooks.Permissions

local GROUPS_KEY = UgCore.Enums.StateBags.Groups
local MAX_BY = 64
local CONSOLE = 0

---@type table<string, UgGroupDefinition>
local definitions = {}

---@type table<string, table<string, boolean>> identifier -> group names
local members = {}

---@param group any
---@param caller string
local function checkGroupName(group, caller)
    if type(group) ~= 'string' or group == '' then
        Utils.Raise(3, 'Permissions.%s expects a group name such as "admin"', caller)
    end
end

---The group and every group it inherits, nearest first. Config validation rules out cycles.
---@param group string
---@return string[]
local function lineage(group)
    local list = {}
    local current = group

    while current and definitions[current] do
        list[#list + 1] = current
        current = definitions[current].inherits
    end

    return list
end

---Groups of an identifier that exist in config, highest weight first.
---@param identifier string?
---@return string[]
local function groupsOf(identifier)
    local list = {}

    for group in pairs(identifier and members[identifier] or {}) do
        if definitions[group] then
            list[#list + 1] = group
        end
    end

    table.sort(list, function(a, b)
        local weightA, weightB = definitions[a].weight, definitions[b].weight

        if weightA ~= weightB then
            return weightA > weightB
        end

        return a < b
    end)

    return list
end

---@param identifier string?
---@return integer
local function weightOf(identifier)
    local weight = 0

    for _, group in ipairs(groupsOf(identifier)) do
        for _, inherited in ipairs(lineage(group)) do
            weight = math.max(weight, definitions[inherited].weight)
        end
    end

    return weight
end

---@param target any source or identifier
---@return string?
local function identifierOf(target)
    if math.type(target) == 'integer' and target > 0 then
        return UgCore.Identity.GetPrimary(target)
    end

    return InternalPermissions.IsIdentifier(target) and target or nil
end

---@param source integer
local function publishSource(source)
    Player(source).state:set(GROUPS_KEY, groupsOf(UgCore.Identity.GetPrimary(source)), true)
end

---Updates `ug-core:Groups` of every connected player with this identifier.
---@param identifier string
local function publish(identifier)
    for _, player in ipairs(GetPlayers()) do
        local source = math.tointeger(tonumber(player))

        if source and UgCore.Identity.GetPrimary(source) == identifier then
            publishSource(source)
        end
    end
end

---@param identifier string
---@param group string
---@param add boolean
local function applyPrincipal(identifier, group, add)
    ExecuteCommand(('%s identifier.%s group.%s'):format(add and 'add_principal' or 'remove_principal', identifier, group))
end

---Adds the target to a group from config/permissions.lua and applies it right away. MUST run in a thread.
---@param target integer|string source or identifier
---@param group string
---@param by? string who added it, up to 64 characters
---@return boolean ok
---@return UgErrorCode? errorCode `invalid_args` for groups missing from config, `no_permission` when a hook cancelled
function Permissions.AddGroup(target, group, by)
    checkGroupName(group, 'AddGroup')

    local identifier = InternalPermissions.Resolve(target, 'AddGroup')

    if by ~= nil and (type(by) ~= 'string' or #by > MAX_BY) then
        Utils.Raise(2, 'Permissions.AddGroup: "by" MUST be a string of up to %d characters', MAX_BY)
    end

    if not identifier then
        return false, Errors.NotFound
    end

    if not definitions[group] then
        return false, Errors.InvalidArgs
    end

    if members[identifier] and members[identifier][group] then
        return true, nil
    end

    if not InternalHooks.Run(GroupHooks.BeforeGroupAdd, { identifier = identifier, group = group, by = by }) then
        return false, Errors.NoPermission
    end

    local ok = Repository.Update([[
        INSERT INTO `ug_group_members` (`identifier`, `group_name`, `added_by`)
        VALUES (?, ?, NULLIF(?, ''))
        ON DUPLICATE KEY UPDATE `added_by` = VALUES(`added_by`)
    ]], { identifier, group, by or '' })

    if not ok then
        return false, Errors.InternalError
    end

    members[identifier] = members[identifier] or {}
    members[identifier][group] = true
    applyPrincipal(identifier, group, true)
    publish(identifier)
    Events.Emit(GroupEvents.GroupAdded, identifier, group, by)

    return true, nil
end

---Removes the target from a group. Also removes stored memberships of groups no longer in config. MUST run in a thread.
---@param target integer|string source or identifier
---@param group string
---@return boolean ok
---@return boolean? removed false when the target was not a member
---@return UgErrorCode? errorCode
function Permissions.RemoveGroup(target, group)
    checkGroupName(group, 'RemoveGroup')

    local identifier = InternalPermissions.Resolve(target, 'RemoveGroup')

    if not identifier then
        return false, nil, Errors.NotFound
    end

    local member = members[identifier] ~= nil and members[identifier][group] == true

    if member and not InternalHooks.Run(GroupHooks.BeforeGroupRemove, { identifier = identifier, group = group }) then
        return false, nil, Errors.NoPermission
    end

    local ok, removed = Repository.Update('DELETE FROM `ug_group_members` WHERE `identifier` = ? AND `group_name` = ?', { identifier, group })

    if not ok then
        return false, nil, Errors.InternalError
    end

    if member then
        members[identifier][group] = nil
        applyPrincipal(identifier, group, false)
        publish(identifier)
        Events.Emit(GroupEvents.GroupRemoved, identifier, group)
    end

    return true, member or (removed or 0) > 0, nil
end

---Groups of the target from config/permissions.lua, highest weight first. Inherited groups are not listed.
---@param target integer|string source or identifier
---@return string[]
function Permissions.GetGroups(target)
    return groupsOf(InternalPermissions.Resolve(target, 'GetGroups'))
end

---True when the target is in the group, directly or through inheritance: a founder is also an admin.
---Only groups managed by ug-core count, not principals from server.cfg.
---@param target integer|string source or identifier
---@param group string
---@return boolean
function Permissions.IsInGroup(target, group)
    checkGroupName(group, 'IsInGroup')

    for _, direct in ipairs(groupsOf(InternalPermissions.Resolve(target, 'IsInGroup'))) do
        for _, inherited in ipairs(lineage(direct)) do
            if inherited == group then
                return true
            end
        end
    end

    return false
end

---Highest weight of the target's groups, 0 without groups.
---@param target integer|string source or identifier
---@return integer
function Permissions.GetWeight(target)
    return weightOf(InternalPermissions.Resolve(target, 'GetWeight'))
end

---True when `actor` outranks `target`: a strictly higher weight. The console (source 0) outranks everyone.
---@param actor integer|string source, identifier or 0 for the console
---@param target integer|string source or identifier
---@return boolean
function Permissions.CanTarget(actor, target)
    if actor == CONSOLE then
        return true
    end

    if target == CONSOLE then
        return false
    end

    local actorId, targetId = identifierOf(actor), identifierOf(target)

    if actorId == nil and math.type(actor) ~= 'integer' then
        InternalPermissions.Resolve(actor, 'CanTarget')
    end

    if targetId == nil and math.type(target) ~= 'integer' then
        InternalPermissions.Resolve(target, 'CanTarget')
    end

    return weightOf(actorId) > weightOf(targetId)
end

---@param group string
---@return UgGroupDefinition? definition a copy, nil for groups missing from config
function Permissions.GetGroupDefinition(group)
    checkGroupName(group, 'GetGroupDefinition')

    local definition = definitions[group]

    return definition and Utils.Table.DeepCopy(definition) or nil
end

---@return UgGroupSummary[] highest weight first
function Groups.GetSummary()
    local counts = {}

    for _, groups in pairs(members) do
        for group in pairs(groups) do
            counts[group] = (counts[group] or 0) + 1
        end
    end

    local list = {}

    for name, definition in pairs(definitions) do
        list[#list + 1] = { name = name, label = definition.label, weight = definition.weight, inherits = definition.inherits, members = counts[name] or 0 }
    end

    table.sort(list, function(a, b)
        if a.weight ~= b.weight then
            return a.weight > b.weight
        end

        return a.name < b.name
    end)

    return list
end

---Applies group ACEs and inheritance, then every stored member.
---@param ctx UgModuleContext
function Groups.Init(ctx)
    definitions = (ctx.config or {}).groups or {}
    members = {}

    for name, definition in pairs(definitions) do
        for _, permission in ipairs(definition.permissions) do
            ExecuteCommand(('add_ace group.%s %s allow'):format(name, permission))
        end

        if definition.inherits then
            ExecuteCommand(('add_principal group.%s group.%s'):format(name, definition.inherits))
        end
    end

    local ok, rows = Repository.Query('SELECT `identifier`, `group_name` FROM `ug_group_members`')

    if not ok or not rows then
        error('cannot load ug_group_members', 0)
    end

    local applied, unknown = 0, 0

    for _, row in ipairs(rows) do
        local identifier, group = row.identifier, row.group_name

        if InternalPermissions.IsIdentifier(identifier) and type(group) == 'string' then
            members[identifier] = members[identifier] or {}
            members[identifier][group] = true

            if definitions[group] then
                applyPrincipal(identifier, group, true)
                applied = applied + 1
            else
                unknown = unknown + 1
            end
        else
            Logger.Warn('Permissions: skipped an invalid member in ug_group_members.')
        end
    end

    if unknown > 0 then
        ctx.logger.Warn('%d member(s) of groups missing from config/permissions.lua are kept but not applied.', unknown)
    end

    AddEventHandler('playerJoining', function()
        local joined = math.tointeger(tonumber(source))

        if joined then
            publishSource(joined)
        end
    end)

    for _, player in ipairs(GetPlayers()) do
        local connected = math.tointeger(tonumber(player))

        if connected then
            publishSource(connected)
        end
    end

    ctx.logger.Debug('applied %d group member(s).', applied)
end
