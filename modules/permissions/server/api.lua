--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Permissions granted per identifier, stored in `ug_permissions` and applied as ACEs on `identifier.<id>`.
---`Has` is a plain ACE check, so ACEs from server.cfg count too.
---@class UgCore.Permissions
local Permissions = {}
UgCore.Permissions = Permissions

---@class UgCore.Internal.Permissions
local InternalPermissions = {}
UgCore.Internal.Permissions = InternalPermissions

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Repository = UgCore.Internal.Database.Repository
local Errors = UgCore.Enums.Errors

-- Both end up in ExecuteCommand, so they MUST stay this strict.
local PERMISSION_PATTERN = '^%a[%w%._%-]*$'
local IDENTIFIER_PATTERN = '^%a[%w]*:%w+$'
local MAX_LENGTH = 64
local SELF_PRINCIPAL = 'resource.' .. GetCurrentResourceName()

---@type table<string, table<string, boolean>> identifier -> permissions
local grants = {}

---@param permission any
---@param caller string
local function checkPermission(permission, caller)
    if type(permission) ~= 'string' or #permission > MAX_LENGTH or not permission:find(PERMISSION_PATTERN) then
        Utils.Raise(3, 'Permissions.%s expects a permission of letters, digits, dots, dashes and underscores, such as "ug.admin"', caller)
    end
end

---@param target any source or identifier
---@param caller string
---@return string? identifier nil when the source has no primary identifier
local function resolve(target, caller)
    if math.type(target) == 'integer' and target > 0 then
        local identifier = UgCore.Identity.GetPrimary(target)

        return identifier and identifier:find(IDENTIFIER_PATTERN) and identifier or nil
    end

    if type(target) == 'string' and #target <= MAX_LENGTH and target:find(IDENTIFIER_PATTERN) then
        return target
    end

    Utils.Raise(3, 'Permissions.%s expects a player source or an identifier such as "license:abc"', caller)

    return nil
end

---Raises like the public functions, at the caller of the function that calls it.
InternalPermissions.Resolve = resolve

---@param value any
---@return boolean
function InternalPermissions.IsIdentifier(value)
    return type(value) == 'string' and #value <= MAX_LENGTH and value:find(IDENTIFIER_PATTERN) ~= nil
end

---@param identifier string
---@param permission string
---@param allow boolean
local function applyAce(identifier, permission, allow)
    ExecuteCommand(('%s identifier.%s %s allow'):format(allow and 'add_ace' or 'remove_ace', identifier, permission))
end

---@param source integer
---@param permission string
---@return boolean
function Permissions.Has(source, permission)
    checkPermission(permission, 'Has')

    if math.type(source) ~= 'integer' or source < 1 then
        Utils.Raise(2, 'Permissions.Has expects a player source')
    end

    return IsPlayerAceAllowed(tostring(source), permission)
end

---Grants and applies the ACE right away. MUST run in a thread.
---@param target integer|string source or identifier
---@param permission string
---@param by? string who granted it, up to 64 characters
---@return boolean ok
---@return UgErrorCode? errorCode
function Permissions.Grant(target, permission, by)
    checkPermission(permission, 'Grant')

    local identifier = resolve(target, 'Grant')

    if by ~= nil and (type(by) ~= 'string' or #by > MAX_LENGTH) then
        Utils.Raise(2, 'Permissions.Grant: "by" MUST be a string of up to %d characters', MAX_LENGTH)
    end

    if not identifier then
        return false, Errors.NotFound
    end

    local ok = Repository.Update([[
        INSERT INTO `ug_permissions` (`identifier`, `permission`, `granted_by`)
        VALUES (?, ?, NULLIF(?, ''))
        ON DUPLICATE KEY UPDATE `granted_by` = VALUES(`granted_by`)
    ]], { identifier, permission, by or '' })

    if not ok then
        return false, Errors.InternalError
    end

    grants[identifier] = grants[identifier] or {}
    grants[identifier][permission] = true
    applyAce(identifier, permission, true)

    return true, nil
end

---Revokes a permission granted with Grant. ACEs from server.cfg stay. MUST run in a thread.
---@param target integer|string source or identifier
---@param permission string
---@return boolean ok
---@return boolean? removed false when it was not granted
---@return UgErrorCode? errorCode
function Permissions.Revoke(target, permission)
    checkPermission(permission, 'Revoke')

    local identifier = resolve(target, 'Revoke')

    if not identifier then
        return false, nil, Errors.NotFound
    end

    local ok, removed = Repository.Update('DELETE FROM `ug_permissions` WHERE `identifier` = ? AND `permission` = ?', { identifier, permission })

    if not ok then
        return false, nil, Errors.InternalError
    end

    if grants[identifier] then
        grants[identifier][permission] = nil
    end

    applyAce(identifier, permission, false)

    return true, (removed or 0) > 0, nil
end

---Permissions granted with Grant, sorted. ACEs from server.cfg are not listed.
---@param target integer|string source or identifier
---@return string[]
function Permissions.GetAll(target)
    local identifier = resolve(target, 'GetAll')
    local list = {}

    for permission in pairs(identifier and grants[identifier] or {}) do
        list[#list + 1] = permission
    end

    table.sort(list)

    return list
end

---Loads every grant and applies its ACE.
---@param ctx UgModuleContext
function InternalPermissions.Init(ctx)
    if not IsPrincipalAceAllowed(SELF_PRINCIPAL, 'command.add_ace') then
        ctx.logger.Error('ug-core cannot run add_ace. Add `add_ace %s command allow` to server.cfg.', SELF_PRINCIPAL)
    end

    local ok, rows = Repository.Query('SELECT `identifier`, `permission` FROM `ug_permissions`')

    if not ok or not rows then
        error('cannot load ug_permissions', 0)
    end

    grants = {}

    for _, row in ipairs(rows) do
        local identifier, permission = row.identifier, row.permission

        if type(identifier) == 'string' and identifier:find(IDENTIFIER_PATTERN) and type(permission) == 'string' and permission:find(PERMISSION_PATTERN) then
            grants[identifier] = grants[identifier] or {}
            grants[identifier][permission] = true
            applyAce(identifier, permission, true)
        else
            Logger.Warn('Permissions: skipped an invalid grant in ug_permissions.')
        end
    end

    ctx.logger.Debug('applied %d grants.', #rows)
end
