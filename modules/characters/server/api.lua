--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Characters of a player, keyed by the primary identifier. Delete is a soft delete.
---Every function that touches the database MUST run in a thread.
---@class UgCore.Characters
local Characters = {}
UgCore.Characters = Characters

---@class UgCore.Internal.Characters
local InternalCharacters = {}
UgCore.Internal.Characters = InternalCharacters

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Schema = UgCore.Schema
local Repository = UgCore.Internal.Database.Repository
local InternalHooks = UgCore.Internal.Hooks
local InternalPlayers = UgCore.Internal.Players
local InternalDeath = UgCore.Internal.Death
local Errors = UgCore.Enums.Errors
local CharacterEvents = UgCore.Enums.Events.Characters
local CharacterHooks = UgCore.Enums.Hooks.Characters
local States = UgCore.Enums.DeathState

local MAX_DATA_BYTES = 16384
local NAME_RULE = Schema.String({ min = 1, max = 64 })

local COLUMNS = '`id`, `name`, `data`, `position`, `death`, UNIX_TIMESTAMP(`created_at`) AS `createdAt`, UNIX_TIMESTAMP(`last_played`) AS `lastPlayed`'

---@type table<integer, UgCharacter> source -> loaded character
local active = {}

---@type UgModuleContext?
local context = nil

---@class UgCharacterParticipant
---@field create? fun(source: integer, characterId: integer): boolean
---@field load? fun(source: integer, characterId: integer): boolean
---@field unload? fun(source: integer, characterId: integer)

---Module steps run when a character is created, loaded or unloaded, before the matching event.
---@type UgCharacterParticipant[]
local participants = {}

---@param text any
---@return table
local function decode(text)
    if type(text) ~= 'string' then
        return {}
    end

    local ok, value = pcall(json.decode, text)

    return ok and type(value) == 'table' and value or {}
end

---@param data any
---@return string? text nil when not encodable or too large
local function encode(data)
    if data == nil then
        return '{}'
    end

    if type(data) ~= 'table' then
        return nil
    end

    local ok, text = pcall(json.encode, data)

    if not ok or type(text) ~= 'string' or #text > MAX_DATA_BYTES then
        return nil
    end

    return text
end

---@param value number
---@return boolean
local function isFinite(value)
    return type(value) == 'number' and value == value and value > -math.huge and value < math.huge
end

---@param text any stored JSON
---@return vector4?
local function decodePosition(text)
    local value = type(text) == 'string' and decode(text) or {}

    if not (isFinite(value.x) and isFinite(value.y) and isFinite(value.z) and isFinite(value.heading)) then
        return nil
    end

    return vector4(value.x, value.y, value.z, value.heading)
end

---@return boolean
local function persistsDeath()
    return UgCore.Config.Get('players', 'persistDeathState') == true
end

---The saved death state, so a selection screen knows before loading. Alive when nothing is saved or saving is off.
---@param text any stored JSON
---@return UgDeathState
local function deathStateOf(text)
    local state = persistsDeath() and decode(text).state

    if state == States.Downed then
        return States.Downed
    end

    if state == States.Dead then
        return States.Dead
    end

    return States.Alive
end

---@param row table
---@return UgCharacter
local function toCharacter(row)
    return {
        id = math.tointeger(row.id) or 0,
        name = row.name,
        data = decode(row.data),
        position = decodePosition(row.position),
        deathState = deathStateOf(row.death),
        createdAt = math.tointeger(row.createdAt) or 0,
        lastPlayed = row.lastPlayed and math.tointeger(row.lastPlayed) or nil,
    }
end

---@param source integer
---@return string? identifier
local function identifierOf(source)
    local player = UgCore.Players.Get(source)

    return player and player.identifier or nil
end

---@param value number
---@return number
local function round(value)
    return math.floor(value * 100 + 0.5) / 100
end

---The ped position, read on the server. Nil without a ped, or at the map origin where a ped sits before it spawns.
---@param source integer
---@return { x: number, y: number, z: number, heading: number }?
local function positionOf(source)
    if UgCore.Config.Get('characters', 'persistPosition') ~= true then
        return nil
    end

    local ped = GetPlayerPed(tostring(source))

    if not ped or ped == 0 then
        return nil
    end

    local coords = GetEntityCoords(ped)

    if math.abs(coords.x) < 1 and math.abs(coords.y) < 1 then
        return nil
    end

    return { x = round(coords.x), y = round(coords.y), z = round(coords.z), heading = round(GetEntityHeading(ped)) }
end

