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

---Every definition, from config/gangs.lua and from resources.
---@return table<string, UgAssignmentDefinition>
function Gangs.GetAll()
    return impl.GetAll()
end

---Registers a gang a resource needs, so owners do not have to add it by hand. config/gangs.lua wins: a
---gang the owner defines keeps the owner's definition. The first resource to register a name keeps it.
---Registrations stay until ug-core restarts. Raises on a malformed definition.
---@param name string lowercase letters, digits and underscores
---@param definition UgAssignmentDefinition
---@return boolean registered false when config/gangs.lua or another resource defines the name
function Gangs.Register(name, definition)
    return impl.Register(name, definition, GetInvokingResource())
end

---Where a definition comes from: `config`, the registering resource, or nil when unknown.
---@param name string
---@return string?
function InternalGangs.Source(name)
    return impl.Source(name)
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
        registered = Enums.Events.Gangs.Registered,
        beforeSet = Enums.Hooks.Gangs.BeforeSet,
    }, ctx)
end
