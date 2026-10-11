--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Bounded validators for untrusted input. Failure details are for server logs only.
---@class UgCore.Schema
local Schema = {}
UgCore.Schema = Schema

---@class UgSchemaRule
---@field package kind string
---@field package optional boolean
---@field package check fun(value: any): boolean, any, string?

---@class UgSchema
---@field package rules UgSchemaRule[]
---@field package count integer

local Utils = UgCore.Internal.Utils

local type, next, rawget = type, next, rawget
local mathType, toInteger, HUGE = math.type, math.tointeger, math.huge
local utf8Len = utf8.len
local find = string.find

local MAX_EXTRA_ARGS = 8
local BYTES_PER_CHAR = 4
local CUSTOM_FAILURE = 'failed custom validation'
local CONTROL_PATTERN = '[%c]'
local CONTROL_PATTERN_MULTILINE = '[\0-\8\11\12\14-\31\127]'
local C1_CONTROL_PATTERN = '\194[\128-\159]'

local KEY_KINDS = { string = true, integer = true, number = true, enum = true, boolean = true }

---@type table<table, boolean>
local ruleSet = setmetatable({}, { __mode = 'k' })

---@type table<table, boolean>
local schemaSet = setmetatable({}, { __mode = 'k' })

---Describes a value without echoing its content.
---@param value any
---@return string
local function describe(value)
    local valueType = type(value)

    if valueType == 'string' then
        return ('a string of %d bytes'):format(#value)
    end

    if valueType == 'number' then
        if value ~= value then
            return 'NaN'
        end

        return mathType(value) == 'integer' and tostring(value) or ('%.14g'):format(value)
    end

    if valueType == 'nil' or valueType == 'boolean' then
        return tostring(value)
    end

    return 'a ' .. valueType
end

---@param message string
---@param value any
---@return string
local function failGot(message, value)
    return ': ' .. message .. ', got ' .. describe(value)
end

---@param number number
---@return string
local function formatNumber(number)
    return mathType(number) == 'integer' and tostring(number) or ('%.14g'):format(number)
end

---@param validate UgSchemaValidator?
---@param value any
---@return boolean ok
---@return any value
---@return string? detail
local function finish(validate, value)
    if not validate then
        return true, value, nil
    end

    local called, passed, message = pcall(validate, value)

    if not called then
        return false, nil, ': ' .. CUSTOM_FAILURE
    end

    if passed ~= true then
        return false, nil, ': ' .. (type(message) == 'string' and message or CUSTOM_FAILURE)
    end

    return true, value, nil
end

---@param builder string
---@param options table?
---@param allowed string[]
---@param required boolean
---@return table
local function readOptions(builder, options, allowed, required)
    if options == nil then
        if required then
            Utils.Raise(3, 'Schema.%s requires options with "max"', builder)
        end

        return {}
    end

    if type(options) ~= 'table' then
        Utils.Raise(3, 'Schema.%s options MUST be a table', builder)
    end

    for key in next, options do
        local known = false

        for index = 1, #allowed do
            if allowed[index] == key then
                known = true
                break
            end
        end

        if not known then
            local name = tostring(key)
            local suggestion = type(key) == 'string' and Utils.String.Suggest(name, allowed) or nil
            local hint = suggestion and (' Did you mean "%s"?'):format(suggestion) or ''

            Utils.Raise(3, 'Schema.%s: unknown option "%s".%s', builder, name, hint)
        end
    end

    if options.validate ~= nil and type(options.validate) ~= 'function' then
        Utils.Raise(3, 'Schema.%s: "validate" MUST be a function', builder)
    end

    return options
end

---@param builder string
---@param options table
---@param key string
---@param required boolean
---@return integer?
local function readCount(builder, options, key, required)
    local value = options[key]

    if value == nil then
        if required then
            Utils.Raise(3, 'Schema.%s: "%s" is required', builder, key)
        end

        return nil
    end

    if mathType(value) ~= 'integer' or value < 0 then
        Utils.Raise(3, 'Schema.%s: "%s" MUST be a non-negative integer', builder, key)
    end

    return value
end

---@param builder string
---@param options table
---@param key string
---@return number?
local function readNumber(builder, options, key)
    local value = options[key]

    if value == nil then
        return nil
    end

    if type(value) ~= 'number' or value ~= value then
        Utils.Raise(3, 'Schema.%s: "%s" MUST be a number', builder, key)
    end

    return value
end

---@param builder string
---@param minimum number?
---@param maximum number?
local function checkRange(builder, minimum, maximum)
    if minimum and maximum and minimum > maximum then
        Utils.Raise(3, 'Schema.%s: "min" MUST NOT be greater than "max"', builder)
    end
end

---@param builder string
---@param rule any
---@param label string
local function checkRule(builder, rule, label)
    if type(rule) ~= 'table' or not ruleSet[rule] then
        Utils.Raise(3, 'Schema.%s: %s MUST be a schema rule', builder, label)
    end
end

---@param kind string
---@param check fun(value: any): boolean, any, string?
---@return UgSchemaRule
local function newRule(kind, check)
    local rule = { kind = kind, optional = false, check = check }
    ruleSet[rule] = true

    return rule
end

---Strings count UTF-8 characters. Invalid UTF-8 and control characters are rejected.
---@param options UgSchemaStringOptions
---@return UgSchemaRule
function Schema.String(options)
    local builder = 'String'
    options = readOptions(builder, options, { 'min', 'max', 'pattern', 'multiline', 'validate' }, true)

    local maximum = readCount(builder, options, 'max', true) --[[@as integer]]
    local minimum = readCount(builder, options, 'min', false)
    local pattern = options.pattern
    local controls = options.multiline and CONTROL_PATTERN_MULTILINE or CONTROL_PATTERN
    local validate = options.validate

    checkRange(builder, minimum, maximum)

    if pattern ~= nil then
        if type(pattern) ~= 'string' or not pcall(find, '', pattern) then
            Utils.Raise(2, 'Schema.String: "pattern" MUST be a valid Lua pattern')
        end
    end

    local maxBytes = maximum * BYTES_PER_CHAR

    return newRule('string', function(value)
        if type(value) ~= 'string' then
            return false, nil, failGot('MUST be a string', value)
        end

        if #value > maxBytes then
            return false, nil, failGot(('MUST be at most %d characters'):format(maximum), value)
        end

        local length = utf8Len(value)

        if not length then
            return false, nil, ': MUST be valid UTF-8'
        end

        if length > maximum then
            return false, nil, failGot(('MUST be at most %d characters'):format(maximum), value)
        end

        if minimum and length < minimum then
            return false, nil, failGot(('MUST be at least %d characters'):format(minimum), value)
        end

        if find(value, controls) or find(value, C1_CONTROL_PATTERN) then
            return false, nil, ': MUST NOT contain control characters'
        end

        if pattern and not find(value, pattern) then
            return false, nil, ': MUST match the expected format'
        end

        return finish(validate, value)
    end)
end

---@param builder string
---@param integer boolean
---@param options UgSchemaNumberOptions?
---@return UgSchemaRule
local function numberRule(builder, integer, options)
    options = readOptions(builder, options, { 'min', 'max', 'validate' }, false)

    local minimum = readNumber(builder, options, 'min')
    local maximum = readNumber(builder, options, 'max')
    local validate = options.validate
    local expected = integer and 'MUST be an integer' or 'MUST be a number'

    checkRange(builder, minimum, maximum)

    return newRule(integer and 'integer' or 'number', function(value)
        if type(value) ~= 'number' then
            return false, nil, failGot(expected, value)
        end

        if value ~= value or value == HUGE or value == -HUGE then
            return false, nil, ': MUST be a finite number'
        end

        if integer then
            local converted = toInteger(value)

            if not converted then
                return false, nil, failGot(expected, value)
            end

            value = converted
        end

        if minimum and value < minimum then
            return false, nil, failGot('MUST be at least ' .. formatNumber(minimum), value)
        end

        if maximum and value > maximum then
            return false, nil, failGot('MUST be at most ' .. formatNumber(maximum), value)
        end

        return finish(validate, value)
    end)
end

---Rejects NaN and infinity.
---@param options? UgSchemaNumberOptions
---@return UgSchemaRule
function Schema.Number(options)
    return numberRule('Number', false, options)
end

---Rejects NaN and infinity. Integral floats such as `5.0` become integers.
---@param options? UgSchemaNumberOptions
---@return UgSchemaRule
function Schema.Integer(options)
    return numberRule('Integer', true, options)
end

---@param options? UgSchemaBooleanOptions
---@return UgSchemaRule
function Schema.Boolean(options)
    options = readOptions('Boolean', options, { 'validate' }, false)

    local validate = options.validate

    return newRule('boolean', function(value)
        if type(value) ~= 'boolean' then
            return false, nil, failGot('MUST be a boolean', value)
        end

        return finish(validate, value)
    end)
end

---@param builder string
---@param kind string
---@param components string[]
---@param options UgSchemaVectorOptions?
---@return UgSchemaRule
local function vectorRule(builder, kind, components, options)
    options = readOptions(builder, options, { 'maxComponent', 'validate' }, false)

    local maxComponent = readNumber(builder, options, 'maxComponent')
    local validate = options.validate
    local expected = 'MUST be a ' .. kind
    local count = #components

    if maxComponent and maxComponent < 0 then
        Utils.Raise(2, 'Schema.%s: "maxComponent" MUST NOT be negative', builder)
    end

    return newRule(kind, function(value)
        if type(value) ~= kind then
            return false, nil, failGot(expected, value)
        end

        for index = 1, count do
            local component = value[components[index]]

            if type(component) ~= 'number' or component ~= component or component == HUGE or component == -HUGE then
                return false, nil, ': MUST have finite components'
            end

            if maxComponent and (component > maxComponent or component < -maxComponent) then
                return false, nil, ': MUST have components within ' .. formatNumber(maxComponent)
            end
        end

        return finish(validate, value)
    end)
end

---@param options? UgSchemaVectorOptions
---@return UgSchemaRule
function Schema.Vector2(options)
    return vectorRule('Vector2', 'vector2', { 'x', 'y' }, options)
end

---@param options? UgSchemaVectorOptions
---@return UgSchemaRule
function Schema.Vector3(options)
    return vectorRule('Vector3', 'vector3', { 'x', 'y', 'z' }, options)
end

---@param options? UgSchemaVectorOptions
---@return UgSchemaRule
function Schema.Vector4(options)
    return vectorRule('Vector4', 'vector4', { 'x', 'y', 'z', 'w' }, options)
end

---@param values (string|number|boolean)[]
---@param options? UgSchemaEnumOptions
---@return UgSchemaRule
function Schema.Enum(values, options)
    options = readOptions('Enum', options, { 'validate' }, false)

    if type(values) ~= 'table' or #values == 0 then
        Utils.Raise(2, 'Schema.Enum expects a non-empty array of values')
    end

    local allowed = {}

    for index = 1, #values do
        local value = values[index]
        local valueType = type(value)

        if valueType ~= 'string' and valueType ~= 'number' and valueType ~= 'boolean' then
            Utils.Raise(2, 'Schema.Enum values MUST be strings, numbers or booleans')
        end

        allowed[value] = true
    end

    local validate = options.validate

    return newRule('enum', function(value)
        if value == nil or not allowed[value] then
            return false, nil, failGot('MUST be one of the allowed values', value)
        end

        return finish(validate, value)
    end)
end

---Rejects holes and non-integer keys. Tables past `max` entries are rejected without scanning the rest.
---@param item UgSchemaRule
---@param options UgSchemaArrayOptions
---@return UgSchemaRule
function Schema.Array(item, options)
    local builder = 'Array'
    checkRule(builder, item, 'item')
    options = readOptions(builder, options, { 'min', 'max', 'validate' }, true)

    if item.optional then
        Utils.Raise(2, 'Schema.Array: item MUST NOT be Optional')
    end

    local maximum = readCount(builder, options, 'max', true) --[[@as integer]]
    local minimum = readCount(builder, options, 'min', false)
    local validate = options.validate
    local checkItem = item.check

    checkRange(builder, minimum, maximum)

    return newRule('array', function(value)
        if type(value) ~= 'table' then
            return false, nil, failGot('MUST be an array', value)
        end

        local count, highest = 0, 0
        local key = next(value)

        while key ~= nil do
            count = count + 1

            if count > maximum then
                return false, nil, (': MUST have at most %d items'):format(maximum)
            end

            if mathType(key) ~= 'integer' or key < 1 then
                return false, nil, ': MUST be an array'
            end

            if key > highest then
                highest = key
            end

            key = next(value, key)
        end

        if highest ~= count then
            return false, nil, ': MUST NOT have holes'
        end

        if minimum and count < minimum then
            return false, nil, (': MUST have at least %d items, got %d'):format(minimum, count)
        end

        local result = {}

        for index = 1, count do
            local ok, checked, detail = checkItem(rawget(value, index))

            if not ok then
                return false, nil, '[' .. index .. ']' .. detail
            end

            result[index] = checked
        end

        return finish(validate, result)
    end)
end

---@param key any
---@return string
local function keySegment(key)
    if type(key) == 'string' then
        return ('[%q]'):format(key)
    end

    return '[' .. describe(key) .. ']'
end

---Tables past `max` entries are rejected without scanning the rest.
---@param key UgSchemaRule string, integer, number, enum or boolean rule
---@param value UgSchemaRule
---@param options UgSchemaMapOptions
---@return UgSchemaRule
function Schema.Map(key, value, options)
    local builder = 'Map'
    checkRule(builder, key, 'key')
    checkRule(builder, value, 'value')
    options = readOptions(builder, options, { 'min', 'max', 'validate' }, true)

    if not KEY_KINDS[key.kind] then
        Utils.Raise(2, 'Schema.Map: key MUST be a String, Integer, Number, Enum or Boolean rule')
    end

    if key.optional or value.optional then
        Utils.Raise(2, 'Schema.Map: key and value MUST NOT be Optional')
    end

    local maximum = readCount(builder, options, 'max', true) --[[@as integer]]
    local minimum = readCount(builder, options, 'min', false)
    local validate = options.validate
    local checkKey, checkValue = key.check, value.check

    checkRange(builder, minimum, maximum)

    return newRule('map', function(input)
        if type(input) ~= 'table' then
            return false, nil, failGot('MUST be a table', input)
        end

        local count = 0
        local entry = next(input)

        while entry ~= nil do
            count = count + 1

            if count > maximum then
                return false, nil, (': MUST have at most %d entries'):format(maximum)
            end

            entry = next(input, entry)
        end

        if minimum and count < minimum then
            return false, nil, (': MUST have at least %d entries, got %d'):format(minimum, count)
        end

        local result = {}
        entry = next(input)

        while entry ~= nil do
            local keyOk, checkedKey, keyDetail = checkKey(entry)

            if not keyOk then
                return false, nil, '.<key>' .. keyDetail
            end

            local valueOk, checkedValue, valueDetail = checkValue(rawget(input, entry))

            if not valueOk then
                return false, nil, keySegment(checkedKey) .. valueDetail
            end

            result[checkedKey] = checkedValue
            entry = next(input, entry)
        end

        return finish(validate, result)
    end)
end

---Strict by default: unknown keys are rejected. With `strict = false` they are dropped.
---@param fields table<string, UgSchemaRule>
---@param options? UgSchemaObjectOptions
---@return UgSchemaRule
function Schema.Object(fields, options)
    local builder = 'Object'
    options = readOptions(builder, options, { 'strict', 'validate' }, false)

    if type(fields) ~= 'table' then
        Utils.Raise(2, 'Schema.Object expects a table of fields')
    end

    local names = {}
    local checks = {}
    local optional = {}

    for name, rule in next, fields do
        if type(name) ~= 'string' then
            Utils.Raise(2, 'Schema.Object field names MUST be strings')
        end

        checkRule(builder, rule, ('field "%s"'):format(name))

        names[#names + 1] = name
        checks[name] = rule.check
        optional[name] = rule.optional
    end

    table.sort(names)

    if options.strict ~= nil and type(options.strict) ~= 'boolean' then
        Utils.Raise(2, 'Schema.Object: "strict" MUST be a boolean')
    end

    local strict = options.strict ~= false
    local validate = options.validate
    local fieldCount = #names

    return newRule('object', function(value)
        if type(value) ~= 'table' then
            return false, nil, failGot('MUST be an object', value)
        end

        if strict then
            local key = next(value)

            while key ~= nil do
                if type(key) ~= 'string' or not checks[key] then
                    return false, nil, ': MUST NOT have unknown fields'
                end

                key = next(value, key)
            end
        end

        local result = {}

        for index = 1, fieldCount do
            local name = names[index]
            local fieldValue = rawget(value, name)

            if fieldValue == nil then
                if not optional[name] then
                    return false, nil, '.' .. name .. ': MUST be present'
                end
            else
                local ok, checked, detail = checks[name](fieldValue)

                if not ok then
                    return false, nil, '.' .. name .. detail
                end

                result[name] = checked
            end
        end

        return finish(validate, result)
    end)
end

---Allows nil. Optional arguments MUST be trailing in `Define`.
---@param rule UgSchemaRule
---@return UgSchemaRule
function Schema.Optional(rule)
    checkRule('Optional', rule, 'rule')

    if rule.optional then
        return rule
    end

    local wrapped = newRule(rule.kind, rule.check)
    wrapped.optional = true

    return wrapped
end

---@param rules UgSchemaRule[]
---@return UgSchema
function Schema.Define(rules)
    if type(rules) ~= 'table' then
        Utils.Raise(2, 'Schema.Define expects an array of rules')
    end

    local count = #rules
    local list = {}
    local seenOptional = false

    for index = 1, count do
        local rule = rules[index]

        checkRule('Define', rule, ('argument %d'):format(index))

        if rule.optional then
            seenOptional = true
        elseif seenOptional then
            Utils.Raise(2, 'Schema.Define: argument %d follows an Optional argument. Optional arguments MUST be trailing', index)
        end

        list[index] = rule
    end

    local entries = 0

    for _ in next, rules do
        entries = entries + 1
    end

    if entries ~= count then
        Utils.Raise(2, 'Schema.Define expects an array without holes or extra keys')
    end

    local schema = { rules = list, count = count }
    schemaSet[schema] = true

    return schema
end

---Validates call arguments. Trailing nils are tolerated, extra values are rejected.
---@param schema UgSchema
---@param ... any
---@return boolean ok
---@return UgSchemaArgs? args
---@return string? detail
function Schema.Validate(schema, ...)
    if type(schema) ~= 'table' or not schemaSet[schema] then
        Utils.Raise(2, 'Schema.Validate expects a schema from Schema.Define')
    end

    local count = schema.count
    local received = select('#', ...)

    if received > count + MAX_EXTRA_ARGS then
        return false, nil, ('MUST have at most %d arguments, got %d'):format(count, received)
    end

    local values = { ... }

    for index = count + 1, received do
        if values[index] ~= nil then
            return false, nil, ('MUST have at most %d arguments, got %d'):format(count, received)
        end
    end

    local rules = schema.rules
    local args = { n = count }

    for index = 1, count do
        local rule = rules[index]
        local value = values[index]

        if value == nil then
            if not rule.optional then
                return false, nil, ('arg %d: MUST be present'):format(index)
            end
        else
            local ok, checked, detail = rule.check(value)

            if not ok then
                return false, nil, 'arg ' .. index .. detail
            end

            args[index] = checked
        end
    end

    return true, args, nil
end

---Validates a single value.
---@param rule UgSchemaRule
---@param value any
---@return boolean ok
---@return any value
---@return string? detail
function Schema.Check(rule, value)
    checkRule('Check', rule, 'rule')

    if value == nil then
        if rule.optional then
            return true, nil, nil
        end

        return false, nil, 'value: MUST be present'
    end

    local ok, checked, detail = rule.check(value)

    if not ok then
        return false, nil, 'value' .. detail
    end

    return true, checked, nil
end
