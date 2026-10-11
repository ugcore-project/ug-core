--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

local PISTOL = GetHashKey('WEAPON_PISTOL')
local RPG = GetHashKey('WEAPON_RPG')
local HEAD_BONE = 31086
local LEFT_LEG_BONE = 58271

---@param lines string[]
---@param text string
---@return boolean
local function contains(lines, text)
    for index = 1, #lines do
        if lines[index]:find(text, 1, true) then
            return true
        end
    end

    return false
end

---@param config? string body of config/players.lua
local function fresh(config)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players' } }

    if config then
        H.ResourceFiles['config/players.lua'] = 'return ' .. config
    end

    for source = 1, 3 do
        H.Net.identifiers[source] = { 'license:' .. source }
        H.Net.names[source] = 'Player' .. source
        H.Net.peds[source] = 100 + source
        H.Net.owners[100 + source] = source
        H.Net.coords[100 + source] = vector3(0, 0, 0)
    end

    H.Capture(function()
        H.LoadManifest('server')
    end)
end

---@param source integer
local function join(source)
    H.Capture(function()
        H.TriggerEvent('playerJoining', source, 'temp')
    end)
end

---Marks the ped fatally injured with a cause, then sends the client report.
---@param source integer
---@param weapon integer
---@param bone integer
---@param killer? integer
local function die(source, weapon, bone, killer)
    local ped = 100 + source

    H.Net.health[ped] = 0
    H.Net.causeOfDeath[ped] = weapon
    H.Net.sourceOfDeath[ped] = killer and (100 + killer) or 0

    H.Capture(function()
        H.TriggerNetEvent('ug-core:PlayersReportFatal', source, bone)
    end)
end

---@return table<string, any[]> emitted ug-core:Players:* events by name
local function recordEvents()
    local seen = {}

    for _, name in ipairs({ 'DeathStateChanged', 'Downed', 'Died', 'Revived', 'Respawned', 'Injured', 'Loaded' }) do
        UgCore.Events.On('ug-core:Players:' .. name, function(...)
            seen[name] = seen[name] or {}
            table.insert(seen[name], table.pack(...))
        end)
    end

    return seen
end

-- Registry

H.Test('Players already online are added at start, joining players on playerJoining', function()
    H.Net.identifiers[9] = { 'license:9' }
    fresh()

    H.Equal(UgCore.Players.GetAll()[1].source, 1)

    H.Net.identifiers[4] = { 'license:4' }
    join(4)

    local player = H.Any(UgCore.Players.Get(4))

    H.Equal({ player.source, player.name, player.identifier }, { 4, 'Player 4', 'license:4' })
    H.Equal(UgCore.Players.GetByIdentifier('license:2').source, 2)
end)

H.Test('Without characters, players are loaded at join', function()
    fresh()

    local seen = recordEvents()

    join(5)

    H.Equal(H.Net.states[5], nil)

    H.Net.identifiers[5] = { 'license:5' }
    join(5)

    H.Equal(H.Net.states[5]['ug-core:Loaded'], true)
    H.Equal(seen.Loaded, { { n = 1, 5 } })
    H.Equal(H.Net.states[5]['ug-core:Player'], { name = 'Player 5' })
end)

H.Test('Dropped players are removed a tick later', function()
    fresh()

    H.TriggerEvent('playerDropped', 2, 'Exiting')
    H.Assert(UgCore.Players.Get(2) ~= nil, 'removed before other drop handlers ran')

    H.Advance(0)
    H.Equal(UgCore.Players.Get(2), nil)
end)

H.Test('Metadata is session data, replicated keys reach the statebag', function()
    fresh()

    H.Equal({ UgCore.Players.SetMetadata(1, 'hunger', 80, true) }, { true })
    H.Equal({ UgCore.Players.SetMetadata(1, 'secret', { pin = '1234' }) }, { true })

    H.Equal(UgCore.Players.GetMetadata(1, 'hunger'), 80)
    H.Equal(UgCore.Players.GetMetadata(1), { hunger = 80, secret = { pin = '1234' } })
    H.Equal(H.Net.states[1]['ug-core:Metadata'], { hunger = 80 })

    UgCore.Players.SetMetadata(1, 'hunger', nil)
    H.Equal(H.Net.states[1]['ug-core:Metadata'], {})
    H.Equal({ UgCore.Players.SetMetadata(99, 'hunger', 1) }, { false, 'not_found' })
end)

