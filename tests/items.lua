--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---@type TestHelpers
local H = dofile('tests/helpers.lua')

---@param lines string[]
---@param text string
---@return boolean
local function contains(lines, text)
    for _, line in ipairs(lines) do
        if line:find(text, 1, true) then
            return true
        end
    end

    return false
end

---@param configFile? string Lua source of config/items.lua
---@return string[] lines
local function fresh(configFile)
    H.ResourceFiles = {}
    H.Kvp = {}
    H.Convars = {}
    H.ResetGlobalState()
    H.ResetDb()
    H.ResetNetwork()
    H.DiskModules = true
    H.Metadata = { ug_module = { 'identity', 'players', 'items' } }

    if configFile then
        H.ResourceFiles['config/items.lua'] = configFile
    end

    return H.LoadManifest('server')
end

H.Test('Config items load with defaults and replicate without validators', function()
    fresh()

    H.Equal(UgCore.Items.Get('water'), {
        name = 'water', label = 'Water', weight = 500, stack = true, maxStack = 10, keepOnRespawn = false, usable = false,
    })
    H.Equal(UgCore.Items.Exists('bread'), true)
    H.Equal(UgCore.Items.Exists('gold'), false)
    H.Equal(UgCore.Items.Get('gold'), nil)
    H.Equal(GlobalState['ug-core:Items'].bandage.maxStack, 20)
end)

H.Test('Owners define items in config/items.lua', function()
    fresh([[return {
        phone = { label = 'Phone', weight = 200, stack = false, keepOnRespawn = true, description = 'Calls.' },
    }]])

    H.Equal(UgCore.Items.Get('phone'), {
        name = 'phone', label = 'Phone', weight = 200, stack = false, maxStack = 1, description = 'Calls.', keepOnRespawn = true, usable = false,
    })
    H.Equal(UgCore.Items.Exists('water'), false)
end)

H.Test('Invalid config items stop boot', function()
    local cases = {
        { 'Water = { label = "W", weight = 1 }', 'item names MUST be lowercase' },
        { 'water = { label = "W", weight = -1 }', 'weight MUST be an integer of grams' },
        { 'water = { label = "W", weight = 1, maxStack = 0 }', 'maxStack MUST be an integer' },
        { 'water = { label = "W", weight = 1, metadata = {} }', 'unknown field "metadata"' },
    }

    for _, case in ipairs(cases) do
        local lines = fresh('return { ' .. case[1] .. ' }')

        H.Assert(contains(lines, case[2]), 'missing error: ' .. case[2])
        H.Equal(UgCore.Lifecycle.GetState(), 'Stopped', case[2])
    end
end)

H.Test('Resources register items, validated like config items', function()
    fresh()

    UgCore.Items.Register('radio', { label = 'Radio', weight = 300, stack = false })

    H.Equal(UgCore.Items.Get('radio').maxStack, 1)
    H.Equal(GlobalState['ug-core:Items'].radio.label, 'Radio')

    H.Raises(function()
        UgCore.Items.Register('Radio', { label = 'Radio', weight = 1 })
    end, 'Items.Register("Radio"): item names MUST be lowercase')

    H.Raises(function()
        UgCore.Items.Register('box', { label = 'Box', weight = 1, metadata = H.Any(5) })
    end, 'metadata MUST be a UgCore.Schema rule or a function')
end)

H.Test('Config wins over a resource registering the same item', function()
    fresh()

    local lines = H.Capture(function()
        UgCore.Items.Register('water', { label = 'Fancy water', weight = 1 })
    end)

    H.Assert(contains(lines, 'registers "water", which config/items.lua defines. The config definition wins.'), 'warning missing')
    H.Equal(UgCore.Items.Get('water').label, 'Water')
end)

