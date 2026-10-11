--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Scores suspicious behavior per player and acts on thresholds from config/guard.lua.
---Detail stays in server logs. Kick and ban messages are generic.
---@class UgCore.Guard
local Guard = {}
UgCore.Guard = Guard

---@class UgCore.Internal.Guard
local InternalGuard = {}
UgCore.Internal.Guard = InternalGuard

---@class UgGuardState
---@field score number
---@field updated integer
---@field warned boolean
---@field flags UgGuardFlag[]

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger
local Events = UgCore.Events
local Weights = UgCore.Enums.ViolationWeights
local GuardEvents = UgCore.Enums.Events.Guard
local InternalHooks = UgCore.Internal.Hooks
local BEFORE_ACTION = UgCore.Enums.Hooks.Guard.BeforeAction

local IDENTITY_NAMESPACE = 'Identity'
local MAX_FLAGS = 10
local Actions = UgCore.Enums.GuardActions
local SEVERITY = { [Actions.Warn] = 1, [Actions.Kick] = 2, [Actions.Ban] = 3 }
local MAX_DETAIL = 200
local KICK_MESSAGE = 'You were disconnected from the server.'
local BAN_MESSAGE = 'You are banned from this server.'

---@type table<integer, UgGuardState>
local states = {}

---@type UgRateLimiter?
local budget = nil

---@param source any
---@return boolean
local function isPlayer(source)
    return math.type(source) == 'integer' and source > 0
end

---Applies decay up to now.
---@param state UgGuardState
local function decay(state)
    local now = GetGameTimer()
    local perMinute = UgCore.Config.Get('guard', 'decayPerMinute')

    state.score = math.max(0, state.score - perMinute * (now - state.updated) / 60000)
    state.updated = now
end

