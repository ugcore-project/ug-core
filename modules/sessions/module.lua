--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'sessions',
    namespace = 'Sessions',
    description = 'Separate worlds on routing buckets, such as instances and lobbies.',
    deps = { 'players' },
    shared = { 'enums' },
    server = { 'api' },
    Init = function(ctx)
        UgCore.Internal.Sessions.Init(ctx)
    end,
    Stop = function(ctx)
        UgCore.Internal.Sessions.Stop(ctx)
    end,
}
