--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

UgCore.Internal.Config.Register('core', {
    kind = 'settings',
    options = {
        {
            key = 'locale',
            type = 'string',
            default = 'en',
            min = 2,
            max = 10,
            side = 'shared',
            description = 'Language of core messages and logs.',
        },
        {
            key = 'debug',
            type = 'boolean',
            default = false,
            side = 'shared',
            description = 'Prints debug logs on the server and in client F8.',
        },
    },
})