H.Test('Metadata rejects functions, bad keys and oversized tables', function()
    fresh()

    H.Raises(function()
        UgCore.Players.SetMetadata(1, 'cb', H.Any(function() end))
    end, 'Players.SetMetadata: value MUST be data')

    H.Raises(function()
        UgCore.Players.SetMetadata(1, 'Bad Key', 1)
    end, 'Players.SetMetadata expects a camelCase key')

    local big = {}

    for index = 1, 300 do
        big[index] = index
    end

    H.Raises(function()
        UgCore.Players.SetMetadata(1, 'big', big)
    end, 'value MUST be data')
end)

H.Test('Kick uses a generic message by default', function()
    fresh()

    UgCore.Players.Kick(1)
    UgCore.Players.Kick(2, 'AFK')

    H.Equal(H.Net.dropped, {
        { source = '1', reason = 'You were disconnected from the server.' },
        { source = '2', reason = 'AFK' },
    })
end)

-- Death detection

H.Test('Weapon categories come from the Cfx weapon list', function()
    fresh()

    local Injuries = UgCore.Internal.Injuries

    H.Equal(PISTOL, 453432689)
    H.Equal(Injuries.CategoryOf(PISTOL), 'Gunshot')
    H.Equal(Injuries.CategoryOf(PISTOL + 4294967296), 'Gunshot')
    H.Equal(Injuries.CategoryOf(GetHashKey('WEAPON_KNIFE')), 'Stab')
    H.Equal(Injuries.CategoryOf(RPG), 'Explosion')
    H.Equal(Injuries.CategoryOf(12345), 'Unknown')
    H.Equal(Injuries.RegionOf(HEAD_BONE), 'Head')
    H.Equal(Injuries.RegionOf(99999), 'Unknown')
end)

