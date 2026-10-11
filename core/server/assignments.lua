--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Factory for per-character roles with grades, such as jobs and gangs.
---Definitions come from a data config, assignments from one table, the current role from a public statebag.
---@class UgCore.Internal.Assignments
local Assignments = {}
UgCore.Internal.Assignments = Assignments

---@class UgAssignmentGrade
---@field name string
---@field label string
---@field salary integer
---@field boss? boolean

---@class UgAssignmentDefinition
---@field label string
---@field grades UgAssignmentGrade[]
---@field defaultDuty? boolean

---@class UgAssignment
---@field name string
---@field label string
---@field grade integer
---@field gradeName string
---@field gradeLabel string
---@field salary integer
---@field boss boolean
---@field onDuty? boolean only with duty

---@class UgAssignmentSpec
---@field namespace string such as `Jobs`, for errors
---@field config string data config name
---@field table string SQL table with `character_id`, `name`, `grade`
---@field statebag string such as `ug-core:Job`
---@field default string definition every character falls back to
---@field duty boolean
---@field changed string event emitted with `(source, assignment, previous)`
---@field dutyChanged? string event emitted with `(source, onDuty)`
---@field beforeSet string hook with `{ source, name, grade }`

local Utils = UgCore.Internal.Utils
local Events = UgCore.Events
local Repository = UgCore.Internal.Database.Repository
local InternalHooks = UgCore.Internal.Hooks
local Errors = UgCore.Enums.Errors

local NAME_PATTERN = '^%l[%w_]*$'
local MAX_NAME = 32
local MAX_GRADES = 32
local MAX_SALARY = 1000000000

---Validates one definition of a data config. Use as its `validate`.
---@param entry any
---@param id any
---@return boolean ok
---@return string? message
function Assignments.ValidateDefinition(entry, id)
    if type(id) ~= 'string' or #id > MAX_NAME or not id:find(NAME_PATTERN) then
        return false, 'names MUST be lowercase letters, digits and underscores'
    end

    if type(entry) ~= 'table' or type(entry.label) ~= 'string' or type(entry.grades) ~= 'table' then
        return false, 'MUST have a label and grades'
    end

    if #entry.grades < 1 or #entry.grades > MAX_GRADES then
        return false, ('MUST have 1 to %d grades'):format(MAX_GRADES)
    end

    if entry.defaultDuty ~= nil and type(entry.defaultDuty) ~= 'boolean' then
        return false, 'defaultDuty MUST be a boolean'
    end

    for index, grade in ipairs(entry.grades) do
        if type(grade) ~= 'table' or type(grade.name) ~= 'string' or type(grade.label) ~= 'string' then
            return false, ('grade %d MUST have a name and a label'):format(index)
        end

        if math.type(grade.salary) ~= 'integer' or grade.salary < 0 or grade.salary > MAX_SALARY then
            return false, ('grade %d salary MUST be an integer from 0 to %d'):format(index, MAX_SALARY)
        end

        if grade.boss ~= nil and type(grade.boss) ~= 'boolean' then
            return false, ('grade %d boss MUST be a boolean'):format(index)
        end
    end

    return true
end

