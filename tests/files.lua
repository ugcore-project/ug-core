--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local Files = UgCore.Internal.Files

H.Test('Load returns nil for a missing file', function()
    H.Equal(Files.Load('config/missing.lua'), nil)
    H.Equal(Files.Exists('config/missing.lua'), false)
end)

H.Test('Save then Load round-trips content', function()
    H.Equal(Files.Save('config/core.lua', 'return {}\n'), true)
    H.Equal(Files.Exists('config/core.lua'), true)
    H.Equal(Files.Load('config/core.lua'), 'return {}\n')
end)

H.Test('Save overwrites', function()
    Files.Save('config/a.lua', 'first')
    Files.Save('config/a.lua', 'second')
    H.Equal(Files.Load('config/a.lua'), 'second')
end)

H.Test('Save keeps multibyte content intact', function()
    local content = '-- café · ✓\n'
    Files.Save('config/utf8.lua', content)
    H.Equal(Files.Load('config/utf8.lua'), content)
end)

H.Test('Empty file exists', function()
    Files.Save('config/empty.lua', '')
    H.Equal(Files.Exists('config/empty.lua'), true)
    H.Equal(Files.Load('config/empty.lua'), '')
end)

H.Test('Invalid paths raise', function()
    H.Raises(function()
        Files.Load('')
    end, '[ug-core] Files.Load expects a non-empty path')

    H.Raises(function()
        Files.Exists(H.Any(nil))
    end, '[ug-core] Files.Exists expects a non-empty path')

    H.Raises(function()
        Files.Save(H.Any(1), 'x')
    end, '[ug-core] Files.Save expects a non-empty path')
end)

H.Test('Save raises on non-string content', function()
    H.Raises(function()
        Files.Save('config/a.lua', H.Any({}))
    end, '[ug-core] Files.Save expects string content, got table')
end)

H.Test('Save is server-only', function()
    H.LoadManifest('client')

    H.Raises(function()
        UgCore.Internal.Files.Save('config/a.lua', 'x')
    end, '[ug-core] Files.Save is server-only')

    H.Equal(UgCore.Internal.Files.Load('config/core.lua'), 'return {}\n')
end)

H.Done()
