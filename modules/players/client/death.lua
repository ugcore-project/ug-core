--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Reports damage and death to the server and applies the death state the server decides.
-- Clients never revive or respawn themselves: only server events do.

local Network = UgCore.Network
local Injuries = UgCore.Internal.Injuries
local States = UgCore.Enums.DeathState

local STATE_KEY = UgCore.Enums.StateBags.DeathState
local REPORT_FATAL = 'ug-core:PlayersReportFatal'
local REPORT_DAMAGE = 'ug-core:PlayersReportDamage'
local POLL_INTERVAL = 250
local DAMAGE_INTERVAL = 500
local ANIMATION_CHECK = 500
local DOWNED_HEALTH = 150
local DEAD_HEALTH = 101
local MAX_HEALTH = 200
local ANIMATION_FLAG = 1

local DOWNED_CONTROLS = {
    21, -- INPUT_SPRINT
    22, -- INPUT_JUMP
    23, -- INPUT_ENTER
    24, -- INPUT_ATTACK
    25, -- INPUT_AIM
    37, -- INPUT_SELECT_WEAPON
    44, -- INPUT_COVER
    69, -- INPUT_VEH_ATTACK
    75, -- INPUT_VEH_EXIT
    140, -- INPUT_MELEE_ATTACK_LIGHT
    141, -- INPUT_MELEE_ATTACK_HEAVY
    142, -- INPUT_MELEE_ATTACK_ALTERNATE
    143, -- INPUT_MELEE_BLOCK
    257, -- INPUT_ATTACK2
}

local DEAD_CONTROLS = {
    30, -- INPUT_MOVE_LR
    31, -- INPUT_MOVE_UD
}

---@type UgDeathState
local current = States.Alive
local reported = false

---@return { dict: string, name: string }|false
local function animationFor(state)
    local section = state == States.Downed and 'downed' or 'dead'
    local config = UgCore.Config.Get('players', section)

    return config.animation
end

---@param ped integer
---@param health integer
local function resurrectInPlace(ped, health)
    local coords = GetEntityCoords(ped)

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, GetEntityHeading(ped), 0, false)
    SetEntityHealth(PlayerPedId(), health)
end

---@param ped integer
---@param animation { dict: string, name: string }|false
local function playAnimation(ped, animation)
    if not animation or IsEntityPlayingAnim(ped, animation.dict, animation.name, 3) then
        return
    end

    RequestAnimDict(animation.dict)

    if HasAnimDictLoaded(animation.dict) then
        TaskPlayAnim(ped, animation.dict, animation.name, 8.0, -8.0, -1, ANIMATION_FLAG, 0.0, false, false, false)
    end
end

---Holds the downed or dead pose until the server changes the state.
local function holdPose()
    CreateThread(function()
        local lastCheck = 0

        while current ~= States.Alive do
            local ped = PlayerPedId()

            for _, control in ipairs(DOWNED_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            if current == States.Dead then
                for _, control in ipairs(DEAD_CONTROLS) do
                    DisableControlAction(0, control, true)
                end
            end

            if GetGameTimer() - lastCheck >= ANIMATION_CHECK then
                lastCheck = GetGameTimer()
                playAnimation(ped, animationFor(current))
            end

            Wait(0)
        end
    end)
end

---@param state any
local function apply(state)
    if state ~= States.Downed and state ~= States.Dead then
        state = States.Alive
    end

    local previous = current

    current = state
    reported = false

    if state == States.Alive then
        return
    end

    local ped = PlayerPedId()

    if IsPedFatallyInjured(ped) then
        resurrectInPlace(ped, state == States.Downed and DOWNED_HEALTH or DEAD_HEALTH)
    end

    if previous == States.Alive then
        holdPose()
    end
end

---@param ped integer
---@return integer? bone
local function lastBone(ped)
    local found, bone = GetPedLastDamageBone(ped)

    return found and bone or nil
end

---@param ped integer
---@return integer? weapon environment cause, when one damaged the ped
local function environmentWeapon(ped)
    for _, hash in ipairs(Injuries.GetEnvironmentHashes()) do
        if HasEntityBeenDamagedByWeapon(ped, hash, 0) then
            return hash
        end
    end

    return nil
end

Network.Register('PlayersRevive', function(health)
    local ped = PlayerPedId()

    resurrectInPlace(ped, math.type(health) == 'integer' and health or MAX_HEALTH)
    ClearPedTasks(PlayerPedId())
end)

Network.Register('PlayersRespawn', function(coords)
    if type(coords) ~= 'vector4' then
        return
    end

    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, coords.w, 0, false)
    SetEntityHealth(PlayerPedId(), MAX_HEALTH)
    ClearPedTasks(PlayerPedId())
end)

AddStateBagChangeHandler(STATE_KEY, ('player:%d'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    apply(value)
end)

-- The core owns respawning. spawnmanager MUST NOT respawn players on its own.
if GetResourceState('spawnmanager') == 'started' then
    pcall(function()
        exports.spawnmanager:setAutoSpawn(false)
    end)
end

apply(LocalPlayer.state[STATE_KEY])

CreateThread(function()
    local lastHealth = GetEntityHealth(PlayerPedId())
    local lastDamage = 0

    while true do
        Wait(POLL_INTERVAL)

        local ped = PlayerPedId()
        local health = GetEntityHealth(ped)

        if current ~= States.Dead then
            if IsPedFatallyInjured(ped) then
                if not reported then
                    reported = true
                    Network.TriggerServer(REPORT_FATAL, lastBone(ped))
                end
            elseif health < lastHealth and GetGameTimer() - lastDamage >= DAMAGE_INTERVAL then
                lastDamage = GetGameTimer()
                Network.TriggerServer(REPORT_DAMAGE, lastBone(ped), environmentWeapon(ped))
                ClearEntityLastDamageEntity(ped)
            end
        end

        lastHealth = health
    end
end)
