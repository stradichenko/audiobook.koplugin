--[[--
Highlight Manager Module
Uses KOReader's native text selection to highlight the current sentence
being read by TTS. Works with both EPUB (CreDocument) and PDF.

For EPUB: Uses getTextFromPositions() with draw_selection enabled, which
lets crengine draw the selection highlight natively.

@module highlightmanager
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("gettext")

-- Shared utility modules (DRY: ws helper)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")

local Screen = Device.screen

local HighlightManager = {
    STYLES = {
        UNDERLINE = "underline",
        BACKGROUND = "background",
        BOX = "box",
        INVERT = "invert",
    },
}

function HighlightManager:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.current_style = o.style or self.STYLES.INVERT
    o.is_highlighting = false
    o.current_word = nil
    -- For native crengine highlighting
    o._selection_active = false

    return o
end

function HighlightManager:setStyle(style)
    self.current_style = style
    if self.plugin then
        self.plugin:setSetting("highlight_style", style)
    end
end

function HighlightManager:getStyle()
    return self.current_style
end

--[[--
Highlight a sentence in the document using KOReader's native selection.

For EPUB (rolling/CreDocument): We call getTextFromPositions() which
internally tells crengine to draw a selection highlight over the text
range. This produces the standard blue/gray selection you see when
long-pressing text.

@param sentence table Sentence object with .text, .start_pos, .end_pos
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightSentence(sentence, parsed_data)
    if not sentence then return end
    if not self.ui or not self.ui.document then return end

    local doc = self.ui.document

    -- EPUB / rolling mode: use screen-coordinate selection
    if self.ui.rolling then
        self:_highlightSentenceRolling(sentence, parsed_data, doc)
    else
        -- PDF / paged mode: use view.highlight.temp
        self:_highlightSentencePaging(sentence, parsed_data, doc)
    end
end

--[[--
EPUB: Find the sentence on screen and have crengine draw the selection.

Strategy: getTextFromPositions() with two screen-coordinate points returns
the text and xpointer range. We need to find the screen position of the
sentence's first and last word. We do this by searching through the
visible text positions.

CRe snaps selections to word boundaries, and proportional fonts make
character-based x estimates unreliable.  We use a two-phase approach:
  1. Proportional char estimate as initial guess
  2. Binary-search refinement: query CRe, compare against expected text,
     adjust x inward (for overshoot) or outward (for undershoot)
This typically converges in 2-4 CRe calls — fast enough for e-ink.
--]]
function HighlightManager:_highlightSentenceRolling(sentence, parsed_data, doc, _retried)
    -- Clear any existing selection
    pcall(function() doc:clearSelection() end)

    local sent_text = Utils.ws(sentence.text)
    if sent_text == "" then return end

    -- ── Cached line map ──────────────────────────────────────────
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    local cache = self._line_cache
    local built_text, cum, sboxes, n

    if cache and cache.screen_w == cur_w and cache.screen_h == cur_h then
        built_text = cache.built_text
        cum        = cache.cum
        sboxes     = cache.sboxes
        n          = cache.n
    else
        -- Build fresh line map (expensive path — N document calls)
        local full_res = doc:getTextFromPositions(
            {x = 0, y = 0},
            {x = cur_w, y = cur_h},
            true
        )
        if not full_res or not full_res.pos0 or not full_res.pos1 then
            return
        end

        sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
        if not sboxes or #sboxes == 0 then return end
        n = #sboxes

        built_text = ""
        cum = {[0] = 0}
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
        end

        self._line_cache = {
            screen_w   = cur_w,
            screen_h   = cur_h,
            built_text = built_text,
            cum        = cum,
            sboxes     = sboxes,
            n          = n,
        }
    end

    -- Find the sentence in our built text
    local vis_start = built_text:find(sent_text, 1, true)
    if not vis_start then
        vis_start = built_text:find(sent_text:sub(1, math.min(40, #sent_text)), 1, true)
    end
    if not vis_start then
        if not _retried and self._line_cache then
            self._line_cache = nil
            return self:_highlightSentenceRolling(sentence, parsed_data, doc, true)
        end
        logger.dbg("HighlightManager: sentence not found:", sent_text:sub(1, 50))
        return
    end
    local vis_end = vis_start + #sent_text - 1

    -- Find start and end lines
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
    if not sb or not eb then return end

    -- ── Helper: proportional x estimate within a line ────────────
    local function estimateX(box, line_idx, char_off)
        local total = cum[line_idx] - cum[line_idx - 1]
        if total <= 0 then return box.x end
        local x = box.x + math.floor((char_off / total) * box.w)
        return math.max(box.x, math.min(box.x + box.w - 1, x))
    end

    -- ── Helper: query CRe selection (no-draw) ────────────────────
    local function querySelection(sx, sy, ex, ey)
        local r = doc:getTextFromPositions({x = sx, y = sy}, {x = ex, y = ey}, true)
        return r and r.text and Utils.ws(r.text) or ""
    end

    local start_y = sb.y + math.floor(sb.h / 2)
    local end_y   = eb.y + math.floor(eb.h / 2)

    -- ── Phase 1: Initial proportional estimates ──────────────────
    local sl_off = vis_start - cum[start_line - 1]
    local el_off = vis_end   - cum[end_line - 1]
    local start_x = estimateX(sb, start_line, sl_off)
    local end_x   = estimateX(eb, end_line, el_off)

    -- ── Phase 2: Binary-search refinement for end_x ──────────────
    -- CRe snaps to word boundaries.  If our end_x estimate is slightly
    -- past the last word of the sentence, CRe grabs the NEXT word too
    -- (overshoot).  If it's slightly before the period, CRe drops the
    -- last word (undershoot).  Binary-search to find the sweet spot.
    local function refineEndX(cur_sx, cur_sy, cur_ey)
        local got = querySelection(cur_sx, cur_sy, end_x, cur_ey)
        local got_len = #got
        local want_len = #sent_text

        if got_len == want_len and got == sent_text then
            return end_x  -- perfect match on first try
        end

        local lo, hi
        if got_len > want_len then
            -- Overshoot: pull end_x left.  Binary search [eb.x, end_x]
            hi = end_x
            lo = eb.x
        else
            -- Undershoot: push end_x right.  Binary search [end_x, eb.x+eb.w]
            lo = end_x
            hi = eb.x + eb.w - 1
        end

        local best_x = end_x
        local best_diff = math.abs(got_len - want_len)
        local MAX_ITER = 6  -- converges in ~log2(box.w/char_w) ≈ 5-6 steps
        for _ = 1, MAX_ITER do
            if hi - lo < 2 then break end
            local mid = math.floor((lo + hi) / 2)
            local mid_text = querySelection(cur_sx, cur_sy, mid, cur_ey)
            local mid_len = #mid_text
            local diff = math.abs(mid_len - want_len)

            if mid_text == sent_text then
                return mid  -- exact match
            elseif mid_len > want_len then
                -- Still overshooting, pull left
                hi = mid
            else
                -- Undershooting, push right
                lo = mid
            end

            if diff < best_diff or (diff == best_diff and mid_len <= want_len) then
                best_diff = diff
                best_x = mid
            end
        end
        return best_x
    end

    end_x = refineEndX(start_x, start_y, end_y)

    -- ── Phase 3: Refine start_x if sentence starts mid-line ──────
    -- Same problem: proportional estimate may land on wrong word.
    if sl_off > 1 then
        local got = querySelection(start_x, start_y, end_x, end_y)
        if got ~= sent_text then
            local got_start = got:sub(1, math.min(20, #got))
            local want_start = sent_text:sub(1, math.min(20, #sent_text))
            -- If the start is wrong, binary-search start_x
            if got_start ~= want_start then
                local lo = sb.x
                local hi = start_x + math.floor(sb.w * 0.3) -- don't search too far right
                hi = math.min(hi, sb.x + sb.w - 1)
                local best_x = start_x
                for _ = 1, 6 do
                    if hi - lo < 2 then break end
                    local mid = math.floor((lo + hi) / 2)
                    local mid_text = querySelection(mid, start_y, end_x, end_y)
                    local mid_start = mid_text:sub(1, math.min(20, #mid_text))
                    if mid_start == want_start then
                        best_x = mid
                        -- Tighten: try going right to find rightmost valid start
                        lo = mid
                    else
                        -- Selection start is wrong — go left to include more
                        hi = mid
                    end
                end
                start_x = best_x
                -- Re-refine end_x with corrected start_x
                end_x = refineEndX(start_x, start_y, end_y)
            end
        end
    end

    -- ── Draw the final selection ─────────────────────────────────
    local sel = doc:getTextFromPositions(
        {x = start_x, y = start_y},
        {x = end_x,   y = end_y},
        false  -- draw selection
    )

    if sel then
        self._selection_active = true
        self.is_highlighting = true
        UIManager:setDirty(self.ui.dialog or "all", "ui")
    end

    -- ── Diagnostic log (to /tmp, lightweight) ────────────────────
    local df = io.open("/tmp/highlight_diag.log", "a")
    if df then
        local got_ws = sel and sel.text and Utils.ws(sel.text) or ""
        local tag = (got_ws == sent_text) and "OK" or
                    (#got_ws > #sent_text and "OVER+" .. (#got_ws - #sent_text) or
                     "UNDER-" .. (#sent_text - #got_ws))
        df:write(string.format("S%d [%s] sx=%d ex=%d lines=%d-%d exp=[%.60s] got=[%.60s]\n",
            sentence.index, tag, start_x, end_x, start_line, end_line,
            sent_text, got_ws))
        df:close()
    end
end

--[[--
PDF: Use view.highlight.temp to draw temporary highlights.
--]]
function HighlightManager:_highlightSentencePaging(sentence, parsed_data, doc)
    logger.dbg("HighlightManager: PDF sentence highlight not yet implemented")
end

--[[--
Highlight a single word. Stores current word for reference;
actual visual highlighting is done at the sentence level to avoid
excessive e-ink refreshes.
@param word table Word object
@param parsed_data table Full parsed text data
--]]
function HighlightManager:highlightWord(word, parsed_data)
    self.current_word = word
    self.is_highlighting = true
end

--[[--
Clear all highlights.
--]]
function HighlightManager:clearHighlights()
    if self._selection_active and self.ui and self.ui.document then
        pcall(function() self.ui.document:clearSelection() end)
        UIManager:setDirty(self.ui.dialog or "all", "ui")
        self._selection_active = false
    end
    self.current_word = nil
    self.is_highlighting = false
end

function HighlightManager:clearWordHighlight()
    -- No separate word highlight to clear
end

function HighlightManager:clearSentenceHighlight()
    self:clearHighlights()
end

function HighlightManager:hasHighlights()
    return self.is_highlighting
end

function HighlightManager:getStyleMenu()
    local menu = {}
    local style_names = {
        { id = "invert", name = _("Invert (best for e-ink)") },
        { id = "underline", name = _("Underline") },
        { id = "box", name = _("Box") },
        { id = "background", name = _("Background") },
    }
    for _, style in ipairs(style_names) do
        table.insert(menu, {
            text = style.name,
            checked_func = function()
                return self.current_style == style.id
            end,
            callback = function()
                self:setStyle(style.id)
            end,
        })
    end
    return menu
end

function HighlightManager:updateHighlight(word, sentence, parsed_data)
    if not word then return end
    if self.current_word and self.current_word.index == word.index then
        return
    end
    self:highlightWord(word, parsed_data)
end

return HighlightManager
