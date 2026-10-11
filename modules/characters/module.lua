--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'characters',
    namespace = 'Characters',
    description = 'Characters per player. A player is loaded once a character is loaded.',
    deps = { 'players' },
    shared = { 'enums' },
    server = { 'api' },
    migrations = { '1.0.0', '1.1.0' },
    Init = function(ctx)
        UgCore.Internal.Characters.Init(ctx)
    end,
    Stop = function(ctx)
        UgCore.Internal.Characters.Stop(ctx)
    end,
}
