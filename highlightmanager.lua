--[[--
Highlight Manager Module
Uses KOReader's native text selection to highlight the current sentence
being read by TTS. Works with both EPUB (CreDocument) and PDF.

For EPUB: Uses getTextFromPositions() with draw_selection enabled, which
lets crengine draw the selection highlight natively.

@module highlightmanager
--]]

local Blitbuffer = require("ffi/blitbuffer")
local Device = require("device")
local Geom = require("ui/geometry")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")

-- Shared utility modules (DRY: ws helper)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")

local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then
        pcall(DL.log, ...)
    end
end

local Screen = Device.screen

--[[--
Union of highlight box arrays, clamped to screen bounds.
Returns a Geom refresh region or nil when there is nothing to refresh.
--]]
local function boxesUnionRegion(arrays)
    local min_x, min_y, max_x, max_y
    for _, arr in ipairs(arrays) do
        if arr then
            for _, b in ipairs(arr) do
                local x2, y2 = b.x + b.w, b.y + b.h
                if not min_x or b.x < min_x then min_x = b.x end
                if not min_y or b.y < min_y then min_y = b.y end
                if not max_x or x2 > max_x then max_x = x2 end
                if not max_y or y2 > max_y then max_y = y2 end
            end
        end
    end
    if not min_x then return nil end
    local sw, sh = Screen:getWidth(), Screen:getHeight()
    min_x = math.max(0, min_x)
    min_y = math.max(0, min_y)
    max_x = math.min(sw, max_x)
    max_y = math.min(sh, max_y)
    if max_x <= min_x or max_y <= min_y then return nil end
    return Geom:new{x = min_x, y = min_y, w = max_x - min_x, h = max_y - min_y}
end

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

    o.current_style = o.style or self.STYLES.BACKGROUND
    o.is_highlighting = false
    o.current_word = nil
    -- For native crengine highlighting
    o._selection_active = false
    -- Pending boxes for non-invert styles, drawn by the view module
    o._pending_boxes = nil
    o._view_module_registered = false
    -- Boxes of the highlight currently on screen (and their page), used to
    -- limit the next e-ink refresh to the changed strip.
    o._last_boxes = nil
    o._last_boxes_page = nil

    return o
end

--[[--
Refresh the screen region covering the previous and new highlight boxes.
Pages containing images are refreshed dithered by KOReader (slow waveform),
so a full-page refresh there flashes visibly once per sentence; limiting
the update to the changed strip keeps those updates cheap and flash-free.
When no boxes are known, fall back to the caller's previous full refresh.
@param new_boxes table|nil Boxes of the newly drawn highlight
@param page number|nil Current page, used to drop stale boxes from the union
--]]
function HighlightManager:_refreshHighlight(new_boxes, page)
    local arrays = {}
    if self._last_boxes and self._last_boxes_page == page then
        table.insert(arrays, self._last_boxes)
    end
    if new_boxes and #new_boxes > 0 then
        table.insert(arrays, new_boxes)
    end
    local region = boxesUnionRegion(arrays)
    if region then
        -- Keep the e-ink refresh off the mini player / KOReader footer so
        -- sentence updates do not flash a second ghost bar at the bottom.
        local bar_top = self:_overlayBarTop()
        if bar_top and region.y + region.h > bar_top then
            region.h = math.max(0, bar_top - region.y)
        end
        if region.h > 0 then
            UIManager:setDirty(self.ui.dialog or "all", "ui", region)
        end
    end
    self._last_boxes = new_boxes
    self._last_boxes_page = page
end

