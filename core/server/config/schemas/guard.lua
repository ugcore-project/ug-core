--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

UgCore.Internal.Config.Register('guard', {
    kind = 'settings',
    options = {
        {
            key = 'decayPerMinute',
            type = 'number',
            default = 1,
            min = 0,
            description = 'Score removed from every player per minute.',
        },
        {
            key = 'warnScore',
            type = 'integer',
            default = 10,
            min = 0,
            description = 'Score that logs a warning with recent flags. 0 disables it.',
        },
        {
            key = 'kickScore',
            type = 'integer',
            default = 25,
            min = 0,
            description = 'Score that kicks the player. 0 disables it.',
        },
        {
            key = 'banScore',
            type = 'integer',
            default = 0,
            min = 0,
            description = 'Score that bans the player. Needs the identity module. 0 disables it.',
        },
        {
            key = 'budgetMax',
            type = 'integer',
            default = 40,
            min = 1,
            description = 'Burst of net events and callbacks per player, across every resource.',
        },
        {
            key = 'budgetPer',
            type = 'integer',
            default = 1000,
            min = 100,
            description = 'Time in ms to refill an empty budget.',
        },
    },
})