H.Test('A confirmed fatal report downs the player', function()
    fresh()

    local seen = recordEvents()

    die(1, PISTOL, LEFT_LEG_BONE)

    H.Equal(UgCore.Players.GetDeathState(1), 'Downed')
    H.Equal(H.Net.states[1]['ug-core:DeathState'], 'Downed')
    H.Equal(UgCore.Players.GetInjuries(1)[1].region, 'LeftLeg')
    H.Equal(UgCore.Players.GetCauseOfDeath(1).category, 'Gunshot')
    H.Equal(seen.DeathStateChanged[1][2], 'Downed')
    H.Equal(seen.DeathStateChanged[1][3], 'Alive')
    H.Equal(#seen.Downed, 1)
end)

H.Test('Fatal reports without fatal server health are ignored', function()
    fresh()

    H.Capture(function()
        H.TriggerNetEvent('ug-core:PlayersReportFatal', 1, HEAD_BONE)
    end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Alive')
end)

H.Test('Headshots and instant-death categories skip downed', function()
    fresh()

    die(1, PISTOL, HEAD_BONE)
    die(2, RPG, LEFT_LEG_BONE)

    H.Equal(UgCore.Players.GetDeathState(1), 'Dead')
    H.Equal(UgCore.Players.GetDeathState(2), 'Dead')
end)

H.Test('With downed disabled, fatal damage kills', function()
    fresh("{ downed = { enabled = false, duration = 1000, killOnDamage = true, animation = false } }")

    die(1, PISTOL, LEFT_LEG_BONE)

    H.Equal(UgCore.Players.GetDeathState(1), 'Dead')
end)

H.Test('Damage while downed kills when killOnDamage is set', function()
    fresh()

    die(1, PISTOL, LEFT_LEG_BONE)
    die(1, PISTOL, LEFT_LEG_BONE)

    H.Equal(UgCore.Players.GetDeathState(1), 'Dead')
    H.Equal(UgCore.Players.GetInjuries(1)[1].hits, 2)
end)

H.Test('A killer counts only when a weaponDamageEvent confirms it', function()
    fresh()

    die(1, PISTOL, LEFT_LEG_BONE, 2)
    H.Equal(UgCore.Players.GetCauseOfDeath(1).killer, nil)

    H.Net.netEntities[55] = 103
    H.TriggerEvent('weaponDamageEvent', nil, 2, { weaponType = PISTOL, hitGlobalId = 55 })
    H.Net.netEntities[56] = 102
    H.TriggerEvent('weaponDamageEvent', nil, 3, { weaponType = PISTOL, hitGlobalIds = { 56 } })

    die(3, PISTOL, LEFT_LEG_BONE, 2)
    die(2, PISTOL, LEFT_LEG_BONE, 1)

    H.Equal(UgCore.Players.GetCauseOfDeath(3).killer, 2)
    H.Equal(UgCore.Players.GetCauseOfDeath(2).killer, nil)
end)

H.Test('Damage reports aggregate into injuries', function()
    fresh()

    H.Capture(function()
        H.TriggerNetEvent('ug-core:PlayersReportDamage', 1, LEFT_LEG_BONE, GetHashKey('WEAPON_FALL'))
        H.Advance(1000)
        H.TriggerNetEvent('ug-core:PlayersReportDamage', 1, LEFT_LEG_BONE, GetHashKey('WEAPON_FALL'))
    end)

    local injury = UgCore.Players.GetInjuries(1)[1]

    H.Equal({ injury.region, injury.category, injury.hits }, { 'LeftLeg', 'Fall', 2 })
end)

-- Transitions

H.Test('Bleedout kills downed players, unless a hook postpones it', function()
    fresh("{ downed = { enabled = true, duration = 5000, killOnDamage = true, animation = false } }")

    local postpone = true

    UgCore.Hooks.Register('Players:BeforeBleedout', function()
        return not postpone
    end)

    die(1, PISTOL, LEFT_LEG_BONE)

    H.Capture(function()
        H.Advance(5000)
    end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Downed')

    postpone = false

    H.Capture(function()
        H.Advance(10000)
    end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Dead')
end)

H.Test('Revive brings players back in place and can clear injuries', function()
    fresh()

    local seen = recordEvents()

    die(1, PISTOL, LEFT_LEG_BONE)

    H.Equal({ UgCore.Players.Revive(1, { by = 2, health = 150, clearInjuries = true }) }, { true })
    H.Equal(UgCore.Players.GetDeathState(1), 'Alive')
    H.Equal(UgCore.Players.GetInjuries(1), {})
    H.Equal(H.ClientEvents('ug-core:PlayersRevive')[1].args, { n = 1, 150 })
    H.Equal(seen.Revived[1], { n = 3, 1, 2 })
    H.Equal({ UgCore.Players.Revive(1) }, { false, 'invalid_args' })
end)

H.Test('Respawn moves players to the configured coords and clears injuries', function()
    fresh()

    die(1, PISTOL, HEAD_BONE)

    H.Equal({ UgCore.Players.Respawn(1) }, { true })
    H.Equal(UgCore.Players.GetInjuries(1), {})
    H.Equal(H.ClientEvents('ug-core:PlayersRespawn')[1].args[1], vector4(298.5, -584.6, 43.3, 70.0))
end)

H.Test('Hooks can cancel down, revive and respawn', function()
    fresh()

    UgCore.Hooks.Register('Players:BeforeDown', function() return false end)
    UgCore.Hooks.Register('Players:BeforeRevive', function() return false end)
    UgCore.Hooks.Register('Players:BeforeRespawn', function() return false end)

    H.Equal({ UgCore.Players.Down(1) }, { false, 'no_permission' })

    UgCore.Players.Kill(1)

    H.Equal({ UgCore.Players.Revive(1) }, { false, 'no_permission' })
    H.Equal({ UgCore.Players.Respawn(1) }, { false, 'no_permission' })
end)

H.Test('Auto respawn follows death after the delay', function()
    fresh("{ respawn = { auto = true, delay = 3000, coords = vector4(1, 2, 3, 4) } }")

    die(1, RPG, HEAD_BONE)

    H.Capture(function()
        H.Advance(3000)
    end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Alive')
    H.Equal(H.ClientEvents('ug-core:PlayersRespawn')[1].args[1], vector4(1, 2, 3, 4))
end)

H.Test('Moving away while dead flags InvalidDeathState once', function()
    fresh()

    die(1, RPG, HEAD_BONE)
    H.Net.coords[101] = vector3(20, 0, 0)

    H.Capture(function()
        H.Advance(2000)
        H.Advance(2000)
    end)

    local flags = UgCore.Internal.Guard.GetFlags(1)

    H.Equal(#flags, 1)
    H.Equal(flags[1].violation, 'InvalidDeathState')
end)

H.Test('requireAlive rejects downed players without flagging them', function()
    fresh()

    local calls = 0
    local S = UgCore.Schema

    UgCore.Network.Register('Shoot', { schema = S.Define({}), rate = { max = 5, per = 1000 }, requireAlive = true }, function()
        calls = calls + 1
    end)

    die(1, PISTOL, LEFT_LEG_BONE)
    H.TriggerNetEvent('ug-core:Shoot', 1)
    H.TriggerNetEvent('ug-core:Shoot', 2)

    H.Equal(calls, 1)
    H.Equal(UgCore.Guard.GetScore(1), 0)
end)

H.Test('Death state exports and restores for the characters module', function()
    fresh()

    die(1, PISTOL, LEFT_LEG_BONE)

    local data = H.Any(UgCore.Internal.Death.Export(1))

    H.Equal({ data.state, #data.injuries }, { 'Downed', 1 })

    UgCore.Players.Revive(1, { clearInjuries = true })
    H.Capture(function()
        UgCore.Internal.Death.Restore(1, data)
    end)

    H.Equal(UgCore.Players.GetDeathState(1), 'Downed')
    H.Equal(UgCore.Players.GetInjuries(1)[1].region, 'LeftLeg')
end)

H.Test('Wrong API usage raises', function()
    fresh()

    H.Raises(function()
        UgCore.Players.Revive(1, { health = 50 })
    end, 'Players.Revive: health MUST be an integer from 101 to 200')

    H.Raises(function()
        UgCore.Players.Respawn(1, H.Any(vector3(0, 0, 0)))
    end, 'Players.Respawn expects coords as a vector4')

    H.Raises(function()
        UgCore.Players.ClearInjuries(1, H.Any('Tail'))
    end, 'Players.ClearInjuries: unknown region "Tail"')
end)

-- Client

H.Test('LocalPlayer reads statebags and the client applies the server state', function()
    fresh()
    die(1, PISTOL, LEFT_LEG_BONE)

    H.Net.health[101] = 0
    H.Capture(function()
        H.LoadManifest('client')
    end)

    H.Equal(UgCore.LocalPlayer.GetDeathState(), 'Downed')
    H.Equal(UgCore.LocalPlayer.IsDowned(), true)
    H.Equal(UgCore.LocalPlayer.GetInjuries()[1].region, 'LeftLeg')
    H.Equal(H.Net.calls[1], 'resurrect 0 0 0 0')
    H.Equal(H.Net.health[101], 150)

    H.Capture(function()
        H.Advance(0)
    end)

    H.Equal(H.Net.disabled[24], true)
    H.Assert(contains(H.Net.calls, 'anim combat@damage@writhe writhe_loop'), 'downed animation not played')
end)

H.Test('The client reports a fatal injury once per state', function()
    fresh()
    H.Capture(function()
        H.LoadManifest('client')
    end)

    H.Net.health[101] = 0
    H.Net.lastBone[101] = HEAD_BONE

    H.Capture(function()
        H.Advance(250)
        H.Advance(250)
    end)

    local reports = {}

    for _, record in ipairs(H.Net.server) do
        if record.name == 'ug-core:PlayersReportFatal' then
            reports[#reports + 1] = record.args[1]
        end
    end

    H.Equal(reports, { HEAD_BONE })
end)

H.Done()
