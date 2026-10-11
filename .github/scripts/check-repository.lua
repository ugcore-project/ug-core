--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

-- Repository checks for CI. Run from the repository root with Lua 5.4: lua5.4 .github/scripts/check-repository.lua
-- Checks the manifest against the files in the repository, and the license header of every Lua file.
--
-- With --package, checks a release archive instead. Run from the unpacked folder with its file list on stdin:
--   find . -type f | lua5.4 check-repository.lua --package
-- The same manifest checks apply, plus: nothing for development ships, and the owner config folder ships empty.

local PACKAGE = arg and arg[1] == '--package'

local HEADER = table.concat({
    '--[[',
    '',
    '    ug-core - https://github.com/ugcore-project',
    '    Copyright (C) 2026 UgCore Framework & Contributors',
    '    Licensed under the GNU General Public License. See LICENSE for details.',
    '',
    ']] --',
    '',
}, '\n') .. '\n'

-- Never sent to clients: server code, module schemas and migrations, owner config, tests.
local SERVER_ONLY = {
    '^core/server/',
    '^modules/[^/]+/server/',
    '^modules/[^/]+/sql/',
    '^modules/[^/]+/config%.schema%.lua$',
    '^config/',
    '^tests/',
    '^%.github/',
}

local SCRIPT_DIRECTIVES = {
    shared_script = 'shared', shared_scripts = 'shared',
    server_script = 'server', server_scripts = 'server',
    client_script = 'client', client_scripts = 'client',
    file = 'files', files = 'files',
}

---@type string[]
local errors = {}

