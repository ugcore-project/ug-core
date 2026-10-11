--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Balances of loaded characters live in memory. Every change writes the balance and a ledger row in one transaction.
---Changes apply in memory first and revert when the write fails, so concurrent changes never spend the same money twice.
---Functions that change balances MUST run in a thread.
---@class UgCore.Accounts
local Accounts = {}
UgCore.Accounts = Accounts

---@class UgCore.Internal.Accounts
local InternalAccounts = {}
UgCore.Internal.Accounts = InternalAccounts

---@class UgLedgerEntry
---@field amount integer
---@field balanceAfter integer
---@field reason? string
---@field relatedCharacterId? integer
---@field createdAt integer Unix seconds

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Repository = UgCore.Internal.Database.Repository
local InternalHooks = UgCore.Internal.Hooks
local Errors = UgCore.Enums.Errors
local AccountEvents = UgCore.Enums.Events.Accounts
local AccountHooks = UgCore.Enums.Hooks.Accounts

local MAX_AMOUNT = 1000000000000
local MAX_REASON = 128
local MAX_LEDGER = 100
local STARTING_REASON = 'Starting balance'
local CHANGED_EVENT = 'ug-core:AccountsChanged'
local SYNC_EVENT = 'ug-core:AccountsSync'

---@type table<integer, table<string, integer>> characterId -> account -> balance
local balances = {}

---@type table<integer, integer> characterId -> source
local owners = {}

---@return table<string, { label: string, startingBalance: integer, allowNegative: boolean }>
local function definitions()
    return UgCore.Config.Get('accounts', 'accounts')
end

---@param account any
---@param caller string
---@return { label: string, startingBalance: integer, allowNegative: boolean }
local function checkAccount(account, caller)
    local definition = type(account) == 'string' and definitions()[account] or nil

    if not definition then
        Utils.Raise(3, 'Accounts.%s: unknown account "%s"', caller, tostring(account))
    end

    ---@cast definition -nil

    return definition
end

---@param amount any
---@param caller string
local function checkAmount(amount, caller)
    if math.type(amount) ~= 'integer' or amount < 1 or amount > MAX_AMOUNT then
        Utils.Raise(3, 'Accounts.%s: amount MUST be an integer from 1 to %d', caller, MAX_AMOUNT)
    end
end

