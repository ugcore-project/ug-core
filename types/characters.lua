--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@meta

---@class UgCharacter
---@field id integer
---@field name string display name
---@field data table owner fields such as first name and birth date, set by the character creator
---@field position? vector4 last saved position and heading, read from the ped on the server
---@field deathState UgDeathState saved death state, `Alive` when death state is not persisted
---@field createdAt integer Unix seconds
---@field lastPlayed? integer Unix seconds

---@class UgCharacterInput
---@field name string 1 to 64 characters
---@field data? table JSON data, up to 16 KB encoded
