--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Sessions are routing buckets owned by ug-core, allocated from 1000 up. A player is in at most one session.
---Bucket 0 is the shared world.
---@class UgCore.Sessions
local Sessions = {}
UgCore.Sessions = Sessions

---@class UgCore.Internal.Sessions
local InternalSessions = {}
UgCore.Internal.Sessions = InternalSessions

---@class UgSessionOptions
---@field name? string up to 64 characters
---@field lockdown? 'strict'|'relaxed'|'inactive' client entity creation, defaults to strict
---@field population? boolean ambient peds and vehicles, defaults to false
---@field persistent? boolean keeps the session when the last member leaves, defaults to false

---@class UgSession
---@field id integer
---@field name? string
---@field bucket integer
---@field lockdown string
---@field population boolean
---@field persistent boolean
---@field members integer[]

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local InternalHooks = UgCore.Internal.Hooks
local Errors = UgCore.Enums.Errors
local SessionEvents = UgCore.Enums.Events.Sessions
local SessionHooks = UgCore.Enums.Hooks.Sessions

local FIRST_BUCKET = 1000
local WORLD_BUCKET = 0
local MAX_NAME = 64
local STATE_KEY = UgCore.Enums.StateBags.Session
local LOCKDOWN = { strict = true, relaxed = true, inactive = true }

---@class UgSessionRecord
---@field id integer
---@field name? string
---@field bucket integer
---@field lockdown string
---@field population boolean
---@field persistent boolean
---@field members table<integer, boolean>

---@type table<integer, UgSessionRecord>
local sessions = {}

---@type table<integer, integer> source -> session id
local memberOf = {}

local lastId = 0

---@param record UgSessionRecord
---@return UgSession
local function snapshot(record)
    local members = {}

    for source in pairs(record.members) do
        members[#members + 1] = source
    end

    table.sort(members)

    return {
        id = record.id,
        name = record.name,
        bucket = record.bucket,
        lockdown = record.lockdown,
        population = record.population,
        persistent = record.persistent,
        members = members,
    }
end

---@param source integer
---@param bucket integer
---@param sessionId integer?
local function move(source, bucket, sessionId)
    SetPlayerRoutingBucket(tostring(source), bucket)
    Player(source).state:set(STATE_KEY, sessionId, true)
end

---@param options? UgSessionOptions
---@return boolean ok
---@return integer? sessionId
---@return UgErrorCode? errorCode
function Sessions.Create(options)
    options = options or {}

    if type(options) ~= 'table' then
        Utils.Raise(2, 'Sessions.Create expects options as a table')
    end

    if options.name ~= nil and (type(options.name) ~= 'string' or #options.name > MAX_NAME) then
        Utils.Raise(2, 'Sessions.Create: name MUST be a string of up to %d characters', MAX_NAME)
    end

    local lockdown = options.lockdown or 'strict'

    if not LOCKDOWN[lockdown] then
        Utils.Raise(2, 'Sessions.Create: lockdown MUST be "strict", "relaxed" or "inactive"')
    end

    lastId = lastId + 1

    local record = {
        id = lastId,
        name = options.name,
        bucket = FIRST_BUCKET + lastId - 1,
        lockdown = lockdown,
        population = options.population == true,
        persistent = options.persistent == true,
        members = {},
    }

    SetRoutingBucketEntityLockdownMode(record.bucket, lockdown)
    SetRoutingBucketPopulationEnabled(record.bucket, record.population)

    sessions[record.id] = record
    Events.Emit(SessionEvents.Created, record.id)

    return true, record.id, nil
end

---Moves every member back to the shared world.
---@param sessionId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Sessions.Destroy(sessionId)
    local record = sessions[sessionId]

    if not record then
        return false, Errors.NotFound
    end

    -- Persistent while emptying, so the last Leave does not destroy it a second time.
    record.persistent = true

    for source in pairs(record.members) do
        Sessions.Leave(source)
    end

    sessions[sessionId] = nil
    Events.Emit(SessionEvents.Destroyed, sessionId)

    return true, nil
end

---Leaves the current session first. `Sessions:BeforeJoin` MAY cancel.
---@param source integer
---@param sessionId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Sessions.Join(source, sessionId)
    local record = sessions[sessionId]

    if not record then
        return false, Errors.NotFound
    end

    if not UgCore.Players.Get(source) then
        return false, Errors.NotLoaded
    end

    if memberOf[source] == sessionId then
        return true, nil
    end

    if not InternalHooks.Run(SessionHooks.BeforeJoin, { source = source, sessionId = sessionId }) then
        return false, Errors.NoPermission
    end

    if memberOf[source] then
        Sessions.Leave(source)
    end

    record.members[source] = true
    memberOf[source] = sessionId
    move(source, record.bucket, sessionId)
    Events.Emit(SessionEvents.Joined, source, sessionId)

    return true, nil
end

---Back to the shared world. An empty session that is not persistent is destroyed.
---@param source integer
---@return boolean ok
---@return UgErrorCode? errorCode `not_found` when the player is in no session
function Sessions.Leave(source)
    local sessionId = memberOf[source]
    local record = sessionId and sessions[sessionId]

    if not sessionId or not record then
        return false, Errors.NotFound
    end

    record.members[source] = nil
    memberOf[source] = nil

    if UgCore.Players.Get(source) then
        move(source, WORLD_BUCKET, nil)
    end

    Events.Emit(SessionEvents.Left, source, sessionId)

    if not record.persistent and next(record.members) == nil then
        sessions[sessionId] = nil
        Events.Emit(SessionEvents.Destroyed, sessionId)
    end

    return true, nil
end

---@param sessionId integer
---@return UgSession?
function Sessions.Get(sessionId)
    local record = sessions[sessionId]

    return record and snapshot(record) or nil
end

---@param sessionId integer
---@return integer[] sources of the members, none for unknown sessions
function Sessions.GetMembers(sessionId)
    local record = sessions[sessionId]

    return record and snapshot(record).members or {}
end

---@param source integer
---@return integer? sessionId
function Sessions.GetSession(source)
    return memberOf[source]
end

---@param ctx UgModuleContext
function InternalSessions.Init(ctx)
    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        if dropped and memberOf[dropped] then
            Sessions.Leave(dropped)
        end
    end)

    ctx.logger.Debug('sessions use routing buckets from %d.', FIRST_BUCKET)
end

---Sends every member back to the shared world.
---@param ctx UgModuleContext
function InternalSessions.Stop(ctx)
    for sessionId in pairs(sessions) do
        Sessions.Destroy(sessionId)
    end

    ctx.logger.Debug('sessions closed.')
end
