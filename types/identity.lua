--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---@class UgBan
---@field id integer
---@field reason? string
---@field expiresAt? integer Unix seconds, nil for permanent bans
---@field createdAt integer Unix seconds

---@class UgBanOptions
---@field reason? string up to 255 characters, server logs and `ug_bans` only
---@field duration? integer seconds, permanent when nil
---@field by? string who banned, up to 64 characters
---@field kick? boolean drops an online target, defaults to true
