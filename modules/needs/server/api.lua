--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Needs of loaded characters, from 0 to 100. The server ticks them. The owner gets them through a private event.
---@class UgCore.Needs
local Needs = {}
UgCore.Needs = Needs

---@class UgCore.Internal.Needs
local InternalNeeds = {}
UgCore.Internal.Needs = InternalNeeds

---@class UgNeedDefinition
---@field label string
---@field start number
---@field rate number change per minute
---@field damage integer health lost per tick at 0

---@class UgNeedsState
---@field characterId integer
---@field values table<string, number>

local Events = UgCore.Events
local Repository = UgCore.Internal.Database.Repository
local Errors = UgCore.Enums.Errors
local NeedEvents = UgCore.Enums.Events.Needs

local SYNC_EVENT = 'ug-core:NeedsSync'
local DAMAGE_EVENT = 'ug-core:NeedsDamage'
local SAVE_QUERY = 'INSERT INTO `ug_needs` (`character_id`, `data`) VALUES (?, ?) ON DUPLICATE KEY UPDATE `data` = VALUES(`data`)'
-- Ticks change memory only. Values are saved every 5 minutes, on unload and on stop.
local SAVE_INTERVAL = 300000
local DEFAULT_INTERVAL = 10000

---@type table<integer, UgNeedsState> by player source
local players = {}
---@type UgModuleContext?
local context = nil
local running = false

---@param value number
---@return number
local function clamp(value)
    return math.floor(math.min(math.max(value, 0), 100) * 100 + 0.5) / 100
end

---@param value any
---@return boolean
local function isFinite(value)
    return type(value) == 'number' and value == value and value ~= math.huge and value ~= -math.huge
end

---@return table<string, UgNeedDefinition>
local function definitions()
    return context and context.config and context.config.needs or {}
end

---@param characterId integer
---@param values table<string, number>
---@return boolean ok
local function write(characterId, values)
    local ok = Repository.Update(SAVE_QUERY, { characterId, json.encode(values) })

    return ok
end

local cache = UgCore.Internal.Database.Cache.Create({
    name = 'needs',
    flush = write,
    interval = SAVE_INTERVAL,
})

---@param source integer
local function sync(source)
    local state = players[source]

    TriggerClientEvent(SYNC_EVENT, source, state and state.values or {})
end

---@param source integer
---@param name string
---@param value number
---@return boolean changed
local function apply(source, name, value)
    local state = players[source]
    local previous = state.values[name]

    value = clamp(value)

    if value == previous then
        return false
    end

    state.values[name] = value
    cache:MarkDirty(state.characterId)
    Events.Emit(NeedEvents.Changed, source, name, value, previous)

    return true
end

---@param source any
---@param name any
---@return UgErrorCode? errorCode
local function check(source, name)
    if math.type(source) ~= 'integer' or type(name) ~= 'string' then
        return Errors.InvalidArgs
    end

    local state = players[source]

    if not state then
        return Errors.NotLoaded
    end

    if state.values[name] == nil then
        return Errors.NotFound
    end

    return nil
end

---@param source integer
---@param name string
---@return number? value nil when no character is loaded or the need does not exist
function Needs.Get(source, name)
    local state = players[source]

    return state and state.values[name] or nil
end

---@param source integer
---@return table<string, number>? values nil when no character is loaded
function Needs.GetAll(source)
    local state = players[source]

    return state and UgCore.Internal.Utils.Table.DeepCopy(state.values) or nil
end

---@param source integer
---@param name string
---@param value number from 0 to 100, clamped
---@return boolean ok
---@return number? value
---@return UgErrorCode? errorCode
function Needs.Set(source, name, value)
    local errorCode = check(source, name)

    if errorCode then
        return false, nil, errorCode
    end

    if not isFinite(value) then
        return false, nil, Errors.InvalidArgs
    end

    if apply(source, name, value) then
        sync(source)
    end

    return true, players[source].values[name], nil
end

---@param amount any
---@return boolean
local function isAmount(amount)
    return isFinite(amount) and amount >= 0 and amount <= 100
end

