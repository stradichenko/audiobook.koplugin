#!/usr/bin/env luajit
-- Smoke test for the parsed overlay timing cache (epubmediaoverlay.lua).
-- Run from the repo root: luajit dev/test_timing_cache.lua
--
-- Pins the round-trip and every rejection the cache relies on: a different
-- EPUB fingerprint, missing extracted audio, a truncated file, and empty
-- timing data must all force a reparse instead of playing a wrong book.

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

-- Just enough lfs for the audio-file existence check.
local fake_lfs = {}
function fake_lfs.attributes(path, field)
    local f = io.open(path, "rb")
    if f then
        local size = f:seek("end")
        f:close()
        local a = { mode = "file", size = size, modification = 1 }
        return field and a[field] or a
    end
    return nil
end
package.preload["libs/libkoreader-lfs"] = function() return fake_lfs end

local here = (arg and arg[0]):gsub("[^/]+$", "")
local EpubMediaOverlay = dofile(here .. "../epubmediaoverlay.lua")

local ok_sb, string_buffer = pcall(require, "string.buffer")
if not ok_sb or not string_buffer then
    print("string.buffer unavailable; timing cache is disabled by design, skipping")
    os.exit(0)
end

local dir = os.tmpname()
os.remove(dir)
os.execute("mkdir -p '" .. dir .. "'")
local audio = dir .. "/a.mp3"
local f = io.open(audio, "wb")
f:write("x")
f:close()

local overlay = setmetatable({ _cache_dir = dir }, { __index = EpubMediaOverlay })
overlay._chapter_titles = { a = "Chapter 1" }
overlay._spine_hrefs = { "a.html" }

local timing = {
    { start_time = 0, end_time = 1.5, text = "Hello", audio_path = audio,
      fragment_id = "f1", text_doc = "a.html" },
    { start_time = 1, end_time = 2, text = "World", audio_path = audio,
      fragment_id = "f2", text_doc = "a.html" },
}

local fails, checks = 0, 0
local function ok(c, label)
    checks = checks + 1
    if not c then fails = fails + 1; print("FAIL " .. label) else print("ok   " .. label) end
end

overlay:_saveTimingCache("100:200", timing)

local cached = overlay:_loadTimingCache("100:200")
ok(cached ~= nil, "cache loads back")
if cached then
    ok(#cached.timing == 2, "timing entries round-trip")
    ok(cached.timing[1].text == "Hello" and cached.timing[2].fragment_id == "f2",
        "entry fields survive")
    ok(cached.chapter_titles.a == "Chapter 1", "chapter titles survive")
    ok(cached.spine_hrefs[1] == "a.html", "spine survives")
    ok(cached.audio_paths[1] == audio, "audio path list recorded")
end

ok(overlay:_loadTimingCache("999:999") == nil,
    "different EPUB fingerprint rejected")

os.remove(audio)
ok(overlay:_loadTimingCache("100:200") == nil,
    "missing extracted audio invalidates the cache")
f = io.open(audio, "wb")
f:write("x")
f:close()

local path = dir .. "/.timing.v1.bin"
local rf = io.open(path, "rb")
local blob = rf:read("*a")
rf:close()
local wf = io.open(path, "wb")
wf:write(blob:sub(1, math.floor(#blob / 2)))
wf:close()
local ok_call, result = pcall(function() return overlay:_loadTimingCache("100:200") end)
ok(ok_call, "corrupt cache does not throw")
ok(result == nil, "corrupt cache is rejected")

overlay:_saveTimingCache("100:200", {})
ok(overlay:_loadTimingCache("100:200") == nil, "empty timing is rejected")

os.execute("rm -rf '" .. dir .. "'")
print(string.format("%d passed, %d failed", checks - fails, fails))
os.exit(fails == 0 and 0 or 1)