---Saves what belongs to the character but lives elsewhere at runtime.
---@param characterId integer
---@param death UgDeathData?
---@param position? { x: number, y: number, z: number, heading: number }
local function save(characterId, death, position)
    if death then
        Repository.Update('UPDATE `ug_characters` SET `death` = ? WHERE `id` = ?', { json.encode(death), characterId })
    end

    if position then
        Repository.Update('UPDATE `ug_characters` SET `position` = ? WHERE `id` = ?', { json.encode(position), characterId })
    end
end

---@param source integer
---@return UgDeathData?
local function exportDeath(source)
    return persistsDeath() and InternalDeath.Export(source) or nil
end

---@param source integer
---@return boolean ok
---@return UgCharacter[]? characters ordered by creation
---@return UgErrorCode? errorCode
function Characters.GetAll(source)
    local identifier = identifierOf(source)

    if not identifier then
        return false, nil, Errors.NotFound
    end

    local ok, rows = Repository.Query(
        ('SELECT %s FROM `ug_characters` WHERE `identifier` = ? AND `deleted_at` IS NULL ORDER BY `id`'):format(COLUMNS),
        { identifier }
    )

    if not ok or not rows then
        return false, nil, Errors.InternalError
    end

    local list = {}

    for index, row in ipairs(rows) do
        list[index] = toCharacter(row)
    end

    return true, list, nil
end

---Input usually comes from a character creator, so invalid input returns `invalid_args` instead of raising.
---@param source integer
---@param input UgCharacterInput
---@return boolean ok
---@return integer? characterId
---@return UgErrorCode? errorCode `no_permission` when the limit is reached or a hook cancelled
function Characters.Create(source, input)
    if type(input) ~= 'table' or not Schema.Check(NAME_RULE, input.name) or not encode(input.data) then
        return false, nil, Errors.InvalidArgs
    end

    local identifier = identifierOf(source)

    if not identifier then
        return false, nil, Errors.NotFound
    end

    local counted, count = Repository.Scalar(
        'SELECT COUNT(*) AS `total` FROM `ug_characters` WHERE `identifier` = ? AND `deleted_at` IS NULL',
        { identifier }
    )

    if not counted then
        return false, nil, Errors.InternalError
    end

    if (count or 0) >= UgCore.Config.Get('characters', 'maxCharacters') then
        return false, nil, Errors.NoPermission
    end

    local proceed, payload = InternalHooks.Run(CharacterHooks.BeforeCreate, { source = source, name = input.name, data = Utils.Table.DeepCopy(input.data or {}) })

    if not proceed then
        return false, nil, Errors.NoPermission
    end

    local data = encode(payload.data)

    if not Schema.Check(NAME_RULE, payload.name) or not data then
        return false, nil, Errors.InvalidArgs
    end

    local inserted, characterId = Repository.Insert(
        'INSERT INTO `ug_characters` (`identifier`, `name`, `data`) VALUES (?, ?, ?)',
        { identifier, payload.name, data }
    )

    if not inserted or not characterId then
        return false, nil, Errors.InternalError
    end

    for _, participant in ipairs(participants) do
        if participant.create and not participant.create(source, characterId) then
            Repository.Update('UPDATE `ug_characters` SET `deleted_at` = NOW() WHERE `id` = ?', { characterId })
            return false, nil, Errors.InternalError
        end
    end

    Events.Emit(CharacterEvents.Created, source, characterId)

    return true, characterId, nil
end

---Soft delete. The loaded character cannot be deleted.
---@param source integer
---@param characterId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Characters.Delete(source, characterId)
    if math.type(characterId) ~= 'integer' then
        return false, Errors.InvalidArgs
    end

    local identifier = identifierOf(source)

    if not identifier then
        return false, Errors.NotFound
    end

    if active[source] and active[source].id == characterId then
        return false, Errors.InvalidArgs
    end

    if not InternalHooks.Run(CharacterHooks.BeforeDelete, { source = source, characterId = characterId }) then
        return false, Errors.NoPermission
    end

    local ok, affected = Repository.Update(
        'UPDATE `ug_characters` SET `deleted_at` = NOW() WHERE `id` = ? AND `identifier` = ? AND `deleted_at` IS NULL',
        { characterId, identifier }
    )

    if not ok then
        return false, Errors.InternalError
    end

    if (affected or 0) == 0 then
        return false, Errors.NotFound
    end

    Events.Emit(CharacterEvents.Deleted, source, characterId)

    return true, nil
end

