--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Shop positions for blips and markers, and the requests a shop UI makes. Prices always come from the server.
---Actions MUST run in a thread.
---@class UgCore.Shops
local Shops = {}
UgCore.Shops = Shops

local Callback = UgCore.Callback

local REPLICATION_KEY = UgCore.Enums.GlobalState.Shops

---@return table<string, { label: string, coords: vector3[] }> shops by name
function Shops.GetAll()
    local payload = GlobalState[REPLICATION_KEY]
    local list = {}

    for name, shop in pairs(type(payload) == 'table' and payload or {}) do
        local points = {}

        for index, point in ipairs(shop.coords or {}) do
            points[index] = vector3(point.x, point.y, point.z)
        end

        list[name] = { label = shop.label, coords = points }
    end

    return list
end

---What the shop sells now. Refused out of range or without access.
---@param name string
---@return boolean ok
---@return UgErrorCode? errorCode
---@return UgShopListing? listing
function Shops.Open(name)
    local ok, value, errorCode = Callback.Await('ug-core:ShopOpen', name)

    if not ok then
        return false, errorCode, nil
    end

    if type(value) == 'table' then
        return true, nil, value
    end

    return false, type(value) == 'string' and value or nil, nil
end

---@param name string
---@param index integer position of the item in the listing
---@param count integer
---@return boolean ok
---@return UgErrorCode? errorCode
function Shops.Buy(name, index, count)
    local ok, value, errorCode = Callback.Await('ug-core:ShopBuy', name, index, count)

    if not ok then
        return false, errorCode
    end

    if value == true then
        return true, nil
    end

    return false, type(value) == 'string' and value or nil
end