---Builds the public API of a role namespace and wires it into the characters module.
---@param spec UgAssignmentSpec
---@param ctx UgModuleContext
---@return table api functions to assign to the namespace
function Assignments.Create(spec, ctx)
    local api = {}

    ---@type table<integer, { name: string, grade: integer, onDuty: boolean }> source -> current role
    local current = {}

    ---@return table<string, UgAssignmentDefinition>
    local function definitions()
        return UgCore.Config.Get(spec.config)
    end

    if not definitions()[spec.default] then
        error(('config/%s.lua MUST define "%s"'):format(spec.config, spec.default), 0)
    end

    ---@param source integer
    ---@return UgAssignment?
    local function describe(source)
        local role = current[source]
        local definition = role and definitions()[role.name]
        local grade = definition and definition.grades[role.grade]

        if not role or not definition or not grade then
            return nil
        end

        local assignment = {
            name = role.name,
            label = definition.label,
            grade = role.grade,
            gradeName = grade.name,
            gradeLabel = grade.label,
            salary = grade.salary,
            boss = grade.boss == true,
        }

        if spec.duty then
            assignment.onDuty = role.onDuty
        end

        return assignment
    end

    ---@param source integer
    local function publish(source)
        Player(source).state:set(spec.statebag, describe(source), true)
    end

    ---@param name any
    ---@param grade any
    ---@return boolean
    local function valid(name, grade)
        local definition = type(name) == 'string' and definitions()[name] or nil

        return definition ~= nil and math.type(grade) == 'integer' and definition.grades[grade] ~= nil
    end

    ---@param name string
    ---@return boolean
    local function defaultDuty(name)
        local definition = definitions()[name]

        return definition ~= nil and definition.defaultDuty == true
    end

    ---@param source integer
    ---@return integer? characterId
    local function characterOf(source)
        local player = UgCore.Players.Get(source)

        return player and current[source] and player.characterId or nil
    end

    ---@param characterId integer
    ---@param name string
    ---@param grade integer
    ---@return boolean
    local function persist(characterId, name, grade)
        return (Repository.Update(
            ('INSERT INTO `%s` (`character_id`, `name`, `grade`) VALUES (?, ?, ?) ON DUPLICATE KEY UPDATE `name` = VALUES(`name`), `grade` = VALUES(`grade`)'):format(spec.table),
            { characterId, name, grade }
        ))
    end

    ---@param source integer
    ---@return UgAssignment? nil without a loaded character
    function api.Get(source)
        return describe(source)
    end

    ---Unknown names and grades return `invalid_args`, since they often come from admin input. MUST run in a thread.
    ---@param source integer
    ---@param name string
    ---@param grade? integer defaults to 1
    ---@return boolean ok
    ---@return UgErrorCode? errorCode
    function api.Set(source, name, grade)
        grade = grade or 1

        if not valid(name, grade) then
            return false, Errors.InvalidArgs
        end

        local characterId = characterOf(source)

        if not characterId then
            return false, Errors.NotLoaded
        end

        if not InternalHooks.Run(spec.beforeSet, { source = source, name = name, grade = grade }) then
            return false, Errors.NoPermission
        end

        if not persist(characterId, name, grade) then
            return false, Errors.InternalError
        end

        local previous = describe(source)
        local role = current[source]

        -- A new grade in the same role keeps duty. A new role starts at its default.
        local onDuty = role and role.name == name and role.onDuty or defaultDuty(name)

        current[source] = { name = name, grade = grade, onDuty = onDuty }
        publish(source)
        Events.Emit(spec.changed, source, describe(source), previous)

        return true, nil
    end

    ---@param source integer
    ---@param grade integer
    ---@return boolean ok
    ---@return UgErrorCode? errorCode
    function api.SetGrade(source, grade)
        local role = current[source]

        if not role then
            return false, Errors.NotLoaded
        end

        return api.Set(source, role.name, grade)
    end

    ---@param name string
    ---@param grade? integer
    ---@return boolean
    function api.Exists(name, grade)
        if grade == nil then
            return type(name) == 'string' and definitions()[name] ~= nil
        end

        return valid(name, grade)
    end

    ---@param name string
    ---@return UgAssignmentDefinition?
    function api.GetDefinition(name)
        return type(name) == 'string' and definitions()[name] or nil
    end

    if spec.duty then
        ---@param source integer
        ---@param onDuty boolean
        ---@return boolean ok
        ---@return UgErrorCode? errorCode
        function api.SetDuty(source, onDuty)
            if type(onDuty) ~= 'boolean' then
                Utils.Raise(2, '%s.SetDuty expects a boolean', spec.namespace)
            end

            local role = current[source]

            if not role then
                return false, Errors.NotLoaded
            end

            if role.onDuty ~= onDuty then
                role.onDuty = onDuty
                publish(source)
                Events.Emit(spec.dutyChanged, source, onDuty)
            end

            return true, nil
        end

        ---@param source integer
        ---@return boolean
        function api.IsOnDuty(source)
            local role = current[source]

            return role ~= nil and role.onDuty
        end
    end

    UgCore.Internal.Characters.Participate({
        create = function(_, characterId)
            return persist(characterId, spec.default, 1)
        end,
        load = function(source, characterId)
            local ok, row = Repository.Single(('SELECT `name`, `grade` FROM `%s` WHERE `character_id` = ?'):format(spec.table), { characterId })

            if not ok then
                return false
            end

            local name, grade = row and row.name, row and math.tointeger(row.grade)

            if not valid(name, grade) then
                if row then
                    ctx.logger.Warn('character %d had unknown %s "%s". Using "%s".', characterId, spec.config, tostring(name), spec.default)
                end

                name, grade = spec.default, 1
            end

            ---@cast name string
            ---@cast grade integer

            current[source] = { name = name, grade = grade, onDuty = defaultDuty(name) }
            publish(source)

            return true
        end,
        unload = function(source)
            current[source] = nil
            Player(source).state:set(spec.statebag, nil, true)
        end,
    })

    AddEventHandler('playerDropped', function()
        local dropped = math.tointeger(tonumber(source))

        if dropped then
            current[dropped] = nil
        end
    end)

    return api
end
