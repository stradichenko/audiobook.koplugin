#!/usr/bin/env luajit
-- Smoke test for MediaEngine's wait-for-headset path.
-- Run from the repo root: luajit dev/test_bt_wait.lua
--
-- Pins the states that are hard to see on a device: the held position while
-- no headset is connected, the restart at the held offset once one appears,
-- the pause and generation guards, the two-minute cap for a fallback
-- pipeline, and the 30-minute cap that fails cleanly instead of leaving the
-- app claiming to play forever.

local scheduled = {}
local now_s = 0

package.preload["device"] = function() return {} end
package.preload["logger"] = function()
    local t = {}
    for _, name in ipairs({ "warn", "dbg", "err", "info" }) do
        t[name] = function() end
    end
    return t
end
package.preload["ui/time"] = function()
    return {
        to_ms = function(x) return x * 1000 end,
        s = function(x) return x end,
    }
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end
package.preload["ui/uimanager"] = function()
    return {
        getTime = function() return now_s end,
        scheduleIn = function(_, seconds, fn)
            scheduled[#scheduled + 1] = { in_s = seconds, fn = fn }
        end,
        unschedule = function() end,
    }
end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local MediaEngine = dofile(here .. "../mediaengine.lua")

local bt_up, probes = false, 0
local plugin = {
    bt_manager = {
        anyAudioDeviceConnected = function() probes = probes + 1; return bt_up end,
        clearAudioDeviceCache = function() end,
    },
}
local E = setmetatable({
    plugin = plugin,
    is_playing = true,
    is_paused = false,
    play_generation = 7,
    _seek_offset = 123.5,
    _waiting_for_bt = true,
}, { __index = MediaEngine })

local restarted, failed = {}, {}
function E:_restartAt(pos, reason)
    restarted[#restarted + 1] = { pos = pos, reason = reason }
end
E._on_fail = function(err) failed[#failed + 1] = err end

local function reset(up)
    scheduled, restarted, failed = {}, {}, {}
    now_s, probes = 0, 0
    bt_up = up and true or false
end

-- Advance simulated time by the delay the watcher asked for, then run it.
local function tick()
    local item = table.remove(scheduled, 1)
    if not item then error("nothing scheduled") end
    now_s = now_s + item.in_s
    item.fn()
    return item.in_s
end

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- 1. Held position while waiting.
ok(E:getPosition() == 123.5, "getPosition holds the seek offset while waiting")

-- 2. Device appears: one probe sees it, the next check restarts.
reset(true)
E:_startBtReattachWatcher(7, 0)
tick()
ok(#restarted == 0, "device seen, A2DP grace tick first")
tick()
ok(#restarted == 1 and restarted[1].pos == 123.5, "restarts at the held offset")
ok(restarted[1] and restarted[1].reason == "bt device connected", "restart reason recorded")

-- 3. Paused while waiting: no probing, no start, keeps ticking.
reset(true)
E.is_paused = true
E:_startBtReattachWatcher(7, 0)
tick()
ok(probes == 0, "paused waiting does not probe")
ok(#scheduled == 1 and scheduled[1].in_s == 3, "paused waiting keeps a 3 s tick")
ok(#restarted == 0, "paused waiting does not start audio")
E.is_paused = false

-- 4. Stale generation and stopped playback end the watcher.
reset(false)
E:_startBtReattachWatcher(7, 0)
E.play_generation = 8
tick()
ok(#scheduled == 0 and #restarted == 0, "stale generation stops the watcher")
reset(false)
E:_startBtReattachWatcher(8, 0)
E.is_playing = false
tick()
ok(#scheduled == 0 and #restarted == 0, "stopped playback stops the watcher")

-- 5. Fallback pipeline (not waiting for a headset) still gives up after 2 min.
reset(false)
E.is_playing = true
E._waiting_for_bt = nil
E.play_generation = 9
E:_startBtReattachWatcher(9, 0)
for _ = 1, 41 do tick() end
ok(#scheduled == 0, "fallback watcher gives up after 40 tries")
ok(#failed == 0, "fallback give-up does not report a playback failure")

-- 6. Waiting for a headset: no device for 30 minutes -> clean failure.
reset(false)
E.is_playing = true
E._waiting_for_bt = true
E._seek_offset = 123.5
E.play_generation = 10
E:_startBtReattachWatcher(10, 0)
local gave_up_after
for _ = 1, 240 do
    if #scheduled == 0 then break end
    tick()
    if #failed > 0 then gave_up_after = now_s; break end
end
ok(#failed == 1, "waits then reports a failure at the cap")
ok(gave_up_after and gave_up_after >= 1800 and gave_up_after <= 1820,
    "gives up at about 30 minutes (got " .. tostring(gave_up_after) .. " s)")
ok(tostring(failed[1]):find("did not connect", 1, true) ~= nil,
    "failure names the missing headset")
ok(E.is_playing == false and E._waiting_for_bt == nil,
    "engine no longer claims to be playing")
ok(#scheduled == 0, "no polling after the cap")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)