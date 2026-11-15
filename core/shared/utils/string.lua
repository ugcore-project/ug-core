--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@class UgCore.Internal.Utils.String
local String = {}
UgCore.Internal.Utils.String = String

local Utils = UgCore.Internal.Utils

local SUGGEST_MAX_DISTANCE = 3

---Levenshtein distance in bytes. Callers SHOULD pass ASCII, such as config keys.
---@param a string
---@param b string
---@return integer
function String.Distance(a, b)
    if type(a) ~= 'string' or type(b) ~= 'string' then
        Utils.Raise(2, 'String.Distance expects two strings')
    end

    if a == b then
        return 0
    end

    local lengthA, lengthB = #a, #b

    if lengthA == 0 then
        return lengthB
    end

    if lengthB == 0 then
        return lengthA
    end

    local previous, current = {}, {}

    for column = 0, lengthB do
        previous[column] = column
    end

    for row = 1, lengthA do
        current[0] = row
        local byteA = a:byte(row)

        for column = 1, lengthB do
            local cost = byteA == b:byte(column) and 0 or 1
            current[column] = math.min(previous[column] + 1, current[column - 1] + 1, previous[column - 1] + cost)
        end

        previous, current = current, previous
    end

    return previous[lengthB]
end

---Returns the closest candidate within `maxDistance`, ignoring case. Ties go to the earliest candidate.
---@param input string
---@param candidates string[]
---@param maxDistance? integer defaults to 3
---@return string?
function String.Suggest(input, candidates, maxDistance)
    if type(input) ~= 'string' or type(candidates) ~= 'table' then
        Utils.Raise(2, 'String.Suggest expects a string and an array of strings')
    end

    local limit = maxDistance or SUGGEST_MAX_DISTANCE
    local lowered = input:lower()
    local best, bestDistance = nil, limit + 1

    for index = 1, #candidates do
        local candidate = candidates[index]
        local distance = String.Distance(lowered, candidate:lower())

        if distance < bestDistance then
            best, bestDistance = candidate, distance
        end
    end

    return best
end
