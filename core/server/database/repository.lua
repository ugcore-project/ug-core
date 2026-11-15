--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Prepared queries through oxmysql `rawExecute`. Every call MUST run in a thread.
---Failures are logged on the server and return `false`. They never raise.
---@class UgCore.Internal.Database.Repository
local Repository = {}
UgCore.Internal.Database.Repository = Repository

local Utils = UgCore.Internal.Utils
local Logger = UgCore.Logger

---@param sql any
---@param params any
---@param caller string
local function checkArgs(sql, params, caller)
    if type(sql) ~= 'string' or sql == '' then
        Utils.Raise(3, 'Database.%s expects a SQL string', caller)
    end

    if params == nil then
        return
    end

    if type(params) ~= 'table' then
        Utils.Raise(3, 'Database.%s expects params as an array', caller)
    end

    local count = 0

    for _, value in pairs(params) do
        count = count + 1

        if type(value) == 'table' then
            Utils.Raise(3, 'Database.%s params MUST be flat. Nested tables run as a batch', caller)
        end
    end

    if count ~= #params then
        Utils.Raise(3, "Database.%s params MUST NOT contain nil. Use a sentinel with NULLIF(?, '') in SQL", caller)
    end
end

---@param sql string
---@param params UgDbParams?
---@return boolean ok
---@return any result rows for SELECT, a result header for writes
local function execute(sql, params)
    local ok, result = pcall(MySQL.rawExecute.await, sql, params)

    if not ok then
        Logger.Error('Database: query failed: %s', tostring(result))
        Logger.Debug('Database: failed query: %s', sql)

        return false, nil
    end

    return true, result
end

---@param sql string
---@param params? UgDbParams
---@return boolean ok
---@return table[]? rows
function Repository.Query(sql, params)
    checkArgs(sql, params, 'Query')

    local ok, rows = execute(sql, params)

    if not ok then
        return false, nil
    end

    return true, type(rows) == 'table' and rows or {}
end

---@param sql string
---@param params? UgDbParams
---@return boolean ok
---@return table? row the first row, nil when there is none
function Repository.Single(sql, params)
    checkArgs(sql, params, 'Single')

    local ok, rows = execute(sql, params)

    if not ok then
        return false, nil
    end

    return true, type(rows) == 'table' and rows[1] or nil
end

---The query MUST select exactly one column.
---@param sql string
---@param params? UgDbParams
---@return boolean ok
---@return any value the first column of the first row, nil when there is none
function Repository.Scalar(sql, params)
    checkArgs(sql, params, 'Scalar')

    local ok, rows = execute(sql, params)

    if not ok then
        return false, nil
    end

    local row = type(rows) == 'table' and rows[1] or nil

    if type(row) ~= 'table' then
        return true, nil
    end

    local _, value = next(row)

    return true, value
end

---@param sql string
---@param params? UgDbParams
---@return boolean ok
---@return integer? insertId
function Repository.Insert(sql, params)
    checkArgs(sql, params, 'Insert')

    local ok, header = execute(sql, params)

    if not ok then
        return false, nil
    end

    return true, type(header) == 'table' and header.insertId or nil
end

---For UPDATE and DELETE.
---@param sql string
---@param params? UgDbParams
---@return boolean ok
---@return integer? affectedRows
function Repository.Update(sql, params)
    checkArgs(sql, params, 'Update')

    local ok, header = execute(sql, params)

    if not ok then
        return false, nil
    end

    return true, type(header) == 'table' and header.affectedRows or nil
end

---Runs every query or none.
---@param queries UgDbQuery[]
---@return boolean ok
function Repository.Transaction(queries)
    if type(queries) ~= 'table' or #queries == 0 then
        Utils.Raise(2, 'Database.Transaction expects a non-empty array of { query, values }')
    end

    for index = 1, #queries do
        local entry = queries[index]

        if type(entry) ~= 'table' then
            Utils.Raise(2, 'Database.Transaction: query %d MUST be a table', index)
        end

        checkArgs(entry.query, entry.values, 'Transaction')
    end

    local ok, result = pcall(MySQL.transaction.await, queries)

    if not ok then
        Logger.Error('Database: transaction failed: %s', tostring(result))

        return false
    end

    return result == true
end
