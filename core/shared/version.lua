--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---ug-core's version, from its manifest. Resources check it to require a minimum version.
---@class UgCore.Version
local Version = {}
UgCore.Version = Version

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local CORE = 'ug-core'
-- The resource this copy runs in: ug-core itself, or a resource that imports it.
local RESOURCE = GetCurrentResourceName()
local PATTERN = '^(%d+)%.(%d+)%.(%d+)'

---@param text any
---@return integer[]? parts major, minor, patch. Pre-release and build suffixes are ignored.
local function parse(text)
    if type(text) ~= 'string' then
        return nil
    end

    local major, minor, patch = text:match(PATTERN)

    if not major then
        return nil
    end

    return { math.tointeger(tonumber(major)) or 0, math.tointeger(tonumber(minor)) or 0, math.tointeger(tonumber(patch)) or 0 }
end

---@param a integer[]
---@param b integer[]
---@return integer -1, 0 or 1
local function compare(a, b)
    for index = 1, 3 do
        if a[index] ~= b[index] then
            return a[index] < b[index] and -1 or 1
        end
    end

    return 0
end

---@class UgCore.Internal.Version
local InternalVersion = {}
UgCore.Internal.Version = InternalVersion

---Compares two versions by major, minor and patch. Pre-release and build suffixes are ignored.
---@param a string
---@param b string
---@return integer? order -1, 0 or 1, nil when either version is malformed
function InternalVersion.Compare(a, b)
    local left, right = parse(a), parse(b)

    if not left or not right then
        return nil
    end

    return compare(left, right)
end

---@return string version such as `1.2.0`, `0.0.0` when the manifest has none
function Version.Get()
    return GetResourceMetadata(CORE, 'version', 0) or '0.0.0'
end

---@param minimum string such as `1.2.0`
---@return boolean
function Version.IsAtLeast(minimum)
    local wanted = parse(minimum)

    if not wanted then
        Utils.Raise(2, 'Version.IsAtLeast expects a version such as "1.2.0"')
    end

    ---@cast wanted -nil

    local current = parse(Version.Get()) or { 0, 0, 0 }

    return compare(current, wanted) >= 0
end

---Raises when ug-core is older than `minimum`. Warns once when ug-core has a newer major version:
---breaking changes are MAJOR, so the calling resource MAY need an update.
---@param minimum string such as `1.2.0`
function Version.Require(minimum)
    local wanted = parse(minimum)

    if not wanted then
        Utils.Raise(2, 'Version.Require expects a version such as "1.2.0"')
    end

    ---@cast wanted -nil

    local found = Version.Get()
    local current = parse(found) or { 0, 0, 0 }
    local resource = RESOURCE

    if compare(current, wanted) < 0 then
        Utils.Raise(2, '%s requires ug-core %s or newer, found %s. Update ug-core.', resource, minimum, found)
    end

    if current[1] > wanted[1] then
        Logger.Warn('%s was built for ug-core %d.x, found %s. Check the breaking changes of ug-core %d.0.0.', resource, wanted[1], found, current[1])
    end
end
