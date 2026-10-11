--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@class UgPlayer
---@field source integer
---@field name string
---@field identifier string primary identifier
---@field characterId? integer loaded character when the object was created
---@field joinedAt integer Unix seconds
local UgPlayer = {}
UgPlayer.__index = UgPlayer

---@class UgCore.Internal.PlayerObject
local PlayerObject = {}
UgCore.Internal.PlayerObject = PlayerObject

local Utils = UgCore.Internal.Utils

local LOADED_KEY = UgCore.Enums.StateBags.Loaded

-- The `UgCore` methods call through. In ug-core it is the real root. Consumers set their proxy root.
local root = UgCore --[[@as table]]

---@param value table
function PlayerObject.SetRoot(value)
    root = value
end

---Raises like the import proxy when the module is disabled, so errors match in every runtime.
---@param namespace string
---@param module string
---@return any
local function api(namespace, module)
    if not UgCore.Modules.IsEnabled(module) then
        Utils.Raise(3, 'UgCore.%s belongs to disabled module "%s". Enable it in config/modules.lua.', namespace, module)
    end

    return root[namespace]
end

---@param data UgPlayer|table plain player data
---@return UgPlayer
function PlayerObject.Wrap(data)
    return setmetatable(data, UgPlayer)
end

---@param data table?
---@return UgPlayer?
function PlayerObject.WrapOne(data)
    return type(data) == 'table' and PlayerObject.Wrap(data) or nil
end

---@param list table?
---@return UgPlayer[]
function PlayerObject.WrapAll(list)
    local players = {}

    for index, data in ipairs(type(list) == 'table' and list or {}) do
        players[index] = PlayerObject.Wrap(data)
    end

    return players
end

-- Players

---@return boolean online false once the player dropped
function UgPlayer:IsOnline()
    return api('Players', 'players').Get(self.source) ~= nil
end

---@return boolean loaded true once a character is loaded, or at join without the characters module
function UgPlayer:IsLoaded()
    return Player(self.source).state[LOADED_KEY] == true
end

---@param key? string every key when nil
---@return any
function UgPlayer:GetMetadata(key)
    return api('Players', 'players').GetMetadata(self.source, key)
end

---@param key string camelCase
---@param value any `nil` deletes the key
---@param replicate? boolean copies the key to the `ug-core:Metadata` statebag
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetMetadata(key, value, replicate)
    return api('Players', 'players').SetMetadata(self.source, key, value, replicate)
end

---@param reason? string shown to the player, a generic message when nil
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Kick(reason)
    return api('Players', 'players').Kick(self.source, reason)
end

---@return UgDeathState
function UgPlayer:GetDeathState()
    return api('Players', 'players').GetDeathState(self.source)
end

---@return boolean
function UgPlayer:IsDead()
    return api('Players', 'players').IsDead(self.source)
end

---@return boolean
function UgPlayer:IsDowned()
    return api('Players', 'players').IsDowned(self.source)
end

---@return UgInjury[]
function UgPlayer:GetInjuries()
    return api('Players', 'players').GetInjuries(self.source)
end

---@return UgCauseOfDeath?
function UgPlayer:GetCauseOfDeath()
    return api('Players', 'players').GetCauseOfDeath(self.source)
end

---@param region? UgBodyRegion every region when nil
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:ClearInjuries(region)
    return api('Players', 'players').ClearInjuries(self.source, region)
end

---@param cause? UgCauseOfDeath
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Down(cause)
    return api('Players', 'players').Down(self.source, cause)
end

---@param cause? UgCauseOfDeath
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Kill(cause)
    return api('Players', 'players').Kill(self.source, cause)
end

---@param options? UgReviveOptions
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Revive(options)
    return api('Players', 'players').Revive(self.source, options)
end

---@param coords? vector4
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Respawn(coords)
    return api('Players', 'players').Respawn(self.source, coords)
end

-- Identity

---@return string[]
function UgPlayer:GetIdentifiers()
    return api('Identity', 'identity').GetIdentifiers(self.source)
end

---MUST run in a thread.
---@return boolean banned
---@return UgBan? ban
---@return UgErrorCode? errorCode
function UgPlayer:IsBanned()
    return api('Identity', 'identity').IsBanned(self.source)
end

---MUST run in a thread.
---@param options? UgBanOptions
---@return boolean ok
---@return integer? banId
---@return UgErrorCode? errorCode
function UgPlayer:Ban(options)
    return api('Identity', 'identity').Ban(self.source, options)
end

-- Permissions

---@param permission string
---@return boolean
function UgPlayer:HasPermission(permission)
    return api('Permissions', 'permissions').Has(self.source, permission)
end

