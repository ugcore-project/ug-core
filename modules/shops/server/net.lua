--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---What clients may ask a shop. `ShopOpen` replies the listing, `ShopBuy` `true` or an error code.
---@class UgCore.Internal.ShopsNet
local Net = {}
UgCore.Internal.ShopsNet = Net

local Errors = UgCore.Enums.Errors
local InternalShops = UgCore.Internal.Shops

function Net.Init()
    local S = UgCore.Schema
    local NAME = S.String({ min = 1, max = 48, pattern = '^%l[%l%d_]*$' })

    UgCore.Callback.Register('ShopOpen', {
        schema = S.Define({ NAME }),
        rate = { max = 3, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, name)
        local listing, errorCode = InternalShops.Open(source, name)

        return listing or errorCode
    end)

    UgCore.Callback.Register('ShopBuy', {
        schema = S.Define({ NAME, S.Integer({ min = 1, max = 200 }), S.Integer({ min = 1, max = 1000 }) }),
        rate = { max = 4, per = 1000 },
        requirePlayer = true,
        requireAlive = true,
    }, function(source, name, index, count)
        local ok, errorCode = UgCore.Shops.Buy(source, name, index, count)

        return ok and true or errorCode or Errors.InternalError
    end)
end
