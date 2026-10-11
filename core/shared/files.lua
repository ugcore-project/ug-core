--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Paths are relative to the ug-core resource root.
---@class UgCore.Internal.Files
local Files = {}
UgCore.Internal.Files = Files

local Utils = UgCore.Internal.Utils

local RESOURCE = GetCurrentResourceName()
local IS_SERVER = IsDuplicityVersion()

---@param path string
---@param caller string
local function checkPath(path, caller)
    if type(path) ~= 'string' or path == '' then
        Utils.Raise(3, 'Files.%s expects a non-empty path', caller)
    end
end

---On clients only files listed in the manifest are readable.
---@param path string
---@return string?
function Files.Load(path)
    checkPath(path, 'Load')

    return LoadResourceFile(RESOURCE, path)
end

---@param path string
---@return boolean
function Files.Exists(path)
    checkPath(path, 'Exists')

    return LoadResourceFile(RESOURCE, path) ~= nil
end

---Server only. Overwrites the file.
---@param path string
---@param content string
---@return boolean
function Files.Save(path, content)
    if not IS_SERVER then
        Utils.Raise(2, 'Files.Save is server-only')
    end

    checkPath(path, 'Save')

    if type(content) ~= 'string' then
        Utils.Raise(2, 'Files.Save expects string content, got %s', type(content))
    end

    return SaveResourceFile(RESOURCE, path, content, #content)
end
