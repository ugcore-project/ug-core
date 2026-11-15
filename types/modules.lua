--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---Returned by `modules/<name>/module.lua`. File lists are stems loaded in order: `shared/<stem>.lua` on both sides,
---then `server/<stem>.lua` or `client/<stem>.lua`.
---@class UgModuleDefinition
---@field name string camelCase, MUST match the folder name
---@field namespace string PascalCase public namespace, such as `Accounts`
---@field clientNamespace? string PascalCase namespace on clients when it differs, such as `LocalPlayer`
---@field description string shown in config/modules.lua
---@field required? boolean required modules cannot be disabled and are not listed in config/modules.lua
---@field deps? string[] modules that MUST be enabled
---@field optionalDeps? string[] modules loaded first when enabled
---@field shared? string[]
---@field server? string[]
---@field client? string[]
---@field migrations? string[] versions, applied from `sql/v<version>.sql` in semver order
---@field Init? fun(ctx: UgModuleContext)
---@field Start? fun(ctx: UgModuleContext)
---@field Stop? fun(ctx: UgModuleContext)

---@class UgModuleLogger
---@field Debug fun(message: any, ...: any)
---@field Info fun(message: any, ...: any)
---@field Warn fun(message: any, ...: any)
---@field Error fun(message: any, ...: any)

---@class UgModuleContext
---@field name string
---@field logger UgModuleLogger prefixes every line with `[<name>]`
---@field config table? this module's resolved config, nil without `config.schema.lua`
---@field database UgCore.Internal.Database.Repository

---@class UgModuleStatus
---@field name string
---@field enabled boolean
---@field reason string why the module is enabled or disabled
