--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Identifiers and bans. A ban covers every identifier of the player except `ip:`.
---@class UgCore.Identity
local Identity = {}
UgCore.Identity = Identity

---@class UgCore.Internal.Identity
local InternalIdentity = {}
UgCore.Internal.Identity = InternalIdentity

local Utils = UgCore.Internal.Utils
local Repository = UgCore.Internal.Database.Repository
local Errors = UgCore.Enums.Errors

local IDENTIFIER_PATTERN = '^%a[%w]*:%w+$'
local EXCLUDED_TYPES = { ip = true }
local MAX_REASON = 255
local MAX_BY = 64
local BAN_MESSAGE = 'You are banned from this server.'
local BAN_UNTIL = 'You are banned from this server until {date} UTC.'
local MISSING_IDENTIFIER = 'A {type} identifier is required to join this server.'
local UNVERIFIED = 'Your connection could not be verified. Try again later.'

local ACTIVE = '`b`.`revoked_at` IS NULL AND (`b`.`expires_at` IS NULL OR `b`.`expires_at` > NOW())'

---@type UgModuleContext?
local context = nil

---@param source any
---@return boolean
local function isSource(source)
    return math.type(source) == 'integer' and source > 0
end

---@return string
local function primaryType()
    return UgCore.Config.Get('identity', 'primaryIdentifier')
end

