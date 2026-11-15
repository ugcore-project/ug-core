--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@class UgCore.Internal.Utils
---@field Table UgCore.Internal.Utils.Table
---@field String UgCore.Internal.Utils.String
local Utils = {}
UgCore.Internal.Utils = Utils

local ERROR_PREFIX = '[ug-core] '
local LOCALE_NAMESPACE = 'Locale'

---Raises a programmer error. `level` works like in `error`, counted from the function that calls Raise.
---Extra arguments are formatted into `message` with `string.format`.
---@param level integer
---@param message string
---@param ... any
function Utils.Raise(level, message, ...)
    if select('#', ...) > 0 then
        message = message:format(...)
    end

    error(ERROR_PREFIX .. message, level + 1)
end

---Player-facing text from the locale module when it is enabled and has the key, `fallback` otherwise.
---Placeholders are `{name}`.
---@param key string such as `identity.banned`
---@param fallback string English text
---@param vars? table<string, any>
---@return string
function Utils.Text(key, fallback, vars)
    local locale = UgCore[LOCALE_NAMESPACE]

    if type(locale) == 'table' and type(locale.Get) == 'function' then
        local text = locale.Get(key, vars)

        if text ~= key then
            return text
        end
    end

    return (fallback:gsub('{(%w+)}', function(name)
        local value = vars and vars[name]

        return value ~= nil and tostring(value) or '{' .. name .. '}'
    end))
end