H.Test('Items of another resource cannot be replaced, and leave when it stops', function()
    fresh()

    local Banking = H.LoadImport('ug-banking', 'server').UgCore
    local Hud = H.LoadImport('ug-hud', 'server').UgCore

    Banking.Items.Register('card', { label = 'Card', weight = 10 })
    Banking.Items.RegisterUse('card', function() return true end)

    H.Raises(function()
        Hud.Items.Register('card', { label = 'Card', weight = 10 })
    end, '"card" is already registered by ug-banking')

    H.TriggerEvent('onResourceStop', nil, 'ug-banking')

    H.Equal(UgCore.Items.Exists('card'), false)
    H.Equal(UgCore.Items.IsUsable('card'), false)
end)

H.Test('Metadata is bounded and checked by the item rule or function', function()
    fresh()

    local S = UgCore.Schema
    local Check = UgCore.Internal.Items.CheckMetadata

    UgCore.Items.Register('note', { label = 'Note', weight = 5, metadata = S.Object({ text = S.String({ max = 8 }) }) })
    UgCore.Items.Register('key', {
        label = 'Key', weight = 5,
        metadata = function(metadata) return type(metadata.door) == 'string', 'a key needs a door' end,
    })

    H.Equal({ Check('note', { text = 'hi' }) }, { true, { text = 'hi' } })
    H.Equal(Check('note', { text = 'far too long' }), false)
    H.Equal(Check('note', { text = 'hi', extra = 1 }), false)
    H.Equal({ Check('key', { door = 'a' }) }, { true, { door = 'a' } })
    H.Equal({ Check('key', { room = 'a' }) }, { false, nil, 'a key needs a door' })
    H.Equal({ Check('water', {}) }, { true })
    H.Equal({ Check('water', nil) }, { true })
    H.Equal(Check('water', { pos = vector3(1, 2, 3) }), false)
    H.Equal(Check('water', { text = ('x'):rep(600) }), false)
    H.Equal(Check('water', H.Any('text')), false)
end)

H.Test('Consumers pass schema rules through the proxy', function()
    fresh()

    local Consumer = H.LoadImport('ug-banking', 'server').UgCore
    local S = Consumer.Schema

    Consumer.Items.Register('cheque', { label = 'Cheque', weight = 1, metadata = S.Object({ amount = S.Integer({ min = 1, max = 100 }) }) })

    H.Equal({ UgCore.Internal.Items.CheckMetadata('cheque', { amount = 5 }) }, { true, { amount = 5 } })
    H.Equal(UgCore.Internal.Items.CheckMetadata('cheque', { amount = 500 }), false)
end)

H.Test('RegisterUse validates and marks the item usable', function()
    fresh()

    UgCore.Items.RegisterUse('bread', function() return true end, { consume = 1, cooldown = 500 })

    H.Equal(UgCore.Items.IsUsable('bread'), true)
    H.Equal(UgCore.Items.Get('bread').usable, true)
    H.Equal(GlobalState['ug-core:Items'].bread.usable, true)

    H.Raises(function()
        UgCore.Items.RegisterUse('gold', function() end)
    end, 'Items.RegisterUse: unknown item "gold"')

    H.Raises(function()
        UgCore.Items.RegisterUse('water', function() end, { consume = -1 })
    end, 'consume MUST be an integer')
end)

H.Test('Clients read definitions from GlobalState', function()
    fresh()

    local definitions = GlobalState['ug-core:Items']

    H.LoadManifest('client')
    H.SetGlobalState('ug-core:Items', definitions)

    H.Equal(UgCore.Items.Get('water').label, 'Water')
    H.Equal(UgCore.Items.Exists('gold'), false)
end)

H.Test('ug items lists definitions and shows one', function()
    fresh()

    local lines = H.RunCommand('ug', 0, { 'items' })

    H.Equal(lines[1], '7 item(s):')
    H.Equal(lines[2], '  ammo_9mm                 9mm rounds                    10 g  ')
    H.Equal(H.RunCommand('ug', 0, { 'items', 'water' }), { 'water: Water, 500 g, stacks to 10, not usable' })
    H.Equal(H.RunCommand('ug', 0, { 'items', 'gold' }), { 'Unknown item "gold".' })
end)

H.Done()
