--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

-- Settles the boot timer, so H.Advance below only moves the clock.
H.Capture(function()
    H.Advance(0)
end)

local RateLimit = UgCore.RateLimit

H.Test('Consume allows a burst of max, then refuses', function()
    local limiter = RateLimit.Create({ max = 3, per = 1000 })

    H.Equal({ limiter:Consume(1) }, { true, 0 })
    H.Equal({ limiter:Consume(1) }, { true, 0 })
    H.Equal({ limiter:Consume(1) }, { true, 0 })
    H.Equal({ limiter:Consume(1) }, { false, 334 })
end)

H.Test('retryAfter is exact when the token arrives', function()
    local limiter = RateLimit.Create({ max = 5, per = 1000 })

    for _ = 1, 5 do
        limiter:Consume(1)
    end

    local allowed, retryAfter = limiter:Consume(1)

    H.Equal(allowed, false)
    H.Equal(retryAfter, 200)

    H.Advance(199)
    H.Equal((limiter:Consume(1)), false)

    H.Advance(1)
    H.Equal((limiter:Consume(1)), true)
end)

H.Test('Bucket refills over per and caps at max', function()
    local limiter = RateLimit.Create({ max = 2, per = 100 })

    limiter:Consume(1)
    limiter:Consume(1)
    H.Advance(100000)

    H.Equal((limiter:Consume(1)), true)
    H.Equal((limiter:Consume(1)), true)
    H.Equal((limiter:Consume(1)), false)
end)

H.Test('Keys have independent buckets', function()
    local limiter = RateLimit.Create({ max = 1, per = 1000 })

    H.Equal((limiter:Consume(1)), true)
    H.Equal((limiter:Consume(1)), false)
    H.Equal((limiter:Consume(2)), true)
    H.Equal((limiter:Consume('license:abc')), true)
end)

H.Test('Reset refills a key', function()
    local limiter = RateLimit.Create({ max = 1, per = 1000 })

    limiter:Consume(1)
    limiter:Reset(1)

    H.Equal((limiter:Consume(1)), true)
end)

H.Test('Prune drops full buckets only', function()
    local limiter = RateLimit.Create({ max = 1, per = 1000 })

    limiter:Consume(1)
    H.Advance(500)
    limiter:Consume(2)
    H.Advance(500)

    H.Equal(limiter:Prune(), 1)
    H.Equal((limiter:Consume(2)), false)
    H.Equal((limiter:Consume(1)), true)
end)

H.Test('Clear drops every bucket', function()
    local limiter = RateLimit.Create({ max = 1, per = 1000 })

    limiter:Consume(1)
    limiter:Consume(2)
    limiter:Clear()

    H.Equal((limiter:Consume(1)), true)
    H.Equal((limiter:Consume(2)), true)
end)

H.Test('Player drop resets every limiter for that player', function()
    local first = RateLimit.Create({ max = 1, per = 1000 })
    local second = RateLimit.Create({ max = 1, per = 1000 })

    first:Consume(7)
    second:Consume(7)
    first:Consume(8)

    H.TriggerEvent('playerDropped', 7, 'Exiting')

    H.Equal((first:Consume(7)), true)
    H.Equal((second:Consume(7)), true)
    H.Equal((first:Consume(8)), false)
end)

H.Test('Create rejects invalid options', function()
    H.Raises(function()
        RateLimit.Create(H.Any(nil))
    end, 'RateLimit.Create expects options { max, per }')

    H.Raises(function()
        RateLimit.Create({ max = 0, per = 1000 })
    end, '"max" MUST be a positive integer')

    H.Raises(function()
        RateLimit.Create({ max = 1, per = 1.5 })
    end, '"per" MUST be a positive integer')
end)

H.Done()
