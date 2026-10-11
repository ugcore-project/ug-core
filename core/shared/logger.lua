--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Messages with extra arguments are formatted with `string.format`.
---@class UgCore.Logger
local Logger = {}
UgCore.Logger = Logger

---@class UgCore.Internal.Logger
local InternalLogger = {}
UgCore.Internal.Logger = InternalLogger

local Utils = UgCore.Internal.Utils

local TAG_DEBUG = '^6[DEBUG]^7'
local TAG_INFO = '^5[INFO]^7'
local TAG_WARN = '^3[WARN]^7'
local TAG_ERROR = '^1[ERROR]^7'

local debugEnabled = false

---@param tag string
---@param message any
---@param ... any
local function write(tag, message, ...)
    local text = tostring(message)

    if select('#', ...) > 0 then
        text = text:format(...)
    end

    print(tag .. ' ' .. text)
end

---Printed only when debug is enabled.
---@param message any
---@param ... any
function Logger.Debug(message, ...)
    if debugEnabled then
        write(TAG_DEBUG, message, ...)
    end
end

---@param message any
---@param ... any
function Logger.Info(message, ...)
    write(TAG_INFO, message, ...)
end

---@param message any
---@param ... any
function Logger.Warn(message, ...)
    write(TAG_WARN, message, ...)
end

---@param message any
---@param ... any
function Logger.Error(message, ...)
    write(TAG_ERROR, message, ...)
end

---@param enabled boolean
function InternalLogger.SetDebug(enabled)
    if type(enabled) ~= 'boolean' then
        Utils.Raise(2, 'Logger.SetDebug expects a boolean, got %s', type(enabled))
    end

    if enabled == debugEnabled then
        return
    end

    debugEnabled = enabled

    if enabled then
        write(TAG_DEBUG, 'Debug logging enabled.')
    end
end

---@return boolean
function InternalLogger.IsDebug()
    return debugEnabled
end
