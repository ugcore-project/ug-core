--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Server-authoritative death state and injuries. Clients report, the server confirms with server-side ped health.
---@class UgCore.Players
local Players = UgCore.Players

---@class UgCore.Internal.Death
local InternalDeath = {}
UgCore.Internal.Death = InternalDeath

---@class UgDeathRecord
---@field state UgDeathState
---@field injuries table<string, UgInjury>
---@field cause? UgCauseOfDeath
---@field token integer increments on every transition, so stale timers do nothing
---@field position? vector3 where the player went down
---@field flagged boolean

---@class UgRecentHit
---@field attacker integer
---@field weapon integer
---@field at integer

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Events = UgCore.Events
local Schema = UgCore.Schema
local InternalHooks = UgCore.Internal.Hooks
local InternalPlayers = UgCore.Internal.Players
local Injuries = UgCore.Internal.Injuries
local States = UgCore.Enums.DeathState
local Regions = UgCore.Enums.BodyRegion
local Categories = UgCore.Enums.DamageCategory
local Errors = UgCore.Enums.Errors
local Violations = UgCore.Enums.Violations
local PlayerEvents = UgCore.Enums.Events.Players
local PlayerHooks = UgCore.Enums.Hooks.Players

local STATE_KEY = UgCore.Enums.StateBags.DeathState
local INJURIES_KEY = UgCore.Enums.StateBags.Injuries
local REVIVE_EVENT = 'ug-core:PlayersRevive'
local RESPAWN_EVENT = 'ug-core:PlayersRespawn'

-- IS_PED_FATALLY_INJURED uses a threshold of 100 (Cfx docs). Below it, a ped is fatally injured.
local FATAL_HEALTH = 100
local MAX_HEALTH = 200
local HIT_WINDOW = 3000
local DAMAGE_WINDOW = 1000
local BLEEDOUT_RETRY = 10000
local WATCH_INTERVAL = 2000
local DOWNED_RADIUS = 10.0
local DEAD_RADIUS = 3.0
local MAX_REASON = 255

---@type table<integer, UgDeathRecord>
local records = {}

---@type table<integer, UgRecentHit>
local recentHits = {}

---@param source integer
---@return UgDeathRecord?
local function getRecord(source)
    local record = records[source]

    if record then
        return record
    end

    if not InternalPlayers.Exists(source) then
        return nil
    end

    record = { state = States.Alive, injuries = {}, token = 0, flagged = false }
    records[source] = record

    return record
end

