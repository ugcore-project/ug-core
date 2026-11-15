--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'inventory',
    namespace = 'Inventory',
    description = 'Player inventories, stashes, vehicle trunks and gloveboxes, and ground drops, with an item audit log.',
    deps = { 'items', 'characters' },
    shared = { 'enums' },
    server = { 'store', 'api', 'service', 'containers', 'sessions', 'net' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Inventory.Init(ctx)
        UgCore.Internal.InventoryContainers.Init(ctx)
        UgCore.Internal.InventorySessions.Init()
        UgCore.Internal.InventoryNet.Init(ctx)
    end,
}
