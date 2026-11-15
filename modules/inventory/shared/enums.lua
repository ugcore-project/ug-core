--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgInventoryEvent
UgCore.Enums.Events.Inventory = {
    ItemAdded = 'ug-core:Inventory:ItemAdded',
    ItemRemoved = 'ug-core:Inventory:ItemRemoved',
    Changed = 'ug-core:Inventory:Changed',
    Opened = 'ug-core:Inventory:Opened',
    Closed = 'ug-core:Inventory:Closed',
}

---@enum UgInventoryHook
UgCore.Enums.Hooks.Inventory = {
    BeforeAdd = 'Inventory:BeforeAdd',
    BeforeRemove = 'Inventory:BeforeRemove',
    BeforeMove = 'Inventory:BeforeMove',
    BeforeOpen = 'Inventory:BeforeOpen',
    BeforeClearOnRespawn = 'Inventory:BeforeClearOnRespawn',
}
