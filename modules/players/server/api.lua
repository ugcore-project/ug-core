--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Connected players. Metadata lives for the session. Keys set with `replicate` reach every client.
---@class UgCore.Players
local Players = {}
UgCore.Players = Players

---@class UgCore.Internal.Players
local InternalPlayers = {}
UgCore.Internal.Players = InternalPlayers

---@class UgPlayerRecord
---@field source integer
---@field name string
---@field identifier string
---@field characterId? integer
---@field joinedAt integer
---@field metadata table<string, any>
---@field replicated table<string, boolean>

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local PlayerEvents = UgCore.Enums.Events.Players
local Errors = UgCore.Enums.Errors

local LOADED_KEY = UgCore.Enums.StateBags.Loaded
local PLAYER_KEY = UgCore.Enums.StateBags.Player
local METADATA_KEY = UgCore.Enums.StateBags.Metadata
local KEY_PATTERN = '^%l[%w]*$'
local MAX_KEY = 32
local MAX_STRING = 1024
local MAX_ENTRIES = 256
local MAX_DEPTH = 8
local MAX_REASON = 255
local KICK_MESSAGE = 'You were disconnected from the server.'

---@type table<integer, UgPlayerRecord>
local records = {}

---@type UgModuleContext?
local context = nil

---@param source any
---@return boolean
local function isSource(source)
    return math.type(source) == 'integer' and source > 0
end

---@param record UgPlayerRecord
---@return UgPlayer
local function snapshot(record)
    return UgCore.Internal.PlayerObject.Wrap({
        source = record.source,
        name = record.name,
        identifier = record.identifier,
        characterId = record.characterId,
        joinedAt = record.joinedAt,
    })
end

---@param record UgPlayerRecord
local function publishPlayer(record)
    Player(record.source).state:set(PLAYER_KEY, { name = record.name, characterId = record.characterId }, true)
end

---@param record UgPlayerRecord
local function publishMetadata(record)
    local public = {}

    for key in pairs(record.replicated) do
        public[key] = record.metadata[key]
    end

    Player(record.source).state:set(METADATA_KEY, public, true)
end

---Metadata MUST be data: booleans, finite numbers, bounded strings and bounded tables of those.
---@param value any
---@param depth integer
---@param budget { entries: integer }
---@return boolean
local function isData(value, depth, budget)
    local kind = type(value)

    if kind == 'boolean' or kind == 'vector2' or kind == 'vector3' or kind == 'vector4' then
        return true
    end

    if kind == 'number' then
        return value == value and value ~= math.huge and value ~= -math.huge
    end

    if kind == 'string' then
        return #value <= MAX_STRING
    end

    if kind ~= 'table' or depth > MAX_DEPTH or getmetatable(value) ~= nil then
        return false
    end

    for key, entry in pairs(value) do
        budget.entries = budget.entries + 1

        if budget.entries > MAX_ENTRIES or (type(key) ~= 'string' and math.type(key) ~= 'integer') then
            return false
        end

        if not isData(entry, depth + 1, budget) then
            return false
        end
    end

    return true
end

---@param source integer
local function add(source)
    if records[source] then
        return
    end

    local identifier = UgCore.Identity.GetPrimary(source)

    if not identifier then
        return
    end

    local record = {
        source = source,
        name = GetPlayerName(tostring(source)) or ('Player ' .. source),
        identifier = identifier,
        joinedAt = os.time(),
        metadata = {},
        replicated = {},
    }

    records[source] = record
    publishPlayer(record)

    if not UgCore.Modules.IsEnabled('characters') then
        InternalPlayers.SetLoaded(source, true)
    end
end

---@param source integer
---@return UgPlayer?
function Players.Get(source)
    local record = records[source]

    return record and snapshot(record) or nil
end