---MUST run in a thread.
---@param permission string
---@param by? string
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:GrantPermission(permission, by)
    return api('Permissions', 'permissions').Grant(self.source, permission, by)
end

---MUST run in a thread.
---@param permission string
---@return boolean ok
---@return boolean? removed
---@return UgErrorCode? errorCode
function UgPlayer:RevokePermission(permission)
    return api('Permissions', 'permissions').Revoke(self.source, permission)
end

---@return string[] permissions granted with GrantPermission
function UgPlayer:GetPermissions()
    return api('Permissions', 'permissions').GetAll(self.source)
end

---MUST run in a thread.
---@param group string a group from config/permissions.lua
---@param by? string
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:AddGroup(group, by)
    return api('Permissions', 'permissions').AddGroup(self.source, group, by)
end

---MUST run in a thread.
---@param group string
---@return boolean ok
---@return boolean? removed
---@return UgErrorCode? errorCode
function UgPlayer:RemoveGroup(group)
    return api('Permissions', 'permissions').RemoveGroup(self.source, group)
end

---@return string[] groups highest weight first
function UgPlayer:GetGroups()
    return api('Permissions', 'permissions').GetGroups(self.source)
end

---@param group string
---@return boolean member directly or through inheritance
function UgPlayer:IsInGroup(group)
    return api('Permissions', 'permissions').IsInGroup(self.source, group)
end

---@return integer weight highest group weight, 0 without groups
function UgPlayer:GetWeight()
    return api('Permissions', 'permissions').GetWeight(self.source)
end

---@param target UgPlayer|integer|string a player object, source or identifier
---@return boolean outranks true when this player's weight is strictly higher
function UgPlayer:CanTarget(target)
    local other = type(target) == 'table' and target.source or target

    return api('Permissions', 'permissions').CanTarget(self.source, other)
end

-- Characters

---@return UgCharacter?
function UgPlayer:GetCharacter()
    return api('Characters', 'characters').GetActive(self.source)
end

---@return boolean ok
---@return UgCharacter[]? characters
---@return UgErrorCode? errorCode
function UgPlayer:GetCharacters()
    return api('Characters', 'characters').GetAll(self.source)
end

---@param characterId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:LoadCharacter(characterId)
    return api('Characters', 'characters').Load(self.source, characterId)
end

---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:UnloadCharacter()
    return api('Characters', 'characters').Unload(self.source)
end

-- Accounts

---@param account string
---@return integer? balance nil when no character is loaded
function UgPlayer:GetBalance(account)
    return api('Accounts', 'accounts').GetBalance(self.source, account)
end

---@return table<string, integer>? balances nil when no character is loaded
function UgPlayer:GetBalances()
    return api('Accounts', 'accounts').GetAll(self.source)
end

---@param account string
---@param amount integer
---@param reason? string
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function UgPlayer:AddMoney(account, amount, reason)
    return api('Accounts', 'accounts').Add(self.source, account, amount, reason)
end

---@param account string
---@param amount integer
---@param reason? string
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function UgPlayer:RemoveMoney(account, amount, reason)
    return api('Accounts', 'accounts').Remove(self.source, account, amount, reason)
end

---@param account string
---@param balance integer
---@param reason? string
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function UgPlayer:SetMoney(account, balance, reason)
    return api('Accounts', 'accounts').Set(self.source, account, balance, reason)
end

---@param targetCharacterId integer
---@param account string
---@param amount integer
---@param reason? string
---@return boolean ok
---@return integer? balance
---@return UgErrorCode? errorCode
function UgPlayer:TransferMoney(targetCharacterId, account, amount, reason)
    return api('Accounts', 'accounts').Transfer(self.source, targetCharacterId, account, amount, reason)
end

---@param account string
---@param limit? integer
---@return boolean ok
---@return UgLedgerEntry[]? entries
---@return UgErrorCode? errorCode
function UgPlayer:GetLedger(account, limit)
    return api('Accounts', 'accounts').GetLedger(self.source, account, limit)
end

-- Jobs

---@return UgAssignment?
function UgPlayer:GetJob()
    return api('Jobs', 'jobs').Get(self.source)
end

---MUST run in a thread.
---@param name string
---@param grade? integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetJob(name, grade)
    return api('Jobs', 'jobs').Set(self.source, name, grade)
end

---MUST run in a thread.
---@param grade integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetJobGrade(grade)
    return api('Jobs', 'jobs').SetGrade(self.source, grade)
end

---@param onDuty boolean
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetDuty(onDuty)
    return api('Jobs', 'jobs').SetDuty(self.source, onDuty)
end

---@return boolean
function UgPlayer:IsOnDuty()
    return api('Jobs', 'jobs').IsOnDuty(self.source)
end

-- Inventory

