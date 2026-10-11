--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

H.LoadManifest('server')

local S = UgCore.Schema

---@param rule UgSchemaRule
---@param value any
---@param expected any
local function accepts(rule, value, expected)
    local ok, checked, detail = S.Check(rule, value)

    H.Assert(ok, 'expected value to pass, got: ' .. tostring(detail))

    if expected ~= nil then
        H.Equal(checked, expected)
    end
end

---@param rule UgSchemaRule
---@param value any
---@param detail string
local function rejects(rule, value, detail)
    local ok, checked, message = S.Check(rule, value)

    H.Equal(ok, false, 'expected value to fail')
    H.Equal(checked, nil)
    H.Equal(message, detail)
end

-- String

H.Test('String accepts valid input', function()
    accepts(S.String({ max = 5 }), 'hello', 'hello')
end)

H.Test('String rejects other types', function()
    rejects(S.String({ max = 5 }), 5, 'value: MUST be a string, got 5')
    rejects(S.String({ max = 5 }), {}, 'value: MUST be a string, got a table')
end)

H.Test('String counts UTF-8 characters, not bytes', function()
    local rule = S.String({ max = 3 })

    accepts(rule, 'éàü')
    rejects(rule, 'éàüö', 'value: MUST be at most 3 characters, got a string of 8 bytes')
end)

H.Test('String rejects input past max * 4 bytes before scanning', function()
    local rule = S.String({ max = 2 })

    rejects(rule, string.rep('\255', 9), 'value: MUST be at most 2 characters, got a string of 9 bytes')
end)

H.Test('String detail never echoes large input', function()
    local ok, _, detail = S.Check(S.String({ max = 32 }), string.rep('a', 1048576))

    H.Equal(ok, false)
    H.Equal(detail, 'value: MUST be at most 32 characters, got a string of 1048576 bytes')
end)

H.Test('String rejects invalid UTF-8', function()
    rejects(S.String({ max = 10 }), 'ab\255', 'value: MUST be valid UTF-8')
    rejects(S.String({ max = 10 }), '\237\160\128', 'value: MUST be valid UTF-8')
end)

H.Test('String rejects control characters', function()
    local rule = S.String({ max = 10 })

    rejects(rule, 'a\0b', 'value: MUST NOT contain control characters')
    rejects(rule, 'a\nb', 'value: MUST NOT contain control characters')
    rejects(rule, 'a\127b', 'value: MUST NOT contain control characters')
    rejects(rule, 'a\194\133b', 'value: MUST NOT contain control characters')
end)

H.Test('String multiline allows tab, line feed and carriage return only', function()
    local rule = S.String({ max = 10, multiline = true })

    accepts(rule, 'a\tb\r\nc')
    rejects(rule, 'a\0b', 'value: MUST NOT contain control characters')
    rejects(rule, 'a\27b', 'value: MUST NOT contain control characters')
end)

H.Test('String enforces min', function()
    rejects(S.String({ min = 2, max = 5 }), 'a', 'value: MUST be at least 2 characters, got a string of 1 bytes')
end)

H.Test('String enforces pattern', function()
    local rule = S.String({ max = 32, pattern = '^[%w_]+$' })

    accepts(rule, 'user_1')
    rejects(rule, 'user 1', 'value: MUST match the expected format')
end)

H.Test('String builder requires max', function()
    H.Raises(function()
        S.String(H.Any({ min = 1 }))
    end, '[ug-core] Schema.String: "max" is required')

    H.Raises(function()
        S.String(H.Any(nil))
    end, '[ug-core] Schema.String requires options with "max"')
end)

H.Test('String builder rejects bad options', function()
    H.Raises(function()
        S.String({ max = -1 })
    end, '"max" MUST be a non-negative integer')

    H.Raises(function()
        S.String({ min = 5, max = 1 })
    end, '"min" MUST NOT be greater than "max"')

    H.Raises(function()
        S.String({ max = 5, pattern = '[' })
    end, '"pattern" MUST be a valid Lua pattern')
end)

