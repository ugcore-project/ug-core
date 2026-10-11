--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'commands',
    namespace = 'Commands',
    description = 'Chat commands with typed arguments, permissions and rate limits.',
    deps = { 'players', 'permissions' },
    shared = { 'enums' },
    server = { 'api' },
}
