--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Group names and permissions end up in ExecuteCommand, so they MUST stay this strict.
local NAME_PATTERN = '^%l[%l%d_]*$'
local PERMISSION_PATTERN = '^%a[%w%._%-]*$'
local MAX_NAME = 32
local MAX_LABEL = 64
local MAX_PERMISSION = 64
local MAX_PERMISSIONS = 64
local MAX_WEIGHT = 1000000

---@param name string
---@param group any
---@param groups table
---@return string? problem
local function checkGroup(name, group, groups)
    if type(name) ~= 'string' or #name > MAX_NAME or not name:find(NAME_PATTERN) then
        return ('group names MUST be lowercase letters, digits and underscores, up to %d characters, got %s'):format(MAX_NAME, tostring(name))
    end

    if type(group) ~= 'table' then
        return ('group "%s" MUST be a table'):format(name)
    end

    if type(group.label) ~= 'string' or group.label == '' or #group.label > MAX_LABEL then
        return ('group "%s" MUST have a label of up to %d characters'):format(name, MAX_LABEL)
    end

    if math.type(group.weight) ~= 'integer' or group.weight < 0 or group.weight > MAX_WEIGHT then
        return ('group "%s" weight MUST be an integer from 0 to %d'):format(name, MAX_WEIGHT)
    end

    if group.inherits ~= nil and (type(group.inherits) ~= 'string' or group.inherits == name or groups[group.inherits] == nil) then
        return ('group "%s" inherits MUST be another group'):format(name)
    end

    local permissions = group.permissions

    if type(permissions) ~= 'table' or #permissions > MAX_PERMISSIONS then
        return ('group "%s" permissions MUST be an array of up to %d permissions'):format(name, MAX_PERMISSIONS)
    end

    local count = 0

    for _ in pairs(permissions) do
        count = count + 1
    end

    if count ~= #permissions then
        return ('group "%s" permissions MUST be an array'):format(name)
    end

    for _, permission in ipairs(permissions) do
        if type(permission) ~= 'string' or #permission > MAX_PERMISSION or not permission:find(PERMISSION_PATTERN) then
            return ('group "%s" has an invalid permission %s. Use letters, digits, dots, dashes and underscores'):format(name, tostring(permission))
        end
    end

    for key in pairs(group) do
        if key ~= 'label' and key ~= 'weight' and key ~= 'inherits' and key ~= 'permissions' then
            return ('group "%s" has an unknown field "%s"'):format(name, tostring(key))
        end
    end

    return nil
end

---@param groups table
---@return string? problem
local function checkCycles(groups)
    local names = {}

    for name in pairs(groups) do
        names[#names + 1] = name
    end

    table.sort(names)

    for _, start in ipairs(names) do
        local path, seen, current = { start }, { [start] = true }, groups[start].inherits

        while current do
            path[#path + 1] = current

            if seen[current] then
                return 'inheritance cycle: ' .. table.concat(path, ' -> ')
            end

            seen[current] = true
            current = groups[current].inherits
        end
    end

    return nil
end

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'groups',
            type = 'table',
            default = {
                moderator = { label = 'Moderator', weight = 10, permissions = {} },
                admin = { label = 'Admin', weight = 50, inherits = 'moderator', permissions = { 'ug.admin' } },
                founder = { label = 'Founder', weight = 100, inherits = 'admin', permissions = {} },
            },
            max = 64,
            description = 'Staff groups by lowercase name: { label, weight, inherits?, permissions }. Each is the ACE principal group.<name>. Higher weight outranks lower.',
            validate = function(value)
                for name, group in pairs(value) do
                    local problem = checkGroup(name, group, value)

                    if problem then
                        return false, problem
                    end
                end

                local problem = checkCycles(value)

                if problem then
                    return false, problem
                end

                return true
            end,
        },
    },
}
