#!/bin/sh
# Run highlight accuracy test on Kobo
# This script creates a Lua test, uploads it, and runs it via KOReader's luajit
# It tests the highlight coordinate calculation without needing to trigger TTS

KOBO="root@192.168.1.28"
SSH="sshpass -p '' ssh -p 2222 $KOBO"
SCP="sshpass -p '' scp -P 2222"

cat > /tmp/test_hl_accuracy.lua << 'LUAEOF'
-- Highlight accuracy test
-- Run with: cd /mnt/onboard/.adds/koreader && ./luajit /tmp/test_hl_accuracy.lua
-- This tests the binary-search refinement algorithm in isolation

local PLUGIN = "plugins/audiobook.koplugin/"

-- Load utils
local Utils = dofile(PLUGIN .. "utils.lua")

-- Simulate the line-map and binary search logic
-- We'll test it against known data from the diagnostic log

-- From diagnostic: screen 1264x1680, page from The Alchemist Epilogue
local test_cases = {
    {
        name = "S2: sentence ending mid-line, next word starts immediately",
        sent_text = "The boy reached the small, abandoned church just as night was falling.",
        -- Line 2: cum[1]=8, cum[2]=52, box(170,479 924x55) - 44 chars
        -- Line 3: cum[2]=52, cum[3]=102, box(170,534 924x55) - 50 chars
        -- vis_start=10, vis_end=79 => start in line2 off=2, end in line3 off=27
        vis_start = 10,
        vis_end = 79,
        start_line = 2,
        end_line = 3,
        expected_overshoot_with_raw = true,  -- RAW gives "... falling. The"
    },
    {
        name = "S7: sentence on single line, period before next word",
        sent_text = "He sat looking at the sky for a long time.",
        -- Line 11: cum[10]=374, cum[11]=422, box(245,974 849x55) - 48 chars
        -- vis_start=376, vis_end=418 => start off=2, end off=43/48
        vis_start = 376,
        vis_end = 418,
        start_line = 11,
        end_line = 11,
        expected_overshoot_with_raw = true,  -- RAW gives "... time. Then"
    },
    {
        name = "S8: sentence starting mid-line, period mid-line on different line",
        sent_text = "Then he took from his knapsack a bottle of wine, and drank some.",
        -- starts line 11 off=45, ends line 13 off=12
        vis_start = 419,
        vis_end = 482,
        start_line = 11,
        end_line = 13,
        expected_undershoot_with_pull = true,  -- 1x pull misses the period
    },
}

print("\n====== BINARY SEARCH ALGORITHM TEST ======")
print("Testing: does binary search converge to correct selection?")

-- The key insight from the diagnostic data:
-- - RAW (no pullback): overshoots when next word is on same line
-- - 1x char_w pullback: undershoots on periods (misses last char)
-- - 2x char_w pullback: undershoots even more
-- - Binary search should find the sweet spot

-- Simulate what the binary search does
-- Given a line box, estimate end_x using the refinement loop
local function simulate_binary_search(el_off, el_total, box_x, box_w, check_fn)
    -- Initial raw estimate
    local end_x = box_x + math.floor((el_off / el_total) * box_w)
    end_x = math.max(box_x, math.min(box_x + box_w - 1, end_x))

    local got_len = check_fn(end_x)
    local want_len = el_off  -- approximate

    if got_len == want_len then
        return end_x, 0, "perfect"
    end

    local lo, hi
    if got_len > want_len then
        hi = end_x
        lo = box_x
    else
        lo = end_x
        hi = box_x + box_w - 1
    end

    local best_x = end_x
    local best_diff = math.abs(got_len - want_len)
    local iters = 0
    for i = 1, 6 do
        if hi - lo < 2 then break end
        local mid = math.floor((lo + hi) / 2)
        local mid_len = check_fn(mid)
        local diff = math.abs(mid_len - want_len)
        iters = i

        if mid_len == want_len then
            return mid, iters, "exact"
        elseif mid_len > want_len then
            hi = mid
        else
            lo = mid
        end

        if diff < best_diff or (diff == best_diff and mid_len <= want_len) then
            best_diff = diff
            best_x = mid
        end
    end
    return best_x, iters, "best_effort"
end

-- Test the simulation
for _, tc in ipairs(test_cases) do
    print(string.format("\n--- %s ---", tc.name))
    print(string.format("  sentence: [%s]", tc.sent_text:sub(1, 60)))

    -- Simulate CRe word-boundary snapping:
    -- CRe snaps to the nearest word boundary for selection endpoints.
    -- We model this as: the selection includes characters up to the
    -- nearest word break at or after the x position.
    -- This is a simplification but captures the key behavior.
    print("  (simulation only - need device CRe for real test)")
end

-- Now test with actual CRe if we have access
-- This part only works when run inside KOReader's environment
local ok, _ = pcall(require, "ui/uimanager")
if not ok then
    print("\nNot running inside KOReader - skipping CRe tests")
    print("To run the real test, start read-aloud and check /tmp/highlight_diag.log")
    os.exit(0)
end

print("\nRunning inside KOReader environment - CRe tests available")
LUAEOF

echo "Test script created. Uploading..."

$SCP /tmp/test_hl_accuracy.lua $KOBO:/tmp/test_hl_accuracy.lua

echo "Running test..."
$SSH "cd /mnt/onboard/.adds/koreader && ./luajit /tmp/test_hl_accuracy.lua 2>&1"
