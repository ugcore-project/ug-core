--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Write-behind cache. Owners edit cached values in place and mark them dirty.
---Dirty entries flush periodically, a player's entries flush on drop, every entry flushes on resource stop.
---@class UgCore.Internal.Database.Cache
local Cache = {}
UgCore.Internal.Database.Cache = Cache

---@class UgCache
---@field private name string
---@field private writer fun(key: any, value: any): boolean
---@field private interval integer
---@field private lastFlush integer
---@field private entries table<any, any>
---@field private dirty table<any, boolean>
---@field private owners table<any, integer>
local Instance = {}
Instance.__index = Instance

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

local DEFAULT_INTERVAL = 30000
local TICK = 1000

---@type UgCache[]
local caches = {}

---@param options UgCacheOptions
---@return UgCache
function Cache.Create(options)
    if type(options) ~= 'table' or type(options.name) ~= 'string' or options.name == '' then
        Utils.Raise(2, 'Cache.Create expects options with a name')
    end

    if type(options.flush) ~= 'function' then
        Utils.Raise(2, 'Cache.Create: "flush" MUST be a function')
    end

    local interval = options.interval or DEFAULT_INTERVAL

    if math.type(interval) ~= 'integer' or interval < TICK then
        Utils.Raise(2, 'Cache.Create: "interval" MUST be an integer of at least %d ms', TICK)
    end

    local cache = setmetatable({
        name = options.name,
        writer = options.flush,
        interval = interval,
        lastFlush = GetGameTimer(),
        entries = {},
        dirty = {},
        owners = {},
    }, Instance)

    caches[#caches + 1] = cache

    return cache
end

---The cached value itself, not a copy. Edit it in place, then call MarkDirty.
---@param key any
---@return any
function Instance:Get(key)
    return self.entries[key]
end

---Stores a value already in the database, such as a row just loaded. It is not flushed.
---@param key any
---@param value any
---@param owner? integer player source whose drop evicts this entry
function Instance:Put(key, value, owner)
    self.entries[key] = value
    self.owners[key] = owner
    self.dirty[key] = nil
end

---Stores a value and marks it dirty.
---@param key any
---@param value any
---@param owner? integer player source whose drop evicts this entry
function Instance:Set(key, value, owner)
    self.entries[key] = value
    self.owners[key] = owner
    self.dirty[key] = true
end

---@param key any
---@return boolean marked false when the key is not cached
function Instance:MarkDirty(key)
    if self.entries[key] == nil then
        return false
    end

    self.dirty[key] = true

    return true
end

---@param key any
---@return boolean
function Instance:IsDirty(key)
    return self.dirty[key] == true
end

---@private
---@param key any
---@return boolean ok
function Instance:writeEntry(key)
    local value = self.entries[key]

    if not self.dirty[key] or value == nil then
        return true
    end

    -- Cleared first, so edits made while the write runs mark the entry dirty again.
    self.dirty[key] = nil

    local called, written = pcall(self.writer, key, value)

    if called and written == true then
        return true
    end

    if self.entries[key] ~= nil then
        self.dirty[key] = true
    end

    Logger.Error('Cache %s: flush of %s failed: %s', self.name, tostring(key), called and 'writer returned false' or tostring(written))

    return false
end

---Writes dirty entries. Failed entries stay dirty and retry on the next flush.
---@param key? any one entry, every dirty entry when nil
---@return boolean ok false when any write failed
function Instance:Flush(key)
    if key ~= nil then
        return self:writeEntry(key)
    end

    local keys = {}

    for dirtyKey in pairs(self.dirty) do
        keys[#keys + 1] = dirtyKey
    end

    local ok = true

    for index = 1, #keys do
        ok = self:writeEntry(keys[index]) and ok
    end

    self.lastFlush = GetGameTimer()

    return ok
end

---Flushes the entry, then removes it. A failed flush keeps it cached.
---@param key any
---@return boolean removed
function Instance:Evict(key)
    if not self:writeEntry(key) then
        return false
    end

    self.entries[key] = nil
    self.owners[key] = nil
    self.dirty[key] = nil

    return true
end

---@return UgCacheStats
function Instance:GetStats()
    local entries, dirty = 0, 0

    for _ in pairs(self.entries) do
        entries = entries + 1
    end

    for _ in pairs(self.dirty) do
        dirty = dirty + 1
    end

    return { name = self.name, entries = entries, dirty = dirty }
end

---@param now integer
function Instance:FlushIfDue(now)
    if now - self.lastFlush >= self.interval then
        self:Flush()
    end
end

---@param source integer
function Instance:EvictOwner(source)
    local keys = {}

    for key, owner in pairs(self.owners) do
        if owner == source then
            keys[#keys + 1] = key
        end
    end

    for index = 1, #keys do
        self:Evict(keys[index])
    end
end

---Flushes every cache. Runs on resource stop, best effort: the stopping resource MAY not finish slow writes.
---@return boolean ok
function Cache.FlushAll()
    local ok = true

    for index = 1, #caches do
        ok = caches[index]:Flush() and ok
    end

    return ok
end

---@return UgCacheStats[]
function Cache.GetStats()
    local stats = {}

    for index = 1, #caches do
        stats[index] = caches[index]:GetStats()
    end

    return stats
end

AddEventHandler('playerDropped', function()
    local dropped = source

    if not dropped then
        return
    end

    for index = 1, #caches do
        caches[index]:EvictOwner(dropped)
    end
end)

CreateThread(function()
    while true do
        Wait(TICK)

        local now = GetGameTimer()

        for index = 1, #caches do
            caches[index]:FlushIfDue(now)
        end
    end
end)
