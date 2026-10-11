--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local CORE = 'ug-core'

local SHARED_FILES = {
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
    'core/shared/logger.lua',
    'core/shared/version.lua',
    'core/shared/events.lua',
    'core/shared/modules.lua',
    'core/shared/schema.lua',
    'import/proxy.lua',
    'import/lifecycle.lua',
}

local SERVER_FILES = {
    'core/server/ratelimit.lua',
    'core/server/network.lua',
    'core/server/callback.lua',
    'core/server/player.lua',
}

local CLIENT_FILES = {
    'core/client/network.lua',
    'core/client/callback.lua',
}

local private = setmetatable({}, { __index = _ENV })

---@param path string
local function run(path)
    local content = LoadResourceFile(CORE, path)

    if not content then
        error(('[ug-core] import: cannot read %s. Start ug-core before this resource.'):format(path), 0)
    end

    local chunk, syntaxError = load(content, ('@@%s/%s'):format(CORE, path), 't', private)

    if not chunk then
        error(syntaxError, 0)
    end

    chunk()
end

for _, path in ipairs(SHARED_FILES) do
    run(path)
end

for _, path in ipairs(IsDuplicityVersion() and SERVER_FILES or CLIENT_FILES) do
    run(path)
end

local required = GetResourceMetadata(GetCurrentResourceName(), 'ugcore_version', 0)

if required then
    private.UgCore.Version.Require(required)
end

UgCore = private.UgCore.Internal.Proxy.CreateRoot()
