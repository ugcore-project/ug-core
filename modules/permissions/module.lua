--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'permissions',
    namespace = 'Permissions',
    description = 'Permissions and staff groups per identifier, applied as ACEs and principals.',
    required = true,
    deps = { 'identity' },
    shared = { 'enums' },
    server = { 'api', 'groups' },
    migrations = { '1.0.0', '1.1.0' },
    Init = function(ctx)
        UgCore.Internal.Permissions.Init(ctx)
        UgCore.Internal.Groups.Init(ctx)
    end,
}
