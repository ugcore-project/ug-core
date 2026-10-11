--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---Runs after built-in checks with the normalized value. Return `false, message` to reject.
---@alias UgSchemaValidator fun(value: any): boolean, string?

---@class UgSchemaStringOptions
---@field max integer maximum length in UTF-8 characters
---@field min? integer minimum length in UTF-8 characters
---@field pattern? string Lua pattern the value MUST match
---@field multiline? boolean allows tab, line feed and carriage return
---@field validate? UgSchemaValidator

---@class UgSchemaNumberOptions
---@field min? number
---@field max? number
---@field validate? UgSchemaValidator

---@class UgSchemaBooleanOptions
---@field validate? UgSchemaValidator

---@class UgSchemaVectorOptions
---@field maxComponent? number maximum absolute value of each component
---@field validate? UgSchemaValidator

---@class UgSchemaEnumOptions
---@field validate? UgSchemaValidator

---@class UgSchemaArrayOptions
---@field max integer maximum item count
---@field min? integer minimum item count
---@field validate? UgSchemaValidator

---@class UgSchemaMapOptions
---@field max integer maximum entry count
---@field min? integer minimum entry count
---@field validate? UgSchemaValidator

---@class UgSchemaObjectOptions
---@field strict? boolean rejects unknown keys when true, drops them when false. Defaults to true.
---@field validate? UgSchemaValidator

---Validated arguments. `n` is the number of declared arguments, so trailing optionals unpack correctly.
---@class UgSchemaArgs
---@field n integer
---@field [integer] any
