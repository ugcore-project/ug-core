--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---One gang per character, from config/gangs.lua. The current gang replicates in the `ug-core:Gang` statebag.
---@class UgCore.Gangs
local Gangs = {}
UgCore.Gangs = Gangs

---@class UgCore.Internal.Gangs
local InternalGangs = {}
UgCore.Internal.Gangs = InternalGangs

---@type table
local impl = {}

---@param source integer
---@return UgAssignment? nil without a loaded character
function Gangs.Get(source)
    return impl.Get(source)
end

---MUST run in a thread. Unknown gangs and grades return `invalid_args`.
---@param source integer
---@param name string
---@param grade? integer defaults to 1
---@return boolean ok
---@return UgErrorCode? errorCode
function Gangs.Set(source, name, grade)
    return impl.Set(source, name, grade)
end

---MUST run in a thread.
---@param source integer
---@param grade integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Gangs.SetGrade(source, grade)
    return impl.SetGrade(source, grade)
end

---@param name string
---@param grade? integer
---@return boolean
function Gangs.Exists(name, grade)
    return impl.Exists(name, grade)
end

---@param name string
---@return UgAssignmentDefinition?
function Gangs.GetDefinition(name)
    return impl.GetDefinition(name)
end

---@param ctx UgModuleContext
function InternalGangs.Init(ctx)
    local Enums = UgCore.Enums

    impl = UgCore.Internal.Assignments.Create({
        namespace = 'Gangs',
        config = 'gangs',
        table = 'ug_character_gangs',
        statebag = UgCore.Enums.StateBags.Gang,
        default = 'none',
        duty = false,
        changed = Enums.Events.Gangs.Changed,
        beforeSet = Enums.Hooks.Gangs.BeforeSet,
    }, ctx)
end
