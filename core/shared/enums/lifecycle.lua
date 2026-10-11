--[[

    ug-core - https://github.com/ugcore-project
    Copyright (C) 2026 UgCore Framework & Contributors
    Licensed under the GNU General Public License. See LICENSE for details.

]] --

---States in boot order. Only the module loader changes state.
---@enum UgLifecycleState
UgCore.Enums.Lifecycle = {
    Booting = 'Booting',
    Configured = 'Configured',
    Initializing = 'Initializing',
    Starting = 'Starting',
    Ready = 'Ready',
    Stopping = 'Stopping',
    Stopped = 'Stopped',
}
