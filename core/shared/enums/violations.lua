--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@enum UgViolation
UgCore.Enums.Violations = {
    InvalidPayload = 'InvalidPayload',
    RateLimited = 'RateLimited',
    ConcurrencyExceeded = 'ConcurrencyExceeded',
    UnknownCallback = 'UnknownCallback',
    NotLoaded = 'NotLoaded',
    NoPermission = 'NoPermission',
    OutOfRange = 'OutOfRange',
    InvalidDeathState = 'InvalidDeathState',
    WeaponMismatch = 'WeaponMismatch',
}

local Violations = UgCore.Enums.Violations

---Guard score added per flag. Every violation MUST have a weight.
---@type table<UgViolation, integer>
UgCore.Enums.ViolationWeights = {
    [Violations.InvalidPayload] = 5,
    [Violations.RateLimited] = 1,
    [Violations.ConcurrencyExceeded] = 2,
    [Violations.UnknownCallback] = 3,
    [Violations.NotLoaded] = 2,
    [Violations.NoPermission] = 3,
    [Violations.OutOfRange] = 5,
    [Violations.InvalidDeathState] = 5,
    [Violations.WeaponMismatch] = 5,
}

---Guard actions, mildest first. `Guard:BeforeAction` hooks MAY pick a milder one.
---@enum UgGuardAction
UgCore.Enums.GuardActions = {
    Warn = 'warn',
    Kick = 'kick',
    Ban = 'ban',
}
