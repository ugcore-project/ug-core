--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgConfigDataDefinition
return {
    kind = 'data',
    description = 'Gangs by name: { label, grades = { { name, label, salary, boss? }, ... } }. Grades start at 1. "none" MUST exist.',
    side = 'shared',
    default = {
        none = {
            label = 'None',
            grades = {
                { name = 'none', label = 'None', salary = 0 },
            },
        },
    },
    validate = function(entry, id)
        return UgCore.Internal.Assignments.ValidateDefinition(entry, id)
    end,
}