function HighlightManager:_overlayBarTop()
    local p = self.plugin
    local bar = p and p.media_sync and p.media_sync.playback_bar
    if bar and bar._minimized then
        if bar.dimen and bar.dimen.y and bar.dimen.y > 0 then
            return bar.dimen.y
        end
        if bar._miniBarY then
            local ok, y = pcall(function() return bar:_miniBarY() end)
            if ok and type(y) == "number" and y > 0 then return y end
        end
    end
    return nil
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

    -- Always drop the previous highlight before searching for the new one;
    -- otherwise a sentence that is not visible on the current page would
    -- leave stale boxes that get mirrored at the wrong x,y.
    self._pending_boxes = nil
    self.is_highlighting = false

    local doc = self.ui.document

    -- EPUB / rolling mode: use screen-coordinate selection.
    -- Returns true when the sentence was found and highlighted on the
    -- visible page (callers use this for read-along page advancement).
    if self.ui.rolling then
        -- Storyteller / EPUB3 Media Overlays: prefer the SMIL fragment id
        -- (Readest-style) over fuzzy on-screen text matching.
        if sentence.fragment_id then
            local frag_ok = self:_highlightByFragmentId(doc, sentence.fragment_id, sentence)
            if frag_ok then return true end
            -- Same content document: CRe's #id index often misses Storyteller
            -- <span id> nested inside Word-exported <p>/<h1>, so fall back to
            -- a contiguous text match on this page. An other-document miss
            -- must still return false (#64) so page-advance can run instead
            -- of highlighting a look-alike sentence here.
            if self:_fragmentOnCurrentDoc(sentence) then
                dlog("hl-frag-roll", "id", tostring(sentence.fragment_id))
                return self:_highlightSentenceRolling(sentence, parsed_data, doc, nil, true)
            end
            return false
        end
        return self:_highlightSentenceRolling(sentence, parsed_data, doc)
    else
        -- PDF / paged mode: use view.highlight.temp
        return self:_highlightSentencePaging(sentence, parsed_data, doc)
    end
end

--- Folded word list for comparing CRe node text to a growing xpointer range.
local function foldedWords(s)
    local toks = Utils.tokenizeForAlign(s or "")
    local out = {}
    for i = 1, #toks do
        out[i] = toks[i].fold
    end
    return out
end

--- True when `drawn` is this SMIL element's text, or a visible prefix/slice
--- of it (sentence wrapping a page). False for an unrelated nearby phrase.
local function drawnBelongsToNode(drawn, want)
    if not drawn or drawn == "" or not want or want == "" then return false end
    if drawn == want then return true end
    local dw, ww = foldedWords(drawn), foldedWords(want)
    if #dw == 0 or #ww == 0 then return false end
    if #dw > #ww then return false end
    local n = math.min(#dw, #ww)
    for i = 1, n do
        if dw[i] ~= ww[i] then return false end
    end
    return true
end

--- Next SMIL fragment in the same content document (exclusive end clamp).
function HighlightManager:_nextSmilFragmentId(sentence)
    if not sentence or not sentence.fragment_id then return nil end
    local ms = self.plugin and self.plugin.media_sync
    local data = ms and ms.timing_data
    if not data then return nil end
    local idx = ms._current_sentence_idx
    local cur = idx and data[idx]
    if not (cur and cur.fragment_id == sentence.fragment_id) then
        cur, idx = nil, nil
        for i, e in ipairs(data) do
            if e.fragment_id == sentence.fragment_id
                and (not sentence.text_doc or e.text_doc == sentence.text_doc) then
                cur, idx = e, i
                break
            end
        end
    end
    if not idx then return nil end
    local nxt = data[idx + 1]
    if nxt and nxt.fragment_id and nxt.text_doc == (cur and cur.text_doc or sentence.text_doc) then
        return nxt.fragment_id
    end
    return nil
end

function HighlightManager:_currentDocFragmentIndex(doc)
    doc = doc or (self.ui and self.ui.document)
    if not doc or not doc.getXPointer then return nil end
    local xp
    pcall(function() xp = doc:getXPointer() end)
    return xp and tonumber((xp or ""):match("DocFragment%[(%d+)%]"))
end

--- True when the SMIL content document is the currently loaded DocFragment.
function HighlightManager:_fragmentOnCurrentDoc(sentence)
    if not sentence or not sentence.text_doc then return false end
    local n = self:_currentDocFragmentIndex()
    if not n then return false end
    local ms = self.plugin and self.plugin.media_sync
    local expected = ms and ms:_getExpectedDocFragmentIndex(sentence.text_doc)
    return expected ~= nil and expected == n
end

--- Resolve a SMIL fragment id to a CRe xpointer.
-- `#id` uses crengine's id index, which often omits inline Storyteller
-- spans. Attribute-path probes still match `[@id=...]` on the current
-- DocFragment (e.g. body/h1/span[@id='html28-s0']). Same probe list as
-- MediaSync:_tryGotoDocFragment.
function HighlightManager:_resolveFragmentXPointer(doc, fragment_id)
    if not doc or not fragment_id then return nil end
    local function try_xp(xp)
        local ok, nx = pcall(function() return doc:getNormalizedXPointer(xp) end)
        if ok and nx and nx ~= false then return nx end
        return nil
    end
    local hit = try_xp("#" .. fragment_id)
    if hit then return hit end
    local n = self:_currentDocFragmentIndex(doc)
    if not n then return nil end
    local nested = {
        "h1/span", "p/span", "div/span", "div/p/span",
        "h2/span", "h3/span", "blockquote/span",
    }
    local tags = {"span", "p", "div", "h1", "h2", "h3", "h4", "li", "td", "em", "strong", "a"}
    local bodies = {"body", "body.0"}
    for _, body in ipairs(bodies) do
        hit = try_xp(string.format("/body/DocFragment[%d]/%s/id('%s')", n, body, fragment_id))
        if hit then break end
        for _, path in ipairs(nested) do
            hit = try_xp(string.format("/body/DocFragment[%d]/%s/%s[@id='%s']", n, body, path, fragment_id))
            if hit then break end
        end
        if hit then break end
        for _, tag in ipairs(tags) do
            hit = try_xp(string.format("/body/DocFragment[%d]/%s/%s[@id='%s']", n, body, tag, fragment_id))
            if hit then break end
        end
        if hit then break end
    end
    if hit then
        dlog("hl-frag-xp", "id", tostring(fragment_id), "n", n)
    end
    return hit
end

--- Expand `#id` to the element's full text range (Readest `textRangeOf`).
-- CRe's `#id` xpointer is the element start; a collapsed xp0==xp1 only
-- selects a stub word, which then fell through to fuzzy page matching.
function HighlightManager:_fragmentTextRange(doc, fragment_id, sentence)
    local xp0 = self:_resolveFragmentXPointer(doc, fragment_id)
    if not xp0 then return nil end

    local node_text = ""
    pcall(function() node_text = doc:getTextFromXPointer(xp0) or "" end)
    node_text = Utils.normalizeForMatching(node_text)
    if node_text == "" and sentence and sentence.text then
        node_text = Utils.normalizeForMatching(sentence.text)
    end
    local want = foldedWords(node_text)

    if #want == 0 then
        -- No reference text to walk against: the word-walk below would run
        -- away to the document end. Use CRe's sentence-segment expansion.
        local a, b
        pcall(function() a, b = doc:extendXPointersToSentenceSegment(xp0, xp0) end)
        if a and b then return a, b, node_text end
        return xp0, xp0, node_text
    end

    local xp_limit = nil
    local next_id = self:_nextSmilFragmentId(sentence)
    if next_id and doc.getNormalizedXPointer then
        pcall(function()
            local nxp = doc:getNormalizedXPointer("#" .. next_id)
            if nxp and nxp ~= false then
                if doc.getPrevVisibleWordEnd then
                    xp_limit = doc:getPrevVisibleWordEnd(nxp)
                else
                    xp_limit = nxp
                end
            end
        end)
    end

    if xp_limit then
        local drawn = ""
        pcall(function() drawn = doc:getTextFromXPointers(xp0, xp_limit) or "" end)
        drawn = Utils.normalizeForMatching(drawn)
        if drawnBelongsToNode(drawn, node_text) then
            return xp0, xp_limit, node_text
        end
    end

    local xp1 = xp0
    if doc.getNextVisibleWordEnd then
        local last = xp0
        for _ = 1, 400 do
            local nxt
            pcall(function() nxt = doc:getNextVisibleWordEnd(last) end)
            if not nxt or nxt == last then break end
            if xp_limit and doc.compareXPointers then
                local cmp
                pcall(function() cmp = doc:compareXPointers(xp_limit, nxt) end)
                -- 1 = nxt is after the last word of this element
                if cmp == 1 then break end
            end
            local drawn = ""
            pcall(function() drawn = doc:getTextFromXPointers(xp0, nxt) or "" end)
            drawn = Utils.normalizeForMatching(drawn)
            local dw = foldedWords(drawn)
            if #dw > #want then break end
            local n = math.min(#dw, #want)
            local prefix_ok = n > 0
            for i = 1, n do
                if dw[i] ~= want[i] then
                    prefix_ok = false
                    break
                end
            end
            if not prefix_ok then break end
            xp1 = nxt
            last = nxt
            if #dw >= #want then break end
        end
    elseif xp_limit then
        xp1 = xp_limit
    end
    return xp0, xp1, node_text
end

--- Highlight a SMIL sentence via its DOM id (e.g. "html39-s12").
-- Mirrors Readest: the highlighted unit is the element the publisher marked,
-- not a nearby phrase found by searching the page.
function HighlightManager:_highlightByFragmentId(doc, fragment_id, sentence)
    if not doc or not fragment_id then return false end
    local xp0, xp1, node_text = self:_fragmentTextRange(doc, fragment_id, sentence)
    if not xp0 or not xp1 then
        dlog("hl-frag-miss", "id", tostring(fragment_id))
        return false
    end

    local drawn = ""
    pcall(function()
        drawn = doc:getTextFromXPointers(xp0, xp1, true) or ""
    end)
    drawn = Utils.normalizeForMatching(drawn)
    local want = node_text
    if want == "" and sentence and sentence.text then
        want = Utils.normalizeForMatching(sentence.text)
    end

    if want ~= "" and not drawnBelongsToNode(drawn, want) then
        dlog("hl-frag-mismatch", "id", tostring(fragment_id),
            "drawn_w", #foldedWords(drawn), "want_w", #foldedWords(want))
        pcall(function() doc:clearSelection() end)
        return false
    end
    if drawn == "" then
        pcall(function() doc:clearSelection() end)
        return false
    end

    -- Master used to report success whenever anything was drawn, even with
    -- no on-screen boxes; that suppressed page advance while painting
    -- nothing. Only a range with at least one visible box counts.
    local boxes
    pcall(function()
        boxes = doc:getScreenBoxesFromPositions(xp0, xp1, true)
    end)
    local on_screen = 0
    if boxes then
        local sw, sh = Screen:getWidth(), Screen:getHeight()
        for _, b in ipairs(boxes) do
            if b.w and b.h and b.w > 0 and b.h > 0
                and b.x < sw and b.y < sh and (b.x + b.w) > 0 and (b.y + b.h) > 0 then
                on_screen = on_screen + 1
            end
        end
    end
    if on_screen == 0 then
        pcall(function() doc:clearSelection() end)
        dlog("hl-frag-offpage", "id", tostring(fragment_id))
        return false
    end

    self._selection_active = true
    self.is_highlighting = true
    self._pending_boxes = nil
    if self.current_style ~= self.STYLES.INVERT then
        self._pending_boxes = boxes
        self:_ensureViewModule()
        pcall(function() doc:clearSelection() end)
        self._selection_active = false
    end
    dlog("hl-frag", "drawn_w", #foldedWords(drawn), "want_w", #foldedWords(want),
        "nbox", on_screen, "id", tostring(fragment_id))
    self:_refreshHighlight(boxes, doc:getCurrentPage())
    return true
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
function HighlightManager:_highlightSentenceRolling(sentence, parsed_data, doc, _retried, contiguous_only)
    -- Clear any existing selection
    pcall(function() doc:clearSelection() end)

    -- Normalize sentence text for matching: collapse whitespace, normalize
    -- common Unicode punctuation that getTextFromPositions() may return
    -- differently, and undo apostrophe-run escaping in SMIL text.
    local sent_text = Utils.normalizeForMatching(sentence.text)
    if sent_text == "" then return end

    -- ── Cached line map ──────────────────────────────────────────
    local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
    -- Include the current page in the cache key so a page turn invalidates
    -- the cached text/geometry; otherwise highlights can be drawn at stale
    -- x,y coordinates after the view changes.
    local cur_page = self.ui.document:getCurrentPage() or 0
    -- Crop the mini-player strip so words hidden under it are not treated
    -- as on-screen (that clipped the visible last word and delayed page follow).
    local bar_h = self.plugin and self.plugin.media_sync
        and self.plugin.media_sync._reserved_mini_bar_h or 0
    local crop_h = cur_h
    if bar_h > 0 then
        crop_h = math.max(1, cur_h - bar_h)
    end
    local cache = self._line_cache
    local built_text, cum, sboxes, n

    if cache and cache.screen_w == cur_w and cache.screen_h == cur_h
        and cache.page == cur_page and cache.crop_h == crop_h then
        built_text = cache.built_text
        cum        = cache.cum
        sboxes     = cache.sboxes
        n          = cache.n
    else
        -- Build fresh line map (expensive path — N document calls)
        local full_res = doc:getTextFromPositions(
            {x = 0, y = 0},
            {x = cur_w, y = crop_h},
            true
        )
        if not full_res or not full_res.pos0 or not full_res.pos1 then
            return
        end

        sboxes = doc:getScreenBoxesFromPositions(full_res.pos0, full_res.pos1, true)
        if not sboxes or #sboxes == 0 then return end
        n = #sboxes

        -- Pad each line box so the first/last glyph is not clipped, and
        -- prefer the full rectangle text for matching (it still has those words).
        local line_texts = {}
        local pad = 8
        for i = 1, n do
            local box = sboxes[i]
            local r = doc:getTextFromPositions(
                {x = math.max(0, box.x - pad), y = box.y + math.floor(box.h / 2)},
                {x = math.min(cur_w - 1, box.x + box.w - 1 + pad),
                 y = box.y + math.floor(box.h / 2)},
                true)
            line_texts[i] = (r and r.text) and Utils.normalizeForMatching(r.text) or ""
        end
        local full_norm = Utils.normalizeForMatching(full_res.text or "")
        built_text = ""
        cum = {[0] = 0}
        if full_norm ~= "" then
            built_text = full_norm
            local search = 1
            for i = 1, n do
                local lt = line_texts[i]
                if lt ~= "" then
                    local p = built_text:find(lt, search, true)
                    if p then
                        cum[i] = p + #lt - 1
                        search = p + 1
                    else
                        cum[i] = cum[i - 1] + #lt
                    end
                else
                    cum[i] = cum[i - 1]
                end
            end
            if cum[n] < #built_text then
                cum[n] = #built_text
            end
        else
            for i = 1, n do
                local lt = line_texts[i]
                if i > 1 and lt ~= "" then
                    built_text = built_text .. " "
                end
                built_text = built_text .. lt
                cum[i] = #built_text
            end
        end

        self._line_cache = {
            screen_w   = cur_w,
            screen_h   = cur_h,
            crop_h     = crop_h,
            page       = cur_page,
            built_text = built_text,
            cum        = cum,
            sboxes     = sboxes,
            n          = n,
        }
    end

    -- Find the sentence in our built text. Exact substring first (tightest
    -- boxes when it hits), then a word-level aligner that bookends the first
    -- and last matching words so a hyphenation/elision hole does not drop
    -- the start or end of the visible phrase, then prefix/suffix or
    -- word-range fallbacks.
    local sent_words = Utils.splitWords(sent_text)
    local vis_start, vis_end, matched_len
    local first_w, last_w

    vis_start = built_text:find(sent_text, 1, true)
    if vis_start then
        matched_len = #sent_text
        vis_end = vis_start + matched_len - 1
    end

    if not vis_start and not contiguous_only then
        local a, b
        first_w, last_w, a, b = Utils.alignSentenceOnPage(sent_words, built_text)
        local span = (first_w and last_w) and (last_w - first_w + 1) or 0
        if span <= 1 and #sent_words > 3 then
            first_w, last_w, span = nil, nil, 0
        end
        if first_w and a and b and b >= a then
            vis_start = a
            vis_end = b
            matched_len = vis_end - vis_start + 1
        end
    end

    if not vis_start then
        local i, j
        if contiguous_only then
            -- Overlay same-document fallback: only a real prefix (this page
            -- has the sentence start) or a suffix (page-wrap tail). A middle
            -- coincidence paints a random phrase on a page the user flipped
            -- to. Require 3 words on the prefix side: a one-word match
            -- ("The", "Il") would otherwise suppress page advance while
            -- narration walks off the page (#64 within one content document).
            local prefix_n = Utils.sentencePrefixOnPage(sent_words, built_text)
            if prefix_n >= math.min(3, #sent_words) then
                i, j = 1, prefix_n
            else
                local suffix_n = Utils.sentenceSuffixOnPage(sent_words, built_text)
                if suffix_n >= 2 or (#sent_words <= 3 and suffix_n > 0) then
                    i, j = #sent_words - suffix_n + 1, #sent_words
                end
            end
        else
            i, j = Utils.visibleSentenceWordRange(sent_words, built_text)
            local span = (i and j) and (j - i + 1) or 0
            local min_span = math.min(4, #sent_words)
            if span < min_span then
                i, j = nil, nil
            end
        end
        if i and j and j >= i then
            local phrase = table.concat(sent_words, " ", i, j)
            vis_start = built_text:find(phrase, 1, true)
            if vis_start then
                vis_end = vis_start + #phrase - 1
                matched_len = #phrase
                first_w, last_w = i, j
            end
        end
    end
    if not vis_start then
        if not _retried and self._line_cache then
            self._line_cache = nil
            return self:_highlightSentenceRolling(sentence, parsed_data, doc, true, contiguous_only)
        end
        logger.dbg("HighlightManager: sentence not found:", sent_text:sub(1, 80))
        dlog("hl-roll-miss", "sent_words", #sent_words, "built_n", #built_text,
            "contiguous", contiguous_only and 1 or 0)
        return
    end
    if not vis_end then
        vis_end = vis_start + matched_len - 1
    end

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
        return r and r.text and Utils.normalizeForMatching(r.text) or ""
    end

    local start_y = sb.y + math.floor(sb.h / 2)
    local end_y   = eb.y + math.floor(eb.h / 2)

    -- ── Phase 1: Initial proportional estimates ──────────────────
    local sl_off = vis_start - cum[start_line - 1]
    local el_off = vis_end   - cum[end_line - 1]
    -- sl_off is 1-based char offset within the line.  For the start
    -- position we want the LEFT edge of that character, so subtract 1
    -- to convert to 0-based.  For end we want the RIGHT edge, so the
    -- 1-based offset maps directly to "fraction of line covered".
    local start_x = estimateX(sb, start_line, math.max(0, sl_off - 1))
    local end_x   = estimateX(eb, end_line, el_off)

    -- Visible slice only: using the full SMIL string here dropped the last
    -- on-page word (undershoot) or grabbed the next sentence (overshoot).
    local want_text = built_text:sub(vis_start, vis_end)
    if want_text == "" then want_text = sent_text end
    local want_len = #want_text

    -- ── Phase 2: Binary-search refinement for end_x ──────────────
    -- CRe snaps to word boundaries.  Prefer covering the visible slice
    -- (allow a little punctuation overshoot) over dropping the last word.
    local function refineEndX(cur_sx, cur_sy, cur_ey)
        local function scoreOf(text)
            local len = #text
            if text == want_text then return 0 end
            if len >= want_len and len <= want_len + 6 then
                return 1 + (len - want_len)
            end
            if len < want_len then
                return 100 + (want_len - len)
            end
            return 200 + (len - want_len)
        end

        local best_x = end_x
        local best_score = scoreOf(querySelection(cur_sx, cur_sy, end_x, cur_ey))
        if best_score == 0 then return end_x end

        local lo, hi = eb.x, eb.x + eb.w - 1
        for _ = 1, 8 do
            if hi - lo < 2 then break end
            local mid = math.floor((lo + hi) / 2)
            local mid_text = querySelection(cur_sx, cur_sy, mid, cur_ey)
            local score = scoreOf(mid_text)
            if score < best_score then
                best_score = score
                best_x = mid
            end
            if mid_text == want_text then
                return mid
            elseif #mid_text > want_len then
                -- Still overshooting, pull left
                hi = mid
            else
                -- Undershooting, push right
                lo = mid
            end
        end
        return best_x
    end

    end_x = refineEndX(start_x, start_y, end_y)

    -- ── Phase 3: Always refine start_x ───────────────────────────
    -- CRe word-snap can drop the first narrated word even when the
    -- proportional estimate sits at the left edge of the line.
    do
        local want_start = want_text:sub(1, math.min(20, #want_text))
        local got = querySelection(start_x, start_y, end_x, end_y)
        local got_start = got:sub(1, math.min(20, #got))
        if got_start ~= want_start then
            local lo = sb.x
            local hi = math.min(sb.x + sb.w - 1, start_x + math.floor(sb.w * 0.3))
            local best_x = start_x
            for _ = 1, 8 do
                if hi - lo < 2 then break end
                local mid = math.floor((lo + hi) / 2)
                local mid_text = querySelection(mid, start_y, end_x, end_y)
                local mid_start = mid_text:sub(1, math.min(20, #mid_text))
                if mid_start == want_start then
                    best_x = mid
                    -- Leftmost pixel that still selects the correct first
                    -- word, so the highlight box covers the full first word.
                    hi = mid
                else
                    -- Went too far left (includes previous word) — go right
                    lo = mid
                end
            end
            start_x = best_x
            -- Re-refine end_x with corrected start_x
            end_x = refineEndX(start_x, start_y, end_y)
        end
    end

    -- ── Draw the final selection ─────────────────────────────────
    -- Try CRe-accurate boxes first: make a final getTextFromPositions
    -- call with the refined coordinates, get xpointers, then use
    -- getScreenBoxesFromPositions for pixel-perfect word-boundary-aligned
    -- boxes.  Falls back to line-map estimation if CRe query fails.
    local boxes
    local cre_len = 0
    local final_res = doc:getTextFromPositions(
        {x = start_x, y = start_y},
        {x = end_x,   y = end_y},
        true)
    if final_res and final_res.pos0 and final_res.pos1 then
        -- Guard: only use CRe boxes if the selected text matches the
        -- sentence length.  If CRe snapped to a wider word boundary
        -- the boxes would visually overflow into the next sentence.
        -- Cover the visible slice; reject a dropped last word and a grab
        -- of the next sentence.
        local cre_text = final_res.text and Utils.normalizeForMatching(final_res.text) or ""
        cre_len = #cre_text
        local len_ok = #cre_text >= want_len - 2 and #cre_text <= want_len + 6
        if len_ok then
            local cre_boxes = doc:getScreenBoxesFromPositions(
                final_res.pos0, final_res.pos1, true)
            if cre_boxes and #cre_boxes > 0 then
                boxes = {}
                for _, cb in ipairs(cre_boxes) do
                    if cb.w > 0 and cb.h > 0 then
                        table.insert(boxes, {x = cb.x, y = cb.y, w = cb.w, h = cb.h})
                    end
                end
                if #boxes == 0 then boxes = nil end
            end
        end
    end
    -- Fallback: compute boxes from line map with estimated pixel coords
    if not boxes then
        boxes = {}
        for i = start_line, end_line do
            local box = sboxes[i]
            local bx, bw = box.x, box.w
            if i == start_line and i == end_line then
                bx = start_x
                bw = end_x - start_x
            elseif i == start_line then
                bw = (box.x + box.w) - start_x
                bx = start_x
            elseif i == end_line then
                bw = end_x - box.x
            end
            if bw > 0 and box.h > 0 then
                table.insert(boxes, {x = bx, y = box.y, w = bw, h = box.h})
            end
        end
    end
    if #boxes > 0 then
        self._pending_boxes = boxes
        self:_ensureViewModule()
        self.is_highlighting = true
        self:_refreshHighlight(boxes, cur_page)
        dlog("hl-roll", "sent_words", #sent_words, "span", first_w, last_w, "mlen", matched_len, "want", want_len, "lines", start_line, end_line, "nbox", #boxes, "cre_n", cre_len or 0)
        return true
    end
end

--[[--
Register a view module so our paintTo runs after page content is drawn.
This is necessary because painting directly onto Screen.bb before the
repaint cycle causes the page redraw to overwrite our rectangles.
--]]
function HighlightManager:_ensureViewModule()
    if self._view_module_registered then return end
    if not self.ui or not self.ui.view then return end
    -- Create a minimal view module that delegates paintTo to us
    local hm = self
    local module = { paintTo = function(_, bb, x, y) hm:_paintOverlay(bb, x, y) end }
    self.ui.view:registerViewModule("audiobook_highlight", module)
    self._view_module_registered = true
end

--[[--
Called by the view module after page content is drawn.
Paints highlight rectangles for all styles (including invert).
@param bb BlitBuffer The screen framebuffer
--]]
function HighlightManager:_paintOverlay(bb, _x, _y)
    local boxes = self._pending_boxes
    if not boxes or #boxes == 0 then return end
    if not bb then return end
    local style = self.current_style
    local line_w = Screen:scaleBySize(2)
    local sw, sh = Screen:getWidth(), Screen:getHeight()

    for _, box in ipairs(boxes) do
        -- Clip to screen bounds to prevent out-of-range framebuffer access
        local bx = math.max(0, box.x)
        local by = math.max(0, box.y)
        local bw = math.min(box.w - (bx - box.x), sw - bx)
        local bh = math.min(box.h - (by - box.y), sh - by)
        if bw > 0 and bh > 0 then
            if style == self.STYLES.INVERT then
                pcall(function() bb:invertRect(bx, by, bw, bh) end)
            elseif style == self.STYLES.UNDERLINE then
                bb:paintRect(bx, by + bh - line_w, bw, line_w,
                    Blitbuffer.COLOR_BLACK)
            elseif style == self.STYLES.BACKGROUND then
                -- Match KOReader's native "lighten" highlight style:
                -- darkenRect dims existing pixels by a factor (0.2 = 20%),
                -- producing the same smooth gray overlay used for bookmarks.
                bb:darkenRect(bx, by, bw, bh, 0.2)
            elseif style == self.STYLES.BOX then
                -- Top
                bb:paintRect(bx, by, bw, line_w, Blitbuffer.COLOR_BLACK)
                -- Bottom
                bb:paintRect(bx, by + bh - line_w, bw, line_w,
                    Blitbuffer.COLOR_BLACK)
                -- Left
                bb:paintRect(bx, by, line_w, bh, Blitbuffer.COLOR_BLACK)
                -- Right
                bb:paintRect(bx + bw - line_w, by, line_w, bh,
                    Blitbuffer.COLOR_BLACK)
            end
        end
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
        self._selection_active = false
    end
    self._pending_boxes = nil
    if self.is_highlighting then
        -- Refresh only the strip where the highlight was drawn.
        self:_refreshHighlight(nil, self._last_boxes_page)
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
