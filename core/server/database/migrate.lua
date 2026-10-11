--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Connection check and versioned migrations, tracked in `ug_migrations (scope, version, applied_at)`.
---Migration files are trusted static SQL. They are the only queries that skip prepared statements.
---@class UgCore.Internal.Database.Migrate
local Migrate = {}
UgCore.Internal.Database.Migrate = Migrate

local Files = UgCore.Internal.Files
local Logger = UgCore.Logger
local Repository = UgCore.Internal.Database.Repository

local CONNECT_TIMEOUT = 30000
local VERSION_PATTERN = '^(%d+)%.(%d+)%.(%d+)$'
local CORE_SCOPE = 'core'
local CORE_DIR = 'core/server/database/sql/'

---Core table versions, applied before any module. Files are `core/server/database/sql/v<version>.sql`.
---@type string[]
local CORE_VERSIONS = {}

local MIGRATIONS_TABLE = [[
CREATE TABLE IF NOT EXISTS `ug_migrations` (
    `scope` VARCHAR(64) NOT NULL,
    `version` VARCHAR(32) NOT NULL,
    `applied_at` TIMESTAMP NOT NULL DEFAULT CURRENT_TIMESTAMP,
    PRIMARY KEY (`scope`, `version`)
)]]

---@type string?
local serverLabel = nil

---@type table<string, string[]>
local applied = {}

---@param text string
---@return integer[]? parts
local function parseVersion(text)
    local major, minor, patch = text:match(VERSION_PATTERN)

    if not major then
        return nil
    end

    return {
        tonumber(major) --[[@as integer]],
        tonumber(minor) --[[@as integer]],
        tonumber(patch) --[[@as integer]]
    }
end

---@param a string
---@param b string
---@return boolean
local function versionLess(a, b)
    local left, right = parseVersion(a) or { 0, 0, 0 }, parseVersion(b) or { 0, 0, 0 }

    for index = 1, 3 do
        if left[index] ~= right[index] then
            return left[index] < right[index]
        end
    end

    return false
end

---@param text string
---@return boolean
function Migrate.IsVersion(text)
    return type(text) == 'string' and parseVersion(text) ~= nil
end

---Statements end with `;` at the end of a line. Lines starting with `--` are comments.
---@param content string
---@return string[]
local function splitStatements(content)
    local statements = {}
    local current = {}

    for line in (content .. '\n'):gmatch('(.-)\r?\n') do
        local trimmed = line:match('^%s*(.-)%s*$')

        if trimmed ~= '' and trimmed:sub(1, 2) ~= '--' then
            if trimmed:sub(-1) == ';' then
                current[#current + 1] = trimmed:sub(1, -2)
                statements[#statements + 1] = table.concat(current, '\n')
                current = {}
            else
                current[#current + 1] = trimmed
            end
        end
    end

    if #current > 0 then
        statements[#statements + 1] = table.concat(current, '\n')
    end

    return statements
end

---@param version string `SELECT VERSION()` output
---@return boolean supported
---@return string label
local function checkServer(version)
    local major, minor = version:match('^(%d+)%.(%d+)')
    major, minor = tonumber(major) or 0, tonumber(minor) or 0

    if version:find('MariaDB', 1, true) then
        return major > 10 or (major == 10 and minor >= 6), 'MariaDB ' .. version:match('^[%d%.]+')
    end

    return major >= 8, 'MySQL ' .. (version:match('^[%d%.]+') or version)
end

---Waits for oxmysql, checks the server version and creates `ug_migrations`. MUST run in a thread.
---@return boolean ok
---@return string? message
function Migrate.Connect()
    local pending = promise.new()
    local settled = false

    ---@param ok boolean
    ---@param message string?
    local function settle(ok, message)
        if not settled then
            settled = true
            pending:resolve({ ok, message })
        end
    end

    CreateThread(function()
        local ok, err = pcall(MySQL.ready.await)

        settle(ok, not ok and tostring(err) or nil)
    end)

    SetTimeout(CONNECT_TIMEOUT, function()
        settle(false, ('no connection after %d s. Check oxmysql and mysql_connection_string'):format(CONNECT_TIMEOUT // 1000))
    end)

    local result = Citizen.Await(pending)

    if not result[1] then
        return false, 'Database: ' .. tostring(result[2])
    end

    local ok, version = Repository.Scalar('SELECT VERSION() AS `version`')

    if not ok or type(version) ~= 'string' then
        return false, 'Database: cannot read the server version'
    end

    local supported, label = checkServer(version)

    if not supported then
        return false, ('Database: MySQL 8.0 or MariaDB 10.6+ is required, found %s'):format(label)
    end

    if not Repository.Query(MIGRATIONS_TABLE) then
        return false, 'Database: cannot create ug_migrations'
    end

    serverLabel = label
    Logger.Info('Database: connected to %s.', label)

    return true, nil
end

---Applies pending versions of one scope in semver order. Stops at the first failure.
---@param scope string `core` or a module name
---@param versions string[]
---@param directory string folder holding `v<version>.sql`, with a trailing slash
---@return boolean ok
---@return string? message
function Migrate.Run(scope, versions, directory)
    local ok, rows = Repository.Query('SELECT `version` FROM `ug_migrations` WHERE `scope` = ?', { scope })

    if not ok or not rows then
        return false, ('Database: cannot read migrations of %s'):format(scope)
    end

    local done = {}

    for index = 1, #rows do
        done[rows[index].version] = true
    end

    local ordered = {}

    for index = 1, #versions do
        ordered[index] = versions[index]
    end

    table.sort(ordered, versionLess)

    for _, version in ipairs(ordered) do
        if not done[version] then
            local path = ('%sv%s.sql'):format(directory, version)
            local content = Files.Load(path)

            if content == nil then
                return false, ('%s migration %s failed: missing file %s'):format(scope, version, path)
            end

            for _, statement in ipairs(splitStatements(content)) do
                local executed, err = pcall(MySQL.query.await, statement)

                if not executed then
                    return false, ('%s migration %s failed: %s'):format(scope, version, tostring(err))
                end
            end

            if not Repository.Insert('INSERT INTO `ug_migrations` (`scope`, `version`) VALUES (?, ?)', { scope, version }) then
                return false, ('%s migration %s ran but was not recorded'):format(scope, version)
            end

            done[version] = true
            Logger.Info('Database: applied %s v%s.', scope, version)
        end
    end

    local list = {}

    for version in pairs(done) do
        list[#list + 1] = version
    end

    table.sort(list, versionLess)
    applied[scope] = list

    return true, nil
end

---@return boolean ok
---@return string? message
function Migrate.RunCore()
    return Migrate.Run(CORE_SCOPE, CORE_VERSIONS, CORE_DIR)
end

---@return string? label such as `MariaDB 10.11.6`, nil before Connect
---@return table<string, string[]> applied versions by scope, after Run
function Migrate.GetState()
    local copy = {}

    for scope, list in pairs(applied) do
        copy[scope] = { table.unpack(list) }
    end

    return serverLabel, copy
end
