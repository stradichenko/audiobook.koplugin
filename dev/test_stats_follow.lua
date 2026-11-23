#!/usr/bin/env luajit
package.preload["ui/widget/container/widgetcontainer"] = function()
    return { extend = function(_self, o) o = o or {}; o.__index = o; return o end }
end
package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["gettext"] = function() return function(s) return s end end
package.preload["audiobook_gettext"] = function() return function(s) return s end end

-- Resolve main.lua relative to this script, so the test runs from the repo root
-- (luajit dev/test_stats_follow.lua) as well as from dev/.
local Audiobook = dofile((arg and arg[0] or "dev/test_stats_follow.lua"):gsub("[^/]+$", "") .. "../main.lua")

local fails, total = 0, 0
local function ok(cond, name)
    total = total + 1
    if cond then print("ok    " .. name) else print("FAIL  " .. name); fails = fails + 1 end
end

local calls = {}
local stats = { onPageUpdate = function(_, p) table.insert(calls, p) end }
local function obj(state, ui)
    return setmetatable({
        ui = ui or { statistics = stats },
        sync_controller = { state = state, STATE = { STOPPED = "stopped" } },
        media_sync = { state = "stopped", STATE = { STOPPED = "stopped" } },
    }, { __index = Audiobook })
end

calls = {}
Audiobook._reportPageToStatistics(obj("playing"), 7)
ok(#calls == 1 and calls[1] == 7, "playing session forwards the page")

calls = {}
Audiobook._reportPageToStatistics(obj("loading"), 8)
ok(#calls == 1 and calls[1] == 8, "loading session forwards the page")

calls = {}
Audiobook._reportPageToStatistics(obj("stopped"), 9)
ok(#calls == 0, "idle session forwards nothing")

calls = {}
Audiobook._reportPageToStatistics(obj("playing"), "9")
ok(#calls == 0, "non-numeric page ignored")

calls = {}
local o = obj("playing", {})
local okc = pcall(function() Audiobook._reportPageToStatistics(o, 10) end)
ok(okc and #calls == 0, "missing statistics plugin is a no-op")

-- current-page helper: report once per page number
local current = 12
local ui = { statistics = stats, getCurrentPage = function() return current end }
local o2 = obj("playing", ui)
calls = {}
Audiobook._reportCurrentPageToStatistics(o2)
Audiobook._reportCurrentPageToStatistics(o2)
ok(#calls == 1 and calls[1] == 12, "current page forwarded once")
current = 13
Audiobook._reportCurrentPageToStatistics(o2)
ok(#calls == 2 and calls[2] == 13, "new current page forwarded")

if fails > 0 then print(string.format("%d passed, %d failed", total - fails, fails)); os.exit(1) end
print(string.format("%d passed, %d failed", total, fails))
