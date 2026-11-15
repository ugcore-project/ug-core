--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'needs',
    namespace = 'Needs',
    description = 'Hunger, thirst, stress and custom needs per character.',
    deps = { 'characters' },
    shared = { 'enums' },
    server = { 'api' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Needs.Init(ctx)
    end,
    Start = function()
        UgCore.Internal.Needs.Start()
    end,
    Stop = function()
        UgCore.Internal.Needs.Stop()
    end,
}
