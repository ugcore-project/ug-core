--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'accounts',
    namespace = 'Accounts',
    description = 'Cash, bank and custom accounts with a ledger.',
    deps = { 'characters' },
    shared = { 'enums' },
    server = { 'api' },
    client = { 'api' },
    migrations = { '1.0.0' },
    Init = function(ctx)
        UgCore.Internal.Accounts.Init(ctx)
    end,
}