H.Test('Unknown option raises with a suggestion', function()
    H.Raises(function()
        S.String(H.Any({ max = 5, multiLine = true }))
    end, 'unknown option "multiLine". Did you mean "multiline"?')
end)

H.Test('Builder errors point to the caller', function()
    local message = H.Raises(function()
        S.Integer(H.Any({ mx = 1 }))
    end)

    H.Assert(message:find('tests/schema.lua:', 1, true) == 1, 'trace points to: ' .. message)
end)

-- Numbers

H.Test('Number rejects NaN and infinity', function()
    local rule = S.Number()

    accepts(rule, 1.5, 1.5)
    rejects(rule, 0 / 0, 'value: MUST be a finite number')
    rejects(rule, math.huge, 'value: MUST be a finite number')
    rejects(rule, -math.huge, 'value: MUST be a finite number')
    rejects(rule, '1', 'value: MUST be a number, got a string of 1 bytes')
end)

H.Test('Number enforces min and max', function()
    local rule = S.Number({ min = 0, max = 1.5 })

    rejects(rule, -1, 'value: MUST be at least 0, got -1')
    rejects(rule, 2, 'value: MUST be at most 1.5, got 2')
end)

H.Test('Integer normalizes integral floats', function()
    local ok, value = S.Check(S.Integer(), 5.0)

    H.Equal(ok, true)
    H.Equal(math.type(value), 'integer')
    H.Equal(value, 5)
end)

H.Test('Integer rejects fractions, NaN and out-of-range floats', function()
    local rule = S.Integer()

    rejects(rule, 5.5, 'value: MUST be an integer, got 5.5')
    rejects(rule, 0 / 0, 'value: MUST be a finite number')
    rejects(rule, 2.0 ^ 63, 'value: MUST be an integer, got 9.2233720368548e+18')
end)

H.Test('Integer enforces min and max', function()
    local rule = S.Integer({ min = 1, max = 1000000 })

    accepts(rule, 1)
    rejects(rule, 0, 'value: MUST be at least 1, got 0')
    rejects(rule, 1000001, 'value: MUST be at most 1000000, got 1000001')
end)

-- Boolean, enum, vectors

H.Test('Boolean accepts booleans only', function()
    accepts(S.Boolean(), false, false)
    rejects(S.Boolean(), 0, 'value: MUST be a boolean, got 0')
end)

H.Test('Enum accepts listed values only', function()
    local rule = S.Enum({ 'cash', 'bank' })

    accepts(rule, 'bank', 'bank')
    rejects(rule, 'crypto', 'value: MUST be one of the allowed values, got a string of 6 bytes')
    rejects(rule, {}, 'value: MUST be one of the allowed values, got a table')
end)

H.Test('Enum builder rejects empty or invalid values', function()
    H.Raises(function()
        S.Enum({})
    end, 'Schema.Enum expects a non-empty array of values')

    H.Raises(function()
        S.Enum(H.Any({ {} }))
    end, 'Schema.Enum values MUST be strings, numbers or booleans')
end)

H.Test('Vector3 checks the native type', function()
    local rule = S.Vector3()

    accepts(rule, vector3(1, 2, 3))
    rejects(rule, { x = 1, y = 2, z = 3 }, 'value: MUST be a vector3, got a table')
    rejects(rule, vector2(1, 2), 'value: MUST be a vector3, got a vector2')
end)

H.Test('Vectors require finite components', function()
    rejects(S.Vector3(), vector3(1, 0 / 0, 3), 'value: MUST have finite components')
    rejects(S.Vector4(), vector4(1, 2, 3, math.huge), 'value: MUST have finite components')
end)

H.Test('Vector maxComponent bounds each component', function()
    local rule = S.Vector2({ maxComponent = 100 })

    accepts(rule, vector2(-100, 100))
    rejects(rule, vector2(0, 100.5), 'value: MUST have components within 100')
    rejects(rule, vector2(-101, 0), 'value: MUST have components within 100')
end)

-- Array