---Loads an owned character. A loaded character is unloaded first. Restores death state when persisted.
---@param source integer
---@param characterId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Characters.Load(source, characterId)
    if math.type(characterId) ~= 'integer' then
        return false, Errors.InvalidArgs
    end

    local identifier = identifierOf(source)

    if not identifier then
        return false, Errors.NotFound
    end

    local ok, row = Repository.Single(
        ('SELECT %s FROM `ug_characters` WHERE `id` = ? AND `identifier` = ? AND `deleted_at` IS NULL'):format(COLUMNS),
        { characterId, identifier }
    )

    if not ok then
        return false, Errors.InternalError
    end

    if not row then
        return false, Errors.NotFound
    end

    if active[source] then
        Characters.Unload(source)
    end

    local character = toCharacter(row)

    for index, participant in ipairs(participants) do
        if participant.load and not participant.load(source, character.id) then
            for undo = index - 1, 1, -1 do
                if participants[undo].unload then
                    participants[undo].unload(source, character.id)
                end
            end

            return false, Errors.InternalError
        end
    end

    active[source] = character
    InternalPlayers.SetCharacter(source, character.id)

    if persistsDeath() and row.death then
        InternalDeath.Restore(source, decode(row.death))
    end

    Repository.Update('UPDATE `ug_characters` SET `last_played` = NOW() WHERE `id` = ?', { character.id })
    InternalPlayers.SetLoaded(source, true)
    Events.Emit(CharacterEvents.Loaded, source, character.id)

    if context then
        context.logger.Debug('player %d loaded character %d.', source, character.id)
    end

    return true, nil
end

---Saves and unloads the character. The player goes back to not loaded and alive.
---@param source integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Characters.Unload(source)
    local character = active[source]

    if not character then
        return false, Errors.NotLoaded
    end

    save(character.id, exportDeath(source), positionOf(source))

    for index = #participants, 1, -1 do
        if participants[index].unload then
            participants[index].unload(source, character.id)
        end
    end

    active[source] = nil
    InternalPlayers.SetCharacter(source, nil)
    InternalPlayers.SetLoaded(source, false)
    InternalDeath.Restore(source, { state = States.Alive, injuries = {} })
    Events.Emit(CharacterEvents.Unloaded, source, character.id)

    return true, nil
end

---Last saved position of a character, nil before its first save. MUST run in a thread.
---@param characterId integer
---@return boolean ok
---@return vector4? position
---@return UgErrorCode? errorCode
function Characters.GetPosition(characterId)
    if math.type(characterId) ~= 'integer' then
        return false, nil, Errors.InvalidArgs
    end

    local ok, row = Repository.Single('SELECT `position` FROM `ug_characters` WHERE `id` = ? AND `deleted_at` IS NULL', { characterId })

    if not ok then
        return false, nil, Errors.InternalError
    end

    if not row then
        return false, nil, Errors.NotFound
    end

    return true, decodePosition(row.position), nil
end

---@param source integer
---@return UgCharacter?
function Characters.GetActive(source)
    return Utils.Table.DeepCopy(active[source])
end

---Lets a module create, load and unload its per-character data in step with characters.
---`create` and `load` run in the caller's thread and return false to fail the operation. `unload` MUST NOT wait.
---@param participant UgCharacterParticipant
function InternalCharacters.Participate(participant)
    participants[#participants + 1] = participant
end

---@param ctx UgModuleContext
function InternalCharacters.Init(ctx)
    context = ctx

    -- Disconnecting MUST NOT revive a player: death state is read now and saved with the character.
    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))
        local character = dropped and active[dropped]

        if not dropped or not character then
            return
        end

        local death = exportDeath(dropped)
        local position = positionOf(dropped)

        active[dropped] = nil

        for index = #participants, 1, -1 do
            if participants[index].unload then
                participants[index].unload(dropped, character.id)
            end
        end

        Events.Emit(CharacterEvents.Unloaded, dropped, character.id)

        CreateThread(function()
            save(character.id, death, position)
        end)
    end)

    CreateThread(function()
        while true do
            local interval = UgCore.Config.Get('characters', 'positionInterval')

            Wait(interval > 0 and interval or 60000)

            if interval > 0 then
                for source, character in pairs(active) do
                    save(character.id, nil, positionOf(source))
                end
            end
        end
    end)
end

---Saves every loaded character. Best effort: the stopping resource MAY not finish the writes.
---@param ctx UgModuleContext
function InternalCharacters.Stop(ctx)
    for source, character in pairs(active) do
        save(character.id, exportDeath(source), positionOf(source))
    end

    ctx.logger.Debug('saved loaded characters.')
end
