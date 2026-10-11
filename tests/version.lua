--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---Boots ug-core with `version` in its manifest.
---@param version string
local function boot(version)
    H.ResourceFiles = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.Metadata = {}
    H.ResourceMetadata = { ['ug-core'] = { version = version } }
    H.Capture(function()
        H.LoadManifest('server')
    end)
end

H.Test('Get reads the ug-core manifest version', function()
    boot('1.4.2')

    H.Equal(UgCore.Version.Get(), '1.4.2')
end)

H.Test('IsAtLeast compares major, minor and patch numerically', function()
    boot('1.10.0')

    H.Equal(UgCore.Version.IsAtLeast('1.9.9'), true)
    H.Equal(UgCore.Version.IsAtLeast('1.10.0'), true)
    H.Equal(UgCore.Version.IsAtLeast('1.10.1'), false)
    H.Equal(UgCore.Version.IsAtLeast('2.0.0'), false)
end)

H.Test('Pre-release suffixes are ignored', function()
    boot('1.2.0-beta.1')

    H.Equal(UgCore.Version.IsAtLeast('1.2.0'), true)
end)

H.Test('Require raises for an older ug-core, pointing to the caller', function()
    boot('1.0.0')

    local line = debug.getinfo(1, 'l').currentline + 2
    local message = H.Raises(function()
        UgCore.Version.Require('1.2.0')
    end, '[ug-core] ug-core requires ug-core 1.2.0 or newer, found 1.0.0. Update ug-core.')

    H.Assert(message:find('tests/version.lua:' .. line .. ':', 1, true) == 1, message)
end)

H.Test('Require passes for the same or a newer version', function()
    boot('1.3.0')

    H.Equal(H.Capture(function()
        UgCore.Version.Require('1.2.0')
        UgCore.Version.Require('1.3.0')
    end), {})
end)

H.Test('Require warns when ug-core has a newer major version', function()
    boot('2.1.0')

    H.Equal(H.Capture(function()
        UgCore.Version.Require('1.2.0')
    end), { '^3[WARN]^7 ug-core was built for ug-core 1.x, found 2.1.0. Check the breaking changes of ug-core 2.0.0.' })
end)

H.Test('Malformed versions raise', function()
    boot('1.0.0')

    H.Raises(function()
        UgCore.Version.Require('v1')
    end, 'Version.Require expects a version such as "1.2.0"')

    H.Raises(function()
        UgCore.Version.IsAtLeast(H.Any(1))
    end, 'Version.IsAtLeast expects a version such as "1.2.0"')
end)

H.Test('Importing resources check the version locally, as themselves', function()
    boot('1.0.0')

    local Consumer = H.LoadImport('ug-banking', 'server').UgCore

    H.Equal(Consumer.Version.Get(), '1.0.0')
    H.Raises(function()
        Consumer.Version.Require('1.1.0')
    end, 'ug-banking requires ug-core 1.1.0 or newer, found 1.0.0. Update ug-core.')
end)

H.Test('ugcore_version in a consumer manifest stops the import of an older ug-core', function()
    boot('1.0.0')
    H.ResourceMetadata['ug-banking'] = { ugcore_version = '1.5.0' }

    H.Raises(function()
        H.LoadImport('ug-banking', 'server')
    end, 'ug-banking requires ug-core 1.5.0 or newer, found 1.0.0. Update ug-core.')

    H.ResourceMetadata['ug-banking'] = { ugcore_version = '1.0.0' }

    H.Assert(H.LoadImport('ug-banking', 'server').UgCore ~= nil)
end)

H.Done()
