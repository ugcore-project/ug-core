--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---Maps bones to body regions and weapons to damage categories. Unknown values map to Unknown, never to an error.
---@class UgCore.Internal.Injuries
local Injuries = {}
UgCore.Internal.Injuries = Injuries

local Regions = UgCore.Enums.BodyRegion
local Categories = UgCore.Enums.DamageCategory

-- Weapon names and groups from the Cfx weapon models reference.
local WEAPONS_BY_CATEGORY = {
    [Categories.Gunshot] = {
        'WEAPON_VINTAGEPISTOL', 'WEAPON_PISTOL', 'WEAPON_PISTOLXM3', 'WEAPON_APPISTOL', 'WEAPON_CERAMICPISTOL',
        'WEAPON_GADGETPISTOL', 'WEAPON_COMBATPISTOL', 'WEAPON_SNSPISTOL_MK2', 'WEAPON_NAVYREVOLVER',
        'WEAPON_DOUBLEACTION', 'WEAPON_PISTOL50', 'WEAPON_RAYPISTOL', 'WEAPON_SNSPISTOL', 'WEAPON_PISTOL_MK2',
        'WEAPON_REVOLVER', 'WEAPON_REVOLVER_MK2', 'WEAPON_HEAVYPISTOL', 'WEAPON_MARKSMANPISTOL',
        'WEAPON_COMBATPDW', 'WEAPON_MICROSMG', 'WEAPON_TECPISTOL', 'WEAPON_SMG', 'WEAPON_SMG_MK2', 'WEAPON_MINISMG',
        'WEAPON_MACHINEPISTOL', 'WEAPON_ASSAULTSMG',
        'WEAPON_ASSAULTRIFLE_MK2', 'WEAPON_COMPACTRIFLE', 'WEAPON_BATTLERIFLE', 'WEAPON_BULLPUPRIFLE',
        'WEAPON_CARBINERIFLE', 'WEAPON_BULLPUPRIFLE_MK2', 'WEAPON_SPECIALCARBINE_MK2', 'WEAPON_MILITARYRIFLE',
        'WEAPON_ADVANCEDRIFLE', 'WEAPON_ASSAULTRIFLE', 'WEAPON_SPECIALCARBINE', 'WEAPON_HEAVYRIFLE',
        'WEAPON_TACTICALRIFLE', 'WEAPON_CARBINERIFLE_MK2',
        'WEAPON_RAYCARBINE', 'WEAPON_GUSENBERG', 'WEAPON_COMBATMG', 'WEAPON_MG', 'WEAPON_COMBATMG_MK2',
        'WEAPON_COMBATSHOTGUN', 'WEAPON_AUTOSHOTGUN', 'WEAPON_PUMPSHOTGUN', 'WEAPON_HEAVYSHOTGUN',
        'WEAPON_PUMPSHOTGUN_MK2', 'WEAPON_SAWNOFFSHOTGUN', 'WEAPON_BULLPUPSHOTGUN', 'WEAPON_ASSAULTSHOTGUN',
        'WEAPON_DBSHOTGUN',
        'WEAPON_SNIPERRIFLE', 'WEAPON_HEAVYSNIPER_MK2', 'WEAPON_HEAVYSNIPER', 'WEAPON_MARKSMANRIFLE_MK2',
        'WEAPON_PRECISIONRIFLE', 'WEAPON_MUSKET', 'WEAPON_MARKSMANRIFLE',
        'WEAPON_MINIGUN', 'WEAPON_RAYMINIGUN', 'WEAPON_RAILGUN', 'WEAPON_RAILGUNXM3',
    },
    [Categories.Stab] = {
        'WEAPON_DAGGER', 'WEAPON_KNIFE', 'WEAPON_MACHETE', 'WEAPON_SWITCHBLADE', 'WEAPON_HATCHET',
        'WEAPON_STONE_HATCHET', 'WEAPON_BATTLEAXE', 'WEAPON_BOTTLE',
    },
    [Categories.Blunt] = {
        'WEAPON_WRENCH', 'WEAPON_GOLFCLUB', 'WEAPON_HAMMER', 'WEAPON_CANDYCANE', 'WEAPON_NIGHTSTICK',
        'WEAPON_CROWBAR', 'WEAPON_FLASHLIGHT', 'WEAPON_POOLCUE', 'WEAPON_BAT', 'WEAPON_STUNROD',
        'WEAPON_UNARMED', 'WEAPON_KNUCKLE', 'WEAPON_SNOWBALL', 'WEAPON_BALL', 'WEAPON_SNOWLAUNCHER',
    },
    [Categories.Explosion] = {
        'WEAPON_COMPACTLAUNCHER', 'WEAPON_HOMINGLAUNCHER', 'WEAPON_FIREWORK', 'WEAPON_GRENADELAUNCHER',
        'WEAPON_RPG', 'WEAPON_EMPLAUNCHER', 'WEAPON_STICKYBOMB', 'WEAPON_GRENADE', 'WEAPON_PROXMINE',
        'WEAPON_PIPEBOMB',
        -- Not in the Cfx weapon models reference. Verify on a live server.
        'WEAPON_EXPLOSION',
    },
    [Categories.Fire] = {
        'WEAPON_MOLOTOV', 'WEAPON_FLARE', 'WEAPON_FLAREGUN', 'WEAPON_PETROLCAN', 'WEAPON_HAZARDCAN',
        'WEAPON_FERTILIZERCAN',
        -- Not in the Cfx weapon models reference. Verify on a live server.
        'WEAPON_FIRE',
    },
    -- Environment causes are not in the Cfx weapon models reference. Verify on a live server.
    [Categories.Fall] = { 'WEAPON_FALL' },
    [Categories.Vehicle] = { 'WEAPON_RUN_OVER_BY_CAR', 'WEAPON_RAMMED_BY_CAR' },
    [Categories.Drowning] = { 'WEAPON_DROWNING', 'WEAPON_DROWNING_IN_VEHICLE' },
    [Categories.Animal] = { 'WEAPON_ANIMAL', 'WEAPON_COUGAR' },
}

