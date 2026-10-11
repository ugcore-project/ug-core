--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Writes Lua source for config values. Generated files MUST load back to the same values.
---@class UgCore.Internal.Config.Serializer
local Serializer = {}
UgCore.Internal.Config.Serializer = Serializer

local Validator = UgCore.Internal.Config.Validator

local INDENT = '    '

local ESCAPES = {
    ['\\'] = '\\\\',
    ["'"] = "\\'",
    ['\n'] = '\\n',
    ['\r'] = '\\r',
    ['\0'] = '\\0',
}

local KEYWORDS = {}

for word in ('and break do else elseif end false for function goto if in local nil not or repeat return then true until while'):gmatch('%a+') do
    KEYWORDS[word] = true
end

local VECTOR_COMPONENTS = {
    vector2 = { 'x', 'y' },
    vector3 = { 'x', 'y', 'z' },
    vector4 = { 'x', 'y', 'z', 'w' },
}

---@param value number
---@return string
local function number(value)
    if math.type(value) == 'integer' then
        return tostring(value)
    end

    -- Shortest form that reads back to the same number.
    local text = ('%.14g'):format(value)

    if tonumber(text) ~= value then
        text = ('%.17g'):format(value)
    end

    if not text:find('[%.eEn]') then
        text = text .. '.0'
    end

    return text
end

---@param key any
---@return string
local function sortKey(key)
    return (type(key) == 'number' and '0' or '1') .. tostring(key)
end

---@param tbl table
---@return any[] keys
---@return boolean isArray
local function orderedKeys(tbl)
    local keys = {}
    local count = 0

    for key in pairs(tbl) do
        count = count + 1
        keys[count] = key
    end

    if count == #tbl then
        table.sort(keys)

        return keys, true
    end

    table.sort(keys, function(a, b)
        return sortKey(a) < sortKey(b)
    end)

    return keys, false
end

local serialize

---@param key any
---@return string
local function keyPrefix(key)
    if type(key) == 'string' and key:find('^[%a_][%w_]*$') and not KEYWORDS[key] then
        return key .. ' = '
    end

    return '[' .. serialize(key, 0, true) .. '] = '
end

---@param value any
---@param depth integer
---@param inline boolean
---@return string
serialize = function(value, depth, inline)
    local valueType = type(value)

    if valueType == 'string' then
        return "'" .. value:gsub("[\\'\n\r\0]", ESCAPES) .. "'"
    end

    if valueType == 'number' then
        return number(value)
    end

    if valueType == 'boolean' then
        return tostring(value)
    end

    local components = VECTOR_COMPONENTS[valueType]

    if components then
        local parts = {}

        for index = 1, #components do
            parts[index] = number(value[components[index]])
        end

        return ('%s(%s)'):format(valueType, table.concat(parts, ', '))
    end

    if valueType ~= 'table' then
        error(('cannot serialize a %s'):format(valueType), 0)
    end

    local keys, isArray = orderedKeys(value)

    if #keys == 0 then
        return '{}'
    end

    local parts = {}

    for index = 1, #keys do
        local key = keys[index]
        local prefix = isArray and '' or keyPrefix(key)

        parts[index] = prefix .. serialize(value[key], depth + 1, inline)
    end

    if inline then
        return '{ ' .. table.concat(parts, ', ') .. ' }'
    end

    local padding = INDENT:rep(depth + 1)

    return '{\n' .. padding .. table.concat(parts, ',\n' .. padding) .. ',\n' .. INDENT:rep(depth) .. '}'
end

---Multi-line Lua source for a value, indented for `depth`.
---@param value any
---@param depth? integer
---@return string
function Serializer.Value(value, depth)
    return serialize(value, depth or 0, false)
end

---Single-line Lua source for a value, for logs and console output.
---@param value any
---@return string
function Serializer.Inline(value)
    return serialize(value, 0, true)
end

---@param text string
---@param indent string
---@param lines string[]
local function comment(text, indent, lines)
    for line in (text .. '\n'):gmatch('(.-)\r?\n') do
        lines[#lines + 1] = indent .. (line == '' and '--' or '-- ' .. line)
    end
end

---@param option UgConfigOption
---@return string
local function describeLimits(option)
    local parts = { 'Type: ' .. option.type .. '.' }
    local measured = option.type == 'string' and ' length' or option.type == 'table' and ' entries' or ''

    if option.min then
        parts[#parts + 1] = 'Min' .. measured .. ': ' .. number(option.min) .. '.'
    end

    if option.max then
        parts[#parts + 1] = 'Max' .. measured .. ': ' .. number(option.max) .. '.'
    end

    return table.concat(parts, ' ')
end

---Config file content with every option, its description, limits and default.
---@param name string
---@param definition UgConfigDefinition
---@return string
function Serializer.Generate(name, definition)
    local lines = {
        ('-- ug-core config: %s'):format(name),
        '-- Generated on first boot. ug-core never edits this file. Delete it to restore the defaults.',
    }

    if definition.kind == 'data' then
        lines[#lines + 1] = '--'
        comment(definition.description, '', lines)
        lines[#lines + 1] = ''
        lines[#lines + 1] = 'return ' .. serialize(definition.default, 0, false)
        lines[#lines + 1] = ''

        return table.concat(lines, '\n')
    end

    lines[#lines + 1] = '-- Missing options use their default. Convars override values set here.'
    lines[#lines + 1] = ''
    lines[#lines + 1] = 'return {'

    local options = definition.options

    for index = 1, #options do
        local option = options[index]

        comment(option.description, INDENT, lines)
        lines[#lines + 1] = INDENT .. '-- ' .. describeLimits(option)

        if option.values then
            local values = {}

            for position = 1, #option.values do
                values[position] = serialize(option.values[position], 0, true)
            end

            lines[#lines + 1] = INDENT .. '-- Values: ' .. table.concat(values, ', ') .. '.'
        end

        if option.type ~= 'table' and not VECTOR_COMPONENTS[option.type] then
            lines[#lines + 1] = INDENT .. '-- Convar: ' .. Validator.ConvarName(name, option.key) .. '.'
        end
        lines[#lines + 1] = INDENT .. option.key .. ' = ' .. serialize(option.default, 1, false) .. ','

        if index < #options then
            lines[#lines + 1] = ''
        end
    end

    lines[#lines + 1] = '}'
    lines[#lines + 1] = ''

    return table.concat(lines, '\n')
end
