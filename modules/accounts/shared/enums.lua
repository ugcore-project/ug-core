--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgAccountsEvent
UgCore.Enums.Events.Accounts = {
    Changed = 'ug-core:Accounts:Changed',
}

---@enum UgAccountsHook
UgCore.Enums.Hooks.Accounts = {
    BeforeAdd = 'Accounts:BeforeAdd',
    BeforeRemove = 'Accounts:BeforeRemove',
    BeforeTransfer = 'Accounts:BeforeTransfer',
}
