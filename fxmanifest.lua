--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@diagnostic disable: undefined-global

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'ug-core'
author 'UgCore Framework & Contributors'
version '1.0.0' -- x-release-please-version
description 'Core resource of the UgCore Framework'
repository 'https://github.com/ugcore-project/ug-core'

ug_module 'identity'
ug_module 'players'
ug_module 'permissions'
ug_module 'characters'
ug_module 'accounts'
ug_module 'jobs'
ug_module 'gangs'
ug_module 'sessions'
ug_module 'commands'
ug_module 'locale'
ug_module 'items'
ug_module 'inventory'
ug_module 'weapons'
ug_module 'shops'

dependencies {
    '/onesync',
    'oxmysql'
}

shared_scripts {
    'core/shared/init.lua',
    'core/shared/utils/init.lua',
    'core/shared/utils/table.lua',
    'core/shared/utils/string.lua',
    'core/shared/enums/init.lua',
    'core/shared/enums/lifecycle.lua',
    'core/shared/enums/events.lua',
    'core/shared/enums/hooks.lua',
    'core/shared/enums/violations.lua',
    'core/shared/enums/errors.lua',
    'core/shared/enums/statebags.lua',
    'core/shared/files.lua',
    'core/shared/logger.lua',
    'core/shared/version.lua',
    'core/shared/events.lua',
    'core/shared/lifecycle.lua',
    'core/shared/modules.lua',
    'core/shared/exports.lua',
    'core/shared/schema.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'core/server/ratelimit.lua',
    'core/server/config/init.lua',
    'core/server/config/validator.lua',
    'core/server/config/serializer.lua',
    'core/server/config/loader.lua',
    'core/server/config/api.lua',
    'core/server/config/schemas/core.lua',
    'core/server/config/schemas/guard.lua',
    'core/server/hooks.lua',
    'core/server/guard.lua',
    'core/server/network.lua',
    'core/server/callback.lua',
    'core/server/database/init.lua',
    'core/server/database/repository.lua',
    'core/server/database/cache.lua',
    'core/server/database/migrate.lua',
    'core/server/assignments.lua',
    'core/server/player.lua',
    'core/server/modules/loader.lua',
    'core/server/updates.lua',
    'core/server/command.lua',
    'core/server/boot.lua',
}

client_scripts {
    'core/client/config.lua',
    'core/client/network.lua',
    'core/client/callback.lua',
    'core/client/boot.lua',
}

files {
    'import.lua',
    'import/*.lua',
    'core/shared/*.lua',
    'core/shared/utils/*.lua',
    'core/shared/enums/*.lua',
    'core/client/network.lua',
    'core/client/callback.lua',
    'modules/**/shared/*.lua',
    'modules/**/client/*.lua',
    'locales/*.json',
}
