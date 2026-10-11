--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---oxmysql access for core and modules. Requires MySQL 8.0 or MariaDB 10.6+.
---@class UgCore.Internal.Database
---@field Repository UgCore.Internal.Database.Repository
---@field Cache UgCore.Internal.Database.Cache
---@field Migrate UgCore.Internal.Database.Migrate
UgCore.Internal.Database = {}
