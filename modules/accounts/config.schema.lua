--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

local NAME_PATTERN = '^%l[%w]*$'
local MAX_BALANCE = 1000000000000

---@type UgConfigSettingsDefinition
return {
    kind = 'settings',
    options = {
        {
            key = 'accounts',
            type = 'table',
            default = {
                cash = { label = 'Cash', startingBalance = 500, allowNegative = false },
                bank = { label = 'Bank', startingBalance = 5000, allowNegative = false },
            },
            min = 1,
            max = 32,
            side = 'shared',
            description = 'Accounts every character has, by camelCase name: { label, startingBalance, allowNegative }.',
            validate = function(value)
                for name, account in pairs(value) do
                    if type(name) ~= 'string' or not name:find(NAME_PATTERN) then
                        return false, ('account names MUST be camelCase, got %s'):format(tostring(name))
                    end

                    if type(account) ~= 'table' or type(account.label) ~= 'string' or type(account.allowNegative) ~= 'boolean' then
                        return false, ('account "%s" MUST have a label and allowNegative'):format(name)
                    end

                    local start = account.startingBalance

                    if math.type(start) ~= 'integer' or start < 0 or start > MAX_BALANCE then
                        return false, ('account "%s" startingBalance MUST be an integer from 0 to %d'):format(name, MAX_BALANCE)
                    end
                end

                return true
            end,
        },
    },
}
