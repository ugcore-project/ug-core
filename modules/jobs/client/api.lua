--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---The local player's job, from the `ug-core:Job` statebag.
---@class UgCore.Jobs
local Jobs = {}
UgCore.Jobs = Jobs

---@return UgAssignment?
function Jobs.Get()
    return UgCore.Internal.Utils.Table.DeepCopy(LocalPlayer.state[UgCore.Enums.StateBags.Job])
end

---@return boolean
function Jobs.IsOnDuty()
    local job = LocalPlayer.state[UgCore.Enums.StateBags.Job]

    return type(job) == 'table' and job.onDuty == true
end
