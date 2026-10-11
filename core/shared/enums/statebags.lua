--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Player statebag keys. Only the server writes them.
---@enum UgStateBag
UgCore.Enums.StateBags = {
    Loaded = 'ug-core:Loaded',
    Player = 'ug-core:Player',
    Metadata = 'ug-core:Metadata',
    DeathState = 'ug-core:DeathState',
    Injuries = 'ug-core:Injuries',
    Job = 'ug-core:Job',
    Gang = 'ug-core:Gang',
    Session = 'ug-core:Session',
    Groups = 'ug-core:Groups',
}

---GlobalState keys. Only the server writes them.
---@enum UgGlobalStateKey
UgCore.Enums.GlobalState = {
    Config = 'ug-core:Config',
    Modules = 'ug-core:Modules',
    Exports = 'ug-core:Exports',
    Items = 'ug-core:Items',
    Drops = 'ug-core:Drops',
    Shops = 'ug-core:Shops',
    BannerShown = 'ug-core:BannerShown',
}
