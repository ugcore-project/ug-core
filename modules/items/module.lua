--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'items',
    namespace = 'Items',
    description = 'Item definitions and usable items.',
    shared = { 'enums' },
    server = { 'api' },
    client = { 'api' },
    Init = function(ctx)
        UgCore.Internal.Items.Init(ctx)
    end,
}
