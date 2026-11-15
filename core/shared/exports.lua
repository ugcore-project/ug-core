--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Binds public namespaces as flat exports named `<Namespace><Function>`.
---Consumers MUST go through the import proxy, never raw exports.
---@class UgCore.Internal.Exports
local InternalExports = {}
UgCore.Internal.Exports = InternalExports

local CATALOG_KEY = UgCore.Enums.GlobalState.Exports

---Exported function names by namespace, for the server-side proxy.
---@type table<string, string[]>
local catalog = {}

---Exports every function of `UgCore[namespace]`. Missing namespaces are skipped.
---@param namespace string
---@return integer count of exported functions
function InternalExports.Bind(namespace)
    local tbl = UgCore[namespace]

    if type(tbl) ~= 'table' then
        return 0
    end

    local names = {}

    for key, value in pairs(tbl) do
        if type(key) == 'string' and type(value) == 'function' then
            exports(namespace .. key, value)
            names[#names + 1] = key
        end
    end

    table.sort(names)
    catalog[namespace] = names

    return #names
end

---Exports one function under a name the proxy never exposes, for the import bridge.
---@param name string
---@param fn function
function InternalExports.BindInternal(name, fn)
    exports(name, fn)
end

---Server only. Publishes the catalog so proxies reject unknown functions.
function InternalExports.Publish()
    GlobalState:set(CATALOG_KEY, catalog, false)
end
