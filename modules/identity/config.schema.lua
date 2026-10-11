--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'primaryIdentifier',
            type = 'string',
            default = 'license',
            values = { 'license', 'license2', 'steam', 'discord', 'fivem' },
            description = 'Identifier type that identifies a player. Players without it cannot connect.',
        },
    },
}
