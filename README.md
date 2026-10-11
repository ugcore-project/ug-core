<div align="center">

# ⬢ ug-core

**The core resource of the UgCore Framework. Secure, headless and modular, in Lua 5.4.**

[![Documentation](https://img.shields.io/badge/Docs-ugcore.urging.ch-7C5CFF?logo=readthedocs&logoColor=white)](https://ugcore.urging.ch)
[![CI](https://img.shields.io/github/actions/workflow/status/ugcore-project/ug-core/prerelease.yml?branch=dev&label=CI)](https://github.com/ugcore-project/ug-core/actions/workflows/prerelease.yml)
[![Release](https://img.shields.io/github/v/release/ugcore-project/ug-core?label=Release&color=22D3EE)](https://github.com/ugcore-project/ug-core/releases/latest)
[![License](https://img.shields.io/github/license/ugcore-project/ug-core?color=brightgreen)](LICENSE)
[![Discord](https://img.shields.io/discord/1518308384900649021?label=Discord&logo=discord&logoColor=white&color=5865F2)](https://discord.gg/pCJUcyVw5X)

[**Documentation**](https://ugcore.urging.ch) · [**Installation**](https://ugcore.urging.ch/installation) · [**Quickstart**](https://ugcore.urging.ch/quickstart) · [**API reference**](https://ugcore.urging.ch/api/overview)

</div>

---

ug-core holds the state of your server and protects it. It loads players and characters, keeps money, jobs and permissions, and gives every other resource a typed, validated API under `UgCore.*`.

The server is authoritative. Clients send intent, never results.

## Features

- 🛡️ **Layered client protection.** Every net event and callback has a bounded schema and a rate limit, a global budget per player and a cap on callbacks in flight. Guard scores suspicious behavior and warns, kicks or bans.
- 🎨 **Headless.** No NUI, no notifications. ug-core returns error codes and emits events, so you choose how things look.
- 🧩 **Modular.** Enable only the modules you need in `config/modules.lua`. A disabled module has no tables, no events and no config.
- ⚡ **Fast.** Read-heavy data replicates through statebags. Callbacks and net events run in your resource, with no export call per request.
- 🧰 **Owner friendly.** Config files are generated on first boot with every option documented, validated on every boot, and never overwritten by updates. Convars override any option.
- 🧑‍💻 **Developer friendly.** LuaLS types for the whole API, hooks to cancel or change actions, events, and errors that point at your line.
- 💀 **Death system.** Server-authoritative downed and dead states, injuries per body region, and the cause of death.

## Requirements

- FXServer with **OneSync**
- [**oxmysql**](https://github.com/overextended/oxmysql)
- **MySQL 8.0+** or **MariaDB 10.6+**

ug-core has no other dependency.

## Installation

1. Download `ug-core-<version>.zip` from the [latest release](https://github.com/ugcore-project/ug-core/releases/latest) and extract it into your `resources` folder, for example `resources/[ug]/ug-core`. The archive holds only what the server runs. To update, extract the new one over it: `config/` ships empty, so your config stays.

2. Add it to `server.cfg`, after `oxmysql`:

   ```bash
   set mysql_connection_string "mysql://user:password@localhost:3306/ugcore"

   ensure oxmysql
   ensure ug-core

   # Lets the permissions module apply grants as ACEs.
   add_ace resource.ug-core command allow

   # Lets admins use the `ug` command in game.
   add_ace group.admin ug.admin allow
   ```

3. Start the server. ug-core prints its banner, generates `config/` and creates its tables.

4. Check it from the server console:

   ```text
   ug modules
   ug config core
   ```

See the [installation guide](https://ugcore.urging.ch/installation) for details and troubleshooting.

## Usage

Load the import in your resource:

```lua
-- fxmanifest.lua
fx_version 'cerulean'
game 'gta5'
lua54 'yes'

dependency 'ug-core'
ugcore_version '1.0.0'

shared_script '@ug-core/import.lua'
server_script 'server.lua'
client_script 'client.lua'
```

Then use the `UgCore` global:

```lua
-- server.lua
local S = UgCore.Schema

UgCore.Callback.Register('Pay', {
    schema = S.Define({ S.Integer({ min = 1, max = 10000 }) }),
    rate = { max = 3, per = 1000 },
    requirePlayer = true,
}, function(source, amount)
    local ok, balance, err = UgCore.Accounts.Remove(source, 'cash', amount, 'my-resource:pay')

    return ok and balance or err
end)

UgCore.Events.On(UgCore.Enums.Events.Players.Loaded, function(source)
    local player = UgCore.Players.Get(source)

    if player then
        UgCore.Logger.Info('%s is loaded with $%d cash', player.name, player:GetBalance('cash') or 0)
    end
end)
```

`UgCore.Players.Get` returns a [player object](https://ugcore.urging.ch/api/player) with shortcuts such as `player:AddMoney`, `player:SetJob`, `player:HasPermission` and `player:Revive`.

```lua
-- client.lua
CreateThread(function()
    local ok, result = UgCore.Callback.Await('my-resource:Pay', 250)
end)
```

Start with the [quickstart](https://ugcore.urging.ch/quickstart), then read the [developer guides](https://ugcore.urging.ch/developers/importing).

## Modules

| Module | Description | |
| --- | --- | --- |
| `identity` | Identifiers and bans | Required |
| `players` | Connected players, metadata, death state and injuries | Required |
| `permissions` | Staff groups with ranks, and persistent ACE grants | Required |
| `characters` | Multiple characters per player | Optional |
| `accounts` | Cash, bank and custom accounts with a ledger | Optional |
| `jobs` | Jobs with grades, salaries and duty | Optional |
| `gangs` | Gangs with grades | Optional |
| `sessions` | Isolated worlds on routing buckets | Optional |
| `commands` | Typed, rate limited chat commands | Optional |
| `locale` | Core messages in your language | Optional |
| `items` | Item definitions and usable items | Optional |
| `inventory` | Player inventories, stashes, vehicle trunks and gloveboxes, ground drops, with an audit log | Optional |
| `weapons` | Weapons as items: serials, ammo, attachments, tints and durability | Optional |
| `shops` | Shops with server-side prices, stock and restocking | Optional |

Optional modules are enabled by default. Disable them in `config/modules.lua` or with convars such as `set ug-core:Modules:Gangs false`. Disabling a module never deletes its data.

## Configuration

Every file in `config/` is yours. ug-core generates missing files on boot and never edits them again.

Values resolve in this order, last wins: default in code, `config/<name>.lua`, convar.

```bash
set ug-core:Debug true
set ug-core:Guard:KickScore 30
```

See [Configuration](https://ugcore.urging.ch/owners/configuration) and every option in the [config reference](https://ugcore.urging.ch/reference/config-files).

## Console

`ug` inspects the framework. It works in the server console and for players with the `ug.admin` ACE.

| Command | Shows |
| --- | --- |
| `ug modules` | Enabled and disabled modules, with reasons |
| `ug config <name>` | Resolved values and where each comes from |
| `ug lifecycle` | Boot states with timings |
| `ug database` | Database version, migrations and caches |
| `ug groups` | Staff groups and their member counts |
| `ug hooks` | Registered hooks |
| `ug inventory <id>` | A loaded inventory and its items |
| `ug items [name]` | Item definitions |
| `ug shops [name]` | Shops, prices and stock |
| `ug weapon <id>` | A player's equipped weapon |
| `ug guard <id>` | A player's Guard score and recent flags |
| `ug version` | Checks GitHub for a newer release |

### Version check

On server start, the boot banner shows whether a newer release exists on GitHub. Boot waits for the answer at most 3 seconds. Turn it off, for example without internet access, with `set ug-core:VersionCheck false`.

## Project structure

```text
ug-core/
├── fxmanifest.lua
├── import.lua        loaded by other resources
├── import/           import proxy and lifecycle mirror
├── core/
│   ├── shared/       namespace root, enums, events, lifecycle, schema, logger
│   ├── server/       boot, config, modules, database, network, callbacks, guard, hooks
│   └── client/       boot, config, network, callbacks
├── modules/<name>/   module.lua, config schema, migrations, server, client, shared
├── locales/          core messages
├── types/            LuaLS type definitions
├── tests/            Lua 5.4 tests with native mocks, never shipped
└── config/           generated, owned by the server owner, git-ignored
```

## Development

Every change MUST pass three checks. CI runs them on pushes and pull requests to `dev` and `main`.

```bash
# 1. LuaLS strict check, zero problems
lua-language-server --check . --checklevel=Information --configpath=.luarc.json

# 2. Runtime tests
for suite in tests/*.lua; do [ "$suite" = tests/helpers.lua ] || lua5.4 "$suite" || exit 1; done

# 3. Manifest and license headers
lua5.4 .github/scripts/check-repository.lua
```

For editor support, install the [Lua](https://marketplace.visualstudio.com/items?itemName=sumneko.lua) and [CfxLua](https://marketplace.visualstudio.com/items?itemName=overextended.cfxlua-vscode) VS Code extensions. `.luarc.json` MUST NOT set `workspace.library`, because it would replace the FiveM natives the CfxLua extension provides.

### Releases

Releases are automated, so commit subjects become the changelog. Write them for server owners.

- Every push to `dev` that passes CI replaces the [`dev-build`](https://github.com/ugcore-project/ug-core/releases/tag/dev-build) pre-release.
- On `main`, [release-please](https://github.com/googleapis/release-please) keeps a release PR open with the next version and its changelog. `feat` bumps the minor version, `fix` the patch, a breaking change the major. Merging the PR tags the release, and CI attaches `ug-core-<version>.zip`.
- `.github/scripts/package.sh` builds that archive from a fixed list of paths, then checks it with `check-repository.lua --package`.

See [Conventions](https://ugcore.urging.ch/contributing/conventions) and [Testing](https://ugcore.urging.ch/contributing/testing).

## Contributing

Contributions are welcome. Branch off `dev`, follow [Conventional Commits](https://www.conventionalcommits.org), and read the [contributing guide](https://github.com/ugcore-project/.github/blob/main/CONTRIBUTING.md) and the [Code of Conduct](https://github.com/ugcore-project/.github/blob/main/CODE_OF_CONDUCT.md).

## Security

Never report a vulnerability in a public issue. [Report it privately](https://github.com/ugcore-project/ug-core/security/advisories/new) and read the [Security Policy](https://github.com/ugcore-project/.github/blob/main/SECURITY.md).

## License

ug-core is free software, licensed under the [GNU General Public License v3.0](LICENSE).

Copyright (C) 2026 UgCore Framework & Contributors.
