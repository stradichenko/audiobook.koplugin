#!/usr/bin/env luajit
-- Smoke test for the arrangeable large bar (AudiobookPlayer.barOrder and
-- _orderBar). Run from the repo root: luajit dev/test_bar_order.lua
--
-- Pins: the default order reproduces the bar as it was; a saved order is
-- kept; unknown and duplicate ids are dropped; ids a saved list lacks keep
-- their default side of the title; buttons a bar does not carry are skipped.

-- Any KOReader module the player requires at load time is a forgiving stub:
-- indexing or calling it returns another stub.
local function stub()
    local s = {}
    return setmetatable(s, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end
table.insert(package.loaders, 2, function(name)
    return function() return stub() end
end)
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local ABP = dofile("audiobookplayer.lua")

local failures = 0
local function eq(name, got, want)
    local g, w = table.concat(got, ","), table.concat(want, ",")
    if g ~= w then
        failures = failures + 1
        print("FAIL " .. name .. "\n  got  " .. g .. "\n  want " .. w)
    else
        print("ok   " .. name)
    end
end

local DEFAULT = { "play", "chapters", "vol_down", "vol_up", "title",
    "sync_minus", "sync_plus", "speed", "settings", "refocus" }

eq("default order", ABP.barOrder(nil), DEFAULT)
eq("non-table setting", ABP.barOrder("garbage"), DEFAULT)

local saved = { "title", "play", "vol_up", "vol_down", "chapters",
    "refocus", "sync_plus", "sync_minus", "settings", "speed" }
eq("saved order kept", ABP.barOrder(saved), saved)

eq("unknown and duplicate ids dropped",
    ABP.barOrder({ "play", "nope", "play", "title", "refocus" }),
    { "play", "chapters", "vol_down", "vol_up", "title", "refocus",
      "sync_minus", "sync_plus", "speed", "settings" })

-- An old saved list without "chapters" (before-title by default) puts it
-- left of the title; one without "refocus" puts it on the right.
eq("new ids keep their side",
    ABP.barOrder({ "vol_up", "play", "title", "sync_plus", "sync_minus" }),
    { "vol_up", "play", "chapters", "vol_down", "title",
      "sync_plus", "sync_minus", "speed", "settings", "refocus" })

-- _orderBar: only the buttons present, split at the title.
local bar = setmetatable({
    plugin = { getSetting = function(_self, key)
        if key == "bar_button_order" then
            return { "sync_plus", "play", "title", "vol_up", "refocus" }
        end
    end },
}, { __index = ABP })
local left, right = bar:_orderBar({ play = "P", vol_up = "V+", sync_plus = "S+",
    refocus = "R", chapters = "C" })
eq("left of title", left, { "S+", "P", "C" })
eq("right of title", right, { "V+", "R" })

if failures > 0 then
    print(failures .. " failure(s)")
    os.exit(1)
end
print("all passed")
