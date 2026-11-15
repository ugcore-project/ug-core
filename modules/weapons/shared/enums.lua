--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgWeaponsEvent
UgCore.Enums.Events.Weapons = {
    Equipped = 'ug-core:Weapons:Equipped',
    Unequipped = 'ug-core:Weapons:Unequipped',
    Broken = 'ug-core:Weapons:Broken',
}

---@enum UgWeaponsHook
UgCore.Enums.Hooks.Weapons = {
    BeforeEquip = 'Weapons:BeforeEquip',
}
