--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Core messages from `locales/<core.locale>.json`, with English for missing keys. Keys are dotted paths.
---Placeholders are `{name}`.
---@class UgCore.Locale
local Locale = {}
UgCore.Locale = Locale

local Files = UgCore.Internal.Files
local Logger = UgCore.Logger

local FALLBACK = 'en'

---@type table<string, string>
local messages = {}

---@param prefix string
---@param tbl table
---@param out table<string, string>
local function flatten(prefix, tbl, out)
    for key, value in pairs(tbl) do
        local path = prefix == '' and tostring(key) or prefix .. '.' .. tostring(key)

        if type(value) == 'table' then
            flatten(path, value, out)
        elseif type(value) == 'string' then
            out[path] = value
        end
    end
end

---@param code string
---@return table<string, string>?
local function load(code)
    if not code:find('^[%a_%-]+$') then
        return nil
    end

    local content = Files.Load(('locales/%s.json'):format(code))

    if not content then
        return nil
    end

    local ok, decoded = pcall(json.decode, content)

    if not ok or type(decoded) ~= 'table' then
        Logger.Error('Locale: locales/%s.json is not valid JSON.', code)
        return nil
    end

    local flat = {}

    flatten('', decoded, flat)

    return flat
end

---@param key string such as `identity.banned`
---@param vars? table<string, any> values for `{name}` placeholders
---@return string text the key itself when no locale has it
function Locale.Get(key, vars)
    local text = messages[key]

    if not text then
        return key
    end

    return (text:gsub('{(%w+)}', function(name)
        local value = vars and vars[name]

        return value ~= nil and tostring(value) or '{' .. name .. '}'
    end))
end

---@return string code such as `en`
function Locale.GetCode()
    return UgCore.Config.Get('core', 'locale')
end

local code = Locale.GetCode()

messages = load(FALLBACK) or {}

if code ~= FALLBACK then
    local selected = load(code)

    if selected then
        for key, value in pairs(selected) do
            messages[key] = value
        end
    else
        Logger.Warn('Locale: locales/%s.json is missing. Using %s.', code, FALLBACK)
    end
end
