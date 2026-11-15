--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgJobsEvent
UgCore.Enums.Events.Jobs = {
    Changed = 'ug-core:Jobs:Changed',
    DutyChanged = 'ug-core:Jobs:DutyChanged',
}

---@enum UgJobsHook
UgCore.Enums.Hooks.Jobs = {
    BeforeSet = 'Jobs:BeforeSet',
}
