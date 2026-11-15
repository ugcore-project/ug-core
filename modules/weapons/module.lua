--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'weapons',
    namespace = 'Weapons',
    description = 'Weapons as items: serials, ammo, attachments, tints and durability.',
    deps = { 'inventory' },
    shared = { 'enums' },
    server = { 'api', 'net' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Weapons.Init(ctx)
        UgCore.Internal.WeaponsNet.Init(ctx)
    end,
}
