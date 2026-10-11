--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgConfigDataDefinition
return {
    kind = 'data',
    description = 'Jobs by name: { label, defaultDuty?, grades = { { name, label, salary, boss? }, ... } }. Grades start at 1. "unemployed" MUST exist.',
    side = 'shared',
    default = {
        unemployed = {
            label = 'Unemployed',
            grades = {
                { name = 'unemployed', label = 'Unemployed', salary = 0 },
            },
        },
        police = {
            label = 'Police',
            defaultDuty = false,
            grades = {
                { name = 'recruit', label = 'Recruit', salary = 100 },
                { name = 'officer', label = 'Officer', salary = 150 },
                { name = 'sergeant', label = 'Sergeant', salary = 200 },
                { name = 'chief', label = 'Chief', salary = 300, boss = true },
            },
        },
    },
    validate = function(entry, id)
        return UgCore.Internal.Assignments.ValidateDefinition(entry, id)
    end,
}
