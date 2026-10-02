--[[

    ug-core
    Copyright (C) 2026 UgCore Framework & Contributors.
    https://github.com/ugcore-project/ug-core

]]--

---@diagnostic disable: undefined-global

fx_version 'cerulean'
game 'gta5'
lua54 'yes'
use_experimental_fxv2_oal 'yes'

name 'ug-core'
author 'UgCore Framework & Contributors'
version '1.0.0'
description 'Core resource of the UgCore framework'
repository 'https://github.com/ugcore-project/ug-core'

dependencies {
    '/onesync',
    'oxmysql'
}

shared_scripts {
    'core/shared/namespace.lua',
    'core/shared/utils/init.lua',
    'core/shared/utils/table.lua',
    'core/shared/utils/string.lua',
    'core/shared/files.lua',
    'core/shared/logger.lua',
}

server_scripts {
    '@oxmysql/lib/MySQL.lua',
    'core/server/config/init.lua',
    'core/server/config/validator.lua',
    'core/server/config/serializer.lua',
    'core/server/config/loader.lua',
    'core/server/config/api.lua',
    'core/server/boot.lua',
}

client_scripts {
    'core/client/config.lua',
    'core/client/boot.lua',
}

files {
    'import/**/*.lua',
    'modules/**/module.lua',
    'modules/**/shared/*.lua',
    'modules/**/client/*.lua',
    'locales/*.json',
}
