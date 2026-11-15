--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type UgModuleDefinition
return {
    name = 'locale',
    namespace = 'Locale',
    description = 'Translations of core messages from locales/*.json, picked by core.locale.',
    shared = { 'api' },
}