---@param reason any
---@param caller string
local function checkReason(reason, caller)
    if reason ~= nil and (type(reason) ~= 'string' or #reason > MAX_REASON) then
        Utils.Raise(3, 'Accounts.%s: reason MUST be a string of up to %d characters', caller, MAX_REASON)
    end
end

---@param source integer
---@return integer? characterId of the loaded character with balances in memory
local function loadedCharacter(source)
    local player = UgCore.Players.Get(source)
    local characterId = player and player.characterId

    if characterId and balances[characterId] then
        return characterId
    end

    return nil
end

---@param characterId integer
---@param account string
---@param balance integer
---@return UgDbQuery
local function balanceQuery(characterId, account, balance)
    return {
        query = 'INSERT INTO `ug_accounts` (`character_id`, `account`, `balance`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `balance` = VALUES(`balance`)',
        values = { characterId, account, balance },
    }
end

---@param characterId integer
---@param account string
---@param amount integer signed change
---@param balance integer balance after the change
---@param reason string?
---@param related integer?
---@return UgDbQuery
local function ledgerQuery(characterId, account, amount, balance, reason, related)
    return {
        query = "INSERT INTO `ug_ledger` (`character_id`, `account`, `amount`, `balance_after`, `reason`, `related_character_id`) VALUES (?, ?, ?, ?, NULLIF(?, ''), NULLIF(?, 0))",
        values = { characterId, account, amount, balance, reason or '', related or 0 },
    }
end

---@param characterId integer
---@param account string
---@param delta integer
---@param reason string?
local function notify(characterId, account, delta, reason)
    local source = owners[characterId]
    local balance = balances[characterId] and balances[characterId][account]

    if source and balance then
        TriggerClientEvent(CHANGED_EVENT, source, account, balance)
        Events.Emit(AccountEvents.Changed, source, account, balance, delta, reason)
    end
end

---Memory first, then one transaction. A failed write reverts the delta, not the whole balance.
---@param changes { characterId: integer, account: string, delta: integer, related: integer? }[]
---@param reason string?
---@param extra UgDbQuery[]? queries for offline characters, in the same transaction
---@return boolean ok
local function commit(changes, reason, extra)
    local queries = {}

    for _, change in ipairs(changes) do
        local accounts = balances[change.characterId]
        local balance = (accounts[change.account] or 0) + change.delta

        accounts[change.account] = balance
        queries[#queries + 1] = balanceQuery(change.characterId, change.account, balance)
        queries[#queries + 1] = ledgerQuery(change.characterId, change.account, change.delta, balance, reason, change.related)
    end

    for _, query in ipairs(extra or {}) do
        queries[#queries + 1] = query
    end

    if not Repository.Transaction(queries) then
        for _, change in ipairs(changes) do
            local accounts = balances[change.characterId]

            if accounts then
                accounts[change.account] = (accounts[change.account] or 0) - change.delta
            end
        end

        return false
    end

    for _, change in ipairs(changes) do
        notify(change.characterId, change.account, change.delta, reason)
    end

    return true
end

---@param source integer
---@param account string
---@return integer? balance nil when no character is loaded
function Accounts.GetBalance(source, account)
    checkAccount(account, 'GetBalance')

    local characterId = loadedCharacter(source)

    return characterId and balances[characterId][account] or nil
end

---@param source integer
---@return table<string, integer>? balances by account, nil when no character is loaded
function Accounts.GetAll(source)
    local characterId = loadedCharacter(source)

    return characterId and Utils.Table.DeepCopy(balances[characterId]) or nil
end

---@param source integer
---@param account string
---@param amount integer
---@param reason? string stored in the ledger
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function Accounts.Add(source, account, amount, reason)
    checkAccount(account, 'Add')
    checkAmount(amount, 'Add')
    checkReason(reason, 'Add')

    local characterId = loadedCharacter(source)

    if not characterId then
        return false, nil, Errors.NotLoaded
    end

    if not InternalHooks.Run(AccountHooks.BeforeAdd, { source = source, account = account, amount = amount, reason = reason }) then
        return false, nil, Errors.NoPermission
    end

    if not commit({ { characterId = characterId, account = account, delta = amount } }, reason) then
        return false, nil, Errors.InternalError
    end

    return true, balances[characterId][account], nil
end

---@param source integer
---@param account string
---@param amount integer
---@param reason? string stored in the ledger
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode `insufficient_funds` unless the account allows negative balances
function Accounts.Remove(source, account, amount, reason)
    local definition = checkAccount(account, 'Remove')

    checkAmount(amount, 'Remove')
    checkReason(reason, 'Remove')

    local characterId = loadedCharacter(source)

    if not characterId then
        return false, nil, Errors.NotLoaded
    end

    if not InternalHooks.Run(AccountHooks.BeforeRemove, { source = source, account = account, amount = amount, reason = reason }) then
        return false, nil, Errors.NoPermission
    end

    if not definition.allowNegative and (balances[characterId][account] or 0) < amount then
        return false, nil, Errors.InsufficientFunds
    end

    if not commit({ { characterId = characterId, account = account, delta = -amount } }, reason) then
        return false, nil, Errors.InternalError
    end

    return true, balances[characterId][account], nil
end

---Sets an exact balance. The ledger records the difference.
---@param source integer
---@param account string
---@param balance integer
---@param reason? string stored in the ledger
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function Accounts.Set(source, account, balance, reason)
    local definition = checkAccount(account, 'Set')
    local minimum = definition.allowNegative and -MAX_AMOUNT or 0

    if math.type(balance) ~= 'integer' or balance < minimum or balance > MAX_AMOUNT then
        Utils.Raise(2, 'Accounts.Set: balance MUST be an integer from %d to %d', minimum, MAX_AMOUNT)
    end

    checkReason(reason, 'Set')

    local characterId = loadedCharacter(source)

    if not characterId then
        return false, nil, Errors.NotLoaded
    end

    local delta = balance - (balances[characterId][account] or 0)

    if delta ~= 0 and not commit({ { characterId = characterId, account = account, delta = delta } }, reason) then
        return false, nil, Errors.InternalError
    end

    return true, balances[characterId][account], nil
end

---Moves money to another character, online or offline, in one transaction.
---@param source integer
---@param targetCharacterId integer
---@param account string
---@param amount integer
---@param reason? string stored in both ledgers
---@return boolean ok
---@return integer? balance of the sender
---@return UgErrorCode? errorCode
function Accounts.Transfer(source, targetCharacterId, account, amount, reason)
    local definition = checkAccount(account, 'Transfer')

    checkAmount(amount, 'Transfer')
    checkReason(reason, 'Transfer')

    if math.type(targetCharacterId) ~= 'integer' or targetCharacterId < 1 then
        Utils.Raise(2, 'Accounts.Transfer expects a target character id')
    end

    local characterId = loadedCharacter(source)

    if not characterId then
        return false, nil, Errors.NotLoaded
    end

    if targetCharacterId == characterId then
        return false, nil, Errors.InvalidArgs
    end

    local payload = { source = source, targetCharacterId = targetCharacterId, account = account, amount = amount, reason = reason }

    if not InternalHooks.Run(AccountHooks.BeforeTransfer, payload) then
        return false, nil, Errors.NoPermission
    end

    if not definition.allowNegative and (balances[characterId][account] or 0) < amount then
        return false, nil, Errors.InsufficientFunds
    end

    local changes = { { characterId = characterId, account = account, delta = -amount, related = targetCharacterId } }
    local extra = nil

    if balances[targetCharacterId] then
        changes[2] = { characterId = targetCharacterId, account = account, delta = amount, related = characterId }
    else
        local found, exists = Repository.Scalar('SELECT `id` FROM `ug_characters` WHERE `id` = ? AND `deleted_at` IS NULL', { targetCharacterId })

        if not found then
            return false, nil, Errors.InternalError
        end

        if not exists then
            return false, nil, Errors.NotFound
        end

        extra = {
            {
                query = 'INSERT INTO `ug_accounts` (`character_id`, `account`, `balance`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `balance` = `balance` + VALUES(`balance`)',
                values = { targetCharacterId, account, amount },
            },
            {
                query = "INSERT INTO `ug_ledger` (`character_id`, `account`, `amount`, `balance_after`, `reason`, `related_character_id`) SELECT ?, ?, ?, `balance`, NULLIF(?, ''), ? FROM `ug_accounts` WHERE `character_id` = ? AND `account` = ?",
                values = { targetCharacterId, account, amount, reason or '', characterId, targetCharacterId, account },
            },
        }
    end

    if not commit(changes, reason, extra) then
        return false, nil, Errors.InternalError
    end

    return true, balances[characterId][account], nil
end

---Latest ledger entries of the loaded character, newest first.
---@param source integer
---@param account string
---@param limit? integer 1 to 100, defaults to 25
---@return boolean ok
---@return UgLedgerEntry[]? entries
---@return UgErrorCode? errorCode
function Accounts.GetLedger(source, account, limit)
    checkAccount(account, 'GetLedger')

    limit = limit or 25

    if math.type(limit) ~= 'integer' or limit < 1 or limit > MAX_LEDGER then
        Utils.Raise(2, 'Accounts.GetLedger: limit MUST be an integer from 1 to %d', MAX_LEDGER)
    end

    local characterId = loadedCharacter(source)

    if not characterId then
        return false, nil, Errors.NotLoaded
    end

    -- LIMIT takes a validated integer inline: some MySQL versions reject LIMIT ? in prepared statements.
    local ok, rows = Repository.Query(([[
        SELECT `amount`, `balance_after` AS `balanceAfter`, `reason`, `related_character_id` AS `relatedCharacterId`,
            UNIX_TIMESTAMP(`created_at`) AS `createdAt`
        FROM `ug_ledger` WHERE `character_id` = ? AND `account` = ? ORDER BY `id` DESC LIMIT %d
    ]]):format(limit), { characterId, account })

    if not ok or not rows then
        return false, nil, Errors.InternalError
    end

    return true, rows, nil
end

---Starting balances, each with a ledger row.
---@param characterId integer
---@param accounts table<string, { startingBalance: integer }>
---@return UgDbQuery[]
local function startingQueries(characterId, accounts)
    local queries = {}

    for account, definition in pairs(accounts) do
        queries[#queries + 1] = balanceQuery(characterId, account, definition.startingBalance)

        if definition.startingBalance > 0 then
            queries[#queries + 1] = ledgerQuery(characterId, account, definition.startingBalance, definition.startingBalance, STARTING_REASON)
        end
    end

    return queries
end

---@param ctx UgModuleContext
function InternalAccounts.Init(ctx)
    UgCore.Internal.Characters.Participate({
        create = function(_, characterId)
            return Repository.Transaction(startingQueries(characterId, definitions()))
        end,
        load = function(source, characterId)
            local ok, rows = Repository.Query('SELECT `account`, `balance` FROM `ug_accounts` WHERE `character_id` = ?', { characterId })

            if not ok or not rows then
                return false
            end

            local stored = {}

            for _, row in ipairs(rows) do
                stored[row.account] = math.tointeger(row.balance) or 0
            end

            local missing = {}
            local loaded = {}

            for account, definition in pairs(definitions()) do
                if stored[account] then
                    loaded[account] = stored[account]
                else
                    missing[account] = definition
                    loaded[account] = definition.startingBalance
                end
            end

            if next(missing) and not Repository.Transaction(startingQueries(characterId, missing)) then
                return false
            end

            balances[characterId] = loaded
            owners[characterId] = source
            TriggerClientEvent(SYNC_EVENT, source, loaded)

            return true
        end,
        unload = function(source, characterId)
            balances[characterId] = nil
            owners[characterId] = nil
            TriggerClientEvent(SYNC_EVENT, source, {})
        end,
    })

    local names = {}

    for name in pairs(definitions()) do
        names[#names + 1] = name
    end

    table.sort(names)
    ctx.logger.Debug('accounts: %s.', table.concat(names, ', '))
end
