#!/usr/bin/env luajit
-- Smoke test for the Kobo headset fixes in btmediacontrol.lua.
-- Run from the repo root: luajit dev/test_bt_media_toggle.lua
--
-- Pins two behaviours that are easy to get wrong and hard to see on a device:
--   1. a Kobo MediaPlay / MediaPause key is treated as a toggle, while other
--      platforms keep the direction the headset asked for;
--   2. when the headset disappears the dead AVRCP node is dropped (so a
--      reconnect can open the new one), but an fd opened by KOReader itself
--      is never closed behind its back.
-- The D-Bus fallback shells out, so io.popen is stubbed to return nothing.

local open_fail = false
local device = {
    input = {
        opened_devices = {},
        event_map = {},
        event_map_adapter = {},
        open = function(self, path)
            if open_fail then return nil end
            self.opened_devices[path] = 99
            return 99
        end,
        close = function(self, path)
            self.opened_devices[path] = nil
        end,
        isEvKeyPress = function() return true end,
    },
}
device.isAndroid = function() return false end
device.isKindle = function() return false end
device.isKobo = function() return true end

package.preload["device"] = function() return device end
package.preload["ui/uimanager"] = function()
    return {
        event_handlers = {},
        scheduleIn = function() end,
        unschedule = function() end,
    }
end
package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

-- The polling fallback runs dbus-send through a pipe; keep it quiet.
io.popen = function() return nil end

local B = dofile((arg and arg[0]):gsub("[^/]+$", "") .. "../btmediacontrol.lua")