---@param source integer
---@param name string
---@param amount number from 0 to 100, the result is clamped at 100
---@return boolean ok
---@return number? value
---@return UgErrorCode? errorCode
function Needs.Add(source, name, amount)
    if not isAmount(amount) then
        return false, nil, Errors.InvalidArgs
    end

    return Needs.Set(source, name, (Needs.Get(source, name) or 0) + amount)
end

---@param source integer
---@param name string
---@param amount number from 0 to 100, the result is clamped at 0
---@return boolean ok
---@return number? value
---@return UgErrorCode? errorCode
function Needs.Remove(source, name, amount)
    if not isAmount(amount) then
        return false, nil, Errors.InvalidArgs
    end

    return Needs.Set(source, name, (Needs.Get(source, name) or 0) - amount)
end

---Sets every need back to its start value.
---@param source integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Needs.Reset(source)
    if math.type(source) ~= 'integer' then
        return false, Errors.InvalidArgs
    end

    if not players[source] then
        return false, Errors.NotLoaded
    end

    local changed = false

    for name, definition in pairs(definitions()) do
        changed = apply(source, name, definition.start) or changed
    end

    if changed then
        sync(source)
    end

    return true, nil
end

---Saved values for the configured needs. Unknown names are dropped and missing ones take their start value.
---@param saved any
---@return table<string, number>
local function restore(saved)
    local values = {}

    for name, definition in pairs(definitions()) do
        local value = type(saved) == 'table' and saved[name] or nil

        values[name] = isFinite(value) and clamp(value --[[@as number]]) or definition.start
    end

    return values
end

---@param source integer
---@param elapsed integer ms since the last tick
local function tickPlayer(source, elapsed)
    local config = context and context.config
    local state = players[source]

    if not config or not state then
        return
    end

    if config.pauseWhileDown and UgCore.Players.GetDeathState(source) ~= UgCore.Enums.DeathState.Alive then
        return
    end

    local changed, damage = false, 0

    for name, definition in pairs(definitions()) do
        local value = state.values[name]

        if value and definition.rate ~= 0 then
            changed = apply(source, name, value + definition.rate * elapsed / 60000) or changed
        end

        if definition.damage > 0 and state.values[name] and state.values[name] <= 0 then
            damage = damage + definition.damage
        end
    end

    if changed then
        sync(source)
    end

    if damage > 0 then
        TriggerClientEvent(DAMAGE_EVENT, source, damage)
    end
end

---Runs one tick for every loaded player.
---@param elapsed integer ms since the last tick
function InternalNeeds.Tick(elapsed)
    for source in pairs(players) do
        tickPlayer(source, elapsed)
    end
end

---@return integer count loaded players with needs
function InternalNeeds.Count()
    local count = 0

    for _ in pairs(players) do
        count = count + 1
    end

    return count
end

---@param ctx UgModuleContext
function InternalNeeds.Init(ctx)
    context = ctx

    UgCore.Internal.Characters.Participate({
        load = function(source, characterId)
            local ok, row = Repository.Single('SELECT `data` FROM `ug_needs` WHERE `character_id` = ?', { characterId })

            if not ok then
                return false
            end

            local saved = nil

            if row and type(row.data) == 'string' then
                local decoded, value = pcall(json.decode, row.data)

                saved = decoded and value or nil
            end

            local values = restore(saved)

            players[source] = {
                characterId = characterId,
                values = values,
            }

            if row then
                cache:Put(characterId, values, source)
            else
                cache:Set(characterId, values, source)
            end

            sync(source)

            return true
        end,
        unload = function(source, characterId)
            cache:Evict(characterId)
            players[source] = nil
            sync(source)
        end,
    })

    Events.On(UgCore.Enums.Events.Players.Respawned, function(source)
        if context and context.config.resetOnRespawn and players[source] then
            Needs.Reset(source)
        end
    end)
end

function InternalNeeds.Start()
    running = true

    CreateThread(function()
        local last = GetGameTimer()

        while running do
            Wait(context and context.config.interval or DEFAULT_INTERVAL)

            if running then
                local now = GetGameTimer()

                InternalNeeds.Tick(now - last)
                last = now
            end
        end
    end)
end

function InternalNeeds.Stop()
    running = false
end
