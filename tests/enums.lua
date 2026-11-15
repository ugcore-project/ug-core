--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local Enums = UgCore.Enums

---@param enum table<string, string>
local function assertUnique(enum)
    local seen = {}

    for key, value in pairs(enum) do
        H.Assert(not seen[value], ('%s and %s share the value "%s"'):format(tostring(seen[value]), key, value))
        seen[value] = key
    end
end

H.Test('Every violation has a positive integer weight', function()
    for key, violation in pairs(Enums.Violations) do
        local weight = Enums.ViolationWeights[violation]

        H.Assert(math.type(weight) == 'integer' and weight > 0, key .. ' has no positive integer weight')
    end

    for violation in pairs(Enums.ViolationWeights) do
        H.Assert(Enums.Violations[violation] == violation, violation .. ' has a weight but is not a violation')
    end
end)

H.Test('Event names are ug-core:<Group>:<Key>', function()
    for group, events in pairs(Enums.Events) do
        for key, name in pairs(events) do
            H.Equal(name, ('ug-core:%s:%s'):format(group, key))
        end
    end
end)

H.Test('Hook names are <Group>:<Key>', function()
    for group, hooks in pairs(Enums.Hooks) do
        for key, name in pairs(hooks) do
            H.Equal(name, ('%s:%s'):format(group, key))
        end
    end
end)

H.Test('Enum values are unique', function()
    assertUnique(Enums.Lifecycle)
    assertUnique(Enums.Violations)
    assertUnique(Enums.Errors)
    assertUnique(Enums.StateBags)
    assertUnique(Enums.GlobalState)
    assertUnique(Enums.GuardActions)
end)

H.Test('Statebag and GlobalState keys are ug-core:<Key>', function()
    for _, enum in ipairs({ Enums.StateBags, Enums.GlobalState }) do
        for key, name in pairs(enum) do
            H.Equal(name, 'ug-core:' .. key)
        end
    end
end)

H.Test('Enums load on the client', function()
    H.LoadManifest('client')

    H.Equal(UgCore.Enums.Errors.InvalidArgs, 'invalid_args')
end)

H.Done()
