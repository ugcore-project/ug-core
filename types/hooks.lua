--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---Return `false` to cancel, a table to replace the payload, anything else to continue unchanged.
---@alias UgHookHandler fun(payload: table): (boolean|table|nil)

---@class UgHookOptions
---@field priority? integer lower runs first, defaults to 0

---Payload of `Guard:BeforeAction`. A hook MAY change `action` to a milder one or cancel.
---@class UgGuardActionPayload
---@field source integer
---@field action UgGuardAction
---@field score number
---@field flags UgGuardFlag[] recent flags, oldest first

---@class UgHookInfo
---@field name UgHookName
---@field resource string
---@field priority integer