---@param message string
---@param ... any
local function fail(message, ...)
    errors[#errors + 1] = message:format(...)
end

---Tracked and untracked files, without ignored ones, with forward slashes.
---In package mode, the file list on stdin.
---@return string[]
local function listFiles()
    local files = {}

    if PACKAGE then
        for line in io.lines() do
            local path = line:gsub('\r$', ''):gsub('^%./', '')

            if path ~= '' then
                files[#files + 1] = path
            end
        end

        return files
    end

    local pipe = assert(io.popen('git ls-files --cached --others --exclude-standard'))

    for line in pipe:lines() do
        files[#files + 1] = line
    end

    pipe:close()

    return files
end

---@param pattern string FiveM glob: `*` within the file name, `**` as a whole segment for any number of folders
---@param path string
---@return boolean
local function globMatch(pattern, path)
    local patternParts, pathParts = {}, {}

    for part in pattern:gmatch('[^/]+') do
        patternParts[#patternParts + 1] = part
    end

    for part in path:gmatch('[^/]+') do
        pathParts[#pathParts + 1] = part
    end

    ---@param segment string
    ---@return string
    local function toLuaPattern(segment)
        local escaped = segment:gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')

        return '^' .. escaped:gsub('%*', '[^/]*') .. '$'
    end

    ---@param i integer
    ---@param j integer
    ---@return boolean
    local function match(i, j)
        if i > #patternParts then
            return j > #pathParts
        end

        local segment = patternParts[i]

        if segment == '**' then
            for k = j, #pathParts + 1 do
                if match(i + 1, k) then
                    return true
                end
            end

            return false
        end

        return j <= #pathParts and pathParts[j]:find(toLuaPattern(segment)) ~= nil and match(i + 1, j + 1)
    end

    return match(1, 1)
end

---@return table<string, string[]> entries by directive group, plus `modules` and `version`
local function readManifest()
    local manifest = { shared = {}, server = {}, client = {}, files = {}, modules = {}, version = {} }

    local env = setmetatable({}, {
        __index = function(_, directive)
            return function(value)
                local group = SCRIPT_DIRECTIVES[directive]
                    or (directive == 'ug_module' and 'modules')
                    or (directive == 'version' and 'version')

                if not group then
                    return
                end

                for _, entry in ipairs(type(value) == 'table' and value or { value }) do
                    table.insert(manifest[group], entry)
                end
            end
        end,
    })

    local chunk = assert(loadfile('fxmanifest.lua', 't', env))

    chunk()

    return manifest
end

---@param files string[]
---@param pattern string
---@return string[]
local function matching(files, pattern)
    local found = {}

    for _, path in ipairs(files) do
        if globMatch(pattern, path) then
            found[#found + 1] = path
        end
    end

    return found
end

---@param path string
---@return boolean
local function isServerOnly(path)
    for _, pattern in ipairs(SERVER_ONLY) do
        if path:find(pattern) then
            return true
        end
    end

    return false
end

local files = listFiles()
local exists = {}

for _, path in ipairs(files) do
    exists[path] = true
end

local manifest = readManifest()

-- Every listed script and file exists. FXServer warns about patterns that match nothing.
for _, group in ipairs({ 'shared', 'server', 'client', 'files' }) do
    for _, entry in ipairs(manifest[group]) do
        if entry:sub(1, 1) ~= '@' then
            local folders = entry:match('^(.*)/[^/]*$') or ''

            if not entry:find('**', 1, true) and folders:find('*', 1, true) then
                fail('fxmanifest.lua: %s entry "%s" has * in a folder name. FXServer only expands it there with **', group, entry)
            end

            local found = entry:find('*', 1, true) and matching(files, entry) or (exists[entry] and { entry } or {})

            if #found == 0 then
                fail('fxmanifest.lua: %s entry "%s" matches no file', group, entry)
            end

            if group == 'files' or group == 'client' or group == 'shared' then
                for _, path in ipairs(found) do
                    if isServerOnly(path) then
                        fail('fxmanifest.lua: %s entry "%s" sends the server-only file %s to clients', group, entry, path)
                    end
                end
            end
        end
    end
end

-- Clients load module shared and client files with LoadResourceFile, which only reads files listed in files {}.
for _, path in ipairs(files) do
    if path:find('^modules/[^/]+/shared/[^/]+%.lua$') or path:find('^modules/[^/]+/client/[^/]+%.lua$') then
        local listed = false

        for _, entry in ipairs(manifest.files) do
            if globMatch(entry, path) then
                listed = true
                break
            end
        end

        if not listed then
            fail('fxmanifest.lua: %s is not in files {}, so clients cannot load it', path)
        end
    end
end

-- Every declared module has a definition, and every module folder is declared.
local declared = {}

for _, name in ipairs(manifest.modules) do
    declared[name] = true

    if not exists[('modules/%s/module.lua'):format(name)] then
        fail('fxmanifest.lua: ug_module "%s" has no modules/%s/module.lua', name, name)
    end
end

for _, path in ipairs(files) do
    local name = path:match('^modules/([^/]+)/module%.lua$')

    if name and not declared[name] then
        fail('modules/%s is not declared with ug_module in fxmanifest.lua', name)
    end
end

local version = tostring(manifest.version[1])

-- Development builds carry build metadata: 1.2.0+dev.42.abc1234. Version.Get callers ignore it.
if #manifest.version ~= 1 or not (version:find('^%d+%.%d+%.%d+$') or (PACKAGE and version:find('^%d+%.%d+%.%d+%+dev%.%d+%.%x+$'))) then
    fail('fxmanifest.lua: version MUST be MAJOR.MINOR.PATCH')
end

-- Owners install the archive: tests, tooling and type stubs stay out. config/ ships empty, so an update
-- extracted over an installed copy never replaces an owner file, and SaveResourceFile has a folder to write in.
if PACKAGE then
    local DEVELOPMENT = { '^tests/', '^types/', '^%.', '/%.', '^config/[^.]' }

    for _, path in ipairs(files) do
        if path ~= 'config/.gitkeep' then
            for _, pattern in ipairs(DEVELOPMENT) do
                if path:find(pattern) then
                    fail('package: %s MUST NOT ship', path)
                    break
                end
            end
        end
    end

    for _, required in ipairs({ 'fxmanifest.lua', 'LICENSE', 'config/.gitkeep' }) do
        if not exists[required] then
            fail('package: %s is missing', required)
        end
    end
end

-- Every Lua file starts with the license header and one blank line.
for _, path in ipairs(files) do
    if path:find('%.lua$') and not path:find('^config/') then
        local handle = io.open(path, 'rb')
        local content = handle and handle:read('a') or ''

        if handle then
            handle:close()
        end

        if content:gsub('\r\n', '\n'):sub(1, #HEADER) ~= HEADER then
            fail('%s does not start with the license header', path)
        end
    end
end

-- Error codes, event names and hook names come from UgCore.Enums, so changing one value updates every user.
-- Only the enum files spell them out.
---@param path string
---@return string
local function read(path)
    local handle = io.open(path, 'rb')
    local content = handle and handle:read('a') or ''

    if handle then
        handle:close()
    end

    return (content:gsub('\r\n', '\n'))
end

local enumValues = {}

for code in read('core/shared/enums/errors.lua'):gmatch("= '([%l_]+)'") do
    enumValues[code] = true
end

for key in read('core/shared/enums/statebags.lua'):gmatch("= '(ug%-core:%u%a*)'") do
    enumValues[key] = true
end

---@param line string
---@return string? literal
local function enumLiteral(line)
    for quoted in line:gmatch("'([^']*)'") do
        if enumValues[quoted] or quoted:find('^ug%-core:%u%a*:%u%a*$') or quoted:find('^%u%a*:Before%u%a*$') then
            return quoted
        end
    end

    return nil
end

for _, path in ipairs(files) do
    local scanned = path:find('^core/.*%.lua$') or path:find('^modules/.*%.lua$') or path:find('^import.*%.lua$')

    if scanned and not path:find('/enums') then
        local number = 0

        for line in (read(path) .. '\n'):gmatch('([^\n]*)\n') do
            number = number + 1

            local literal = not line:find('^%s*%-%-') and enumLiteral(line)

            if literal then
                fail('%s:%d spells out "%s". Use UgCore.Enums instead', path, number, literal)
            end
        end
    end
end

for _, message in ipairs(errors) do
    print('error: ' .. message)
end

print(('%d file(s) checked, %d error(s).'):format(#files, #errors))
os.exit(#errors == 0 and 0 or 1)
