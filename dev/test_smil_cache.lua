#!/usr/bin/env luajit
-- Smoke test for the dedicated SMIL xpointer cache in main.lua.
-- Run from the repo root: luajit dev/test_smil_cache.lua
--
-- Stubs the few KOReader modules main.lua touches at load time and pins the
-- parts that are easy to regress: one-time migration out of reader settings,
-- writes batched until stop/suspend, and the entry and book caps.
local here = (arg and arg[0]):gsub("[^/]+$", "")
package.path = here .. "../?.lua;" .. package.path

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(o)
        o = o or {}
        return setmetatable(o, { __index = self })
    end
    return WC
end
package.preload["logger"] = function()
    return setmetatable({}, { __index = function() return function() end end })
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local writer_settings = { data = {}, flushes = 0, purges = 0, file = "/tmp/smil-cache-test/cache.lua" }
function writer_settings:flush() self.flushes = self.flushes + 1 end
function writer_settings:purge() self.purges = self.purges + 1; self.data = {} end

local opened_files = {}
package.preload["luasettings"] = function()
    return {
        open = function(_, path)
            local s = opened_files[path]
            if not s then
                s = { data = {}, flushes = 0, purges = 0, file = path }
                function s:flush() self.flushes = self.flushes + 1 end
                function s:purge() self.purges = self.purges + 1; self.data = {} end
                opened_files[path] = s
            end
            return s
        end,
    }
end
package.preload["datastorage"] = function()
    return { getSettingsDir = function() return "/tmp/smil-cache-test/settings" end }
end

local reader_settings = { data = {}, flushes = 0 }
function reader_settings:readSetting(k) return self.data[k] end
function reader_settings:saveSetting(k, v) self.data[k] = v end
function reader_settings:delSetting(k) self.data[k] = nil end
function reader_settings:flush() self.flushes = self.flushes + 1 end
_G.G_reader_settings = reader_settings

local Audiobook = dofile(here .. "../main.lua")
local function instance()
    return setmetatable({}, { __index = Audiobook })
end

local fails, checks = 0, 0
local function ok(cond, label)
    checks = checks + 1
    if not cond then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- 1. Legacy migration out of reader settings.
reader_settings.data.audiobook_settings = {
    smil_xpointer_cache = { ["/books/a.epub"] = { ["#p1"] = "xp1" } },
    other = 1,
}
local app = instance()
local cached = app:_loadSmilXPointerCache("/books/a.epub")
ok(cached["#p1"] == "xp1", "legacy entry is readable through the new API")
local file = opened_files["/tmp/smil-cache-test/settings/audiobook_smil_cache.lua"]
ok(file and file.data["/books/a.epub"] and file.data["/books/a.epub"]["#p1"] == "xp1",
    "legacy entry moved into the cache file")
ok(reader_settings.data.audiobook_settings.smil_xpointer_cache == nil,
    "legacy key removed from reader settings")
ok(reader_settings.data.audiobook_settings.other == 1,
    "unrelated plugin settings preserved")
ok(reader_settings.flushes == 1, "migration flushes reader settings once")

-- 2. Saving during playback only touches memory.
local before = file.flushes
app:_saveSmilXPointerCache("/books/a.epub", { ["#p2"] = "xp2" })
app:_saveSmilXPointerCache("/books/a.epub", { ["#p2"] = "xp2", ["#p3"] = "xp3" })
ok(file.flushes == before, "per-sentence saves do not flush the cache file")
app:_flushSmilXPointerCache()
ok(file.flushes == before + 1, "FlushSettings-style call writes once")
app:_flushSmilXPointerCache()
ok(file.flushes == before + 1, "clean cache is not written twice")

-- 3. Per-book cap.
local big = {}
for i = 1, 2500 do big["#f" .. i] = "xp" .. i end
app:_saveSmilXPointerCache("/books/a.epub", big)
app:_flushSmilXPointerCache()
local n = 0
for _ in pairs(file.data["/books/a.epub"]) do n = n + 1 end
ok(n == 2000, "per-book entry cap holds (got " .. n .. ")")

-- 4. Book cap, keeping the active book.
for i = 1, 8 do
    app:_saveSmilXPointerCache("/books/other" .. i .. ".epub", { ["#x"] = "xp" })
    app:_flushSmilXPointerCache()
end
local books = 0
for _ in pairs(file.data) do books = books + 1 end
ok(books == 6, "book cap holds (got " .. books .. ")")
ok(file.data["/books/other8.epub"] ~= nil, "the active book survives trimming")

-- 5. A fresh instance reads the persisted file.
local app2 = instance()
local cached2 = app2:_loadSmilXPointerCache("/books/other8.epub")
ok(cached2["#x"] == "xp", "cache survives across plugin instances")

-- 6. Delete plugin settings purges the file.
app2:deletePluginSettings()
ok(file.purges == 1, "deletePluginSettings purges the cache file")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)
