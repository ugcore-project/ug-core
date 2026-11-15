--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---One job per character, from config/jobs.lua. The current job replicates in the `ug-core:Job` statebag.
---@class UgCore.Jobs
local Jobs = {}
UgCore.Jobs = Jobs

---@class UgCore.Internal.Jobs
local InternalJobs = {}
UgCore.Internal.Jobs = InternalJobs

---@type table
local impl = {}

---@param source integer
---@return UgAssignment? nil without a loaded character
function Jobs.Get(source)
    return impl.Get(source)
end

---MUST run in a thread. Unknown jobs and grades return `invalid_args`.
---@param source integer
---@param name string
---@param grade? integer defaults to 1
---@return boolean ok
---@return UgErrorCode? errorCode
function Jobs.Set(source, name, grade)
    return impl.Set(source, name, grade)
end

---MUST run in a thread.
---@param source integer
---@param grade integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Jobs.SetGrade(source, grade)
    return impl.SetGrade(source, grade)
end

---@param source integer
---@param onDuty boolean
---@return boolean ok
---@return UgErrorCode? errorCode
function Jobs.SetDuty(source, onDuty)
    return impl.SetDuty(source, onDuty)
end

---@param source integer
---@return boolean
function Jobs.IsOnDuty(source)
    return impl.IsOnDuty(source)
end

---@param name string
---@param grade? integer
---@return boolean
function Jobs.Exists(name, grade)
    return impl.Exists(name, grade)
end

---@param name string
---@return UgAssignmentDefinition?
function Jobs.GetDefinition(name)
    return impl.GetDefinition(name)
end

---@param ctx UgModuleContext
function InternalJobs.Init(ctx)
    local Enums = UgCore.Enums

    impl = UgCore.Internal.Assignments.Create({
        namespace = 'Jobs',
        config = 'jobs',
        table = 'ug_character_jobs',
        statebag = UgCore.Enums.StateBags.Job,
        default = 'unemployed',
        duty = true,
        changed = Enums.Events.Jobs.Changed,
        dutyChanged = Enums.Events.Jobs.DutyChanged,
        beforeSet = Enums.Hooks.Jobs.BeforeSet,
    }, ctx)
end