---@param list string[]
---@return string[] identifiers a ban applies to
local function bannable(list)
    local identifiers = {}

    for _, identifier in ipairs(list) do
        local kind = type(identifier) == 'string' and identifier:match('^(%a[%w]*):') or nil

        if kind and not EXCLUDED_TYPES[kind] and identifier:find(IDENTIFIER_PATTERN) then
            identifiers[#identifiers + 1] = identifier
        end
    end

    return identifiers
end

---Identifiers a ban or unban applies to. Raises on invalid targets.
---@param target any source, identifier or array of identifiers
---@param caller string
---@return string[]
local function resolve(target, caller)
    if isSource(target) then
        return bannable(Identity.GetIdentifiers(target))
    end

    if type(target) == 'string' and target:find(IDENTIFIER_PATTERN) then
        return { target }
    end

    if type(target) == 'table' and #target > 0 then
        return bannable(target)
    end

    Utils.Raise(3, 'Identity.%s expects a player source, an identifier such as "license:abc" or an array of them', caller)

    return {}
end

---@param count integer
---@return string
local function placeholders(count)
    return string.rep('?', count, ', ')
end

---Every identifier of a connected or connecting player, such as `license:abc`.
---@param source integer
---@return string[]
function Identity.GetIdentifiers(source)
    local player = tostring(source)
    local identifiers = {}

    for index = 0, GetNumPlayerIdentifiers(player) - 1 do
        local identifier = GetPlayerIdentifier(player, index)

        if identifier then
            identifiers[#identifiers + 1] = identifier
        end
    end

    return identifiers
end

---The identifier of the type set in config/identity.lua.
---@param source integer
---@return string?
function Identity.GetPrimary(source)
    local identifier = GetPlayerIdentifierByType(tostring(source), primaryType())

    if type(identifier) ~= 'string' or identifier == '' then
        return nil
    end

    return identifier
end

---MUST run in a thread.
---@param target integer|string|string[] source, identifier or identifiers
---@return boolean banned
---@return UgBan? ban the active ban that lasts longest
---@return UgErrorCode? errorCode `internal_error` when the database failed
function Identity.IsBanned(target)
    local identifiers = resolve(target, 'IsBanned')

    if #identifiers == 0 then
        return false, nil, nil
    end

    local ok, row = Repository.Single(([[
        SELECT `b`.`id`, `b`.`reason`, UNIX_TIMESTAMP(`b`.`expires_at`) AS `expiresAt`, UNIX_TIMESTAMP(`b`.`created_at`) AS `createdAt`
        FROM `ug_bans` `b`
        JOIN `ug_ban_identifiers` `i` ON `i`.`ban_id` = `b`.`id`
        WHERE `i`.`identifier` IN (%s) AND %s
        ORDER BY `b`.`expires_at` IS NULL DESC, `b`.`expires_at` DESC
        LIMIT 1
    ]]):format(placeholders(#identifiers), ACTIVE), identifiers)

    if not ok then
        return false, nil, Errors.InternalError
    end

    if not row then
        return false, nil, nil
    end

    return true, {
        id = row.id,
        reason = row.reason,
        expiresAt = row.expiresAt and math.tointeger(row.expiresAt) or nil,
        createdAt = math.tointeger(row.createdAt) or 0,
    }, nil
end

---Bans every identifier of the target. MUST run in a thread.
---Pass identifiers instead of a source when the player is already dropped.
---@param target integer|string|string[] source, identifier or identifiers
---@param options? UgBanOptions
---@return boolean ok
---@return integer? banId
---@return UgErrorCode? errorCode
function Identity.Ban(target, options)
    local identifiers = resolve(target, 'Ban')

    options = options or {}

    if type(options) ~= 'table' then
        Utils.Raise(2, 'Identity.Ban expects options as a table')
    end

    local reason, by, duration = options.reason, options.by, options.duration

    if reason ~= nil and (type(reason) ~= 'string' or #reason > MAX_REASON) then
        Utils.Raise(2, 'Identity.Ban: "reason" MUST be a string of up to %d characters', MAX_REASON)
    end

    if by ~= nil and (type(by) ~= 'string' or #by > MAX_BY) then
        Utils.Raise(2, 'Identity.Ban: "by" MUST be a string of up to %d characters', MAX_BY)
    end

    if duration ~= nil and (math.type(duration) ~= 'integer' or duration < 1) then
        Utils.Raise(2, 'Identity.Ban: "duration" MUST be a positive integer of seconds')
    end

    if #identifiers == 0 then
        return false, nil, Errors.NotFound
    end

    local ok, banId = Repository.Insert([[
        INSERT INTO `ug_bans` (`reason`, `banned_by`, `expires_at`)
        VALUES (NULLIF(?, ''), NULLIF(?, ''), IF(? = 0, NULL, DATE_ADD(NOW(), INTERVAL ? SECOND)))
    ]], { reason or '', by or '', duration or 0, duration or 0 })

    if not ok or not banId then
        return false, nil, Errors.InternalError
    end

    local queries = {}

    for index, identifier in ipairs(identifiers) do
        queries[index] = {
            query = 'INSERT INTO `ug_ban_identifiers` (`ban_id`, `identifier`) VALUES (?, ?)',
            values = { banId, identifier },
        }
    end

    if not Repository.Transaction(queries) then
        Repository.Update('UPDATE `ug_bans` SET `revoked_at` = NOW() WHERE `id` = ?', { banId })
        return false, nil, Errors.InternalError
    end

    if context then
        context.logger.Info('banned %s (ban %d, %s).', identifiers[1], banId, duration and (duration .. ' s') or 'permanent')
    end

    if isSource(target) and options.kick ~= false then
        DropPlayer(tostring(target), Utils.Text('identity.banned', BAN_MESSAGE))
    end

    return true, banId, nil
end

---Lifts every active ban covering the target. MUST run in a thread.
---@param target integer|string|string[] source, identifier or identifiers
---@return boolean ok
---@return integer? count of lifted bans
---@return UgErrorCode? errorCode
function Identity.Unban(target)
    local identifiers = resolve(target, 'Unban')

    if #identifiers == 0 then
        return true, 0, nil
    end

    local ok, count = Repository.Update(([[
        UPDATE `ug_bans` `b`
        SET `b`.`revoked_at` = NOW()
        WHERE %s AND `b`.`id` IN (
            SELECT `ban_id` FROM `ug_ban_identifiers` WHERE `identifier` IN (%s)
        )
    ]]):format(ACTIVE, placeholders(#identifiers)), identifiers)

    if not ok then
        return false, nil, Errors.InternalError
    end

    return true, count or 0, nil
end

---@param ban UgBan
---@return string
local function banMessage(ban)
    if ban.expiresAt then
        return Utils.Text('identity.bannedUntil', BAN_UNTIL, { date = os.date('!%Y-%m-%d %H:%M', ban.expiresAt) })
    end

    return Utils.Text('identity.banned', BAN_MESSAGE)
end

---@param ctx UgModuleContext
function InternalIdentity.Init(ctx)
    context = ctx

    -- Deferral calls MUST be at least one tick apart (Cfx playerConnecting docs).
    AddEventHandler('playerConnecting', function(_, _, deferrals)
        local connecting = math.tointeger(tonumber(source))

        deferrals.defer()
        Wait(0)

        if not connecting or not Identity.GetPrimary(connecting) then
            deferrals.done(Utils.Text('identity.missingIdentifier', MISSING_IDENTIFIER, { type = primaryType() }))
            return
        end

        local banned, ban, errorCode = Identity.IsBanned(connecting)

        Wait(0)

        if errorCode then
            deferrals.done(Utils.Text('identity.unverified', UNVERIFIED))
        elseif banned and ban then
            deferrals.done(banMessage(ban))
        else
            deferrals.done()
        end
    end)
end
