--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local Table = UgCore.Internal.Utils.Table
local String = UgCore.Internal.Utils.String

---@param value any
local function raiseFromApi(value)
    UgCore.Internal.Utils.Raise(2, 'Api expects %s, got %s', 'a table', type(value))
end

H.Test('Raise prefixes and formats the message', function()
    H.Raises(function()
        UgCore.Internal.Utils.Raise(1, 'plain 100%')
    end, '[ug-core] plain 100%')

    H.Raises(function()
        raiseFromApi(1)
    end, '[ug-core] Api expects a table, got number')
end)

H.Test('Raise level points to the caller of the API', function()
    local line = debug.getinfo(1, 'l').currentline + 2
    local message = H.Raises(function()
        raiseFromApi(1)
    end)

    H.Assert(message:find('tests/utils.lua:' .. line .. ':', 1, true) == 1, 'trace points to: ' .. message)
end)

H.Test('DeepCopy returns primitives unchanged', function()
    H.Equal(Table.DeepCopy(5), 5)
    H.Equal(Table.DeepCopy('a'), 'a')
    H.Equal(Table.DeepCopy(nil), nil)
    H.Equal(Table.DeepCopy(false), false)
end)

H.Test('DeepCopy copies nested tables', function()
    local source = { a = 1, list = { 1, 2, { deep = true } } }
    local copy = Table.DeepCopy(source)

    H.Equal(copy, source)
    H.Assert(copy ~= source)
    H.Assert(copy.list ~= source.list)
    H.Assert(copy.list[3] ~= source.list[3])

    copy.list[3].deep = false
    H.Equal(source.list[3].deep, true)
end)

H.Test('DeepCopy keeps cycles and shared references', function()
    local shared = { value = 1 }
    local source = { first = shared, second = shared }
    source.self = source

    local copy = Table.DeepCopy(source)

    H.Assert(copy.self == copy)
    H.Assert(copy.first == copy.second)
    H.Assert(copy.first ~= shared)
end)

H.Test('DeepCopy drops metatables', function()
    local source = setmetatable({ a = 1 }, { __index = { hidden = true } })
    local copy = Table.DeepCopy(source)

    H.Equal(getmetatable(copy), nil)
    H.Equal(copy.hidden, nil)
end)

H.Test('Count counts array and hash keys', function()
    H.Equal(Table.Count({}), 0)
    H.Equal(Table.Count({ 1, 2, 3 }), 3)
    H.Equal(Table.Count({ 1, 2, a = 1, b = 2 }), 4)
    H.Equal(Table.Count({ [1] = 1, [10] = 10 }), 2)
end)

H.Test('Count raises on non-table', function()
    H.Raises(function()
        Table.Count(H.Any('a'))
    end, '[ug-core] Table.Count expects a table, got string')
end)

H.Test('Distance matches known Levenshtein values', function()
    H.Equal(String.Distance('', ''), 0)
    H.Equal(String.Distance('abc', ''), 3)
    H.Equal(String.Distance('', 'abc'), 3)
    H.Equal(String.Distance('same', 'same'), 0)
    H.Equal(String.Distance('kitten', 'sitting'), 3)
    H.Equal(String.Distance('flaw', 'lawn'), 2)
    H.Equal(String.Distance('startingcash', 'startingCash'), 1)
end)

H.Test('Distance is symmetric', function()
    H.Equal(String.Distance('debug', 'debgu'), String.Distance('debgu', 'debug'))
end)

H.Test('Distance raises on non-string', function()
    H.Raises(function()
        String.Distance('a', H.Any(1))
    end, '[ug-core] String.Distance expects two strings')
end)

H.Test('Suggest ignores case', function()
    H.Equal(String.Suggest('startingcash', { 'debug', 'startingCash' }), 'startingCash')
end)

H.Test('Suggest returns nil past the default distance of 3', function()
    H.Equal(String.Suggest('abcd', { 'wxyz' }), nil)
    H.Equal(String.Suggest('abcd', { 'axyz' }), 'axyz')
end)

H.Test('Suggest honors maxDistance', function()
    H.Equal(String.Suggest('locale', { 'locales' }, 0), nil)
    H.Equal(String.Suggest('locale', { 'locales' }, 1), 'locales')
end)

H.Test('Suggest picks the closest candidate, then the earliest', function()
    H.Equal(String.Suggest('debug', { 'debugs', 'debug_', 'debu' }), 'debugs')
    H.Equal(String.Suggest('debug', { 'xebug', 'debug2' }), 'xebug')
    H.Equal(String.Suggest('debug', { 'debgu', 'debug' }), 'debug')
end)

H.Test('Suggest returns nil for no candidates', function()
    H.Equal(String.Suggest('debug', {}), nil)
end)

H.Done()
