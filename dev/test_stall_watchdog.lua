#!/usr/bin/env luajit
-- Smoke test for the audioout stall watchdog (mediaengine.lua).
-- Run from the repo root: luajit dev/test_stall_watchdog.lua
--
-- Pins the seek handling: movement in either direction counts as progress,
-- so a backward seek does not look like a stall, and the retry restarts at
-- the position the stream reports rather than the original play target.

local scheduled = {}

package.preload["device"] = function() return {} end
package.preload["logger"] = function()
    local t = {}
    for _, name in ipairs({ "warn", "dbg", "err", "info" }) do
        t[name] = function() end
    end
    return t
end
package.preload["ui/time"] = function()
    return { to_ms = function(x) return x * 1000 end, s = function(x) return x end }
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end
package.preload["ui/uimanager"] = function()
    return {
        getTime = function() return 0 end,
        scheduleIn = function(_, _, fn)
            scheduled[#scheduled + 1] = fn
        end,
        unschedule = function() end,
        show = function() end,
    }
end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local MediaEngine = dofile(here .. "../mediaengine.lua")

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- A position script and the restarts the watchdog requested.
local positions, restarts
local function engine()
    local E = setmetatable({
        _audioout_external = true,
        _audioout_client = {},
        is_playing = true,
        play_generation = 3,
        _seek_offset = 751,
        _stall_retries = nil,
    }, { __index = MediaEngine })
    E._audioout_client.status = function()
        local p = table.remove(positions, 1)
        if p == nil then return nil end
        return { pos_ms = p * 1000 }
    end
    function E:_restartAt(pos, reason)
        restarts[#restarts + 1] = { pos = pos, reason = reason }
    end
    return E
end

local function run(E, n)
    scheduled = {}
    E:_startAudiooutStallWatchdog(E.play_generation)
    for _ = 1, n do
        local fn = table.remove(scheduled, 1)
        if not fn then return false end
        fn()
    end
    return true
end

-- 1. Normal forward playback: five good ticks stop the watchdog.
positions = { 1, 2, 3, 4, 5, 6, 7 }
restarts = {}
local E = engine()
run(E, 6)
ok(#restarts == 0, "forward playback never restarts")
ok(#scheduled == 0, "watchdog stops after five good ticks")

-- 2. Backward seek counts as progress, and a later stall retries at the
--    position the stream reports (650), not the original play target (751).
positions = { 700, 700, 650, 650, 650, 650, 650, 650 }
restarts = {}
E = engine()
run(E, 8)
ok(#restarts == 1, "a stall after a backward seek retries once")
ok(restarts[1] and restarts[1].pos == 650,
    "retry starts at the reported position (got " .. tostring(restarts[1] and restarts[1].pos) .. ")")
ok(restarts[1] and restarts[1].reason == "audio stalled", "retry reason recorded")

-- 3. A daemon that never reports a position falls back to getPosition().
positions = {}
restarts = {}
E = engine()
function E:getPosition() return 654 end
run(E, 4)
ok(#restarts == 1 and restarts[1].pos == 654,
    "missing status falls back to getPosition()")

-- 4. No reported and no computed position falls back to the play target.
positions = {}
restarts = {}
E = engine()
function E:getPosition() error("not available") end
run(E, 4)
ok(#restarts == 1 and restarts[1].pos == 751,
    "unavailable position falls back to the play target")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)