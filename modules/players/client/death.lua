--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Reports damage and death to the server and applies the death state the server decides.
-- Clients never revive or respawn themselves: only server events do. Holding the downed or dead pose is not a revive:
-- the server state stays Downed or Dead.

local Network = UgCore.Network
local Injuries = UgCore.Internal.Injuries
local States = UgCore.Enums.DeathState

local STATE_KEY = UgCore.Enums.StateBags.DeathState
local REPORT_FATAL = 'ug-core:PlayersReportFatal'
local REPORT_DAMAGE = 'ug-core:PlayersReportDamage'
local POLL_INTERVAL = 250
local DAMAGE_INTERVAL = 500
local ANIMATION_CHECK = 500
-- A fatal report the server did not confirm is sent again. The server allows 3 per 5 s.
local REPORT_RETRY = 3000
-- The body ragdolls until it rests: slower than SETTLE_SPEED m/s, on the ground, for SETTLE_MS.
local SETTLE_SPEED = 0.15
local SETTLE_MS = 1000
-- The pose starts after at least MIN_RAGDOLL_MS, and after SETTLE_TIMEOUT_MS even if the body still slides.
local MIN_RAGDOLL_MS = 2000
local SETTLE_TIMEOUT_MS = 10000
local DOWNED_HEALTH = 150
local DEAD_HEALTH = 101
local MAX_HEALTH = 200
local ANIMATION_FLAG = 1
local AUTO_SPAWN_CHECK = 1000

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
-- Game time of the last fatal report of the current fatal injury, nil when none was sent.
---@type integer?
local reportedAt = nil

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

---Stops the looped downed and dead animations, which outlive the pose loop otherwise.
---@param ped integer
local function stopPose(ped)
    for _, state in ipairs({ States.Downed, States.Dead }) do
        local animation = animationFor(state)

        if animation and IsEntityPlayingAnim(ped, animation.dict, animation.name, 3) then
            StopAnimTask(ped, animation.dict, animation.name, 1.0)
        end
    end
end

---Holds the downed or dead pose until the server changes the state. A fatally injured ped ragdolls first, and is
---resurrected in place into the pose once the body rests. The same happens when it is killed again while down.
local function holdPose()
    CreateThread(function()
        local lastCheck = 0
        ---@type integer?
        local fallenAt = nil
        ---@type integer?
        local stillSince = nil

        while current ~= States.Alive do
            local ped = PlayerPedId()
            local now = GetGameTimer()

            for _, control in ipairs(DOWNED_CONTROLS) do
                DisableControlAction(0, control, true)
            end

            if current == States.Dead then
                for _, control in ipairs(DEAD_CONTROLS) do
                    DisableControlAction(0, control, true)
                end
            end

            if IsPedFatallyInjured(ped) then
                fallenAt = fallenAt or now

                if GetEntitySpeed(ped) < SETTLE_SPEED and not IsEntityInAir(ped) then
                    stillSince = stillSince or now
                else
                    stillSince = nil
                end

                local rested = stillSince ~= nil and now - stillSince >= SETTLE_MS

                if (rested and now - fallenAt >= MIN_RAGDOLL_MS) or now - fallenAt >= SETTLE_TIMEOUT_MS then
                    resurrectInPlace(ped, current == States.Downed and DOWNED_HEALTH or DEAD_HEALTH)
                    playAnimation(PlayerPedId(), animationFor(current))
                    lastCheck = now
                end
            else
                fallenAt, stillSince = nil, nil

                if now - lastCheck >= ANIMATION_CHECK then
                    lastCheck = now
                    playAnimation(ped, animationFor(current))
                end
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

    if state ~= States.Alive and previous == States.Alive then
        holdPose()
    elseif state == States.Alive and previous ~= States.Alive then
        stopPose(PlayerPedId())
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

---Reports a fatal injury once while alive is not confirmed, and again every REPORT_RETRY until the server confirms
---it. While down, each new fatal injury is reported once: the server decides whether it kills.
---@param ped integer
local function reportFatal(ped)
    local now = GetGameTimer()

    if reportedAt and (current ~= States.Alive or now - reportedAt < REPORT_RETRY) then
        return
    end

    reportedAt = now
    Network.TriggerServer(REPORT_FATAL, lastBone(ped))
end

-- The server is already Alive when it sends these. The statebag MAY replicate later: until then the pose loop would
-- replay the downed animation over the revive, so the state is applied here first.
Network.Register('PlayersRevive', function(health)
    local ped = PlayerPedId()

    apply(States.Alive)
    resurrectInPlace(ped, math.type(health) == 'integer' and health or MAX_HEALTH)
    ClearPedTasks(PlayerPedId())
end)

Network.Register('PlayersRespawn', function(coords)
    if type(coords) ~= 'vector4' then
        return
    end

    apply(States.Alive)
    NetworkResurrectLocalPlayer(coords.x, coords.y, coords.z, coords.w, 0, false)
    SetEntityHealth(PlayerPedId(), MAX_HEALTH)
    ClearPedTasks(PlayerPedId())
end)

AddStateBagChangeHandler(STATE_KEY, ('player:%d'):format(GetPlayerServerId(PlayerId())), function(_, _, value)
    apply(value)
end)

-- The core owns respawning. spawnmanager MUST NOT respawn players on its own, but gametype resources such as
-- basic-gamemode turn its auto-spawn back on when they start, so it is turned off again after every start.
local function disableAutoSpawn()
    if GetResourceState('spawnmanager') ~= 'started' then
        return
    end

    pcall(function()
        exports.spawnmanager:setAutoSpawn(false)
    end)
end

---@param resource string?
local function afterStart(resource)
    if resource == GetCurrentResourceName() then
        return
    end

    disableAutoSpawn()

    -- The gametype MAY turn it on in a handler that runs after this one.
    CreateThread(function()
        Wait(0)
        disableAutoSpawn()
    end)
end

AddEventHandler('onClientResourceStart', afterStart)
AddEventHandler('onClientGameTypeStart', afterStart)
AddEventHandler('onClientMapStart', afterStart)

disableAutoSpawn()

CreateThread(function()
    while true do
        Wait(AUTO_SPAWN_CHECK)
        disableAutoSpawn()
    end
end)

apply(LocalPlayer.state[STATE_KEY])

CreateThread(function()
    local lastHealth = GetEntityHealth(PlayerPedId())
    local lastDamage = 0

    while true do
        Wait(POLL_INTERVAL)

        local ped = PlayerPedId()
        local health = GetEntityHealth(ped)

        if IsPedFatallyInjured(ped) then
            if current ~= States.Dead then
                reportFatal(ped)
            end
        else
            reportedAt = nil

            if current ~= States.Dead and health < lastHealth and GetGameTimer() - lastDamage >= DAMAGE_INTERVAL then
                lastDamage = GetGameTimer()
                Network.TriggerServer(REPORT_DAMAGE, lastBone(ped), environmentWeapon(ped))
                ClearEntityLastDamageEntity(ped)
            end
        end

        lastHealth = health
    end
end)
