--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local Logger = UgCore.Logger
local InternalLogger = UgCore.Internal.Logger

H.Test('Info, Warn and Error print with a colored level tag', function()
    local lines = H.Capture(function()
        Logger.Info('hello')
        Logger.Warn('careful')
        Logger.Error('broken')
    end)

    H.Equal(lines, {
        '^5[INFO]^7 hello',
        '^3[WARN]^7 careful',
        '^1[ERROR]^7 broken',
    })
end)

H.Test('Extra arguments are formatted', function()
    local lines = H.Capture(function()
        Logger.Info('%s modules in %d ms', 6, 184)
    end)

    H.Equal(lines, { '^5[INFO]^7 6 modules in 184 ms' })
end)

H.Test('Message without arguments is not formatted', function()
    local lines = H.Capture(function()
        Logger.Info('100% done')
    end)

    H.Equal(lines, { '^5[INFO]^7 100% done' })
end)

H.Test('Non-string messages are converted', function()
    local lines = H.Capture(function()
        Logger.Info(42)
        Logger.Warn(nil)
    end)

    H.Equal(lines, { '^5[INFO]^7 42', '^3[WARN]^7 nil' })
end)

H.Test('Debug is off by default and prints nothing', function()
    H.Equal(InternalLogger.IsDebug(), false)

    local lines = H.Capture(function()
        Logger.Debug('hidden')
    end)

    H.Equal(lines, {})
end)

H.Test('SetDebug enables Debug output once', function()
    local lines = H.Capture(function()
        InternalLogger.SetDebug(true)
        InternalLogger.SetDebug(true)
        Logger.Debug('visible %d', 1)
    end)

    H.Equal(InternalLogger.IsDebug(), true)
    H.Equal(lines, { '^6[DEBUG]^7 Debug logging enabled.', '^6[DEBUG]^7 visible 1' })

    local after = H.Capture(function()
        InternalLogger.SetDebug(false)
        Logger.Debug('hidden')
    end)

    H.Equal(after, {})
end)

H.Test('SetDebug raises on non-boolean', function()
    H.Raises(function()
        InternalLogger.SetDebug(H.Any('true'))
    end, '[ug-core] Logger.SetDebug expects a boolean, got string')
end)

H.Done()