local failures, checks = {}, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then failures[#failures + 1] = label end
end

local function makePlugin(state)
    local plugin = { media_sync = { state = state or "playing" }, calls = {} }
    function plugin:pauseReadAlong() self.calls[#self.calls + 1] = "pause" end
    function plugin:resumeReadAlong() self.calls[#self.calls + 1] = "resume" end
    function plugin:stopReadAlong() self.calls[#self.calls + 1] = "stop" end
    function plugin:startReadAlong() self.calls[#self.calls + 1] = "start" end
    return plugin
end

local function reset()
    B._evdev_active = false
    B._evdev_opened_by_us = false
    B._avrcp_evdev_path = nil
    B._dbus_polling_active = false
    B._dbus_poll_count = 0
    B._last_dbus_status = nil
    B._last_sent_status = nil
    device.input.opened_devices = {}
end

-- ── Key dispatch ────────────────────────────────────────────────────
B._plugin = makePlugin("paused")
B._dispatchMediaEvent("MediaPlay")
ok(B._plugin.calls[1] == "resume", "Kobo MediaPlay while paused resumes")

B._plugin = makePlugin("playing")
B._dispatchMediaEvent("MediaPlay")
ok(B._plugin.calls[1] == "pause", "Kobo MediaPlay while playing pauses (toggle)")

B._plugin = makePlugin("playing")
B._dispatchMediaEvent("MediaPause")
ok(B._plugin.calls[1] == "pause", "Kobo MediaPause while playing pauses")

B._plugin = makePlugin("paused")
B._dispatchMediaEvent("MediaPause")
ok(B._plugin.calls[1] == "resume", "Kobo MediaPause while paused resumes (toggle)")

-- D-Bus status changes mirror a state, so they must not toggle.
B._plugin = makePlugin("playing")
B._handleDbusStatusChange("playing")
ok(#B._plugin.calls == 0, "status 'playing' while playing is a no-op")
B._plugin = makePlugin("playing")
B._handleDbusStatusChange("paused")
ok(B._plugin.calls[1] == "pause", "status 'paused' while playing pauses")
B._plugin = makePlugin("paused")
B._handleDbusStatusChange("playing")
ok(B._plugin.calls[1] == "resume", "status 'playing' while paused resumes")

device.isKobo = function() return false end
B._plugin = makePlugin("playing")
B._dispatchMediaEvent("MediaPlay")
ok(#B._plugin.calls == 0, "non-Kobo MediaPlay while playing is a no-op")
B._plugin = makePlugin("paused")
B._dispatchMediaEvent("MediaPlay")
ok(B._plugin.calls[1] == "resume", "non-Kobo MediaPlay while paused resumes")
device.isKobo = function() return true end

B._plugin = makePlugin("playing")
B._dispatchMediaEvent("MediaPlayPause")
ok(B._plugin.calls[1] == "pause", "MediaPlayPause still toggles")

-- ── Reattach after a reconnect ──────────────────────────────────────
-- No node on the first scan: fall back to D-Bus polling.
reset()
B._findAvrcpEvdevDevice = function() return nil, nil end
B.start(makePlugin())
ok(B._dbus_polling_active == true, "no AVRCP node falls back to D-Bus polling")

-- The node a reconnect creates is picked up by the poll loop. Force the
-- probe slot; the throttle is tested separately below.
B._findAvrcpEvdevDevice = function() return "/dev/input/event7", "AVRCP" end
B._dbus_poll_count = 0
B._pollDbusMediaControl()
ok(B._evdev_active == true, "poll opens the reconnected node")
ok(B._avrcp_evdev_path == "/dev/input/event7", "reconnected node recorded")
ok(B._dbus_polling_active == false, "polling stops after reattach")
ok(B._evdev_opened_by_us == true, "node opened by the plugin is marked as ours")

-- Probe throttle: two scans per three polls, first poll included.
reset()
local probes = 0
B._findAvrcpEvdevDevice = function() probes = probes + 1; return nil, nil end
-- start() probes once itself, then the first poll (count 1) probes again.
B.start(makePlugin())
ok(probes == 2, "start and the first poll probe for the node")
B._pollDbusMediaControl()
B._pollDbusMediaControl()
ok(probes == 2, "the next two polls skip the probe")
B._pollDbusMediaControl()
ok(probes == 3, "the poll after that probes again")

-- ── Dead node teardown ──────────────────────────────────────────────
-- Node the plugin opened itself: closing it is correct.
reset()
B._avrcp_evdev_path = "/dev/input/event3"
B._evdev_active = true
B._evdev_opened_by_us = true
B._last_sent_status = "playing"
B._findAvrcpEvdevDevice = function() return nil, nil end
B.start(makePlugin())
ok(B._avrcp_evdev_path == nil, "stale node path cleared")
ok(B._evdev_active == false, "stale node marked inactive")
ok(B._evdev_opened_by_us == false, "ownership flag cleared")
ok(B._last_sent_status == nil, "status dedupe reset for the next headset")
ok(device.input.opened_devices["/dev/input/event3"] == nil, "plugin-owned node closed")

-- Node KOReader opened: dropping our reference must not close its fd.
reset()
B._avrcp_evdev_path = "/dev/input/event4"
B._evdev_active = true
B._evdev_opened_by_us = false
device.input.opened_devices["/dev/input/event4"] = 42
B._findAvrcpEvdevDevice = function() return nil, nil end
B.start(makePlugin())
ok(B._avrcp_evdev_path == nil, "KOReader-owned node reference released")
ok(device.input.opened_devices["/dev/input/event4"] == 42,
    "KOReader-owned fd left open")

-- An open failure while a live node exists drops it for a later retry.
reset()
B._avrcp_evdev_path = "/dev/input/event9"
B._evdev_active = true
B._evdev_opened_by_us = true
B._findAvrcpEvdevDevice = function() return "/dev/input/event9", "AVRCP" end
open_fail = true
B.start(makePlugin())
open_fail = false
ok(B._avrcp_evdev_path == nil, "open failure drops the stale node")

-- ── Result ──────────────────────────────────────────────────────────
if #failures == 0 then
    print(string.format("%d passed, 0 failed", checks))
    os.exit(0)
end
for _, label in ipairs(failures) do
    print("FAIL " .. label)
end
print(string.format("%d passed, %d failed", checks - #failures, #failures))
os.exit(1)