-- Ped bone tags as returned by GET_PED_LAST_DAMAGE_BONE. The Cfx docs do not list them. Verify on a live server.
local BONES_BY_REGION = {
    [Regions.Head] = { 31086, 12844 },
    [Regions.Neck] = { 39317 },
    [Regions.Torso] = { 0, 11816, 23553, 24816, 24817, 24818, 57597 },
    [Regions.LeftArm] = { 64729, 45509, 61163, 18905 },
    [Regions.RightArm] = { 10706, 40269, 28252, 57005 },
    [Regions.LeftLeg] = { 58271, 63931, 14201, 2108 },
    [Regions.RightLeg] = { 51826, 36864, 52301, 20781 },
}

---@type table<integer, UgDamageCategory>
local categoryByHash = {}

---@type table<integer, UgBodyRegion>
local regionByBone = {}

for category, names in pairs(WEAPONS_BY_CATEGORY) do
    for _, name in ipairs(names) do
        categoryByHash[GetHashKey(name)] = category
    end
end

for region, bones in pairs(BONES_BY_REGION) do
    for _, bone in ipairs(bones) do
        regionByBone[bone] = region
    end
end

---@param weapon any weapon hash, signed or unsigned
---@return UgDamageCategory
function Injuries.CategoryOf(weapon)
    if math.type(weapon) ~= 'integer' then
        return Categories.Unknown
    end

    return categoryByHash[weapon] or categoryByHash[weapon - 4294967296] or categoryByHash[weapon + 4294967296] or Categories.Unknown
end

---@param bone any bone tag
---@return UgBodyRegion
function Injuries.RegionOf(bone)
    return regionByBone[bone] or Regions.Unknown
end

---Environment pseudo-weapons, for clients to tell which one damaged them.
---@return integer[]
function Injuries.GetEnvironmentHashes()
    local hashes = {}

    for _, category in ipairs({ Categories.Fall, Categories.Vehicle, Categories.Drowning, Categories.Animal, Categories.Fire, Categories.Explosion }) do
        for _, name in ipairs(WEAPONS_BY_CATEGORY[category]) do
            hashes[#hashes + 1] = GetHashKey(name)
        end
    end

    return hashes
end