---@return UgPlayer[] sorted by source
function Players.GetAll()
    local list = {}

    for _, record in pairs(records) do
        list[#list + 1] = snapshot(record)
    end

    table.sort(list, function(a, b)
        return a.source < b.source
    end)

    return list
end

---@param identifier string
---@return UgPlayer?
function Players.GetByIdentifier(identifier)
    for _, record in pairs(records) do
        if record.identifier == identifier then
            return snapshot(record)
        end
    end

    return nil
end

---@param characterId integer
---@return UgPlayer?
function Players.GetByCharacterId(characterId)
    for _, record in pairs(records) do
        if record.characterId == characterId then
            return snapshot(record)
        end
    end

    return nil
end

---Session metadata. `nil` deletes the key. Replicated keys reach every client, so they MUST NOT hold secrets.
---@param source integer
---@param key string camelCase
---@param value any
---@param replicate? boolean
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.SetMetadata(source, key, value, replicate)
    if type(key) ~= 'string' or #key > MAX_KEY or not key:find(KEY_PATTERN) then
        Utils.Raise(2, 'Players.SetMetadata expects a camelCase key of up to %d characters', MAX_KEY)
    end

    if value ~= nil and not isData(value, 1, { entries = 0 }) then
        Utils.Raise(2, 'Players.SetMetadata: value MUST be data: booleans, finite numbers, strings and bounded tables')
    end

    local record = records[source]

    if not record then
        return false, Errors.NotFound
    end

    record.metadata[key] = Utils.Table.DeepCopy(value)

    local wasReplicated = record.replicated[key] == true

    record.replicated[key] = value ~= nil and replicate == true or nil

    if wasReplicated or record.replicated[key] then
        publishMetadata(record)
    end

    return true, nil
end

---@param source integer
---@param key? string every key when nil
---@return any
function Players.GetMetadata(source, key)
    local record = records[source]

    if not record then
        return nil
    end

    if key == nil then
        return Utils.Table.DeepCopy(record.metadata)
    end

    return Utils.Table.DeepCopy(record.metadata[key])
end

---@param source integer
---@param reason? string shown to the player, a generic message when nil
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.Kick(source, reason)
    if reason ~= nil and (type(reason) ~= 'string' or #reason > MAX_REASON) then
        Utils.Raise(2, 'Players.Kick: reason MUST be a string of up to %d characters', MAX_REASON)
    end

    if not records[source] then
        return false, Errors.NotFound
    end

    DropPlayer(tostring(source), reason or Utils.Text('players.kicked', KICK_MESSAGE))

    return true, nil
end

---Sets `ug-core:Loaded`. True emits `ug-core:Players:Loaded`. Called at join, or by the characters module.
---@param source integer
---@param loaded boolean
---@return boolean found
function InternalPlayers.SetLoaded(source, loaded)
    if not records[source] then
        return false
    end

    Player(source).state:set(LOADED_KEY, loaded == true, true)

    if loaded then
        Events.Emit(PlayerEvents.Loaded, source)
    end

    return true
end

---@param source integer
---@param characterId? integer
---@return boolean found
function InternalPlayers.SetCharacter(source, characterId)
    local record = records[source]

    if not record then
        return false
    end

    record.characterId = characterId
    publishPlayer(record)

    return true
end

---@param source integer
---@return boolean
function InternalPlayers.Exists(source)
    return isSource(source) and records[source] ~= nil
end

---@param ctx UgModuleContext
function InternalPlayers.Init(ctx)
    context = ctx

    AddEventHandler('playerJoining', function()
        local joined = math.tointeger(tonumber(source))

        if joined then
            add(joined)
        end
    end)

    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        -- Removed a tick later, so other drop handlers, such as the characters save, still read the player.
        if dropped then
            SetTimeout(0, function()
                records[dropped] = nil
            end)
        end
    end)
end

---Adds players connected before ug-core started.
---@param ctx UgModuleContext
function InternalPlayers.Start(ctx)
    for _, player in ipairs(GetPlayers()) do
        local source = math.tointeger(tonumber(player))

        if source then
            add(source)
        end
    end

    ctx.logger.Debug('%d players online.', #GetPlayers())
end

---@return UgModuleContext?
function InternalPlayers.GetContext()
    return context
end
