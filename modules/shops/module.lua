--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'shops',
    namespace = 'Shops',
    description = 'Shops with server-side prices, stock and restocking.',
    deps = { 'inventory', 'accounts' },
    shared = { 'enums' },
    server = { 'api', 'net' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Shops.Init(ctx)
        UgCore.Internal.ShopsNet.Init()
    end,
}