H.Test('Array validates items into a fresh table', function()
    local input = { 1, 2.0, 3 }
    local ok, value = S.Check(S.Array(S.Integer(), { max = 3 }), input)

    H.Equal(ok, true)
    H.Equal(value, { 1, 2, 3 })
    H.Assert(value ~= input)
    H.Equal(math.type(value[2]), 'integer')
end)

H.Test('Array rejects holes and non-integer keys', function()
    local rule = S.Array(S.Integer(), { max = 5 })

    rejects(rule, { 1, nil, 3 }, 'value: MUST NOT have holes')
    rejects(rule, { [2] = 1 }, 'value: MUST NOT have holes')
    rejects(rule, { 1, a = 2 }, 'value: MUST be an array')
    rejects(rule, { [0] = 1 }, 'value: MUST be an array')
end)

H.Test('Array rejects oversized tables before checking items', function()
    rejects(S.Array(S.Integer(), { max = 2 }), { 'a', 'b', 'c' }, 'value: MUST have at most 2 items')
end)

H.Test('Array enforces min and reports item paths', function()
    local rule = S.Array(S.Integer(), { min = 2, max = 5 })

    rejects(rule, { 1 }, 'value: MUST have at least 2 items, got 1')
    rejects(rule, { 1, 'x' }, 'value[2]: MUST be an integer, got a string of 1 bytes')
end)

H.Test('Array builder requires max and a non-optional item', function()
    H.Raises(function()
        S.Array(S.Integer(), H.Any({}))
    end, '"max" is required')

    H.Raises(function()
        S.Array(S.Optional(S.Integer()), { max = 1 })
    end, 'item MUST NOT be Optional')

    H.Raises(function()
        S.Array(H.Any({}), { max = 1 })
    end, 'item MUST be a schema rule')
end)

-- Map

H.Test('Map validates keys and values', function()
    local rule = S.Map(S.String({ max = 8 }), S.Integer(), { max = 2 })
    local ok, value = S.Check(rule, { a = 1, b = 2.0 })

    H.Equal(ok, true)
    H.Equal(value, { a = 1, b = 2 })
end)

H.Test('Map rejects oversized tables and reports paths', function()
    local rule = S.Map(S.String({ max = 8 }), S.Integer(), { max = 2 })

    rejects(rule, { a = 1, b = 2, c = 3 }, 'value: MUST have at most 2 entries')
    rejects(rule, { [1] = 1 }, 'value.<key>: MUST be a string, got 1')
    rejects(rule, { a = 'x' }, 'value["a"]: MUST be an integer, got a string of 1 bytes')
end)

H.Test('Map builder rejects table keys and missing max', function()
    H.Raises(function()
        S.Map(S.Object({}), S.Integer(), { max = 1 })
    end, 'key MUST be a String, Integer, Number, Enum or Boolean rule')

    H.Raises(function()
        S.Map(S.String({ max = 1 }), S.Integer(), H.Any(nil))
    end, 'requires options with "max"')
end)

-- Object

H.Test('Object is strict by default', function()
    local rule = S.Object({ name = S.String({ max = 8 }) })

    accepts(rule, { name = 'a' }, { name = 'a' })
    rejects(rule, { name = 'a', admin = true }, 'value: MUST NOT have unknown fields')
end)

H.Test('Object with strict = false drops unknown keys', function()
    local rule = S.Object({ name = S.String({ max = 8 }) }, { strict = false })

    accepts(rule, { name = 'a', admin = true }, { name = 'a' })
end)

H.Test('Object requires fields unless Optional', function()
    local rule = S.Object({
        name = S.String({ max = 8 }),
        note = S.Optional(S.String({ max = 8 })),
    })

    accepts(rule, { name = 'a' }, { name = 'a' })
    rejects(rule, { note = 'b' }, 'value.name: MUST be present')
end)

H.Test('Object ignores metatables', function()
    local rule = S.Object({ name = S.String({ max = 8 }) })
    local input = setmetatable({}, { __index = { name = 'a' } })

    rejects(rule, input, 'value.name: MUST be present')

    local ok, value = S.Check(rule, setmetatable({ name = 'a' }, { __index = { admin = true } }))

    H.Equal(ok, true)
    H.Equal(getmetatable(value), nil)
end)

