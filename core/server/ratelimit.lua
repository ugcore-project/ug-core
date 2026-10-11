--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Token bucket rate limiting. Every limiter is reset for a player on drop and pruned periodically.
---@class UgCore.RateLimit
local RateLimit = {}
UgCore.RateLimit = RateLimit

---@class UgRateLimiter
---@field private max integer
---@field private per integer
---@field private tokens table<integer|string, number>
---@field private updated table<integer|string, integer>
local Limiter = {}
Limiter.__index = Limiter

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local GetGameTimer = GetGameTimer
local min = math.min

local PRUNE_INTERVAL = 60000

---@type table<UgRateLimiter, boolean>
local limiters = setmetatable({}, { __mode = 'k' })

---@param options UgRateLimitOptions
---@return UgRateLimiter
function RateLimit.Create(options)
    if type(options) ~= 'table' then
        Utils.Raise(2, 'RateLimit.Create expects options { max, per }')
    end

    local max, per = options.max, options.per

    if math.type(max) ~= 'integer' or max < 1 then
        Utils.Raise(2, 'RateLimit.Create: "max" MUST be a positive integer')
    end

    if math.type(per) ~= 'integer' or per < 1 then
        Utils.Raise(2, 'RateLimit.Create: "per" MUST be a positive integer')
    end

    local limiter = setmetatable({
        max = max,
        per = per,
        tokens = {},
        updated = {},
    }, Limiter)

    limiters[limiter] = true

    return limiter
end

---Takes one token. When refused, `retryAfter` is the wait in ms until a token is available.
---@param key integer|string usually the player source
---@return boolean allowed
---@return integer retryAfter
function Limiter:Consume(key)
    local now = GetGameTimer()
    local tokens = self.tokens[key]

    if tokens == nil then
        tokens = self.max
    else
        local elapsed = now - self.updated[key]

        if elapsed > 0 then
            tokens = min(self.max, tokens + elapsed * self.max / self.per)
        end
    end

    self.updated[key] = now

    if tokens >= 1 then
        self.tokens[key] = tokens - 1

        return true, 0
    end

    self.tokens[key] = tokens

    return false, math.ceil((1 - tokens) * self.per / self.max)
end

---MUST run on player drop. ug-core does this for every limiter.
---@param key integer|string
function Limiter:Reset(key)
    self.tokens[key] = nil
    self.updated[key] = nil
end

---Drops buckets that are full again. Behavior is unchanged, since a missing bucket starts full.
---@return integer pruned
function Limiter:Prune()
    local now = GetGameTimer()
    local per = self.per
    local pruned = 0

    for key, updated in pairs(self.updated) do
        if now - updated >= per then
            self.tokens[key] = nil
            self.updated[key] = nil
            pruned = pruned + 1
        end
    end

    return pruned
end

function Limiter:Clear()
    self.tokens = {}
    self.updated = {}
end

AddEventHandler('playerDropped', function()
    local dropped = source

    if not dropped then
        return
    end

    for limiter in pairs(limiters) do
        limiter:Reset(dropped)
    end
end)

CreateThread(function()
    while true do
        Wait(PRUNE_INTERVAL)

        local pruned = 0

        for limiter in pairs(limiters) do
            pruned = pruned + limiter:Prune()
        end

        if pruned > 0 then
            Logger.Debug('RateLimit: pruned %d idle buckets.', pruned)
        end
    end
end)
