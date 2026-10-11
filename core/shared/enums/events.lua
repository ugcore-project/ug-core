--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Module groups are declared in their module's shared/enums.lua.
---@alias UgCoreEvent UgLifecycleEvent|UgPlayersEvent|UgGuardEvent|UgCharactersEvent|UgAccountsEvent|UgJobsEvent|UgGangsEvent|UgSessionsEvent|UgCommandsEvent|UgPermissionsEvent|UgItemsEvent|UgInventoryEvent|UgWeaponsEvent|UgShopsEvent

---@enum UgLifecycleEvent
UgCore.Enums.Events.Lifecycle = {
    Changed = 'ug-core:Lifecycle:Changed',
    Ready = 'ug-core:Lifecycle:Ready',
    Stopping = 'ug-core:Lifecycle:Stopping',
}

---@enum UgPlayersEvent
UgCore.Enums.Events.Players = {
    Loaded = 'ug-core:Players:Loaded',
    Injured = 'ug-core:Players:Injured',
    Downed = 'ug-core:Players:Downed',
    Died = 'ug-core:Players:Died',
    Revived = 'ug-core:Players:Revived',
    Respawned = 'ug-core:Players:Respawned',
    DeathStateChanged = 'ug-core:Players:DeathStateChanged',
}

---@enum UgGuardEvent
UgCore.Enums.Events.Guard = {
    Flagged = 'ug-core:Guard:Flagged',
}
