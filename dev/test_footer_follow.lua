#!/usr/bin/env luajit
-- Smoke test for the mini bar following the reader's status bar
-- (AudiobookPlayer:onFooterChanged). Run from the repo root:
-- luajit dev/test_footer_follow.lua
--
-- Pins the touch/refresh half of the fix: when the footer appears or goes
-- away the bar moves its dimen.y to the new strip and repaints the old and
-- new strips together. The visual move alone was not enough: input routing
-- reads dimen.

-- Minimal geometry, enough for the combined dirty rectangle.
local Geom = {}
Geom.__index = Geom
function Geom:new(o)
    o = o or {}
    return setmetatable(o, Geom)
end
function Geom:combine(b)
    local x = math.min(self.x, b.x)
    local y = math.min(self.y, b.y)
    local x2 = math.max(self.x + self.w, b.x + b.w)
    local y2 = math.max(self.y + self.h, b.y + b.h)
    return Geom:new{ x = x, y = y, w = x2 - x, h = y2 - y }
end
package.preload["ui/geometry"] = function() return Geom end

local dirty = {}
package.preload["ui/uimanager"] = function()
    return {
        setDirty = function(_, target, fn)
            local kind, region
            if type(fn) == "function" then
                kind, region = fn()
            else
                kind, region = fn, nil
            end
            dirty[#dirty + 1] = { target = target, kind = kind, region = region }
        end,
    }
end
package.preload["logger"] = function()
    local t = {}
    for _, n in ipairs({ "warn", "dbg", "err", "info" }) do t[n] = function() end end
    return t
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

-- Everything else a KOReader module the player requires: a forgiving stub.
local function stub()
    return setmetatable({}, {
        __index = function() return stub() end,
        __call = function() return stub() end,
    })
end
table.insert(package.loaders, 2, function()
    return function() return stub() end
end)

local ABP = dofile("audiobookplayer.lua")

local footer_shown = true
local function bar()
    local p = setmetatable({
        width = 1072,
        height = 1448,
        _mini_height = 100,
        visible = true,
        _minimized = true,
        dimen = Geom:new{ x = 0, y = 1205, w = 1072, h = 100 },
    }, { __index = ABP })
    function p:_shouldSitAboveFooter() return footer_shown end
    function p:_miniBarY() return footer_shown and 1205 or 1305 end
    return p
end

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- 1. Already in place: no repaint.
dirty = {}
local p = bar()
p.covers_footer = false
p:onFooterChanged()
ok(p.dimen.y == 1205 and #dirty == 0, "no move, no repaint")

-- 2. Footer hidden: the bar drops to the bottom and both strips repaint.
footer_shown = false
p:onFooterChanged()
ok(p.dimen.y == 1305, "bar moves to the new strip")
ok(p.covers_footer == true, "covers_footer follows the footer state")
ok(#dirty == 1 and dirty[1].target == "all" and dirty[1].kind == "ui",
    "one ui repaint of the old and new strips")
local r = dirty[1] and dirty[1].region
ok(r and r.y == 1205 and r.h == 200, "repaint covers both strips (got "
    .. tostring(r and (tostring(r.y) .. "/" .. tostring(r.h))) .. ")")

-- 3. Footer back: the bar moves up again.
footer_shown = true
dirty = {}
p:onFooterChanged()
ok(p.dimen.y == 1205, "bar moves back above the footer")
ok(p.covers_footer == false, "covers_footer clears")
ok(#dirty == 1, "one repaint when moving back")

-- 4. Not minimized or not visible: nothing to move.
footer_shown = false
p._minimized = false
p.dimen.y = 1205
dirty = {}
p:onFooterChanged()
ok(p.dimen.y == 1205 and #dirty == 0, "expanded player ignores footer changes")
p._minimized = true
p.visible = false
p:onFooterChanged()
ok(p.dimen.y == 1205 and #dirty == 0, "hidden bar ignores footer changes")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)