H.Test('Nested paths reach the failing field', function()
    local schema = S.Define({
        S.Object({
            items = S.Array(S.Object({ name = S.String({ max = 8 }) }), { max = 4 }),
        }),
    })

    local ok, args, detail = S.Validate(schema, { items = { { name = 'a' }, { name = 1 } } })

    H.Equal(ok, false)
    H.Equal(args, nil)
    H.Equal(detail, 'arg 1.items[2].name: MUST be a string, got 1')
end)

-- Custom validation

H.Test('Custom validate runs after built-in checks with the normalized value', function()
    local received
    local rule = S.Integer({
        validate = function(value)
            received = value
            return value % 2 == 0, 'MUST be even'
        end,
    })

    accepts(rule, 4.0, 4)
    H.Equal(math.type(received), 'integer')
    rejects(rule, 3, 'value: MUST be even')

    received = nil
    rejects(rule, 'x', 'value: MUST be an integer, got a string of 1 bytes')
    H.Equal(received, nil)
end)

H.Test('Custom validate crash reports no stack', function()
    local rule = S.String({
        max = 8,
        validate = function()
            error('secret internals')
        end,
    })

    rejects(rule, 'a', 'value: failed custom validation')
end)

H.Test('Custom validate without true fails', function()
    local rule = S.Boolean({
        validate = function()
            return H.Any(nil)
        end,
    })

    rejects(rule, true, 'value: failed custom validation')
end)

-- Define and Validate

H.Test('Validate returns fresh validated args with n', function()
    local schema = S.Define({
        S.String({ min = 1, max = 32, pattern = '^[%w_]+$' }),
        S.Integer({ min = 1, max = 1000000 }),
        S.Optional(S.Boolean()),
    })

    local ok, args, detail = S.Validate(schema, 'user', 10.0)

    H.Equal(ok, true)
    H.Equal(detail, nil)
    H.Equal(args, { n = 3, 'user', 10 })
end)

H.Test('Validate tolerates trailing nils', function()
    local schema = S.Define({ S.Integer() })

    H.Equal((S.Validate(schema, 1, nil, nil)), true)
end)

H.Test('Validate rejects extra values', function()
    local schema = S.Define({ S.Integer() })
    local ok, args, detail = S.Validate(schema, 1, nil, 'extra')

    H.Equal(ok, false)
    H.Equal(args, nil)
    H.Equal(detail, 'MUST have at most 1 arguments, got 3')
end)

H.Test('Validate rejects more than 8 extra arguments', function()
    local schema = S.Define({ S.Integer() })
    local ok, _, detail = S.Validate(schema, 1, nil, nil, nil, nil, nil, nil, nil, nil, nil)

    H.Equal(ok, false)
    H.Equal(detail, 'MUST have at most 1 arguments, got 10')
end)

H.Test('Validate requires non-optional arguments', function()
    local schema = S.Define({ S.Integer(), S.Integer() })
    local ok, _, detail = S.Validate(schema, 1)

    H.Equal(ok, false)
    H.Equal(detail, 'arg 2: MUST be present')
end)

H.Test('Validate raises on a non-schema', function()
    H.Raises(function()
        S.Validate(H.Any({}), 1)
    end, 'Schema.Validate expects a schema from Schema.Define')
end)

H.Test('Define requires trailing optionals and real rules', function()
    H.Raises(function()
        S.Define({ S.Optional(S.Integer()), S.Integer() })
    end, 'argument 2 follows an Optional argument')

    H.Raises(function()
        S.Define(H.Any({ S.Integer(), 'x' }))
    end, 'argument 2 MUST be a schema rule')

    H.Raises(function()
        S.Define(H.Any({ S.Integer(), extra = S.Integer() }))
    end, 'expects an array without holes or extra keys')
end)

H.Test('Check handles Optional nil', function()
    local ok, value, detail = S.Check(S.Optional(S.Integer()), nil)

    H.Equal(ok, true)
    H.Equal(value, nil)
    H.Equal(detail, nil)
    rejects(S.Integer(), nil, 'value: MUST be present')
end)

H.Done()
