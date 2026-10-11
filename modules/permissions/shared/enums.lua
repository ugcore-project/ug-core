--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgPermissionsEvent
UgCore.Enums.Events.Permissions = {
    GroupAdded = 'ug-core:Permissions:GroupAdded',
    GroupRemoved = 'ug-core:Permissions:GroupRemoved',
}

---@enum UgPermissionsHook
UgCore.Enums.Hooks.Permissions = {
    BeforeGroupAdd = 'Permissions:BeforeGroupAdd',
    BeforeGroupRemove = 'Permissions:BeforeGroupRemove',
}
