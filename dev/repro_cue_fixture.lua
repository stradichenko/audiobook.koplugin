#!/usr/bin/env luajit
-- Repro harness: run the REAL EpubMediaOverlay parser over a fixture epub,
-- then the cue grouping, and dump what the device would see.
-- Usage: luajit dev/repro_cue_fixture.lua tests/cue_groups_test.epub

local fixture = arg and arg[1] or "tests/cue_groups_test.epub"

-- Stub the two KOReader-side dependencies of epubmediaoverlay.lua.
package.preload["logger"] = function()
    return {
        dbg = function() end,
        warn = function(...) print("[warn]", ...) end,
        err = function(...) print("[err]", ...) end,
        info = function() end,
    }
end
package.preload["audiobook_gettext"] = function()
    return function(s) return s end
end

local Utils = dofile("utils.lua")
local EMO = dofile("epubmediaoverlay.lua")

local t0 = os.clock()
local overlay = EMO:new()
local timing, err = overlay:loadFromEpub(fixture, "/tmp/cue_repro_cache")
if not timing then
    print("PARSE FAILED:", err)
    os.exit(1)
end
print(string.format("parsed %d entries in %.2fs", #timing, os.clock() - t0))
print(string.format("spine=%d, chapter_titles=%d",
    overlay._spine_hrefs and #overlay._spine_hrefs or 0,
    overlay._chapter_titles and overlay:_tableCount(overlay._chapter_titles) or 0))

print("\n-- first 6 entries --")
for i = 1, math.min(6, #timing) do
    local e = timing[i]
    print(string.format("%2d  [%7.3f .. %7.3f]  fid=%-6s doc=%-18s text=%q  audio=%s",
        i, e.start_time or -1, e.end_time or -1,
        tostring(e.fragment_id), tostring(e.text_doc),
        tostring(e.text), tostring(e.audio_path)))
end

-- Sanity: durations and text coverage
local zero_dur, bad_text = 0, 0
for _, e in ipairs(timing) do
    local d = (e.end_time or 0) - (e.start_time or 0)
    if d <= 0 then zero_dur = zero_dur + 1 end
    if type(e.text) ~= "string" or e.text == "" or e.text:find("#", 1, true) then
        bad_text = bad_text + 1
    end
end
print(string.format("\ndurations <= 0: %d / %d;  unusable text: %d / %d",
    zero_dur, #timing, bad_text, #timing))

-- Group exactly like MediaSync:start() does
local groups, entry_group = Utils.buildCueGroups(timing, 0.5)
if not groups then
    print("no groups returned")
    os.exit(0)
end
print(string.format("\n-- %d groups at threshold 0.5 --", #groups))
for gi, g in ipairs(groups) do
    local texts = {}
    for j = g.first, g.last do
        texts[#texts + 1] = timing[j].text or "?"
    end
    local span = (timing[g.last].end_time or 0) - (timing[g.first].start_time or 0)
    print(string.format("g%-2d [%2d..%2d] span=%.2fs  %q",
        gi, g.first, g.last, span, table.concat(texts, " ")))
end

-- What _cueSentObj would build for group 1
local g1 = groups[1]
local texts = {}
for j = g1.first, g1.last do
    texts[#texts + 1] = timing[j].text or ""
end
print("\n-- group 1 highlight object --")
print("text:", string.format("%q", table.concat(texts, " ")))
print("fragment_id:", timing[g1.first].fragment_id)
print("text_doc:", timing[g1.first].text_doc)
local nxt = timing[g1.last + 1]
print("limit_fragment_id:", nxt and nxt.fragment_id or "false")
