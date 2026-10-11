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
            key = 'maxCharacters',
            type = 'integer',
            default = 4,
            min = 1,
            max = 32,
            description = 'Characters a player MAY own. Deleted characters do not count.',
        },
        {
            key = 'persistPosition',
            type = 'boolean',
            default = true,
            description = 'Saves the last position of loaded characters, read from the ped on the server.',
        },
        {
            key = 'positionInterval',
            type = 'integer',
            default = 300000,
            min = 0,
            max = 3600000,
            description = 'Ms between position saves while playing. 0 saves on unload, disconnect and stop only.',
            validate = function(value)
                return value == 0 or value >= 30000, 'MUST be 0 or at least 30000 ms'
            end,
        },
    },
}
