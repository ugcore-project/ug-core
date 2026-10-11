--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---The local player's gang, from the `ug-core:Gang` statebag.
---@class UgCore.Gangs
local Gangs = {}
UgCore.Gangs = Gangs

---@return UgAssignment?
function Gangs.Get()
    return UgCore.Internal.Utils.Table.DeepCopy(LocalPlayer.state[UgCore.Enums.StateBags.Gang])
end
