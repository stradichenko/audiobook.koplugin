#!/usr/bin/env luajit
-- Ad-hoc smoke test for Utils.buildCueGroups (issue #97 e-ink cue grouping).
-- Run from the repo root: luajit dev/test_cue_groups.lua
-- utils.lua is dependency-free, so no KOReader globals are needed.

local Utils = dofile((arg and arg[0]):gsub("[^/]+$", "") .. "../utils.lua")

local failures = {}
local checks = 0

local function eq(actual, expected, label)
    checks = checks + 1
    if actual ~= expected then
        failures[#failures + 1] = string.format("%s: expected %s, got %s",
            label, tostring(expected), tostring(actual))
    end
end

local function sameGroups(groups, expected, label)
    checks = checks + 1
    local got = {}
    for gi, g in ipairs(groups or {}) do
        got[gi] = g.first .. "-" .. g.last
    end
    if table.concat(got, ",") ~= table.concat(expected, ",") then
        failures[#failures + 1] = string.format("%s: expected {%s}, got {%s}",
            label, table.concat(expected, ","), table.concat(got, ","))
    end
end

local function span(g, timing)
    return (timing[g.last].end_time or 0) - (timing[g.first].start_time or 0)
end

-- Build a synthetic slice: each spec { dur=, doc=, text=, fid=, gap= } adds
-- one entry starting after the previous one's end (+ optional gap).
local function makeSlice(specs, opts)
    opts = opts or {}
    local timing, t = {}, 0
    for i, s in ipairs(specs) do
        t = t + (s.gap or 0)
        timing[i] = {
            start_time = t,
            end_time = t + s.dur,
            text = s.text ~= nil and s.text or ("w" .. i),
            fragment_id = s.fid == nil and ("f" .. i) or s.fid,
            text_doc = s.doc or "ch1.xhtml",
        }
        t = t + s.dur
    end
    if opts.start_at then
        local off = opts.start_at - timing[1].start_time
        for _, e in ipairs(timing) do
            e.start_time = e.start_time + off
            e.end_time = e.end_time + off
        end
    end
    return timing
end

-- 1. Empty and nil input.
local g1, m1 = Utils.buildCueGroups(nil, 0.5)
eq(g1, nil, "nil timing -> nil groups")
eq(m1, nil, "nil timing -> nil map")
local g1b = Utils.buildCueGroups({}, 0.5)
eq(g1b, nil, "empty timing -> nil groups")

-- 2. Seven 0.2 s same-doc cues at 0.5 s threshold: pairs merge, the
-- crossing cue is absorbed, so the last lone cue is a singleton.
local timing2 = makeSlice({ { dur = 0.2 }, { dur = 0.2 }, { dur = 0.2 },
    { dur = 0.2 }, { dur = 0.2 }, { dur = 0.2 }, { dur = 0.2 } })
local g2, m2 = Utils.buildCueGroups(timing2, 0.5)
sameGroups(g2, { "1-3", "4-6", "7-7" }, "seven 0.2s cues")
eq(span(g2[1], timing2) >= 0.5, true, "first group span reaches threshold")
eq(m2[1], 1, "entry 1 -> group 1")
eq(m2[3], 1, "entry 3 -> group 1")
eq(m2[4], 2, "entry 4 -> group 2")
eq(m2[7], 3, "entry 7 -> group 3")
eq(g2[#g2].last, 7, "last group ends at slice end")

-- 3. Exact threshold boundary: 0.25 s cues -> pair with span exactly 0.5.
local timing3 = makeSlice({ { dur = 0.25 }, { dur = 0.25 }, { dur = 0.25 } })
local g3 = Utils.buildCueGroups(timing3, 0.5)
sameGroups(g3, { "1-2", "3-3" }, "0.25s cues at 0.5 threshold")
eq(span(g3[1], timing3), 0.5, "boundary group span is exactly the threshold")

-- 4. A long cue is never absorbed and keeps its own visual unit.
local timing4 = makeSlice({ { dur = 0.3 }, { dur = 2.0 }, { dur = 0.3 }, { dur = 0.3 } })
local g4 = Utils.buildCueGroups(timing4, 0.5)
sameGroups(g4, { "1-1", "2-2", "3-4" }, "long cue breaks groups")

-- 5. Content-document change breaks groups.
local timing5 = makeSlice({ { dur = 0.2 }, { dur = 0.2 },
    { dur = 0.2, doc = "ch2.xhtml" }, { dur = 0.2, doc = "ch2.xhtml" } })
local g5 = Utils.buildCueGroups(timing5, 0.5)
sameGroups(g5, { "1-2", "3-4" }, "text_doc change breaks groups")

-- 6. Empty and nil text make singleton singletons (merged text stays non-empty).
local timing6 = makeSlice({ { dur = 0.2 }, { dur = 0.2, text = "" },
    { dur = 0.2, text = nil }, { dur = 0.2 } })
timing6[3].text = nil
local g6 = Utils.buildCueGroups(timing6, 0.5)
sameGroups(g6, { "1-1", "2-2", "3-3", "4-4" }, "empty/nil text breaks groups")

-- 7. A missing fragment_id breaks groups.
local timing7 = makeSlice({ { dur = 0.2 }, { dur = 0.2, fid = nil },
    { dur = 0.2 } })
timing7[2].fragment_id = nil
local g7 = Utils.buildCueGroups(timing7, 0.5)
sameGroups(g7, { "1-1", "2-2", "3-3" }, "missing fragment_id breaks groups")

-- 8. A raw text_ref leak (contains "#") breaks groups.
local timing8 = makeSlice({ { dur = 0.2 }, { dur = 0.2, text = "../text/ch1.xhtml#id12" },
    { dur = 0.2 } })
local g8 = Utils.buildCueGroups(timing8, 0.5)
sameGroups(g8, { "1-1", "2-2", "3-3" }, "raw text_ref (# in text) breaks groups")

-- 9. A time gap between short cues is absorbed into the span (the paint
-- persists through the pause).
local timing9 = makeSlice({ { dur = 0.2 }, { dur = 0.2, gap = 0.8 } })
local g9 = Utils.buildCueGroups(timing9, 0.5)
sameGroups(g9, { "1-2" }, "gap between short cues absorbed")
eq(span(g9[1], timing9) > 0.5, true, "gap included in group span")

-- 10. entry_group is a complete ordered partition of 1..n.
local timing10 = makeSlice({ { dur = 0.1 }, { dur = 0.1 }, { dur = 0.1 },
    { dur = 0.1, doc = "ch2.xhtml" }, { dur = 0.1 } })
local g10, m10 = Utils.buildCueGroups(timing10, 0.5)
checks = checks + 1
do
    local ok = true
    local last_g = 0
    for i = 1, 5 do
        local gi = m10[i]
        if not gi or gi < last_g then ok = false end
        last_g = gi or last_g
    end
    if not ok then
        failures[#failures + 1] = "entry_group is not an ordered partition"
    end
end
sameGroups(g10, { "1-3", "4-4", "5-5" }, "mixed docs partition covers all entries")

-- 11. Member cap: runs of near-zero-length cues never grow a giant group.
-- Zero durations keep the span flat, so without a cap all 12 would merge.
local specs11 = {}
for _ = 1, 12 do
    specs11[#specs11 + 1] = { dur = 0 }
end
local timing11 = makeSlice(specs11, { start_at = 3 })
local g11 = Utils.buildCueGroups(timing11, 0.5)
sameGroups(g11, { "1-8", "9-12" }, "member cap bounds zero-duration runs")
for _, g in ipairs(g11) do
    eq(g.last - g.first + 1 <= 8, true, "group within member cap")
end

-- 12. Default cap equals 8 even when the caller omits the argument.
local g12 = Utils.buildCueGroups(timing11, 0.5, nil)
sameGroups(g12, { "1-8", "9-12" }, "default member cap is 8")

if #failures > 0 then
    print("FAIL (" .. #failures .. "/" .. checks .. " checks):")
    for _, f in ipairs(failures) do
        print("  " .. f)
    end
    os.exit(1)
end
print("ok: " .. checks .. " checks passed")
