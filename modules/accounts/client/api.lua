--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Balances of the local player's loaded character, sent by the server to this player only.
---@class UgCore.Accounts
local Accounts = {}
UgCore.Accounts = Accounts

local Utils = UgCore.Internal.Utils

---@type table<string, integer>
local balances = {}

---@param account string
---@return integer? balance nil when no character is loaded or the account does not exist
function Accounts.GetBalance(account)
    return balances[account]
end

---@return table<string, integer>
function Accounts.GetAll()
    return Utils.Table.DeepCopy(balances)
end

local Events = UgCore.Events
local CHANGED = UgCore.Enums.Events.Accounts.Changed

---On clients `Changed` carries `(account, balance, delta)` for the local player. `balance` is nil once the character unloads.
---@param account string
---@param balance integer?
local function apply(account, balance)
    local previous = balances[account]

    if previous == balance then
        return
    end

    balances[account] = balance
    Events.Emit(CHANGED, account, balance, (balance or 0) - (previous or 0))
end

UgCore.Network.Register('AccountsSync', function(values)
    local incoming = {}

    for account, balance in pairs(type(values) == 'table' and values or {}) do
        if type(account) == 'string' and math.type(balance) == 'integer' then
            incoming[account] = balance
        end
    end

    for account in pairs(balances) do
        if incoming[account] == nil then
            apply(account, nil)
        end
    end

    for account, balance in pairs(incoming) do
        apply(account, balance)
    end
end)

UgCore.Network.Register('AccountsChanged', function(account, balance)
    if type(account) == 'string' and math.type(balance) == 'integer' then
        apply(account, balance)
    end
end)
