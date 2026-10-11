--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'identity',
    namespace = 'Identity',
    description = 'Player identifiers, primary identifier and bans.',
    required = true,
    server = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Identity.Init(ctx)
    end,
}