---@param record UgDeathRecord
---@return UgInjury[] sorted by region, then category
local function injuryList(record)
    local list = {}

    for _, injury in pairs(record.injuries) do
        list[#list + 1] = Utils.Table.DeepCopy(injury)
    end

    table.sort(list, function(a, b)
        if a.region ~= b.region then
            return a.region < b.region
        end

        return a.category < b.category
    end)

    return list
end

---@param source integer
---@param record UgDeathRecord
local function publish(source, record)
    local state = Player(source).state

    state:set(STATE_KEY, record.state, true)
    state:set(INJURIES_KEY, injuryList(record), true)
end

---@param source integer
---@return vector3?
local function pedPosition(source)
    local ped = GetPlayerPed(tostring(source))

    if not ped or ped == 0 then
        return nil
    end

    return GetEntityCoords(ped)
end

---@param cause any
---@return UgCauseOfDeath
local function normalizeCause(cause)
    cause = type(cause) == 'table' and cause or {}

    return {
        region = Regions[cause.region] and cause.region or Regions.Unknown,
        category = Categories[cause.category] and cause.category or Categories.Unknown,
        weapon = math.type(cause.weapon) == 'integer' and cause.weapon or nil,
        killer = math.type(cause.killer) == 'integer' and cause.killer or nil,
        at = os.time(),
    }
end

---@param source integer
---@param record UgDeathRecord
---@param region UgBodyRegion
---@param category UgDamageCategory
---@param weapon integer?
---@param attacker integer?
local function addInjury(source, record, region, category, weapon, attacker)
    local key = region .. ':' .. category
    local injury = record.injuries[key]

    if injury then
        injury.hits = injury.hits + 1
        injury.lastAt = os.time()
        injury.weapon = weapon or injury.weapon
        injury.attacker = attacker or injury.attacker
    else
        injury = { region = region, category = category, weapon = weapon, attacker = attacker, hits = 1, lastAt = os.time() }
        record.injuries[key] = injury
    end

    publish(source, record)
    Events.Emit(PlayerEvents.Injured, source, Utils.Table.DeepCopy(injury))
end

local scheduleBleedout
local scheduleRespawn

---@param source integer
---@param record UgDeathRecord
---@param state UgDeathState
---@param cause UgCauseOfDeath?
local function transition(source, record, state, cause)
    local previous = record.state

    record.state = state
    record.token = record.token + 1
    record.flagged = false
    record.position = state ~= States.Alive and pedPosition(source) or nil

    publish(source, record)
    Events.Emit(PlayerEvents.DeathStateChanged, source, state, previous, cause and Utils.Table.DeepCopy(cause))

    if state == States.Downed then
        Events.Emit(PlayerEvents.Downed, source, cause and Utils.Table.DeepCopy(cause))
        scheduleBleedout(source, record.token, UgCore.Config.Get('players', 'downed').duration)
    elseif state == States.Dead then
        Events.Emit(PlayerEvents.Died, source, cause and Utils.Table.DeepCopy(cause))
        scheduleRespawn(source, record.token)
    end
end

---@param source integer
---@param caller string
---@return UgDeathRecord?
local function requireRecord(source, caller)
    if math.type(source) ~= 'integer' or source < 1 then
        Utils.Raise(3, 'Players.%s expects a player source', caller)
    end

    return getRecord(source)
end

---@param source integer
---@return UgDeathState
function Players.GetDeathState(source)
    local record = records[source]

    return record and record.state or States.Alive
end

---@param source integer
---@return boolean
function Players.IsDead(source)
    return Players.GetDeathState(source) == States.Dead
end

---@param source integer
---@return boolean
function Players.IsDowned(source)
    return Players.GetDeathState(source) == States.Downed
end

---@param source integer
---@return UgInjury[]
function Players.GetInjuries(source)
    local record = records[source]

    return record and injuryList(record) or {}
end

---@param source integer
---@return UgCauseOfDeath?
function Players.GetCauseOfDeath(source)
    local record = records[source]

    return record and Utils.Table.DeepCopy(record.cause) or nil
end

---@param source integer
---@param region? UgBodyRegion every region when nil
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.ClearInjuries(source, region)
    if region ~= nil and not Regions[region] then
        Utils.Raise(2, 'Players.ClearInjuries: unknown region "%s"', tostring(region))
    end

    local record = requireRecord(source, 'ClearInjuries')

    if not record then
        return false, Errors.NotFound
    end

    for key, injury in pairs(record.injuries) do
        if region == nil or injury.region == region then
            record.injuries[key] = nil
        end
    end

    publish(source, record)

    return true, nil
end

---Alive to Downed. `Players:BeforeDown` MAY cancel.
---@param source integer
---@param cause? UgCauseOfDeath
---@return boolean ok
---@return UgErrorCode? errorCode `not_found`, `invalid_args` from another state, `no_permission` when a hook cancelled
function Players.Down(source, cause)
    local record = requireRecord(source, 'Down')

    if not record then
        return false, Errors.NotFound
    end

    if record.state ~= States.Alive then
        return false, Errors.InvalidArgs
    end

    local normalized = normalizeCause(cause)

    if not InternalHooks.Run(PlayerHooks.BeforeDown, { source = source, cause = Utils.Table.DeepCopy(normalized) }) then
        return false, Errors.NoPermission
    end

    record.cause = normalized
    transition(source, record, States.Downed, normalized)

    return true, nil
end

---Alive or Downed to Dead.
---@param source integer
---@param cause? UgCauseOfDeath
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.Kill(source, cause)
    local record = requireRecord(source, 'Kill')

    if not record then
        return false, Errors.NotFound
    end

    if record.state == States.Dead then
        return false, Errors.InvalidArgs
    end

    local normalized = cause and normalizeCause(cause) or record.cause or normalizeCause(nil)

    record.cause = normalized
    transition(source, record, States.Dead, normalized)

    return true, nil
end

---Downed or Dead to Alive, in place. `Players:BeforeRevive` MAY cancel.
---@param source integer
---@param options? UgReviveOptions
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.Revive(source, options)
    options = options or {}

    if type(options) ~= 'table' then
        Utils.Raise(2, 'Players.Revive expects options as a table')
    end

    local health = options.health or MAX_HEALTH

    if math.type(health) ~= 'integer' or health <= FATAL_HEALTH or health > MAX_HEALTH then
        Utils.Raise(2, 'Players.Revive: health MUST be an integer from %d to %d', FATAL_HEALTH + 1, MAX_HEALTH)
    end

    if options.reason ~= nil and (type(options.reason) ~= 'string' or #options.reason > MAX_REASON) then
        Utils.Raise(2, 'Players.Revive: reason MUST be a string of up to %d characters', MAX_REASON)
    end

    local record = requireRecord(source, 'Revive')

    if not record then
        return false, Errors.NotFound
    end

    if record.state == States.Alive then
        return false, Errors.InvalidArgs
    end

    local payload = { source = source, by = options.by, reason = options.reason, health = health, clearInjuries = options.clearInjuries == true }

    if not InternalHooks.Run(PlayerHooks.BeforeRevive, payload) then
        return false, Errors.NoPermission
    end

    if options.clearInjuries then
        record.injuries = {}
    end

    record.cause = nil
    transition(source, record, States.Alive, nil)
    TriggerClientEvent(REVIVE_EVENT, source, health)
    Events.Emit(PlayerEvents.Revived, source, options.by, options.reason)

    return true, nil
end

---Downed or Dead to Alive at `coords`, or `respawn.coords` from config. Clears injuries. `Players:BeforeRespawn` MAY cancel.
---@param source integer
---@param coords? vector4
---@return boolean ok
---@return UgErrorCode? errorCode
function Players.Respawn(source, coords)
    if coords ~= nil and type(coords) ~= 'vector4' then
        Utils.Raise(2, 'Players.Respawn expects coords as a vector4')
    end

    local record = requireRecord(source, 'Respawn')

    if not record then
        return false, Errors.NotFound
    end

    if record.state == States.Alive then
        return false, Errors.InvalidArgs
    end

    local target = coords or UgCore.Config.Get('players', 'respawn').coords

    if not InternalHooks.Run(PlayerHooks.BeforeRespawn, { source = source, coords = target }) then
        return false, Errors.NoPermission
    end

    record.injuries = {}
    record.cause = nil
    transition(source, record, States.Alive, nil)
    TriggerClientEvent(RESPAWN_EVENT, source, target)
    Events.Emit(PlayerEvents.Respawned, source, target)

    return true, nil
end

---Bleedout runs on the server. `Players:BeforeBleedout` MAY postpone it, for example during CPR.
---@param source integer
---@param token integer
---@param delay integer
scheduleBleedout = function(source, token, delay)
    SetTimeout(delay, function()
        local record = records[source]

        if not record or record.token ~= token or record.state ~= States.Downed then
            return
        end

        if not InternalHooks.Run(PlayerHooks.BeforeBleedout, { source = source }) then
            scheduleBleedout(source, token, BLEEDOUT_RETRY)
            return
        end

        Players.Kill(source)
    end)
end

---@param source integer
---@param token integer
scheduleRespawn = function(source, token)
    local respawn = UgCore.Config.Get('players', 'respawn')

    if not respawn.auto then
        return
    end

    SetTimeout(respawn.delay, function()
        local record = records[source]

        if record and record.token == token and record.state == States.Dead then
            Players.Respawn(source)
        end
    end)
end

---@param list string[]
---@param value string
---@return boolean
local function contains(list, value)
    for index = 1, #list do
        if list[index] == value then
            return true
        end
    end

    return false
end

---@param source integer
---@return UgRecentHit?
local function recentHit(source, window)
    local hit = recentHits[source]

    if hit and GetGameTimer() - hit.at <= window then
        return hit
    end

    return nil
end

---A fatal report is a claim. Server-side health confirms it. Weapon and killer come from server natives.
---@param source integer
---@param bone integer?
local function onFatal(source, bone)
    local record = getRecord(source)

    if not record or record.state == States.Dead then
        return
    end

    local ped = GetPlayerPed(tostring(source))

    if not ped or ped == 0 or GetEntityHealth(ped) >= FATAL_HEALTH then
        Logger.Debug('Players: fatal report of player %d not confirmed by server health.', source)
        return
    end

    local weapon = GetPedCauseOfDeath(ped)
    local killer = nil
    local killerPed = GetPedSourceOfDeath(ped)

    if killerPed and killerPed ~= 0 and IsPedAPlayer(killerPed) then
        local owner = NetworkGetEntityOwner(killerPed)
        local hit = recentHit(source, HIT_WINDOW)

        if hit and hit.attacker == owner then
            killer = owner
        end
    end

    local region = Injuries.RegionOf(bone)
    local category = Injuries.CategoryOf(weapon)

    addInjury(source, record, region, category, weapon, killer)

    local cause = { region = region, category = category, weapon = weapon, killer = killer, at = os.time() }
    local config = UgCore.Config.Get('players')

    if record.state == States.Downed then
        if config.downed.killOnDamage then
            Players.Kill(source, cause)
        end

        return
    end

    local instant = (config.instantDeath.headshot and category == Categories.Gunshot and region == Regions.Head)
        or contains(config.instantDeath.categories, category)

    if config.downed.enabled and not instant then
        Players.Down(source, cause)
    else
        Players.Kill(source, cause)
    end
end

---A damage report is a claim. Weapon and attacker come from a recent weaponDamageEvent when there is one.
---@param source integer
---@param bone integer?
---@param claimedWeapon integer?
local function onDamage(source, bone, claimedWeapon)
    local record = getRecord(source)

    if not record then
        return
    end

    local hit = recentHit(source, DAMAGE_WINDOW)
    local weapon = hit and hit.weapon or claimedWeapon

    addInjury(source, record, Injuries.RegionOf(bone), Injuries.CategoryOf(weapon), weapon, hit and hit.attacker or nil)
end

---Players who move away while downed or dead are flagged. Movement is limited to the animation.
local function watch()
    for source, record in pairs(records) do
        if record.state ~= States.Alive and record.position and not record.flagged then
            local position = pedPosition(source)
            local radius = record.state == States.Downed and DOWNED_RADIUS or DEAD_RADIUS

            if position and #(position - record.position) > radius then
                record.flagged = true
                UgCore.Guard.Flag(source, Violations.InvalidDeathState, ('moved while %s'):format(record.state))
            end
        end
    end
end

---Exports death state for the characters module.
---@param source integer
---@return UgDeathData?
function InternalDeath.Export(source)
    local record = records[source]

    if not record then
        return nil
    end

    return { state = record.state, injuries = injuryList(record), cause = Utils.Table.DeepCopy(record.cause) }
end

---Restores saved death state. A player who disconnected downed or dead comes back downed or dead.
---@param source integer
---@param data any
function InternalDeath.Restore(source, data)
    local record = getRecord(source)

    if not record or type(data) ~= 'table' or not States[data.state] then
        return
    end

    record.injuries = {}

    for _, injury in ipairs(type(data.injuries) == 'table' and data.injuries or {}) do
        if type(injury) == 'table' and Regions[injury.region] and Categories[injury.category] then
            record.injuries[injury.region .. ':' .. injury.category] = {
                region = injury.region,
                category = injury.category,
                weapon = math.type(injury.weapon) == 'integer' and injury.weapon or nil,
                attacker = nil,
                hits = math.type(injury.hits) == 'integer' and injury.hits or 1,
                lastAt = math.type(injury.lastAt) == 'integer' and injury.lastAt or os.time(),
            }
        end
    end

    record.cause = data.cause and normalizeCause(data.cause) or nil

    if data.state == record.state then
        publish(source, record)
    else
        transition(source, record, data.state, record.cause)
    end
end

---@param ctx UgModuleContext
function InternalDeath.Init(ctx)
    local S = Schema
    local bone = S.Optional(S.Integer({ min = 0, max = 65535 }))

    UgCore.Network.Register('PlayersReportFatal', {
        schema = S.Define({ bone }),
        rate = { max = 3, per = 5000 },
    }, onFatal)

    UgCore.Network.Register('PlayersReportDamage', {
        schema = S.Define({ bone, S.Optional(S.Integer({ min = -2147483648, max = 4294967295 })) }),
        rate = { max = 10, per = 1000 },
    }, onDamage)

    -- weaponDamageEvent (OneSync): sender and data.hitGlobalId(s), data.weaponType (Cfx server events docs).
    AddEventHandler('weaponDamageEvent', function(sender, data)
        local attacker = math.tointeger(tonumber(sender))

        if not attacker or type(data) ~= 'table' or math.type(data.weaponType) ~= 'integer' then
            return
        end

        local targets = type(data.hitGlobalIds) == 'table' and data.hitGlobalIds or { data.hitGlobalId }

        for _, netId in ipairs(targets) do
            local entity = math.type(netId) == 'integer' and NetworkGetEntityFromNetworkId(netId) or 0

            if entity ~= 0 and IsPedAPlayer(entity) then
                local victim = NetworkGetEntityOwner(entity)

                if victim and victim > 0 and victim ~= attacker then
                    recentHits[victim] = { attacker = attacker, weapon = data.weaponType, at = GetGameTimer() }
                end
            end
        end
    end)

    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        -- Removed a tick later, so the characters save still reads the death state.
        if dropped then
            SetTimeout(0, function()
                records[dropped] = nil
                recentHits[dropped] = nil
            end)
        end
    end)

    CreateThread(function()
        while true do
            Wait(WATCH_INTERVAL)
            watch()
        end
    end)

    ctx.logger.Debug('death state ready.')
end