---@param source integer
---@return string
local function describeFlags(source)
    local parts = {}

    for _, flag in ipairs(states[source].flags) do
        parts[#parts + 1] = flag.violation
    end

    return table.concat(parts, ', ')
end

---Runs `Guard:BeforeAction`. Hooks MAY cancel or pick a milder action, never a harsher one.
---@param source integer
---@param action UgGuardAction
---@param score number
---@return (UgGuardAction)? action nil when a hook cancelled
local function beforeAction(source, action, score)
    local proceed, payload = InternalHooks.Run(BEFORE_ACTION, {
        source = source,
        action = action,
        score = score,
        flags = Utils.Table.DeepCopy(states[source].flags),
    })

    if not proceed then
        Logger.Info('Guard: %s of player %d cancelled by a hook.', action, source)
        return nil
    end

    local chosen = payload.action

    if SEVERITY[chosen] and SEVERITY[chosen] <= SEVERITY[action] then
        return chosen
    end

    return action
end

---@param source integer
local function kick(source)
    DropPlayer(tostring(source), Utils.Text('guard.kicked', KICK_MESSAGE))
end

---@param source integer
local function ban(source)
    -- The identity module arrives at build step 13. Until then bans fall back to kicks.
    local identity = UgCore[IDENTITY_NAMESPACE]

    if type(identity) == 'table' and type(identity.Ban) == 'function' then
        -- Identifiers are read before the drop. Identity.Ban waits on the database, so it runs in a thread.
        local identifiers = identity.GetIdentifiers(source)

        DropPlayer(tostring(source), Utils.Text('guard.banned', BAN_MESSAGE))

        CreateThread(function()
            identity.Ban(identifiers, { reason = 'Guard score', by = 'guard', kick = false })
        end)

        return
    end

    Logger.Error('Guard: banning needs the identity module. Kicking player %d instead.', source)
    kick(source)
end

---@param source integer
---@param action UgGuardAction
---@param score number
local function perform(source, action, score)
    local rounded = math.floor(score)

    if action == Actions.Ban then
        Logger.Warn('Guard: banning player %d at score %d. Recent: %s.', source, rounded, describeFlags(source))
        ban(source)
    elseif action == Actions.Kick then
        Logger.Warn('Guard: kicking player %d at score %d. Recent: %s.', source, rounded, describeFlags(source))
        kick(source)
    else
        Logger.Warn('Guard: player %d reached score %d. Recent: %s.', source, rounded, describeFlags(source))
    end
end

---@param source integer
local function evaluate(source)
    local state = states[source]
    local config = UgCore.Config.Get('guard')
    local score = state.score
    local action = nil

    if config.banScore > 0 and score >= config.banScore then
        action = Actions.Ban
    elseif config.kickScore > 0 and score >= config.kickScore then
        action = Actions.Kick
    elseif config.warnScore > 0 and score >= config.warnScore then
        if state.warned then
            return
        end

        state.warned = true
        action = Actions.Warn
    else
        state.warned = false
        return
    end

    local chosen = beforeAction(source, action, score)

    if chosen then
        perform(source, chosen, score)
    end
end

---Reports a violation. Resources MUST use it for their own checks.
---@param source integer
---@param violation UgViolation
---@param detail? string server logs only
function Guard.Flag(source, violation, detail)
    if not isPlayer(source) then
        Utils.Raise(2, 'Guard.Flag expects a player source')
    end

    local weight = Weights[violation]

    if not weight then
        Utils.Raise(2, 'Guard.Flag: unknown violation "%s"', tostring(violation))
    end

    local state = states[source]

    if not state then
        state = { score = 0, updated = GetGameTimer(), warned = false, flags = {} }
        states[source] = state
    end

    decay(state)
    state.score = state.score + weight

    if type(detail) == 'string' and #detail > MAX_DETAIL then
        detail = detail:sub(1, MAX_DETAIL) .. '...'
    end

    table.insert(state.flags, { violation = violation, detail = detail, at = state.updated })

    if #state.flags > MAX_FLAGS then
        table.remove(state.flags, 1)
    end

    Logger.Debug('Guard: player %d %s (+%d, score %d): %s', source, violation, weight, math.floor(state.score), tostring(detail))
    Events.Emit(GuardEvents.Flagged, source, violation, state.score)
    evaluate(source)
end

---@param source integer
---@return number score after decay, 0 for unknown players
function Guard.GetScore(source)
    local state = states[source]

    if not state then
        return 0
    end

    decay(state)

    return state.score
end

---Reads the ped position on the server (OneSync). Client-sent coordinates are never trusted.
---@param source integer
---@param coords vector3
---@param maxDistance number
---@return boolean
function Guard.IsNear(source, coords, maxDistance)
    if not isPlayer(source) then
        Utils.Raise(2, 'Guard.IsNear expects a player source')
    end

    if type(coords) ~= 'vector3' then
        Utils.Raise(2, 'Guard.IsNear expects coords as a vector3')
    end

    if type(maxDistance) ~= 'number' or maxDistance < 0 then
        Utils.Raise(2, 'Guard.IsNear expects a non-negative maxDistance')
    end

    local ped = GetPlayerPed(tostring(source))

    if not ped or ped == 0 then
        return false
    end

    return #(GetEntityCoords(ped) - coords) <= maxDistance
end

---One budget per player across every ug-core net event and callback.
---@param source integer
---@return boolean allowed
function InternalGuard.ConsumeBudget(source)
    if not budget then
        local config = UgCore.Config.Get('guard')

        budget = UgCore.RateLimit.Create({ max = config.budgetMax, per = config.budgetPer })
    end

    return (budget:Consume(source))
end

---@param source integer
---@return UgGuardFlag[] recent flags, oldest first
function InternalGuard.GetFlags(source)
    local state = states[source]

    return state and Utils.Table.DeepCopy(state.flags) or {}
end

AddEventHandler('playerDropped', function()
    local dropped = tonumber(source)

    if dropped then
        states[math.tointeger(dropped) or dropped] = nil
    end
end)
