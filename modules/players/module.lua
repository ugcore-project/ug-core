--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'players',
    namespace = 'Players',
    clientNamespace = 'LocalPlayer',
    description = 'Connected players, metadata, death state and injuries.',
    required = true,
    deps = { 'identity' },
    shared = { 'enums', 'lookups' },
    server = { 'api', 'death' },
    client = { 'api', 'death' },
    Init = function(ctx)
        UgCore.Internal.Players.Init(ctx)
        UgCore.Internal.Death.Init(ctx)
    end,
    Start = function(ctx)
        UgCore.Internal.Players.Start(ctx)
    end,
}
