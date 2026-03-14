#!/usr/bin/env luajit
--[[--
Diagnostic script for highlight alignment issues.
Runs inside KOReader's Lua environment on the Kobo.

Dumps:
  - The raw page text from crengine
  - The parsed sentences with their char offsets
  - The screen line map (line boxes, their text, cumulative offsets)
  - For each sentence: the estimated start_x/end_x, and the text
    that crengine's getTextFromPositions actually selects

Usage: run this from the KOReader Lua console or inject via main.lua
--]]

local logger = require("logger")
local Device = require("device")
local Screen = Device.screen

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local TextParser = dofile(_utils_dir .. "textparser.lua"):new()

local function runDiagnostic(ui)
    if not ui or not ui.document then
        print("ERROR: no ui.document")
        return
    end

    local doc = ui.document
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()

    print("\n========== HIGHLIGHT DIAGNOSTIC ==========")
    print(string.format("Screen: %d x %d", cur_w, cur_h))

    -- Step 1: Get full page text
    local full_res = doc:getTextFromPositions(
        {x = 0, y = 0},
        {x = cur_w, y = cur_h},
        true  -- no draw
    )
    if not full_res or not full_res.text then
        print("ERROR: could not get page text")
        return
    end
    local page_text = full_res.text
    print("\n--- RAW PAGE TEXT ---")
    print(page_text)
    print("--- END RAW PAGE TEXT ---")

    -- Step 2: Get screen boxes (line map)
    local sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
    if not sboxes or #sboxes == 0 then
        print("ERROR: no screen boxes")
        return
    end
    local n = #sboxes
    print(string.format("\n--- LINE MAP: %d lines ---", n))

    -- Build per-line text + cumulative offsets
    local built_text = ""
    local cum = {[0] = 0}
    local line_texts = {}
    for i = 1, n do
        local box = sboxes[i]
        local r = doc:getTextFromPositions(
            {x = box.x, y = box.y + math.floor(box.h / 2)},
            {x = box.x + box.w - 1, y = box.y + math.floor(box.h / 2)},
            true)
        local lt = (r and r.text) and Utils.ws(r.text) or ""
        if i > 1 and lt ~= "" then
            built_text = built_text .. " "
        end
        built_text = built_text .. lt
        cum[i] = #built_text
        line_texts[i] = lt
        print(string.format("  Line %2d: box(%4d,%4d %4dx%2d) cum[%d]=%d text=[%s]",
            i, box.x, box.y, box.w, box.h, i, cum[i], lt))
    end

    print("\n--- BUILT TEXT ---")
    print(built_text)
    print("--- END BUILT TEXT ---")

    -- Step 3: Parse into sentences using the BUILT text (same as highlightmanager)
    -- Note: textparser normalizes the text, which may shift offsets
    local norm_text = TextParser:normalizeText(page_text)
    print("\n--- NORMALIZED TEXT ---")
    print(norm_text)
    print("--- END NORMALIZED TEXT ---")

    local parsed = TextParser:parse(page_text)
    print(string.format("\n--- PARSED SENTENCES: %d ---", #parsed.sentences))
    for _, s in ipairs(parsed.sentences) do
        print(string.format("  S%d: start=%d end=%d type=%s [%s]",
            s.index, s.start_pos, s.end_pos, s.end_type or "?",
            s.text:sub(1, 60) .. (#s.text > 60 and "..." or "")))
    end

    -- Step 4: For each sentence, simulate the highlight coordinate calc
    print("\n--- HIGHLIGHT SIMULATION ---")
    for _, sentence in ipairs(parsed.sentences) do
        local sent_text = Utils.ws(sentence.text)
        if sent_text == "" then goto next_sentence end

        -- Find in built text (same as highlightmanager)
        local vis_start = built_text:find(sent_text, 1, true)
        if not vis_start then
            vis_start = built_text:find(sent_text:sub(1, math.min(40, #sent_text)), 1, true)
        end
        if not vis_start then
            print(string.format("  S%d: NOT FOUND in built text! [%s]",
                sentence.index, sent_text:sub(1, 50)))
            goto next_sentence
        end
        local vis_end = vis_start + #sent_text - 1

        -- Find start/end lines
        local start_line = 1
        for i = 1, n do
            if cum[i] >= vis_start then
                start_line = i
                break
            end
        end
        local end_line = n
        for i = start_line, n do
            if cum[i] >= vis_end then
                end_line = i
                break
            end
        end

        local sb = sboxes[start_line]
        local eb = sboxes[end_line]

        -- Calculate start_x
        local sl_total = cum[start_line] - cum[start_line - 1]
        local sl_off   = vis_start - cum[start_line - 1]
        local start_x
        if sl_total > 0 then
            start_x = sb.x + math.floor((sl_off / sl_total) * sb.w)
        else
            start_x = sb.x
        end
        start_x = math.max(sb.x, math.min(sb.x + sb.w - 1, start_x))

        -- Calculate end_x (current code with char_w pullback)
        local el_total = cum[end_line] - cum[end_line - 1]
        local el_off   = vis_end - cum[end_line - 1]
        local end_x
        if el_total > 0 then
            local char_w = math.max(1, math.floor(eb.w / math.max(1, el_total)))
            end_x = eb.x + math.floor((el_off / el_total) * eb.w) - char_w
        else
            end_x = eb.x + eb.w
        end
        end_x = math.max(eb.x, math.min(eb.x + eb.w - 1, end_x))

        -- What does crengine actually select?
        local sel = doc:getTextFromPositions(
            {x = start_x, y = sb.y + math.floor(sb.h / 2)},
            {x = end_x,   y = eb.y + math.floor(eb.h / 2)},
            true  -- no draw, just query
        )
        local sel_text = (sel and sel.text) or "(nil)"

        -- Also compute end_x WITHOUT the char_w pullback for comparison
        local end_x_no_pull
        if el_total > 0 then
            end_x_no_pull = eb.x + math.floor((el_off / el_total) * eb.w)
        else
            end_x_no_pull = eb.x + eb.w
        end
        end_x_no_pull = math.max(eb.x, math.min(eb.x + eb.w - 1, end_x_no_pull))

        local sel_no_pull = doc:getTextFromPositions(
            {x = start_x, y = sb.y + math.floor(sb.h / 2)},
            {x = end_x_no_pull, y = eb.y + math.floor(eb.h / 2)},
            true)
        local sel_text_no_pull = (sel_no_pull and sel_no_pull.text) or "(nil)"

        -- Compare
        local expected_ws = Utils.ws(sentence.text)
        local got_ws = Utils.ws(sel_text)
        local match = (expected_ws == got_ws) and "OK" or "MISMATCH"

        print(string.format("\n  S%d [%s]: vis_start=%d vis_end=%d lines=%d-%d",
            sentence.index, match, vis_start, vis_end, start_line, end_line))
        print(string.format("    start_x=%d (line_off=%d/%d)  end_x=%d (line_off=%d/%d) char_w_pull=%s",
            start_x, sl_off, sl_total, end_x, el_off, el_total,
            el_total > 0 and tostring(math.max(1, math.floor(eb.w / math.max(1, el_total)))) or "n/a"))
        print(string.format("    end_x_no_pull=%d", end_x_no_pull))
        print(string.format("    EXPECTED: [%s]", expected_ws:sub(1, 80)))
        print(string.format("    GOT     : [%s]", got_ws:sub(1, 80)))
        if match == "MISMATCH" then
            print(string.format("    NO_PULL : [%s]", Utils.ws(sel_text_no_pull):sub(1, 80)))
            -- Check if selection overshoots or undershoots
            if #got_ws > #expected_ws then
                local extra = got_ws:sub(#expected_ws + 1)
                print(string.format("    OVERSHOOT by %d chars: [%s]", #extra, extra))
            elseif #got_ws < #expected_ws then
                local missing = expected_ws:sub(#got_ws + 1)
                print(string.format("    UNDERSHOOT by %d chars: [%s]", #missing, missing))
            end
        end

        ::next_sentence::
    end
    print("\n========== END DIAGNOSTIC ==========")
end

return { run = runDiagnostic }
