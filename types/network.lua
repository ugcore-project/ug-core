--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---Options of a client-to-server net event or callback. `schema` and `rate` are mandatory.
---@class UgNetworkOptions
---@field schema UgSchema arguments, from `UgCore.Schema.Define`
---@field rate UgRateLimitOptions per player
---@field requirePlayer? boolean rejects players whose `ug-core:Loaded` statebag is not true
---@field requireAlive? boolean rejects downed and dead players with `no_permission`, without a flag
---@field permission? string ACE the player MUST have

---Options of a server-to-client callback. The client result is untrusted input.
---@class UgClientCallbackOptions
---@field schema UgSchemaRule validates the returned value
---@field timeout? integer ms, defaults to 10000

---@class UgGuardFlag
---@field violation UgViolation
---@field detail? string
---@field at integer GetGameTimer value in ms