---@param name string
---@param count integer
---@param metadata? table
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:AddItem(name, count, metadata, reason)
    return api('Inventory', 'inventory').AddItem(self.source, name, count, metadata, reason)
end

---@param name string
---@param count integer
---@param metadata? table filter
---@param reason? string
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:RemoveItem(name, count, metadata, reason)
    return api('Inventory', 'inventory').RemoveItem(self.source, name, count, metadata, reason)
end

---@param name string
---@param metadata? table filter
---@return integer
function UgPlayer:GetItemCount(name, metadata)
    return api('Inventory', 'inventory').Count(self.source, name, metadata)
end

---@param name string
---@param count? integer defaults to 1
---@param metadata? table filter
---@return boolean
function UgPlayer:HasItem(name, count, metadata)
    return api('Inventory', 'inventory').HasItem(self.source, name, count, metadata)
end

---@param name string
---@param count integer
---@param metadata? table
---@return boolean
function UgPlayer:CanCarry(name, count, metadata)
    return api('Inventory', 'inventory').CanCarry(self.source, name, count, metadata)
end

---@return UgInventorySlot[]
function UgPlayer:GetItems()
    return api('Inventory', 'inventory').GetItems(self.source)
end

---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:UseItem(slot)
    return api('Inventory', 'inventory').Use(self.source, slot)
end

---MUST run in a thread.
---@param inventoryId string
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:OpenInventory(inventoryId)
    return api('Inventory', 'inventory').Open(self.source, inventoryId)
end

function UgPlayer:CloseInventory()
    api('Inventory', 'inventory').Close(self.source)
end

---@return string? id the inventory this player has open
function UgPlayer:GetOpenInventory()
    return api('Inventory', 'inventory').GetOpen(self.source)
end

-- Weapons

---@return UgEquippedWeapon?
function UgPlayer:GetEquippedWeapon()
    return api('Weapons', 'weapons').GetEquipped(self.source)
end

---@param slot integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:EquipWeapon(slot)
    return api('Weapons', 'weapons').Equip(self.source, slot)
end

---@param reason? string
---@return boolean ok false when nothing was equipped
function UgPlayer:UnequipWeapon(reason)
    return api('Weapons', 'weapons').Unequip(self.source, reason)
end

---MUST run in a thread.
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:ReloadWeapon()
    return api('Weapons', 'weapons').Reload(self.source)
end

-- Shops

---MUST run in a thread.
---@param shop string
---@param index integer position of the item in the shop
---@param count integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:Buy(shop, index, count)
    return api('Shops', 'shops').Buy(self.source, shop, index, count)
end

-- Gangs

---@return UgAssignment?
function UgPlayer:GetGang()
    return api('Gangs', 'gangs').Get(self.source)
end

---MUST run in a thread.
---@param name string
---@param grade? integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetGang(name, grade)
    return api('Gangs', 'gangs').Set(self.source, name, grade)
end

---MUST run in a thread.
---@param grade integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:SetGangGrade(grade)
    return api('Gangs', 'gangs').SetGrade(self.source, grade)
end

-- Sessions

---@return integer? sessionId nil in the shared world
function UgPlayer:GetSession()
    return api('Sessions', 'sessions').GetSession(self.source)
end

---@param sessionId integer
---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:JoinSession(sessionId)
    return api('Sessions', 'sessions').Join(self.source, sessionId)
end

---@return boolean ok
---@return UgErrorCode? errorCode
function UgPlayer:LeaveSession()
    return api('Sessions', 'sessions').Leave(self.source)
end

-- Guard and network. Core namespaces, always available.

---@param violation UgViolation
---@param detail? string server logs only
function UgPlayer:Flag(violation, detail)
    root.Guard.Flag(self.source, violation, detail)
end

---@return number score
function UgPlayer:GetScore()
    return root.Guard.GetScore(self.source)
end

---@param coords vector3 a position the server knows, never one sent by the client
---@param maxDistance number
---@return boolean
function UgPlayer:IsNear(coords, maxDistance)
    return root.Guard.IsNear(self.source, coords, maxDistance)
end

---@param name string full event name, such as `ug-hud:Update`
---@param ... any
function UgPlayer:TriggerClient(name, ...)
    root.Network.TriggerClient(self.source, name, ...)
end

---Asks this player's client. MUST run in a thread. The answer is untrusted and validated with `options.schema`.
---@param name string full callback name, such as `ug-hud:GetSettings`
---@param options UgClientCallbackOptions
---@param ... any
---@return boolean ok
---@return any value
---@return UgErrorCode? errorCode
function UgPlayer:AwaitCallback(name, options, ...)
    return root.Callback.Await(self.source, name, options, ...)
end
