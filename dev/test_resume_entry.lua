#!/usr/bin/env luajit
-- Smoke test for the aligned-resume page choice in main.lua.
-- Run from the repo root: luajit dev/test_resume_entry.lua
--
-- The saved fragment is only trusted when the saved time falls inside that
-- line (with a 1 s tolerance). Otherwise the file+time search decides, so
-- the page follows the audio that actually plays instead of a line saved at
-- a different moment.

package.path = (arg and arg[0]:gsub("[^/]+$", "")) .. "../?.lua;" .. package.path

package.preload["ui/widget/container/widgetcontainer"] = function()
    local WC = {}
    function WC:extend(o)
        o = o or {}
        return setmetatable(o, { __index = self })
    end
    return WC
end
package.preload["logger"] = function()
    local t = {}
    for _, name in ipairs({ "warn", "dbg", "err", "info" }) do
        t[name] = function() end
    end
    return t
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local Audiobook = dofile(here .. "../main.lua")

local audio = "/cache/book/part1.mp3"
local timing = {
    { start_time = 0, end_time = 10, audio_path = audio, fragment_id = "f1", text_doc = "a.html" },
    { start_time = 10, end_time = 20, audio_path = audio, fragment_id = "f2", text_doc = "a.html" },
    { start_time = 20, end_time = 30, audio_path = audio, fragment_id = "f3", text_doc = "a.html" },
}
local by_file = { [audio] = { timing = timing } }

local function resume(saved_pos, saved_audio, frag, text_doc)
    local self = setmetatable({}, { __index = Audiobook })
    function self:_getSavedAlignedPosition()
        return saved_pos, nil, saved_audio, nil, frag, text_doc
    end
    return self:_resumeEntryFromSave("/books/a.epub", timing, by_file)
end

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

-- 1. Fragment matches and the time is inside it.
local e = resume(15, audio, "f2")
ok(e and e.fragment_id == "f2" and e.start_time == 15 and e.audio_path == audio,
    "matching fragment inside its time is used")

-- 2. Fragment matches but the time is far away (the 26-line case): the
--    page must follow the time.
e = resume(25, audio, "f1")
ok(e and e.fragment_id == "f3" and e.start_time == 25,
    "stale fragment is ignored; line at the saved time is used")

-- 3. 1 s tolerance at both edges.
e = resume(9, audio, "f2")
ok(e and e.fragment_id == "f2", "saved time 1 s before the line still matches")
e = resume(10.5, audio, "f1")
ok(e and e.fragment_id == "f1", "saved time 1 s after the line still matches")
e = resume(8.5, audio, "f2")
ok(e and e.fragment_id == "f1", "saved time 2 s before the line falls back to the time")

-- 4. No fragment: file+time search.
e = resume(15, audio, nil)
ok(e and e.fragment_id == "f2" and e.start_time == 15,
    "file and time pick the line when no fragment is saved")

-- 5. Different text document: fragment is not trusted even if the id matches.
e = resume(15, audio, "f2", "other.html")
ok(e and e.fragment_id == "f2" and e.start_time == 15,
    "different text document falls back to the time")

-- 6. No saved position: no resume target.
e = resume(nil, audio, "f2")
ok(e == nil, "missing saved position yields no entry")

print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)