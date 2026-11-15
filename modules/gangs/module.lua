--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'gangs',
    namespace = 'Gangs',
    description = 'Gangs with grades, one per character.',
    deps = { 'characters' },
    shared = { 'enums' },
    server = { 'api' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Gangs.Init(ctx)
    end,
}
