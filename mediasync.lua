--[[--
MediaSync Controller -- Synchronization loop for pre-recorded audio playback.
Maps audio time position to text positions for synchronized highlighting.
Mirrors SyncController patterns but without TTS synthesis or sentence prefetch.

@module koplugin.audiobook.mediasync
--]]

local Device = require("device")
local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local Screen = require("device").screen
local time = require("ui/time")
local _ = require("audiobook_gettext")
local Geom = require("ui/geometry")
local InfoMessage = require("ui/widget/infomessage")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local PLUGIN_PATH = _utils_dir
local Utils = dofile(_utils_dir .. "utils.lua")

--- Append to plugin debug.log (included in bug reports). Never throws.
local function dlog(...)
    local DL = package.loaded["audiobook_debuglog"]
    if DL and DL.log then
        pcall(DL.log, ...)
    end
end

local MediaSync = {
    STATE = {
        STOPPED = "stopped",
        PLAYING = "playing",
        PAUSED = "paused",
        LOADING = "loading",
    },
}

function MediaSync:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.state = self.STATE.STOPPED
    o.timing_data = nil
    o.chapters = nil
    o.playback_bar = nil
    o.playlist_files = nil
    o.current_playlist_idx = nil
    o.is_shuffled = false
    o._original_playlist = nil
    o.loop_enabled = true

    -- Current playback position tracking
    o._current_sentence_idx = 0
    o._current_word_idx = 0
    o._total_sentences = 0
    o._sync_timer = nil
    o._position_timer = nil
    o._chain_generation = 0

    -- UI update throttling
    o._last_progress_pct = -1
    o._last_ui_update_time = nil

    -- Audiobookshelf tracking (set by main.lua when playing ABS items)
    o._abs_item_id = nil
    o._abs_duration = nil

    return o
end

-- Auto-follow guard: a counter.  It is incremented before every page turn we
-- initiate ourselves and decremented after the resulting page update has had
-- time to fire, so any PageUpdate caused by our navigation is recognised as
-- auto-follow and does not trigger a manual-turn seek.
function MediaSync:_markPageFollowAuto()
    if not self.plugin then return end
    self.plugin._media_sync_page_follow_count = (self.plugin._media_sync_page_follow_count or 0) + 1
end

function MediaSync:_clearPageFollowAuto()
    if not self.plugin then return end
    self.plugin._media_sync_page_follow_count = math.max(0, (self.plugin._media_sync_page_follow_count or 0) - 1)
end

-- Navigate to a SMIL fragment.
--
-- Why "Play aligned audiobook from here" usually works on the first try:
-- the user selects text on the page that is currently visible, so the target
-- fragment is in the currently loaded EPUB content document.  In that case
-- `ui.document:isXPointerInDocument("#id")` is true and a simple
-- `ui.rolling:onGotoXPointer("#id")` scrolls to it.
--
-- Resume/refocus are harder because the saved/current sentence may be in a
-- different content document.  crengine does not expose a direct
-- "go to file#id" API from Lua, and `gotoLink` only follows actual `<a>`
-- links in the current document.  We therefore use a small set of strategies:
--
-- 1. If we have already resolved the full internal xpointer (cached during
--    a previous visit), jump directly with it.
-- 2. If the fragment is in the current content document, scroll directly.
-- 3. If `allow_scan` is true, try to find the content document through the
--    EPUB table of contents and jump with a full internal xpointer.
-- 4. If `allow_scan` is true, use the EPUB spine order to derive the
--    DocFragment index and jump with a full internal xpointer.
-- 5. As a last resort, search the document text for the sentence itself and
--    use the resulting xpointer to jump.  This is slower but reliable even
--    when the fragment id cannot be resolved globally.
--
-- Auto-follow does NOT scan; it only uses strategies 1, 2, and 4 (when the
-- index is already built).  If the sentence is not yet visible it falls back
-- to the existing `GotoViewRel(1)` page-advance retry, which avoids the cost
-- and side effects of text search.
function MediaSync:_gotoSmilFragment(text_doc, fragment_id, allow_scan, sentence_text)
    allow_scan = (allow_scan ~= false)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document then return false end
    if not fragment_id then return false end

    local xp = "#" .. fragment_id
    local raw_xp = (text_doc and text_doc ~= "" and text_doc .. "#" .. fragment_id) or xp
    local cache_key = text_doc and text_doc ~= "" and raw_xp or xp

    if not sentence_text or sentence_text == "" then
        sentence_text = self:_lookupSentenceText(text_doc, fragment_id)
    end

    local function scroll_to_fragment(target_xp)
        target_xp = target_xp or xp
        if not ui.rolling then return false end
        local before = ui.document:getXPointer()
        local ok = pcall(function()
            ui.rolling:onGotoXPointer(target_xp)
        end)
        local after = ui.document:getXPointer()
        if ok then
            logger.warn("MediaSync: onGotoXPointer", target_xp,
                "before", tostring(before), "after", tostring(after))
            UIManager:setDirty("all", "partial")
            return true
        end
        return false
    end

    local function fragment_in_document()
        local ok, in_doc = pcall(function()
            return ui.document:isXPointerInDocument(xp)
        end)
        return ok and in_doc
    end

    local function cache_current_xpointer()
        local ok, norm = pcall(function()
            return ui.document:getNormalizedXPointer(xp)
        end)
        if ok and norm and norm ~= false then
            self:_cacheXPointer(text_doc, fragment_id, norm)
            logger.warn("MediaSync: cached xpointer", norm, "for", cache_key)
        end
    end

    -- 1. Cached full xpointer from a previous visit.
    if self._xpointer_cache and self._xpointer_cache[cache_key] then
        local cached = self._xpointer_cache[cache_key]
        logger.warn("MediaSync: using cached xpointer", cached, "for", cache_key)
        local ok = pcall(function()
            ui.rolling:_gotoXPointer(cached)
        end)
        if ok then
            UIManager:setDirty("all", "ui")
            return true
        end
        -- Stale cache (book layout changed); drop it and continue.
        logger.warn("MediaSync: cached xpointer failed, dropping", cache_key)
        self._xpointer_cache[cache_key] = nil
    end

    -- 2. Same-document: scroll directly and cache the resolved full xpointer.
    if fragment_in_document() then
        logger.warn("MediaSync: fragment", xp, "is in current document")
        cache_current_xpointer()
        return scroll_to_fragment()
    end

    -- Remember where we started so we can restore if every cross-document
    -- strategy fails.
    local start_page = ui.document:getCurrentPage()

    local function try_page(page)
        if not page or page <= 0 then return false end
        local ok = pcall(function()
            ui.rolling:_gotoPage(page)
        end)
        if ok and fragment_in_document() then
            cache_current_xpointer()
            scroll_to_fragment()
            UIManager:setDirty("all", "ui")
            return true
        end
        return false
    end

    local function restore_start_page()
        pcall(function() ui.document:gotoPage(start_page, false) end)
    end

    if not allow_scan then
        return false
    end

    -- 3. Spine DocFragment jump (reliable for Storyteller EPUBs): use the EPUB
    -- spine order to know which DocFragment contains the target document.
    if self:_gotoViaSpineDocFragment(text_doc, fragment_id, start_page) then
        cache_current_xpointer()
        if fragment_in_document() then
            scroll_to_fragment()
            UIManager:setDirty("all", "ui")
            return true
        end
        -- Same chapter, different page: #id often still does not resolve.
        -- Fall through to findText instead of claiming success on the wrong page.
    end

    -- 4. getPageFromXPointer probe (skip page 1 — bogus on Kindle).
    local ok_fp, page_fp = pcall(function()
        return ui.document:getPageFromXPointer(xp)
    end)
    if ok_fp and page_fp and page_fp > 1 and page_fp ~= start_page then
        logger.warn("MediaSync: getPageFromXPointer page", page_fp, "for", xp)
        if try_page(page_fp) then
            return true
        end
        pcall(function() ui.document:gotoPage(start_page, false) end)
    end

    -- 5. TOC fallback: match the content document's chapter title against the
    -- EPUB table of contents, derive the DocFragment index from the TOC
    -- xpointer, and jump to the fragment with a full internal xpointer.
    if allow_scan then
        if self:_gotoViaToc(text_doc, fragment_id, start_page) then
            cache_current_xpointer()
            if fragment_in_document() then
                scroll_to_fragment()
                UIManager:setDirty("all", "ui")
                return true
            end
        end
    end

    -- 6. Text-search fallback: search the whole rendered book for the sentence
    -- text.  crengine cannot resolve a plain fragment id to a global page on
    -- this device, but findText returns full internal xpointers that usually
    -- can be followed.  We accept an occurrence whose DocFragment index matches
    -- the target content document and navigate with its full xpointer.
    if allow_scan and sentence_text and sentence_text ~= "" then
        local search_key = self:_normalizeSearchText(sentence_text)
        -- Long sentences may differ in trailing punctuation between SMIL and
        -- rendered text; search for a prefix that is still distinctive.
        local short_key = search_key
        if #short_key > 120 then
            short_key = short_key:sub(1, 120)
        end
        local cur_page = ui.document:getCurrentPage() or 1

        local function try_search(pattern, origin, direction)
            if not pattern or pattern == "" then return nil end
            local ok, res, words = pcall(function()
                return ui.document:findText(pattern, origin, direction, true, cur_page, false, 20)
            end)
            local brief = #pattern > 40 and pattern:sub(1, 40) .. "…" or pattern
            if not ok then
                logger.warn("MediaSync: findText error",
                    "pattern=", brief, "dir=", direction, "err=", tostring(res))
                return nil
            end
            if res and #res > 0 then
                logger.warn("MediaSync: findText hit",
                    "pattern=", brief, "dir=", direction,
                    "count=", #res, "words=", tostring(words))
                return res
            end
            logger.dbg("MediaSync: findText miss",
                "pattern=", brief, "dir=", direction)
            return nil
        end

        local results = nil
        -- Try forward from current position, then backward, for full and prefixes.
        local prefixes = {}
        if #search_key > 50 then table.insert(prefixes, search_key:sub(1, 50)) end
        if #search_key > 30 then table.insert(prefixes, search_key:sub(1, 30)) end
        for _, key in ipairs({short_key, unpack(prefixes)}) do
            results = try_search(key, 0, 0) or try_search(key, 0, 1)
            if results then break end
        end
        -- Also try the upstream "from start" origin in case it works here.
        if not results then
            results = try_search(short_key, -1, 0)
        end

        if results then
            local expected_n = self:_getExpectedDocFragmentIndex(text_doc)
            logger.warn("MediaSync: text-search expected DocFragment", expected_n,
                "for", text_doc)
            for i, r in ipairs(results) do
                local start_xp = r and r.start
                if start_xp then
                    local r_n = tonumber(start_xp:match("DocFragment%[(%d+)%]"))
                    local in_target = (expected_n and r_n == expected_n) or not expected_n
                    if in_target then
                        logger.warn("MediaSync: text-search occurrence", i,
                            "DocFragment", r_n, start_xp)
                        local before_page = ui.document:getCurrentPage()
                        local ok_goto = pcall(function()
                            ui.rolling:onGotoXPointer(start_xp, start_xp)
                        end)
                        local after_page = ui.document:getCurrentPage()
                        logger.warn("MediaSync: text-search onGotoXPointer",
                            "ok=", tostring(ok_goto),
                            "page_before=", before_page, "page_after=", after_page)
                        if ok_goto and after_page then
                cache_current_xpointer()
                if fragment_in_document() then scroll_to_fragment() end
                UIManager:setDirty("all", "ui")
                return true
            end
                    end
                end
            end
            logger.warn("MediaSync: text-search occurrences did not navigate to target", fragment_id)
        end
    end

    restore_start_page()
    logger.warn("MediaSync: fragment", fragment_id, "not reachable in", text_doc)
    return false
end

-- Look up the sentence text for a fragment so we can use it as a search key.
function MediaSync:_lookupSentenceText(text_doc, fragment_id)
    if not self.timing_data then return nil end
    for _, e in ipairs(self.timing_data) do
        if e.fragment_id == fragment_id and (not text_doc or e.text_doc == text_doc) and e.text then
            return e.text
        end
    end
    return nil
end

-- Normalize sentence text before handing it to crengine's findText.  The
-- extracted SMIL text and the rendered text can differ in whitespace,
-- punctuation, and zero-width characters.
function MediaSync:_normalizeSearchText(text)
    return Utils.normalizeForMatching(text)
end

-- Check whether a fragment id is resolvable in the currently loaded content
-- document.
function MediaSync:_fragmentInDocument(fragment_id)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not fragment_id then return false end
    local xp = "#" .. fragment_id
    local ok, in_doc = pcall(function()
        return ui.document:isXPointerInDocument(xp)
    end)
    return ok and in_doc
end

-- Check whether a fragment id is resolvable in the currently loaded content
-- document.
function MediaSync:_fragmentInDocument(fragment_id)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not fragment_id then return false end
    local xp = "#" .. fragment_id
    local ok, in_doc = pcall(function()
        return ui.document:isXPointerInDocument(xp)
    end)
    return ok and in_doc
end

-- Try to jump to the content document that contains a SMIL fragment by using
-- the EPUB table of contents.  The SMIL parser already loaded a mapping from
-- content-document basename to chapter title; we match that title against the
-- entries returned by `ui.document:getToc()` and jump to the corresponding
-- page or xpointer.
function MediaSync:_gotoViaToc(text_doc, fragment_id, start_page)
    local ui = self.plugin and self.plugin.ui
    local parser = self.plugin and self.plugin._smil_parser
    if not ui or not ui.document or not parser or not text_doc then return false end
    local basename = text_doc:match("([^/]+)$")
    if not basename then return false end
    local chapter_title = parser._chapter_titles and parser._chapter_titles[basename]
    if not chapter_title or chapter_title == "" then
        logger.warn("MediaSync: no chapter title for", basename)
        return false
    end
    local ok_toc, toc = pcall(function() return ui.document:getToc() end)
    if not ok_toc or not toc or #toc == 0 then
        logger.warn("MediaSync: no TOC available")
        return false
    end
    local norm_target = self:_normalizeSearchText(chapter_title):lower()
    for _, entry in ipairs(toc) do
        if entry and entry.title then
            local norm_entry = self:_normalizeSearchText(entry.title):lower()
            local matched = (norm_entry == norm_target)
                or norm_entry:find(norm_target, 1, true)
                or norm_target:find(norm_entry, 1, true)
            if matched then
                logger.warn("MediaSync: TOC title match", entry.title,
                    "page=", entry.page, "xpointer=", entry.xpointer, "for", text_doc)
                -- The TOC xpointer tells us exactly which DocFragment the
                -- chapter starts in. Build a full xpointer to the fragment
                -- inside that DocFragment and jump directly.
                local toc_n = entry.xpointer and tonumber(entry.xpointer:match("DocFragment%[(%d+)%]"))
                if toc_n then
                    local ok_frag, norm = self:_tryGotoDocFragment(text_doc, fragment_id, toc_n, start_page)
                    if ok_frag then
                        logger.warn("MediaSync: TOC DocFragment jump succeeded for", fragment_id, norm)
                        return true
                    end
                end
                -- Legacy page/xpointer fallback.
                local page = entry.page
                if page and page > 0 then
                    local ok = pcall(function() ui.document:gotoPage(page, true) end)
                    if ok and self:_fragmentInDocument(fragment_id) then
                        logger.warn("MediaSync: TOC page jump succeeded for", fragment_id)
                        return true
                    end
                end
                local xp = entry.xpointer
                if xp then
                    local ok = pcall(function() ui.document:gotoXPointer(xp) end)
                    if ok and self:_fragmentInDocument(fragment_id) then
                        logger.warn("MediaSync: TOC xpointer jump succeeded for", fragment_id)
                        return true
                    end
                end
            end
        end
    end
    logger.warn("MediaSync: TOC fallback failed for", text_doc, fragment_id)
    return false
end

-- Try to jump to a specific fragment inside a known DocFragment.  We build
-- full internal xpointers and use onGotoXPointer so crengine resolves the
-- target page/position from the absolute path instead of the plain "#id",
-- which this device maps to page 1 when the fragment is not in the current
-- content document.
function MediaSync:_tryGotoDocFragment(text_doc, fragment_id, docfrag_n, start_page)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not docfrag_n or not fragment_id then return false end
    local doc = ui.document
    -- Direct-child tag[@id] misses Storyteller spans nested in <h1>/<p>
    -- (Word-exported AlexandriZ HTML). Nested paths first.
    local nested = {
        "h1/span", "p/span", "div/span", "div/p/span",
        "h2/span", "h3/span", "blockquote/span",
    }
    local tags = {"span", "p", "div", "h1", "h2", "h3", "h4", "li", "td", "em", "strong", "a"}
    local bodies = {"body", "body.0"}
    local probes = {}
    for _, body in ipairs(bodies) do
        table.insert(probes, string.format("/body/DocFragment[%d]/%s/id('%s')", docfrag_n, body, fragment_id))
        for _, path in ipairs(nested) do
            table.insert(probes, string.format("/body/DocFragment[%d]/%s/%s[@id='%s']",
                docfrag_n, body, path, fragment_id))
        end
        for _, tag in ipairs(tags) do
            table.insert(probes, string.format("/body/DocFragment[%d]/%s/%s[@id='%s']", docfrag_n, body, tag, fragment_id))
        end
    end
    for _, probe in ipairs(probes) do
        local ok, norm = pcall(function() return doc:getNormalizedXPointer(probe) end)
        if ok and norm and norm ~= false then
            logger.warn("MediaSync: DocFragment probe", probe, "resolved to", norm)
            local before_page = doc:getCurrentPage()
            local ok_goto = pcall(function()
                ui.rolling:onGotoXPointer(norm, norm)
            end)
            local after_page = doc:getCurrentPage()
            logger.warn("MediaSync: onGotoXPointer full xp",
                "ok=", tostring(ok_goto),
                "page_before=", before_page, "page_after=", after_page)
            if ok_goto and after_page then
                if self:_fragmentInDocument(fragment_id) then
                    return true, norm
                end
                if after_page ~= before_page then
                    return true, norm
                end
            end
        end
    end
    return false
end

-- Use the EPUB spine order to find which DocFragment contains the target
-- content document, then jump to the fragment inside it.
function MediaSync:_gotoViaSpineDocFragment(text_doc, fragment_id, start_page)
    local parser = self.plugin and self.plugin._smil_parser
    if not parser or not text_doc or not fragment_id then return false end
    local basename = text_doc:match("([^/]+)$")
    if not basename then return false end
    local spine = parser._spine_hrefs or {}
    local n = nil
    for i, href in ipairs(spine) do
        if href == basename then
            n = i
            break
        end
    end
    if not n then
        logger.warn("MediaSync: spine index not found for", basename)
        return false
    end
    logger.warn("MediaSync: spine index for", basename, "is DocFragment", n)
    local ok, norm = self:_tryGotoDocFragment(text_doc, fragment_id, n, start_page)
    if ok then
        logger.warn("MediaSync: spine DocFragment jump succeeded for", fragment_id, norm)
        return true
    end
    return false
end

-- Map a content document basename to its expected DocFragment index.
function MediaSync:_getExpectedDocFragmentIndex(text_doc)
    local parser = self.plugin and self.plugin._smil_parser
    if not parser or not text_doc then return nil end
    local basename = text_doc:match("([^/]+)$")
    if not basename then return nil end
    local spine = parser._spine_hrefs or {}
    for i, href in ipairs(spine) do
        if href == basename then
            return i
        end
    end
    return nil
end

-- Find the page of a SMIL fragment by scanning DocFragment indices.  We try
-- several xpointer probes for each N: an XPath id() lookup first, then a few
-- common element tags.  getNormalizedXPointer() is used to validate the probe
-- because getPageFromXPointer() alone can return page 1 for an invalid probe.
function MediaSync:_findPageByDocFragmentScan(text_doc, fragment_id)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not fragment_id then return nil end
    local doc = ui.document
    local parser = self.plugin and self.plugin._smil_parser
    local spine = parser and parser._spine_hrefs or {}
    local max_n = math.max(#spine + 20, 100)

    local tags = {"span", "p", "div", "h1", "h2", "h3", "h4", "li", "td", "em", "strong", "a"}

    for n = 1, max_n do
        -- Build candidate probes for this DocFragment.
        local probes = { string.format("/body/DocFragment[%d]/body/id('%s')", n, fragment_id) }
        for _, tag in ipairs(tags) do
            table.insert(probes, string.format("/body/DocFragment[%d]/body/%s[@id='%s']", n, tag, fragment_id))
        end

        for _, probe in ipairs(probes) do
            local ok, norm = pcall(function()
                return doc:getNormalizedXPointer(probe)
            end)
            if ok and norm and norm ~= false then
                local ok2, page = pcall(function()
                    return doc:getPageFromXPointer(norm)
                end)
                if ok2 and page and page > 0 then
                    logger.warn("MediaSync: DocFragment scan found", text_doc or "",
                        "N=", n, "page=", page, "probe=", probe, "for", fragment_id)
                    return page, n
                end
            end
        end
    end

    logger.warn("MediaSync: DocFragment scan failed for", text_doc or "", fragment_id)
    return nil
end

function MediaSync:_cacheXPointer(text_doc, fragment_id, full_xpointer)
    if not self._xpointer_cache then
        self._xpointer_cache = {}
    end
    local raw_xp = (text_doc and text_doc ~= "" and text_doc .. "#" .. fragment_id)
        or ("#" .. fragment_id)
    if self._xpointer_cache[raw_xp] == full_xpointer then
        return
    end
    self._xpointer_cache[raw_xp] = full_xpointer
    -- Persist the cache so resume/refocus work across KOReader sessions.
    local doc_path = self.plugin and self.plugin._smil_doc_path
    if doc_path and self.plugin._saveSmilXPointerCache then
        self.plugin:_saveSmilXPointerCache(doc_path, self._xpointer_cache)
    end
end

-- Cache the current document's resolved xpointer for a fragment if it is
-- currently reachable.  This is called after a successful highlight so that
-- resume/refocus can later jump back to this fragment using a full internal
-- xpointer instead of relying on gotoLink.
function MediaSync:_cacheResolvedXPointer(text_doc, fragment_id)
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.document or not fragment_id then return end
    local xp = "#" .. fragment_id
    local ok, norm = pcall(function()
        return ui.document:getNormalizedXPointer(xp)
    end)
    if ok and norm and norm ~= false then
        self:_cacheXPointer(text_doc, fragment_id, norm)
        logger.warn("MediaSync: cached resolved xpointer", norm, "for", text_doc, fragment_id)
    end
end

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

--- @param opts table|nil  { prepare_only = true } arms SMIL + bar without audio
function MediaSync:start(audio_path, timing_data, chapters, cover_path, playlist_files, original_path, start_position, opts)
    opts = opts or {}
    if self.state == self.STATE.PLAYING or self.state == self.STATE.PAUSED then
        -- Soft stop: keep A2DP keepalive + player UI across playlist file changes.
        -- A hard stop was killing track-advance keepalive and hiding the bar,
        -- which left AirPods silent and the play button dead (STOPPED).
        self:stop(true, { track_transition = true })
    end

    if not audio_path or not timing_data or #timing_data == 0 then
        logger.err("MediaSync: start() called without valid audio or timing data")
        return false
    end

    self._track_advance_pending = nil
    self.state = self.STATE.LOADING
    self.timing_data = timing_data
    self.chapters = chapters or {}
    self.cover_path = cover_path
    -- EPUB Media Overlay entries carry SMIL fragment ids; their presence
    -- switches the UI into read-along mode (minimized player, page-follow).
    self.overlay_mode = (timing_data[1] and timing_data[1].fragment_id) and true or false
    -- Resume offset: passed through to the engine so the very first decode
    -- starts at the saved position instead of at 0:00 and then seeking.
    self._start_position = tonumber(start_position) or 0

    -- Detect same-playlist BEFORE overwriting self.playlist_files,
    -- otherwise same_playlist is always true on first load and
    -- _original_playlist never gets saved.
    local same_playlist = playlist_files and self.playlist_files == playlist_files
    self.playlist_files = playlist_files

    -- Only reset shuffle state when starting a brand-new playlist.
    -- If playlist_files is the same table reference, we're transitioning
    -- between tracks within the same shuffled playlist.
    if not same_playlist then
        self.is_shuffled = false
        self._original_playlist = nil
    end
    self.current_playlist_idx = nil
    if playlist_files then
        if not same_playlist then
            -- Save original order so shuffle can be toggled
            self._original_playlist = {}
            for i, f in ipairs(playlist_files) do
                self._original_playlist[i] = {name = f.name, path = f.path}
            end
        end
        local lookup_path = original_path or audio_path
        for i, f in ipairs(playlist_files) do
            if f.path == lookup_path then
                self.current_playlist_idx = i
                break
            end
        end
    end
    -- 0 so the first sync tick (sentence 1) enters the highlight / page-follow
    -- path.  Previously this was 1, which skipped the opening sentence.
    self._current_sentence_idx = 0
    self._current_word_idx = 0
    self._last_hl_idx = nil
    self._last_page_advance_idx = nil
    self._chain_generation = self._chain_generation + 1
    self._last_progress_pct = -1
    self._last_ui_update_time = nil

    -- Cache of full crengine xpointers for SMIL fragments we have visited.
    -- This lets resume/refocus jump across EPUB content documents by using
    -- already-resolved internal xpointers instead of relying on gotoLink.
    -- Load any previously saved cache for this EPUB from KOReader settings.
    local doc_path = self.plugin and self.plugin._smil_doc_path
    if doc_path and self.plugin._loadSmilXPointerCache then
        self._xpointer_cache = self.plugin:_loadSmilXPointerCache(doc_path)
    elseif not self._xpointer_cache then
        self._xpointer_cache = {}
    end

    -- Build sentence index from timing data
    self:_buildSentenceIndex()

    -- Load and play audio
    if not self.media_engine:load(audio_path) then
        logger.err("MediaSync: failed to load audio", audio_path)
        self.state = self.STATE.STOPPED
        local err = self.media_engine and self.media_engine.backend_error
        if err then
            UIManager:show(InfoMessage:new{ text = err, timeout = 8 })
        end
        return false
    end

    -- If probing failed (e.g., no ffprobe for m4b), use the timing data
    -- end_time which was set from the known metadata duration.
    if not self.media_engine.current_duration or self.media_engine.current_duration == 0 then
        local known_dur = timing_data[1] and timing_data[1].end_time
        if known_dur and known_dur > 0 then
            self.media_engine.current_duration = known_dur
        end
    end

    -- Sync playlist menu highlight if it's open
    if self._chapter_menu and self.current_playlist_idx then
        pcall(function()
            if self._chapter_menu.item_table.current ~= self.current_playlist_idx then
                self._chapter_menu.item_table.current = self.current_playlist_idx
                self._chapter_menu:updateItems()
            end
        end)
    end

    -- Apply the persisted volume BEFORE play() so the initial decode spawn
    -- already carries the gain (setVolume is a no-op restart when not playing).
    if self.plugin and self.plugin.getSetting then
        pcall(function()
            self.media_engine:setVolume(self.plugin:getSetting("media_volume_pct", 100))
        end)
    end

    -- Show playback bar in scrubber mode
    self:showPlaybackBar()
    -- Reflow page so book text ends above the mini player (never covered).
    self:_reserveMiniBarSpace()
    self:_refreshPlaybackTimeUi()

    -- Resume position before the first paint, so the bar shows current/total
    -- instead of 0:00 / 0:00, and a prepare_only Play continues from the mark.
    local resume_pos = tonumber(self._start_position) or 0
    if resume_pos > 0 then
        self.media_engine._seek_offset = resume_pos
        self.media_engine._paused_position = resume_pos
    else
        resume_pos = self.media_engine._seek_offset or 0
        self.media_engine._paused_position = resume_pos
    end

    -- Arm SMIL + highlight without starting audio (book open / pinned overlay).
    -- Play then continues from _seek_offset instead of prompting.
    if opts.prepare_only then
        self._start_position = nil
        self.state = self.STATE.STOPPED
        if self.playback_bar and self.playback_bar.setPlaying then
            pcall(function() self.playback_bar:setPlaying(false) end)
        end
        logger.warn("MediaSync: prepared overlay session at", resume_pos)
        return true
    end

    local gen = self._chain_generation
    local ok = self.media_engine:play(
        function() self:_onPlaybackComplete(gen) end,
        function(err) self:_onPlaybackFail(gen, err) end
    )

    -- Clear the resume offset once play() has consumed it.
    self._start_position = nil

    if not ok then
        logger.err("MediaSync: media_engine:play() failed")
        self.state = self.STATE.STOPPED
        return false
    end

    self.state = self.STATE.PLAYING
    self:_startSyncLoop(gen)
    self:_startPositionPoller(gen)

    logger.warn("MediaSync: started playback, sentences=", self._total_sentences,
        "duration=", self.media_engine:getDuration())
    return true
end

--- @param keep_chapter_menu boolean|nil
--- @param opts table|nil  { track_transition = true } spares A2DP keepalive and player UI
---                        { drop_chrome = true } hides the bar (document close, TTS takeover)
function MediaSync:stop(keep_chapter_menu, opts)
    opts = opts or {}
    local track_transition = opts.track_transition and true or false
    local drop_chrome = opts.drop_chrome and true or false
    local was_playing = self.state ~= self.STATE.STOPPED
    if self.overlay_mode and was_playing and not track_transition
        and self.plugin and self.plugin._saveCurrentAlignedProgress then
        pcall(function() self.plugin:_saveCurrentAlignedProgress() end)
    end
    self.state = self.STATE.STOPPED
    self._chain_generation = self._chain_generation + 1

    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
        self._sync_timer = nil
    end
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    if self.media_engine then
        pcall(function()
            -- Hard stop (user close / end of book): tear down keepalive too.
            -- Track transition: spare keepalive so AirPods A2DP stays armed.
            self.media_engine._kill_keepalive_on_stop = not track_transition
            self.media_engine:stop()
        end)
    end
    if self.highlight_manager then
        pcall(function() self.highlight_manager:clearHighlights() end)
    end
    if not track_transition then
        local keep_bar = self:_shouldKeepOverlayBar() and not drop_chrome
        if keep_bar then
            -- Leave the mini player and reserved margins in place so CRE
            -- does not reflow the book on the next play (Android ANR).
            if self.playback_bar and self.playback_bar.setPlaying then
                pcall(function() self.playback_bar:setPlaying(false) end)
            end
        else
            if self.playback_bar then
                pcall(function() self.playback_bar:hide() end)
                self.playback_bar = nil
            end
            if self.plugin and self.plugin._hideReturnToReadAloudButton then
                pcall(function() self.plugin:_hideReturnToReadAloudButton() end)
            end
            -- Document close with the locked layout keeps the sidecar inset
            -- (restoring it would reflow on every KOReader exit); any other
            -- hard stop restores margins as before.
            if not (drop_chrome and self:_shouldKeepOverlayBar()) then
                self:_releaseMiniBarSpace()
            else
                self._bar_space_reserved = false
            end
        end
    end
    if not keep_chapter_menu then
        if self._chapter_menu_window then
            pcall(function() UIManager:close(self._chapter_menu_window) end)
            self._chapter_menu_window = nil
        end
        if self._chapter_menu then
            self._chapter_menu = nil
        end
    end

    if was_playing then
        logger.warn("MediaSync: stopped", track_transition and "(track transition)" or "")
    end
end

--- Footer height (status bar + progress) for positioning / margin math.
function MediaSync:_readerFooterHeight()
    local ui = self.plugin and self.plugin.ui
    local view = ui and ui.view
    if not view or not view.footer or not view.footer_visible then return 0 end
    local ok, h = pcall(function() return view.footer:getHeight() end)
    if ok and type(h) == "number" and h > 0 then return h end
    ok, h = pcall(function()
        local d = view.footer.dimen
        return d and d.h or 0
    end)
    if ok and type(h) == "number" and h > 0 then return h end
    return 0
end

--- Keep the mini bar on screen after playback stops (default: off).
function MediaSync:_shouldKeepOverlayBar()
    if not self.overlay_mode then return false end
    if not (self.plugin and self.plugin.getSetting) then return false end
    return self.plugin:getSetting("keep_media_overlay_bar", false)
end

--- Write the overlay inset into KOReader's own copt_b_page_margin so the
--- next open typesets with it (no SetPageMargins, no CRE reflow). Default: off.
function MediaSync:_shouldLockKoreaderMargins()
    if not (self.plugin and self.plugin.getSetting) then return false end
    return self.plugin:getSetting("lock_koreader_page_margins", false)
        and self.plugin:getSetting("keep_media_overlay_bar", false)
end

--- Show the minimized overlay chrome and reserve bottom margin without
--- starting audio, so a SMIL book does not reflow on every play/stop.
function MediaSync:pinOverlayChrome()
    self.overlay_mode = true
    self:showPlaybackBar()
    if self.playback_bar and self.playback_bar.setPlaying then
        pcall(function() self.playback_bar:setPlaying(false) end)
    end
    -- Without the sidecar lock, still reserve the strip for this session so
    -- the pinned bar never covers book text.
    if self:_shouldKeepOverlayBar() then
        self:_reserveMiniBarSpace()
    end
    self:_refreshPlaybackTimeUi()
end

--- Push current / total time (and scrubber) to the mini bar without playing.
--- Overlay mode shows SMIL chapter time, not the raw audio-file clock.
function MediaSync:_refreshPlaybackTimeUi()
    if not self.playback_bar then return end
    local pos = 0
    if self.media_engine then
        local ok, p = pcall(function() return self.media_engine:getPosition() end)
        if ok and p then pos = p end
        if not pos or pos <= 0 then
            pos = tonumber(self.media_engine._paused_position)
                or tonumber(self.media_engine._seek_offset)
                or tonumber(self._start_position)
                or 0
        end
    end
    local dur = 0
    if self.media_engine then
        local ok, d = pcall(function() return self.media_engine:getDuration() end)
        if ok and d then dur = d end
    end
    local bar_pos, bar_dur = pos, dur
    if self.overlay_mode then
        local ch_pos, ch_dur = self:_overlayChapterProgress(pos)
        if ch_pos and ch_dur and ch_dur > 0 then
            bar_pos, bar_dur = ch_pos, ch_dur
        end
    end
    pcall(function()
        -- force=true so e-ink paints immediately on pin / seek / pause.
        self.playback_bar:updateTimeDisplay(bar_pos or 0, bar_dur or 0, true)
        if bar_dur and bar_dur > 0 then
            local pct = math.floor(((bar_pos or 0) / bar_dur) * 100)
            if pct < 0 then pct = 0 end
            if pct > 100 then pct = 100 end
            self._last_progress_pct = pct
            self.playback_bar:updateProgress(pct, true)
        end
    end)
    self:_refreshPlaybackBarTitles()
    dlog("overlay time ui", "pos=", bar_pos, "dur=", bar_dur, "file_pos=", pos)
end

--- KOReader "Overlap status bar": when true, CRE does not add the footer
--- height to the bottom margin itself.
function MediaSync:_footerReclaimsHeight()
    local ui = self.plugin and self.plugin.ui
    local footer = ui and ui.view and ui.view.footer
    return footer and footer.reclaim_height and true or false
end

--- Sit the mini player above KOReader's footer so neither covers book text.
--- True when the user keeps status bars, or when Overlap status bar is off
--- (the footer is a real page footer, not a temporary overlay).
function MediaSync:_miniBarAboveFooter()
    if self.plugin and self.plugin.getSetting
        and self.plugin:getSetting("keep_reader_status_bars", false) then
        return true
    end
    local ui = self.plugin and self.plugin.ui
    local view = ui and ui.view
    if not (view and view.footer_visible and view.footer) then return false end
    return not view.footer.reclaim_height
end

function MediaSync:_unscalePx(px)
    px = tonumber(px) or 0
    if Screen.unscaleBySize then
        return Screen:unscaleBySize(px)
    end
    local dpi = Screen:getDPI() or 167
    return math.max(1, math.floor(px * 167 / dpi + 0.5))
end

function MediaSync:_miniBarPixelHeight()
    -- Use the painted strip height, not FrameContainer:getSize() — that can
    -- grow with wrapped title text while paintTo still clips to _mini_height.
    local bar = self.playback_bar
    local bar_h = bar and tonumber(bar._mini_height)
    if not bar_h or bar_h <= 0 then
        bar_h = Screen:scaleBySize(44)
    end
    return bar_h
end

--- Bottom inset (unscaled units) that keeps CRE text above the mini player:
--- the bar height plus, when we sit above a reclaiming footer, the footer
--- height ReaderTypeset will not add itself. The user's original bottom
--- margin is deliberately not carried over (that empty band sat between the
--- last line and the overlay).
function MediaSync:_overlayBarExtraUnscaled(bar_h)
    local extra = self:_unscalePx(bar_h)
    if self:_miniBarAboveFooter() and self:_footerReclaimsHeight() then
        extra = extra + self:_unscalePx(self:_readerFooterHeight())
    end
    return extra
end

function MediaSync:_docConfigurable()
    local ui = self.plugin and self.plugin.ui
    if not ui then return nil end
    -- ReaderUI has no .configurable; CRE options live on the document
    -- (and are aliased onto typeset / rolling).
    return ui.configurable
        or (ui.document and ui.document.configurable)
        or (ui.typeset and ui.typeset.configurable)
end

function MediaSync:_persistBottomMargin(unscaled_bottom, overlay_inset)
    local ui = self.plugin and self.plugin.ui
    if not ui then return end
    local ds = ui.doc_settings
    local tp = ui.typeset
    if tp and tp.unscaled_margins then
        tp.unscaled_margins[4] = unscaled_bottom
    end
    local cfg = self:_docConfigurable()
    if cfg then
        cfg.b_page_margin = unscaled_bottom
    end
    if ds then
        -- Durable KOReader setting: next open typesets with this bottom
        -- margin (CRE cache rebuilds once, then hits). Do not SetPageMargins
        -- after the document is on screen — that partial-rerenders the
        -- current fragment and ANRs Android on large illustrated EPUBs.
        ds:saveSetting("copt_b_page_margin", unscaled_bottom)
        if overlay_inset then
            ds:saveSetting("audiobook_overlay_bottom", unscaled_bottom)
        end
        pcall(function() ds:flush() end)
    end
end

-- Locked-bar reopen: re-assert the inset into the sidecar on document close.
-- KOReader's SaveSettings fires before CloseDocument, so the copt_* value it
-- persists already carries the inset; this covers any path that bypasses it.
function MediaSync:_persistLockedOverlayMargin()
    if not self:_shouldLockKoreaderMargins() then return end
    local ui = self.plugin and self.plugin.ui
    local ds = ui and ui.doc_settings
    if not ds or not ds:readSetting("audiobook_overlay_margin_locked") then return end
    local needed = ds:readSetting("audiobook_overlay_bottom")
    if needed == nil then
        local tp = ui.typeset
        needed = tp and tp.unscaled_margins and tp.unscaled_margins[4]
    end
    if needed ~= nil then
        self:_persistBottomMargin(needed, true)
        dlog("overlay-margin", "close-persist", "bottom", needed,
            "copt", ds:readSetting("copt_b_page_margin"))
    end
end

--[[--
Reserve the mini player's height in the document bottom margin so book text
reflows above it (same approach as SyncController:_reserveBarSpace for TTS).
Never leave the mini bar covering readable text — including when the user
keeps KOReader's status / progress bars visible under the mini player.

Keep-bar + lock: persist copt_b_page_margin instead of SetPageMargins.
Changing margins after the page is on screen partial-rerenders the current
DocFragment and ANRs Android, so there the inset is applied on the next open
via onDocSettingsLoad (before the first CRE typeset). Off Android a live
reflow is safe, so the first locked session gets it immediately.
--]]
function MediaSync:_reserveMiniBarSpace()
    -- Full-screen (non-overlay) player intentionally covers the book.
    if not self.overlay_mode then return end
    if not (self.plugin and self.plugin.ui and self.plugin.ui.rolling) then return end
    local ui = self.plugin.ui
    local tp = ui.typeset
    if not (tp and tp.unscaled_margins and ui.document and ui.document.setPageMargins) then
        return
    end
    local bar_h = self:_miniBarPixelHeight()
    local ds = ui.doc_settings
    local m = tp.unscaled_margins

    if self:_shouldKeepOverlayBar() and self:_shouldLockKoreaderMargins() and ds then
        local needed = self:_overlayBarExtraUnscaled(bar_h) + 2
        local orig = ds:readSetting("audiobook_overlay_orig_bottom")
        if orig == nil and math.abs((m[4] or 0) - needed) > 1 then
            orig = m[4]
            ds:saveSetting("audiobook_overlay_orig_bottom", orig)
        end
        ds:saveSetting("audiobook_overlay_margin_locked", true)
        local live_bottom = m[4]
        self:_persistBottomMargin(needed, true)
        self._bar_space_reserved = true
        self._reserved_mini_bar_h = bar_h
        logger.warn("MediaSync: overlay margin saved for next typeset",
            "bottom=", live_bottom, "needed=", needed,
            "copt=", ds:readSetting("copt_b_page_margin"))
        dlog("overlay-margin", "locked-persist-copt", "bar_h", bar_h,
            "bottom", live_bottom, "needed", needed,
            "copt", ds:readSetting("copt_b_page_margin"))
        if Device:isAndroid() then
            return
        end
        if math.abs((live_bottom or 0) - needed) <= 1 then
            return  -- already typeset with the inset (reopen after persist)
        end
        -- Off Android: reflow now so the bar does not cover text this session.
        local ok = pcall(ui.document.setPageMargins, ui.document,
            Screen:scaleBySize(m[1]), Screen:scaleBySize(m[2]),
            Screen:scaleBySize(m[3]), Screen:scaleBySize(needed))
        if ok then
            ui:handleEvent(Event:new("UpdatePos"))
        end
        return
    end

    if self._bar_space_reserved then return end

    -- Session-only reservation: scaled inset, restored on stop.
    -- Mirror ReaderTypeset:onSetPageMargins so reclaim-off includes footer.
    local bottom = Screen:scaleBySize(m[4]) + bar_h
    if not self:_footerReclaimsHeight() or self:_miniBarAboveFooter() then
        bottom = bottom + self:_readerFooterHeight()
    end
    local ok = pcall(ui.document.setPageMargins, ui.document,
        Screen:scaleBySize(m[1]), Screen:scaleBySize(m[2]),
        Screen:scaleBySize(m[3]), bottom)
    if ok then
        self._bar_space_reserved = true
        self._reserved_mini_bar_h = bar_h
        ui:handleEvent(Event:new("UpdatePos"))
        logger.warn("MediaSync: reserved", bar_h, "px bottom margin for mini player")
    end
end

function MediaSync:_releaseMiniBarSpace()
    if not self._bar_space_reserved and not (
        self.plugin and self.plugin.ui and self.plugin.ui.doc_settings
        and self.plugin.ui.doc_settings:readSetting("audiobook_overlay_margin_locked")
    ) then
        return
    end
    self._bar_space_reserved = false
    self._reserved_mini_bar_h = nil
    if not (self.plugin and self.plugin.ui) then return end
    local ui = self.plugin.ui
    local tp = ui.typeset
    local ds = ui.doc_settings
    local orig = ds and ds:readSetting("audiobook_overlay_orig_bottom")
    if orig ~= nil then
        self:_persistBottomMargin(orig)
        if ds then
            ds:delSetting("audiobook_overlay_margin_locked")
            ds:delSetting("audiobook_overlay_orig_bottom")
            ds:delSetting("audiobook_overlay_bottom")
            pcall(function() ds:flush() end)
        end
        logger.warn("MediaSync: restored original bottom margin setting", orig)
        dlog("overlay-margin", "restored-settings", orig)
        -- On Android the live restore is the same ANR-prone reflow; it takes
        -- effect on next open. Off Android, restore immediately.
        if not Device:isAndroid() and tp and tp.unscaled_margins then
            ui:handleEvent(Event:new("SetPageMargins", tp.unscaled_margins))
        end
        return
    end
    if tp and tp.unscaled_margins then
        ui:handleEvent(Event:new("SetPageMargins", tp.unscaled_margins))
        logger.warn("MediaSync: restored user page margins after mini player")
    end
end

function MediaSync:pause(auto)
    if self.state ~= self.STATE.PLAYING then return end
    -- Snapshot position before flipping state so a later STOPPED→play restart
    -- (or Android seek-restart) continues from here, not the original start.
    -- Android only: the other backends compute position as elapsed play time
    -- plus _seek_offset, so rewriting _seek_offset here would double-count
    -- the pre-pause elapsed time after resume.
    local is_android = self.media_engine
        and self.media_engine.backend == self.media_engine.BACKENDS.ANDROID
    local pos = 0
    if self.media_engine then
        pcall(function() pos = self.media_engine:getPosition() or 0 end)
        if not pos or pos < 0 then pos = 0 end
        if is_android then
            self.media_engine._seek_offset = pos
            self.media_engine._paused_position = pos
        end
    end
    self.state = self.STATE.PAUSED
    if self.media_engine then
        pcall(function() self.media_engine:pause() end)
        if is_android then
            -- Re-read after engine pause (Android re-anchors to MediaPlayer).
            pcall(function()
                local p2 = self.media_engine:getPosition()
                if p2 and p2 >= 0 then
                    pos = p2
                    self.media_engine._seek_offset = pos
                    self.media_engine._paused_position = pos
                end
            end)
        end
    end
    -- Pin the SMIL highlight to the pause time immediately.
    pcall(function() self:_updateHighlightAtTime(pos) end)
    if self.playback_bar then
        pcall(function() self.playback_bar:setPlaying(false) end)
    end
    pcall(function() self:_refreshPlaybackTimeUi() end)
    logger.warn("MediaSync: paused", auto and "(auto)" or "", "at", pos)
end

function MediaSync:clearSentenceHighlight()
    if self.highlight_manager then
        pcall(function() self.highlight_manager:clearHighlights() end)
        self.highlight_manager._line_cache = nil
    end
end

function MediaSync:resume(auto)
    if self.state ~= self.STATE.PAUSED then return end
    -- Resume exactly on the SMIL timeline pause mark before starting audio.
    -- The _seek_offset/_paused_position writes are Android only for the same
    -- reason as in pause(): non-Android backends derive position from
    -- elapsed play time plus an unchanged _seek_offset.
    local is_android = self.media_engine
        and self.media_engine.backend == self.media_engine.BACKENDS.ANDROID
    local resume_pos = 0
    if self.media_engine then
        resume_pos = self.media_engine._paused_position
            or self.media_engine._seek_offset
            or 0
        if is_android and resume_pos and resume_pos > 0 then
            self.media_engine._seek_offset = resume_pos
            self.media_engine._paused_position = resume_pos
        end
    end
    self.state = self.STATE.PLAYING
    if self.media_engine then
        pcall(function() self.media_engine:resume() end)
        pcall(function()
            local p2 = self.media_engine:getPosition()
            if p2 and p2 > 0 then resume_pos = p2 end
        end)
    end
    -- Snap highlight to the SMIL sentence for this audio time before the loop.
    pcall(function() self:_updateHighlightAtTime(resume_pos) end)
    if self.playback_bar then
        pcall(function()
            self.playback_bar:setPlaying(true)
        end)
    end
    pcall(function() self:_refreshPlaybackTimeUi() end)
    -- The sync loop self-terminates while paused: its tick bails out without
    -- rescheduling once state != PLAYING.  Restart it (and the position
    -- poller, for symmetry) so the highlight tracks the audio again instead of
    -- staying frozen at the pause point -- otherwise it looks badly desynced
    -- after every resume.  Reading getPosition() (ffmpeg out_time) re-snaps
    -- the highlight to where the audio actually is.
    self:_startSyncLoop(self._chain_generation)
    self:_startPositionPoller(self._chain_generation)
    logger.warn("MediaSync: resumed", auto and "(auto)" or "", "at", resume_pos)
end

function MediaSync:isPlaying()
    return self.state == self.STATE.PLAYING
end

function MediaSync:isPaused()
    return self.state == self.STATE.PAUSED
end

function MediaSync:setSpeed(speed)
    if self.media_engine then
        pcall(function() self.media_engine:setSpeed(speed) end)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:updateSpeed(speed) end)
    end
end

function MediaSync:setVolume(pct)
    if self.media_engine then
        pcall(function() self.media_engine:setVolume(pct) end)
    end
    -- Persist so the level carries across tracks and sessions.
    if self.plugin and self.plugin.setSetting then
        self.plugin:setSetting("media_volume_pct", pct)
    end
    if self.playback_bar then
        pcall(function() self.playback_bar:updateVolume(pct) end)
    end
end

function MediaSync:getVolume()
    if self.plugin and self.plugin.getSetting then
        return self.plugin:getSetting("media_volume_pct", 100)
    end
    return self.media_engine and self.media_engine:getVolume() or 100
end

-- ---------------------------------------------------------------------------
-- Navigation
-- ---------------------------------------------------------------------------

function MediaSync:seekToTime(seconds)
    if not self.media_engine then return end
    logger.warn("MediaSync: seekToTime", seconds)
    self.media_engine:seek(seconds, "absolute")
    -- Force immediate UI update so the bar doesn't wait for the next poller tick
    if self.playback_bar then
        local dur = self.media_engine:getDuration() or 0
        if dur > 0 then
            local pct = math.floor((seconds / dur) * 100)
            self._last_progress_pct = pct
            pcall(function()
                self.playback_bar:updateProgress(pct)
                self.playback_bar:updateTimeDisplay(seconds, dur)
            end)
        end
    end
    -- Full-screen refresh on e-ink to clear ghost trails when seeking
    -- backwards after the progress bar has filled.
    UIManager:setDirty("all", "ui")
end

function MediaSync:seekToChapter(index)
    if not self.chapters or not self.chapters[index] then return end
    local ch = self.chapters[index]
    logger.warn("MediaSync: seekToChapter", index, ch.title, "@", ch.start_time)
    self:seekToTime(ch.start_time)
end

function MediaSync:nextSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx + 1
    if idx > #self.timing_data then
        -- At end; seek to last sentence start or just seek forward 5s
        self.media_engine:seek(5, "relative")
        return
    end
    self:seekToTime(self.timing_data[idx].start_time)
end

function MediaSync:skipBack(seconds)
    seconds = seconds or 30
    if self.overlay_mode and self:_skipOverlayBy(-(seconds)) then
        return
    end
    if not self.media_engine then return end
    self.media_engine:seek(-seconds, "relative")
end

function MediaSync:skipForward(seconds)
    seconds = seconds or 30
    if self.overlay_mode and self:_skipOverlayBy(seconds) then
        return
    end
    if not self.media_engine then return end
    self.media_engine:seek(seconds, "relative")
end

--- Skip within the SMIL chapter timeline (may cross ~4 min audio parts).
function MediaSync:_skipOverlayBy(delta_s)
    local pos = self.media_engine and self.media_engine:getPosition() or 0
    local ch_pos, ch_dur = self:_overlayChapterProgress(pos)
    if not ch_dur or ch_dur <= 0 then return false end
    local target = math.max(0, math.min(ch_dur, (ch_pos or 0) + delta_s))
    self:seekToOverlayProgress(target / ch_dur)
    return true
end

function MediaSync:prevSentence()
    if not self.timing_data then return end
    local idx = self._current_sentence_idx - 1
    if idx < 1 then idx = 1 end
    self:seekToTime(self.timing_data[idx].start_time)
end

--- Resolve the current Storyteller SMIL content-document chapter (not ~4 min audio part).
-- Chapters are keyed by (audio_path, start_time within that file). Across playlist
-- advances we must compare playlist order, not only the current file's local clock.
function MediaSync:_resolveOverlayChapter()
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not chapters or #chapters == 0 then return nil, nil end
    local current_time = self.media_engine and self.media_engine:getPosition() or 0
    local current_path = self.media_engine and self.media_engine.current_path
    local path_order = {}
    if self.playlist_files then
        for i, f in ipairs(self.playlist_files) do
            if f.path then path_order[f.path] = i end
        end
    end
    local cur_order = (current_path and path_order[current_path])
        or self.current_playlist_idx
        or 1
    local current_idx = 1
    for i, ch in ipairs(chapters) do
        local ch_order = (ch.audio_path and path_order[ch.audio_path]) or 0
        local st = ch.start_time or 0
        if ch_order < cur_order
            or (ch.audio_path == current_path and st <= current_time + 1) then
            current_idx = i
        end
    end
    return chapters[current_idx], current_idx
end

--- Index of the current Storyteller SMIL content-document chapter (not audio part).
function MediaSync:_currentOverlayChapterIndex()
    local ch, idx = self:_resolveOverlayChapter()
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not ch then return nil, chapters end
    return idx, chapters
end

local function overlayChapterKey(ch)
    if not ch then return nil end
    return ch.text_doc or ch.title
end

--- Audio segments that belong to one Storyteller content chapter.
-- A single EPUB/XHTML chapter often spans many ~4–5 min MP4 parts, so the
-- raw `_smil_overlay_chapters` list has one row per part boundary.
-- @return segments, total_duration_s
function MediaSync:_overlayChapterSegments(key)
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not key or not chapters or #chapters == 0 then return {}, 0 end

    local segments = {}
    for i, c in ipairs(chapters) do
        local ckey = overlayChapterKey(c)
        if ckey == key then
            local start_t = tonumber(c.start_time) or 0
            local end_t = nil
            for j = i + 1, #chapters do
                if chapters[j].audio_path == c.audio_path then
                    end_t = tonumber(chapters[j].start_time)
                    break
                end
            end
            if not end_t then
                local by_file = self.plugin and self.plugin._smil_by_file
                local slot = by_file and c.audio_path and by_file[c.audio_path]
                local timing = (slot and slot.timing) or self.timing_data
                if timing then
                    for k = #timing, 1, -1 do
                        local e = timing[k]
                        if (not c.text_doc or e.text_doc == c.text_doc)
                            and (not e.audio_path or e.audio_path == c.audio_path) then
                            end_t = tonumber(e.end_time) or tonumber(e.start_time)
                            break
                        end
                    end
                end
            end
            if not end_t then
                end_t = start_t + 1
            end
            table.insert(segments, {
                audio_path = c.audio_path,
                start_time = start_t,
                end_time = end_t,
                dur = math.max(0.1, end_t - start_t),
                idx = i,
            })
        end
    end
    local total = 0
    for _, s in ipairs(segments) do total = total + s.dur end
    return segments, total
end

--- One menu/skip entry per content document (deduped across MP4 parts).
-- @return { { index, ch, duration }, ... }
function MediaSync:_uniqueOverlayChapters()
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not chapters or #chapters == 0 then return {} end
    local seen = {}
    local unique = {}
    for i, ch in ipairs(chapters) do
        local key = overlayChapterKey(ch)
        if key and not seen[key] then
            seen[key] = true
            local _, dur = self:_overlayChapterSegments(key)
            table.insert(unique, {
                index = i,
                ch = ch,
                duration = dur or 0,
            })
        end
    end
    return unique
end

--- Push the live chapter title into the player (full + mini bar).
function MediaSync:_refreshPlaybackBarTitles()
    if not self.playback_bar then return end
    local ch = self:getCurrentChapter()
    local label = ch and ch.title or nil
    if (not label or label == "") and self.playlist_files and self.current_playlist_idx then
        local f = self.playlist_files[self.current_playlist_idx]
        label = f and f.name or nil
    end
    if not label or label == "" then return end
    pcall(function()
        local bar = self.playback_bar
        bar:updateChapterTitle(label)
        if ch and bar.setCurrentChapter then
            bar:setCurrentChapter(ch)
        end
        if not self.overlay_mode and bar.updateOutputName then
            bar:updateOutputName(label)
        end
    end)
end

function MediaSync:nextChapter()
    -- Storyteller read-along: ⏭ means next SMIL chapter, not next ~4 min audio part.
    if self.overlay_mode then
        local unique = self:_uniqueOverlayChapters()
        if #unique == 0 then return end
        local cur = select(1, self:_resolveOverlayChapter())
        local cur_key = overlayChapterKey(cur)
        local cur_u = 1
        for i, u in ipairs(unique) do
            if overlayChapterKey(u.ch) == cur_key then
                cur_u = i
                break
            end
        end
        if cur_u < #unique then
            self:seekToOverlayChapter(unique[cur_u + 1].index)
        end
        return
    end
    if self.playlist_files and #self.playlist_files > 0 then
        local idx = (self.current_playlist_idx or 1) + 1
        if idx <= #self.playlist_files then
            self:switchToPlaylistFile(idx)
        end
        return
    end
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i, ch in ipairs(self.chapters) do
        if ch.start_time > current_time + 1 then
            self:seekToChapter(i)
            return
        end
    end
end

function MediaSync:prevChapter()
    if self.overlay_mode then
        local unique = self:_uniqueOverlayChapters()
        if #unique == 0 then return end
        local cur = select(1, self:_resolveOverlayChapter())
        local cur_key = overlayChapterKey(cur)
        local cur_u = 1
        for i, u in ipairs(unique) do
            if overlayChapterKey(u.ch) == cur_key then
                cur_u = i
                break
            end
        end
        if cur_u > 1 then
            self:seekToOverlayChapter(unique[cur_u - 1].index)
        end
        return
    end
    if self.playlist_files and #self.playlist_files > 0 then
        local idx = (self.current_playlist_idx or 1) - 1
        if idx >= 1 then
            self:switchToPlaylistFile(idx)
        end
        return
    end
    if not self.chapters or #self.chapters == 0 then return end
    local current_time = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        if self.chapters[i].start_time < current_time - 1 then
            self:seekToChapter(i)
            return
        end
    end
end

--- Keepalive (+ optional BT Disconnect/Connect) before switching audio files.
--- @param then_fn function  called after the bridge (or immediately off-Kindle)
function MediaSync:_bridgeKindleA2dpForTrackChange(then_fn)
    local me = self.media_engine
    local cycle_bt = false
    if self.plugin and self.plugin.getSetting then
        cycle_bt = self.plugin:getSetting("kindle_bt_reconnect_on_track", false) and true or false
    end
    if me and me.prepareKindleTrackAdvance then
        me:prepareKindleTrackAdvance(function(_ok)
            if then_fn then then_fn() end
        end, { cycle_bt = cycle_bt })
        return
    end
    if me and me._startKindleA2dpKeepalive then
        pcall(function() me:_startKindleA2dpKeepalive("track-advance") end)
    end
    if then_fn then then_fn() end
end

function MediaSync:switchToPlaylistFile(index)
    if not self.playlist_files or not self.playlist_files[index] then return end
    self.current_playlist_idx = index
    local file_path = self.playlist_files[index].path
    -- Manual ⏭/⏮ and playlist picks: same BT reconnect as natural EOS advance.
    self:_bridgeKindleA2dpForTrackChange(function()
        if self.plugin and self.plugin._playAudioFile then
            self.plugin:_playAudioFile(file_path, self.playlist_files)
        end
    end)
end

function MediaSync:toggleLoop()
    self.loop_enabled = not self.loop_enabled
    if self.playback_bar then
        pcall(function()
            self.playback_bar:setLoopActive(self.loop_enabled)
        end)
    end
    UIManager:show(InfoMessage:new{
        text = self.loop_enabled and _("Loop enabled.") or _("Loop disabled."),
        timeout = 1,
    })
end

function MediaSync:shufflePlaylist()
    if not self.playlist_files or #self.playlist_files <= 1 then return end

    local was_shuffled = self.is_shuffled
    if was_shuffled and self._original_playlist then
        -- Restore original alphabetical order
        self.playlist_files = {}
        for i, f in ipairs(self._original_playlist) do
            self.playlist_files[i] = {name = f.name, path = f.path}
        end
        self.is_shuffled = false
        -- Re-find current track position in restored order
        local current_path = self.media_engine and self.media_engine.current_path
        for i, f in ipairs(self.playlist_files) do
            if f.path == current_path then
                self.current_playlist_idx = i
                break
            end
        end
    else
        -- Shuffle
        math.randomseed(os.time())
        local current_path = self.playlist_files[self.current_playlist_idx or 1].path
        for i = #self.playlist_files, 2, -1 do
            local j = math.random(i)
            self.playlist_files[i], self.playlist_files[j] = self.playlist_files[j], self.playlist_files[i]
        end
        for i, f in ipairs(self.playlist_files) do
            if f.path == current_path then
                self.current_playlist_idx = i
                break
            end
        end
        self.is_shuffled = true
    end

    -- Update shuffle button visual state FIRST (before InfoMessage flash)
    if self.playback_bar then
        local ok, err = pcall(function()
            self.playback_bar:setShuffleActive(self.is_shuffled)
        end)
        if not ok then
            logger.warn("MediaSync: setShuffleActive failed:", err)
        end
    end

    UIManager:show(InfoMessage:new{
        text = self.is_shuffled and _("Playlist shuffled.") or _("Shuffle disabled."),
        timeout = 1,
    })
end

-- ---------------------------------------------------------------------------
-- Internal: sentence index
-- ---------------------------------------------------------------------------

function MediaSync:_buildSentenceIndex()
    -- timing_data is already sentence-level from parser/aligner.
    -- Each entry: {start_time, end_time, text, xpointer, words?}
    self._total_sentences = #self.timing_data
    -- Sort by start_time just in case
    table.sort(self.timing_data, function(a, b)
        return a.start_time < b.start_time
    end)
end

-- ---------------------------------------------------------------------------
-- Internal: sync loop (20Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startSyncLoop(gen)
    -- Idempotent: drop any existing timer so resume() can safely restart us
    -- without leaving two ticks running.
    if self._sync_timer then
        UIManager:unschedule(self._sync_timer)
        self._sync_timer = nil
    end
    local function tick()
        if self._chain_generation ~= gen or self.state ~= self.STATE.PLAYING then
            return
        end

        local ok, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok then
            logger.err("MediaSync: getPosition() error in sync loop:", pos)
            self._sync_timer = UIManager:scheduleIn(0.05, tick)
            return
        end

        -- Compensate for audio in flight (pads + mixer ring + BT chain):
        -- the listener hears position pos - latency.
        local lat = (self.media_engine and self.media_engine.position_latency_s) or 0
        local off = 0
        if self.plugin and self.plugin.getSetting then
            off = (self.plugin:getSetting("smil_sync_offset_ms", 0) or 0) / 1000
        end
        self:_updateHighlightAtTime(math.max(0, pos - lat - off))

        -- Check for sentence/chapter boundary advancement
        self:_checkAutoAdvance(pos)

        self._sync_timer = UIManager:scheduleIn(0.05, tick)
    end

    self._sync_timer = UIManager:scheduleIn(0.05, tick)
end

function MediaSync:_updateHighlightAtTime(pos)
    if not self.timing_data then return end

    -- Find current sentence by binary search on start_time
    local sent_idx = self:_findSentenceAtTime(pos)
    if not sent_idx then return end

    local sentence = self.timing_data[sent_idx]
    if not sentence then return end

    -- Update sentence highlight if changed
    if sent_idx ~= self._current_sentence_idx then
        self._current_sentence_idx = sent_idx
        self._current_word_idx = 1
        self._hl_fail_count = 0
        self._hl_retry_at = nil
        -- EPUB Media Overlay: keep the book view following the narration.
        -- The SMIL fragment id resolves as a "#id" xpointer in crengine;
        -- turn the page before highlighting so the text-matching
        -- highlighter can find the sentence on the visible page.
        -- Auto page-follow while the user stays with the narration.
        -- Manual browsing away (_readaloud_browsing_away) must not yank the
        -- page back or restart audio — only pause highlighting.
        local follow_page_turns = true
        if self.plugin and self.plugin.getSetting then
            follow_page_turns = self.plugin:getSetting("media_follow_page_turn", true)
        end
        local browsing_away = self.plugin and self.plugin._readaloud_browsing_away
        local suppress_auto_follow = browsing_away and true or false
        if self.plugin and self.plugin._suppress_media_sync_auto_page_follow and time then
            if time.now() < self.plugin._suppress_media_sync_auto_page_follow then
                suppress_auto_follow = true
            else
                self.plugin._suppress_media_sync_auto_page_follow = nil
            end
        end
        if browsing_away then
            -- Stay on the user's page: do not paint a coincidental phrase.
        elseif self.highlight_manager and (sentence.text or sentence.fragment_id) then
            -- Build a synthetic sentence object for HighlightManager
            local sent_obj = {
                text = sentence.text or "",
                start_pos = sentence.start_pos or 0,
                end_pos = sentence.end_pos or #(sentence.text or ""),
                fragment_id = sentence.fragment_id,
                text_doc = sentence.text_doc,
            }
            local hl_ok = false
            pcall(function()
                hl_ok = self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
            end)
            if hl_ok and sentence.fragment_id then
                self:_cacheResolvedXPointer(sentence.text_doc, sentence.fragment_id)
            end
            if hl_ok then
                self._highlighted_sentence_idx = sent_idx
                self._hl_fail_count = 0
            end

            -- If the sentence is not on the visible page, JUMP to its fragment
            -- (spine/TOC/findText).  Never crawl with GotoViewRel on every
            -- sentence — that freezes Kindle touch input for minutes.
            -- Skip while the user has manually browsed away.
            local jump_pending = false
            if not hl_ok and self.overlay_mode and sentence.fragment_id
                and follow_page_turns and not suppress_auto_follow then
                local ui = self.plugin and self.plugin.ui
                if ui and ui.rolling and ui.document then
                    jump_pending = true
                    pcall(function()
                        self:_markPageFollowAuto()
                        local ms = self
                        local target_idx = sent_idx
                        -- allow_scan=true: direct DocFragment jump, not +1 page.
                        local jumped = self:_gotoSmilFragment(
                            sentence.text_doc, sentence.fragment_id, true, sentence.text)
                        if not jumped then
                            -- Last resort: a single relative page turn, and only
                            -- when advancing exactly one sentence (not a seek).
                            if sent_idx == (self._last_hl_idx or 0) + 1
                                and self._last_page_advance_idx ~= sent_idx then
                                self._last_page_advance_idx = sent_idx
                                ui:handleEvent(Event:new("GotoViewRel", 1))
                            end
                        end
                        if ms.highlight_manager then
                            ms.highlight_manager._line_cache = nil
                        end
                        UIManager:scheduleIn(0.35, function()
                            if ms.state ~= ms.STATE.PLAYING then
                                ms:_clearPageFollowAuto()
                                return
                            end
                            if ms._current_sentence_idx ~= target_idx then
                                ms:_clearPageFollowAuto()
                                return
                            end
                            local retry_ok = false
                            pcall(function()
                                retry_ok = ms.highlight_manager:highlightSentence(
                                    sent_obj, {sentences = {sent_obj}})
                            end)
                            if retry_ok then
                                ms._last_hl_idx = target_idx
                                ms._highlighted_sentence_idx = target_idx
                                ms._hl_fail_count = 0
                                ms:_cacheResolvedXPointer(
                                    sentence.text_doc, sentence.fragment_id)
                            else
                                pcall(function()
                                    ms.highlight_manager:clearHighlights()
                                end)
                            end
                            UIManager:scheduleIn(2.0, function()
                                ms:_clearPageFollowAuto()
                            end)
                        end)
                    end)
                end
            end

            if not hl_ok and not jump_pending then
                pcall(function() self.highlight_manager:clearHighlights() end)
            end
            if hl_ok or not jump_pending then
                self._last_hl_idx = sent_idx
            end
        end
    end

    -- "Play aligned from here" stamps _current_sentence_idx before the view
    -- has settled, so the block above never runs for that first sentence.
    -- Keep retrying until the highlight actually lands.
    if sent_idx == self._current_sentence_idx
        and self._highlighted_sentence_idx ~= sent_idx then
        self:_ensureSentenceHighlighted(sentence, sent_idx)
    end

    -- Find current word within sentence (if word-level timing available)
    if sentence.words and #sentence.words > 0 then
        local word_idx = self:_findWordAtTime(sentence.words, pos)
        if word_idx and word_idx ~= self._current_word_idx then
            self._current_word_idx = word_idx
            local word = sentence.words[word_idx]
            if self.highlight_manager and word then
                pcall(function()
                    self.highlight_manager:highlightWord(word, {sentences = {sentence}})
                end)
            end
            -- TTS PlaybackBar can show the spoken word. Overlay AudiobookPlayer
            -- uses that slot for the chapter title — rewriting it every word
            -- flashes the Kindle footer into a second ghost bar.
            if self.playback_bar and not self.overlay_mode
                and not self.playback_bar.scrubber_mode then
                pcall(function()
                    self.playback_bar:updateCurrentWord(word.text or "")
                end)
            end
        end
    end

    -- Mid-sentence page follow (Readest-style). SMIL is phrase-timed, so a
    -- sentence laid out across a page break would otherwise leave the view on
    -- page 1 while the narrator reads the tail on page 2. Compare how far
    -- through the sentence's *text* the current page still shows against how
    -- far through its *audio* we are — no invented per-word timestamps.
    if self.overlay_mode then
        self:_followSentenceAcrossPages(sentence, pos)
    end
end

function MediaSync:_ensureSentenceHighlighted(sentence, sent_idx)
    if not self.highlight_manager then return end
    if not (sentence and (sentence.text or sentence.fragment_id)) then return end
    if self.plugin and self.plugin._readaloud_browsing_away then return end
    local fails = self._hl_fail_count or 0
    if fails >= 10 then return end
    local now = time.now()
    if self._hl_retry_at and now < self._hl_retry_at then return end
    self._hl_retry_at = now + time.s(0.35)

    local sent_obj = {
        text = sentence.text or "",
        start_pos = sentence.start_pos or 0,
        end_pos = sentence.end_pos or #(sentence.text or ""),
        fragment_id = sentence.fragment_id,
        text_doc = sentence.text_doc,
    }
    local hl_ok = false
    pcall(function()
        hl_ok = self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
    end)
    if hl_ok then
        self._highlighted_sentence_idx = sent_idx
        self._hl_fail_count = 0
        self._hl_retry_at = nil
        if sentence.fragment_id then
            self:_cacheResolvedXPointer(sentence.text_doc, sentence.fragment_id)
        end
        logger.warn("MediaSync: first-sentence highlight ok idx=", sent_idx)
    else
        self._hl_fail_count = fails + 1
    end
end

-- Page text used to decide a mid-sentence turn. Crops the mini-player and
-- a partial last line so words the reader cannot see do not inflate the
-- break fraction (that turned the page late).
function MediaSync:_visiblePageText()
    local ui = self.plugin and self.plugin.ui
    local doc = ui and ui.document
    if not (ui and ui.rolling and doc) then
        if self.plugin and self.plugin.getCurrentPageText then
            local ok, txt = pcall(function() return self.plugin:getCurrentPageText() end)
            if ok then return txt end
        end
        return nil
    end
    local w, h = Screen:getWidth(), Screen:getHeight()
    local crop = Screen:scaleBySize(18)
    if self._reserved_mini_bar_h and self._reserved_mini_bar_h > 0 then
        crop = crop + self._reserved_mini_bar_h
    end
    local y1 = math.max(1, h - crop)
    local ok, res = pcall(doc.getTextFromPositions, doc,
        {x = 0, y = 0}, {x = w, y = y1}, true)
    if ok and res and res.text and res.text ~= "" then
        return res.text
    end
    return nil
end

-- How much of the SMIL phrase is still on this page, from the start.
-- Uses the prefix only: a later one-word coincidence must not inflate the
-- break (that turned the page at 82–95% of the clip).
function MediaSync:_fragmentVisiblePrefix(sentence, sent_words)
    -- Kindle: per-box text extraction is too slow on the mid-sentence tick;
    -- the whole-page prefix from _visiblePageText is enough there.
    if Device:isKindle() then return nil end
    local ui = self.plugin and self.plugin.ui
    local doc = ui and ui.document
    local fid = sentence and sentence.fragment_id
    if not (doc and fid and sent_words and #sent_words > 0) then return nil end
    local ok, xp = pcall(function()
        return doc:getNormalizedXPointer("#" .. fid)
    end)
    if not (ok and xp and xp ~= false) then return nil end
    local boxes
    pcall(function()
        boxes = doc:getScreenBoxesFromPositions(xp, xp, true)
    end)
    if not boxes or #boxes == 0 then return nil end
    local crop = Screen:getHeight() - (self._reserved_mini_bar_h or 0) - Screen:scaleBySize(12)
    local parts = {}
    local n_on = 0
    for _, b in ipairs(boxes) do
        if (b.y or 0) + (b.h or 0) * 0.4 < crop then
            n_on = n_on + 1
            local r
            pcall(function()
                r = doc:getTextFromPositions(
                    {x = b.x or 0, y = (b.y or 0) + math.floor((b.h or 0) / 2)},
                    {x = (b.x or 0) + math.max((b.w or 1) - 1, 0),
                     y = (b.y or 0) + math.floor((b.h or 0) / 2)},
                    true)
            end)
            if r and r.text then parts[#parts + 1] = r.text end
        end
    end
    local on_text = self:_normalizeSearchText(table.concat(parts, " "))
    local prefix = Utils.sentencePrefixOnPage(sent_words, on_text)
    dlog("page-break-frag", "boxes", #boxes, "on", n_on, "on_n", #on_text, "prefix", prefix)
    -- A single box is usually the id's first word, not the visible phrase.
    if n_on <= 1 or prefix < 3 then return nil end
    return prefix
end

-- Fraction of the sentence's text that is still on the current page (0..1),
-- or nil when the tail is already visible (nothing to follow). Same idea as
-- Readest's pageBreakFraction: layout/page-text decides the break, audio
-- progress decides *when* to turn.
function MediaSync:_sentencePageBreakFraction(sentence)
    local raw = sentence and (sentence.text or "") or ""
    if raw == "" and sentence and sentence.fragment_id then
        raw = self:_lookupSentenceText(sentence.text_doc, sentence.fragment_id) or ""
    end
    local sent = self:_normalizeSearchText(raw)
    if sent == "" then return nil end

    local page = self:_normalizeSearchText(self:_visiblePageText() or "")
    if page == "" then return nil end

    local words = Utils.splitWords(sent)
    if #words < 4 then return false end

    local prefix = Utils.sentencePrefixOnPage(words, page)
    if page:find(sent, 1, true) then
        prefix = #words
    end
    local frag_prefix = self:_fragmentVisiblePrefix(sentence, words)
    dlog("page-break", "n", #words, "prefix", prefix,
        "frag_prefix", tostring(frag_prefix), "page_n", #page, "sent_n", #sent)

    if type(frag_prefix) == "number" and frag_prefix > 0 then
        if prefix <= 0 then
            prefix = frag_prefix
        else
            prefix = math.min(prefix, frag_prefix)
        end
    end

    if prefix <= 0 then
        dlog("page-break-skip", "no-prefix")
        return false
    end
    if prefix >= #words then
        dlog("page-break-skip", "fully-visible", "n", #words)
        return false
    end
    -- Turn at the first word that has left the page (end of the prefix).
    local visible = table.concat(words, " ", 1, prefix)
    if prefix < 3 and #visible < 20 then return false end
    local brk = #visible / #sent
    dlog("page-break-use", "prefix", prefix, "n", #words, "brk", string.format("%.3f", brk))
    return brk
end

function MediaSync:_followSentenceAcrossPages(sentence, pos)
    if not sentence or not pos then return end
    if not self.plugin then return end
    if self.plugin.getSetting and not self.plugin:getSetting("media_follow_page_turn", true) then
        return
    end
    if self.plugin._readaloud_browsing_away then return end
    -- Do not honor `_suppress_media_sync_auto_page_follow` here: that flag
    -- blocks the fragment-crawl GotoViewRel(1) after "play from here", not
    -- this mid-sentence turn which is driven by audio progress vs layout.

    local dur = (sentence.end_time or 0) - (sentence.start_time or 0)
    if dur <= 0.4 then return end
    local progress = (pos - (sentence.start_time or 0)) / dur
    if progress < 0 then progress = 0 end
    if progress > 1 then progress = 1 end

    local now = time.now()
    if self._pf_cooldown_until and now < self._pf_cooldown_until then
        return
    end

    local ui = self.plugin.ui
    if not (ui and ui.rolling and ui.document) then return end
    local page = ui.document:getCurrentPage()
    local sent_idx = self._current_sentence_idx
    if self._pf_sent_idx ~= sent_idx or self._pf_page ~= page or self._pf_break == nil then
        self._pf_sent_idx = sent_idx
        self._pf_page = page
        self._pf_break = self:_sentencePageBreakFraction(sentence)
    end
    local brk = self._pf_break
    if type(brk) ~= "number" then return end
    if progress < brk then return end

    logger.warn("MediaSync: mid-sentence page follow  progress=",
        string.format("%.2f", progress), "break=", string.format("%.2f", brk),
        "sent_idx=", sent_idx)
    dlog("mid-sentence page follow", "progress", progress, "break", brk, "sent", sent_idx)

    self._pf_break = nil
    self._pf_page = nil
    self._pf_cooldown_until = now + time.s(0.45)
    -- Same sentence, new page: force the sync loop to retry the highlight
    -- (otherwise _highlighted_sentence_idx still matches and the tail is skipped).
    self._highlighted_sentence_idx = nil
    self._hl_fail_count = 0
    self:_markPageFollowAuto()
    pcall(function()
        ui:handleEvent(Event:new("GotoViewRel", 1))
    end)
    if self.highlight_manager then
        self.highlight_manager._line_cache = nil
    end
    -- Re-draw the sentence highlight after the page settles.
    local ms = self
    local sent_idx_at_turn = sent_idx
    local sent_obj = {
        text = sentence.text or "",
        start_pos = sentence.start_pos or 0,
        end_pos = sentence.end_pos or #(sentence.text or ""),
        fragment_id = sentence.fragment_id,
        text_doc = sentence.text_doc,
    }
    UIManager:scheduleIn(0.5, function()
        if ms.state ~= ms.STATE.PLAYING then
            ms:_clearPageFollowAuto()
            return
        end
        if ms.highlight_manager then
            local ok_hl = false
            pcall(function()
                ok_hl = ms.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
            end)
            if ok_hl then
                ms._highlighted_sentence_idx = sent_idx_at_turn
                ms._hl_fail_count = 0
            end
        end
        UIManager:scheduleIn(1.5, function()
            ms:_clearPageFollowAuto()
        end)
    end)
end

function MediaSync:_findSentenceAtTime(pos)
    local data = self.timing_data
    if not data or #data == 0 then return nil end
    local lo, hi = 1, #data
    while lo <= hi do
        local mid = math.floor((lo + hi) / 2)
        local entry = data[mid]
        if pos >= entry.start_time and pos < entry.end_time then
            return mid
        elseif pos < entry.start_time then
            hi = mid - 1
        else
            lo = mid + 1
        end
    end
    -- If past the end, return last sentence
    if pos >= data[#data].end_time then
        return #data
    end
    -- If before the beginning, return first
    if pos < data[1].start_time then
        return 1
    end
    -- Gap between clips (Storyteller sometimes leaves tiny holes): keep the
    -- last sentence that has already started so the highlight does not blink off.
    if hi >= 1 and hi <= #data and data[hi].start_time <= pos then
        return hi
    end
    if lo >= 1 and lo <= #data and data[lo].start_time <= pos then
        return lo
    end
    return nil
end

function MediaSync:_findWordAtTime(words, pos)
    for i, word in ipairs(words) do
        if pos >= word.start_time and pos < word.end_time then
            return i
        end
    end
    -- Fallback: find closest word
    local closest = 1
    local min_dist = math.huge
    for i, word in ipairs(words) do
        local dist = math.min(
            math.abs(pos - word.start_time),
            math.abs(pos - word.end_time)
        )
        if dist < min_dist then
            min_dist = dist
            closest = i
        end
    end
    return closest
end

function MediaSync:_checkAutoAdvance(pos)
    if not self.timing_data then return end
    local last_sent = self.timing_data[#self.timing_data]
    if not last_sent then return end

    -- Skip auto-advance during a seek: the media engine is temporarily
    -- stopped while it restarts the pipeline at the new offset.
    if self.media_engine and self.media_engine._seek_offset then
        return
    end

    -- If we're past the last sentence end, check if we should auto-advance
    -- (For standalone audio: just stop. For EPUB Media Overlays: advance page.)
    if pos >= last_sent.end_time then
        -- Small grace period to avoid premature stop
        if pos >= last_sent.end_time + 1 then
            -- Check if audio is still playing (might be silence at end)
            if not self.media_engine:isPlaying() then
                self:_onPlaybackComplete(self._chain_generation)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- Internal: position poller (UI updates at 1Hz)
-- ---------------------------------------------------------------------------

function MediaSync:_startPositionPoller(gen)
    -- Idempotent: the poller keeps running while paused, so guard against a
    -- second concurrent loop when resume() restarts it.
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end
    local function poll()
        if self._chain_generation ~= gen then return end
        if self.state ~= self.STATE.PLAYING and self.state ~= self.STATE.PAUSED then
            return
        end

        local ok_pos, pos = pcall(function() return self.media_engine:getPosition() end)
        if not ok_pos then
            logger.err("MediaSync: getPosition() error in poller:", pos)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        local ok_dur, dur = pcall(function() return self.media_engine:getDuration() end)
        if not ok_dur then
            logger.err("MediaSync: getDuration() error in poller:", dur)
            self._position_timer = UIManager:scheduleIn(1.0, poll)
            return
        end

        -- Update progress bar
        local bar_pos, bar_dur = pos, dur
        if self.overlay_mode then
            local ch_pos, ch_dur = self:_overlayChapterProgress(pos)
            if ch_pos and ch_dur and ch_dur > 0 then
                bar_pos, bar_dur = ch_pos, ch_dur
            end
        end
        if bar_dur and bar_dur > 0 and bar_pos then
            local pct = math.floor((bar_pos / bar_dur) * 100)
            if pct ~= self._last_progress_pct then
                self._last_progress_pct = pct
                if self.playback_bar then
                    pcall(function()
                        self.playback_bar:updateProgress(pct)
                    end)
                end
            end
        end

        -- Update time display
        if self.playback_bar then
            local display_pos, display_dur = bar_pos or 0, bar_dur or 0
            pcall(function()
                self.playback_bar:updateTimeDisplay(display_pos, display_dur)
            end)
            -- Only rewrite the chapter label when it actually changes. A 1 Hz
            -- force-refresh ghosts a second bar on Kindle e-ink.
            local ok_ch, ch, ch_idx = pcall(function() return self:getCurrentChapter() end)
            if ok_ch and ch_idx ~= self._last_bar_chapter_idx then
                self._last_bar_chapter_idx = ch_idx
                pcall(function() self:_refreshPlaybackBarTitles() end)
                if self._chapter_menu and ch_idx and not self.playlist_files then
                    local menu = self._chapter_menu
                    if menu.item_table.current ~= ch_idx then
                        menu.item_table.current = ch_idx
                        pcall(function()
                            menu:updateItems()
                        end)
                    end
                end
            end
        end

        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

-- ---------------------------------------------------------------------------
-- Completion / failure callbacks
-- ---------------------------------------------------------------------------

function MediaSync:_onPlaybackComplete(gen)
    if self._chain_generation ~= gen then return end
    if self._track_advance_pending then
        logger.warn("MediaSync: playback complete ignored (track advance already pending)")
        return
    end
    logger.warn("MediaSync: playback complete")
    -- In playlist mode, auto-advance to the next track
    if self.playlist_files and #self.playlist_files > 0 then
        local next_idx = (self.current_playlist_idx or 1) + 1
        local function advance(idx)
            -- Freeze sync loops for the BT-cycle window (~5–10 s) so we do not
            -- re-enter complete → double-advance.
            self._track_advance_pending = true
            self._chain_generation = self._chain_generation + 1
            if self._sync_timer then
                UIManager:unschedule(self._sync_timer)
                self._sync_timer = nil
            end
            if self._position_timer then
                UIManager:unschedule(self._position_timer)
                self._position_timer = nil
            end
            -- Natural EOS: keepalive + forced BT reconnect, then next file.
            logger.warn("MediaSync: auto-advancing to playlist track", idx,
                "(A2DP bridge + BT cycle)")
            self:switchToPlaylistFile(idx)
        end
        if next_idx <= #self.playlist_files then
            advance(next_idx)
            return
        elseif self.loop_enabled then
            -- Loop: wrap back to start (or random if shuffled)
            if self.is_shuffled then
                math.randomseed(os.time())
                next_idx = math.random(#self.playlist_files)
            else
                next_idx = 1
            end
            logger.warn("MediaSync: looping to playlist track", next_idx)
            advance(next_idx)
            return
        end
    end
    self:stop()
end

function MediaSync:_onPlaybackFail(gen, err)
    if self._chain_generation ~= gen then return end
    logger.err("MediaSync: playback failed:", err)
    self:stop()
    UIManager:show(InfoMessage:new{
        text = _("Audio playback failed: ") .. tostring(err),
        timeout = 3,
    })
end

-- ---------------------------------------------------------------------------
-- Playback bar
-- ---------------------------------------------------------------------------

function MediaSync:showPlaybackBar()
    if self.playback_bar and self.playback_bar:isVisible() then
        -- Track transitions soft-stop and reuse the same player UI — refresh
        -- the chapter label so we don't keep the first playlist entry forever.
        self:_refreshPlaybackBarTitles()
        self:_reserveMiniBarSpace()
        return
    end
    -- For standalone audio (scrubber mode), use full-screen AudiobookPlayer overlay
    local AudiobookPlayer
    do
        local candidates = {
            PLUGIN_PATH .. "audiobookplayer.fix31.lua",
            PLUGIN_PATH .. "audiobookplayer.fix30.lua",
            PLUGIN_PATH .. "audiobookplayer.fix29.lua",
            PLUGIN_PATH .. "audiobookplayer.lua",
        }
        for _, path in ipairs(candidates) do
            local f = io.open(path, "r")
            if f then
                f:close()
                AudiobookPlayer = dofile(path)
                break
            end
        end
    end
    if not AudiobookPlayer then
        AudiobookPlayer = dofile(PLUGIN_PATH .. "audiobookplayer.lua")
    end
    -- Top-bar title = book name (NOT the first SMIL sentence text — that looked
    -- like random words next to the BT button).
    local title = _("Audiobook")
    local ui = self.plugin and self.plugin.ui
    if ui and ui.document then
        local ok_props, props = pcall(function() return ui.document:getProps() end)
        if ok_props and props and props.title and props.title ~= "" then
            title = props.title
        end
    end
    if title == _("Audiobook") and self.plugin and self.plugin._smil_doc_path then
        title = self.plugin._smil_doc_path:match("([^/]+)%.[^./]+$")
            or self.plugin._smil_doc_path:match("([^/]+)$")
            or title
    end
    -- Derive output name: book title in overlay mode (chapter goes in
    -- chapter_title / mini bar). Standalone playlists keep the track name.
    local output_name = ""
    if self.overlay_mode then
        output_name = title
    elseif self.playlist_files and self.current_playlist_idx then
        output_name = self.playlist_files[self.current_playlist_idx].name
    elseif self.media_engine and self.media_engine.current_path then
        output_name = self.media_engine.current_path:match("([^/]+)$") or ""
    end

    local initial_chapter = ""
    if self.overlay_mode then
        local ch = self:getCurrentChapter()
        if ch and ch.title then initial_chapter = ch.title end
    end

    local player = AudiobookPlayer:new{
        plugin = self.plugin,
        title = title,
        chapter_title = initial_chapter,
        output_name = output_name,
        cover_image_path = self.cover_path,
        -- Read-along (EPUB overlay) mode: start minimized so the book page
        -- stays visible; highlighting and page-follow are the primary UI.
        start_minimized = self.overlay_mode or nil,
        on_sync_nudge = self.overlay_mode and function(delta_ms)
            local p = self.plugin
            if not (p and p.getSetting) then return nil end
            local v = (p:getSetting("smil_sync_offset_ms", 0) or 0) + delta_ms
            p:setSetting("smil_sync_offset_ms", v)
            return v
        end or nil,
        show_shuffle = self.playlist_files and #self.playlist_files > 0,
        shuffle_active = self.is_shuffled,
        show_loop = self.playlist_files and #self.playlist_files > 0,
        loop_active = self.loop_enabled,
        volume_pct = self:getVolume(),
        on_volume = function(pct) self:setVolume(pct) end,
        playback_speed = self:getSpeed(),
        ui_widget = self.plugin and self.plugin.ui,
        on_play_pause = function()
            if self.state == self.STATE.PLAYING then
                self:pause()
            elseif self.state == self.STATE.PAUSED then
                self:resume()
            elseif self.media_engine and self.media_engine.current_path then
                -- After a hard stop / botched track advance the bar can stay
                -- visible while state is STOPPED — play must restart audio.
                -- Use the latest seek/pause mark so we do not jump back to the
                -- original "Play aligned from here" offset.
                local restart_pos = self.media_engine._paused_position
                    or self.media_engine._seek_offset
                    or 0
                if restart_pos and restart_pos > 0 then
                    self.media_engine._seek_offset = restart_pos
                end
                logger.warn("MediaSync: play from STOPPED — restarting at",
                    self.media_engine._seek_offset or 0)
                local gen = self._chain_generation + 1
                self._chain_generation = gen
                self.state = self.STATE.PLAYING
                local ok = self.media_engine:play(
                    function() self:_onPlaybackComplete(gen) end,
                    function(err) self:_onPlaybackFail(gen, err) end
                )
                if ok then
                    self:_startSyncLoop(gen)
                    self:_startPositionPoller(gen)
                    if self.playback_bar and self.playback_bar.setPlaying then
                        pcall(function() self.playback_bar:setPlaying(true) end)
                    end
                else
                    self.state = self.STATE.STOPPED
                end
            elseif self.plugin and self.plugin.startMediaPlayback then
                -- Pinned overlay bar before the first play of this session.
                pcall(function() self.plugin:startMediaPlayback() end)
            end
        end,
        on_skip_back = function()
            self:skipBack(30)
        end,
        on_skip_forward = function()
            self:skipForward(30)
        end,
        on_prev_chapter = function()
            self:prevChapter()
        end,
        on_next_chapter = function()
            self:nextChapter()
        end,
        on_seek = function(pct)
            if self.overlay_mode then
                -- Chapter-local scrubber (may cross audio parts).
                self:seekToOverlayProgress(pct)
                return
            end
            local dur = self.media_engine and self.media_engine:getDuration() or 0
            if dur > 0 then
                self:seekToTime(pct * dur)
            end
        end,
        on_minimize = function()
            -- Minimize is handled internally by AudiobookPlayer
            -- (shows mini bar; tap mini bar to restore)
        end,
        on_close = function()
            self:stop()
        end,
        on_chapter_list = function()
            self:showChapterList()
        end,
        on_speed = function()
            -- Cycle speeds: 0.8 → 1.0 → 1.25 → 1.5 → 2.0 → 0.8
            local speeds = {0.8, 1.0, 1.25, 1.5, 2.0}
            local current = self.media_engine and self.media_engine:getSpeed() or 1.0
            local next_speed = speeds[1]
            for i, s in ipairs(speeds) do
                if math.abs(current - s) < 0.01 then
                    next_speed = speeds[i + 1] or speeds[1]
                    break
                end
            end
            self:setSpeed(next_speed)
        end,
        on_shuffle = function()
            self:shufflePlaylist()
        end,
        on_loop = function()
            self:toggleLoop()
        end,
        on_sleep_timer_set = function(minutes)
            if self.plugin and self.plugin._startSleepTimer then
                self.plugin:_startSleepTimer(minutes)
            end
        end,
        on_sleep_timer_cancel = function()
            if self.plugin and self.plugin._cancelSleepTimer then
                self.plugin:_cancelSleepTimer()
            end
        end,
        on_refocus = self.overlay_mode and function()
            if self.plugin then
                self.plugin._readaloud_browsing_away = false
            end
            self:refocusToCurrentSentence()
            if self.plugin and self.plugin._hideReturnToReadAloudButton then
                pcall(function() self.plugin:_hideReturnToReadAloudButton() end)
            end
        end or nil,
        -- BT reconnect lives in plugin settings (Reconnect BT on track change)
        -- and the Bluetooth menu — no overlay "BT" button.
        show_fix_audio = false,
        -- Sit above a visible KOReader footer even when the user did not
        -- toggle "Keep status bars" — otherwise the mini player overlaps it.
        keep_reader_status_bars = self:_miniBarAboveFooter(),
    }
    player:show()
    if self.plugin then
        pcall(function()
            player:updateSleepTimer(self.plugin:getSleepTimerRemaining(),
                self.plugin._sleep_timer_end ~= nil)
        end)
    end
    self.playback_bar = player
    self:_refreshPlaybackBarTitles()
    self:_reserveMiniBarSpace()
end

function MediaSync:navigateToSentenceEntry(entry)
    -- Jump to a specific SMIL timing entry by fragment id (preferred for
    -- "Play aligned from here", where looking up by start_time can hit the
    -- wrong sentence when several share similar clip times).
    if not self.overlay_mode or not self.timing_data or not entry then return false end
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.rolling or not ui.document then return false end

    local sent_idx = nil
    if entry.fragment_id then
        for i, e in ipairs(self.timing_data) do
            if e.fragment_id == entry.fragment_id
                and (not entry.text_doc or e.text_doc == entry.text_doc) then
                sent_idx = i
                break
            end
        end
    end
    if not sent_idx and entry.start_time then
        sent_idx = self:_findSentenceAtTime(entry.start_time)
    end
    local sentence = sent_idx and self.timing_data[sent_idx]
    if not sentence or not sentence.fragment_id then
        logger.warn("MediaSync: navigateToSentenceEntry: no matching sentence")
        return false
    end

    self._current_sentence_idx = sent_idx
    self._last_hl_idx = sent_idx
    logger.warn("MediaSync: navigating to entry", sent_idx, sentence.text_doc, sentence.fragment_id)

    if self.plugin and time then
        self.plugin._suppress_media_sync_auto_page_follow = time.now() + time.s(3.0)
    end

    self:_markPageFollowAuto()
    local ms = self
    local nav_ok = self:_gotoSmilFragment(sentence.text_doc, sentence.fragment_id, true, sentence.text)
    if not nav_ok then
        logger.warn("MediaSync: navigateToSentenceEntry failed for", sentence.fragment_id)
        self:_clearPageFollowAuto()
        return false
    end
    UIManager:scheduleIn(2.5, function()
        ms:_clearPageFollowAuto()
    end)

    if self.highlight_manager and (sentence.text or sentence.fragment_id) then
        local sent_obj = {
            text = sentence.text or "",
            start_pos = sentence.start_pos or 0,
            end_pos = sentence.end_pos or #(sentence.text or ""),
            fragment_id = sentence.fragment_id,
            text_doc = sentence.text_doc,
        }
        self.highlight_manager._line_cache = nil
        UIManager:scheduleIn(0.3, function()
            pcall(function()
                local ok = ms.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
                if ok then
                    ms:_cacheResolvedXPointer(sentence.text_doc, sentence.fragment_id)
                end
            end)
        end)
    end
    return true
end

function MediaSync:navigateToSentenceAtTime(seconds)
    if not self.overlay_mode then return end
    if not self.timing_data then return end
    local sent_idx = self:_findSentenceAtTime(seconds)
    if not sent_idx then
        logger.warn("MediaSync: navigateToSentenceAtTime found no sentence at", seconds)
        return
    end
    self:navigateToSentenceEntry(self.timing_data[sent_idx])
end

function MediaSync:refocusToCurrentSentence()
    logger.warn("MediaSync: refocusToCurrentSentence called")
    if not self.overlay_mode then
        logger.warn("MediaSync: refocus aborted, not overlay_mode")
        return
    end
    if not self.timing_data then
        logger.warn("MediaSync: refocus aborted, no timing_data")
        return
    end
    local ui = self.plugin and self.plugin.ui
    if not ui or not ui.rolling or not ui.document then
        logger.warn("MediaSync: refocus aborted, no UI/rolling/document")
        return
    end

    local sent_idx = self._current_sentence_idx
    if not sent_idx or not self.timing_data[sent_idx] then
        local pos = self.media_engine and self.media_engine:getPosition() or 0
        sent_idx = self:_findSentenceAtTime(pos)
    end
    local sentence = self.timing_data[sent_idx]
    if not sentence or not sentence.fragment_id then
        logger.warn("MediaSync: no current sentence to refocus (idx=", sent_idx, ")")
        return
    end
    self._current_sentence_idx = sent_idx
    logger.warn("MediaSync: refocusing to sentence", sent_idx, sentence.text_doc, sentence.fragment_id)

    local text_doc = sentence.text_doc or ""
    local xp = (text_doc ~= "" and text_doc .. "#" .. sentence.fragment_id)
        or ("#" .. sentence.fragment_id)

    self:_markPageFollowAuto()
    local ms = self
    local nav_ok = self:_gotoSmilFragment(text_doc, sentence.fragment_id, true, sentence.text)
    if not nav_ok then
        logger.warn("MediaSync: refocus cannot navigate to", xp)
        self:_clearPageFollowAuto()
        return
    end
    UIManager:scheduleIn(1.5, function()
        ms:_clearPageFollowAuto()
    end)

    -- Re-highlight the current sentence after the page settles.
    if self.highlight_manager and (sentence.text or sentence.fragment_id) then
        local sent_obj = {
            text = sentence.text or "",
            start_pos = sentence.start_pos or 0,
            end_pos = sentence.end_pos or #(sentence.text or ""),
            fragment_id = sentence.fragment_id,
            text_doc = sentence.text_doc,
        }
        UIManager:scheduleIn(0.3, function()
            pcall(function()
                self.highlight_manager:highlightSentence(sent_obj, {sentences = {sent_obj}})
            end)
        end)
    end
end

function MediaSync:hidePlaybackBar()
    if self.playback_bar then
        pcall(function() self.playback_bar:hide() end)
        self.playback_bar = nil
    end
end

--- Close the modal chapter/playlist menu and clear its references.
function MediaSync:_closeModalMenu()
    local window = self._chapter_menu_window
    self._chapter_menu = nil
    self._chapter_menu_window = nil
    if window then
        pcall(function() UIManager:close(window) end)
    end
end

--[[--
Show a modal list menu centered over the reader, with a full-screen wrapper
that closes the menu when the user taps/swipes outside it (and swallows
hold/pan outside so they don't fall through to the page underneath).  Shared
by showChapterList() and showPlaylist().

@param opts table  { title = string, items = item_table, current = number }
  Each item's `callback` decides whether to close the menu (call
  self:_closeModalMenu()) -- chapters close on select, the playlist stays open.
--]]
function MediaSync:_showModalMenu(opts)
    -- Always drop a previous chapter sheet first.
    self:_closeModalMenu()

    -- Android/Boox: opening KOReader's Menu widget synchronously from a
    -- transport-bar button callback has been crashing the activity (blank
    -- crash screen / ActivityThread top-resumed noise).  Use ButtonDialogTitle
    -- and defer the show by a tick so we leave the gesture handler first.
    local is_android = Device.isAndroid and Device:isAndroid()
    if is_android then
        self:_showModalMenuButtonDialog(opts)
        return
    end

    local Menu = require("ui/widget/menu")
    local CenterContainer = require("ui/widget/container/centercontainer")
    local InputContainer = require("ui/widget/container/inputcontainer")

    local menu_w = Screen:getWidth() * 0.8
    local menu_h = Screen:getHeight() * 0.7

    local items = opts.items
    items.current = opts.current or 1

    local menu = Menu:new{
        title = opts.title,
        item_table = items,
        width = menu_w,
        height = menu_h,
    }
    self._chapter_menu = menu

    local window = InputContainer:new{
        dimen = Screen:getSize(),
        CenterContainer:new{
            dimen = Screen:getSize(),
            menu,
        },
    }
    self._chapter_menu_window = window

    local menu_rect = Geom:new{
        x = math.floor((Screen:getWidth() - menu_w) / 2),
        y = math.floor((Screen:getHeight() - menu_h) / 2),
        w = menu_w,
        h = menu_h,
    }

    local ms = self
    local function outside(ges_ev)
        return ges_ev and ges_ev.pos and ges_ev.pos:notIntersectWith(menu_rect)
    end
    function window:onTap(arg, ges_ev)
        if outside(ges_ev) then ms:_closeModalMenu(); return true end
        return false
    end
    function window:onSwipe(arg, ges_ev)
        if outside(ges_ev) then ms:_closeModalMenu(); return true end
        -- Drive Menu pagination explicitly and force a full-screen refresh.
        -- Letting the event propagate sometimes leaves the new page invisible
        -- on e-ink until the next suspend/resume cycle.
        local direction = ges_ev.direction
        if direction == "west" then
            menu:onNextPage()
        elseif direction == "east" then
            menu:onPrevPage()
        else
            return false
        end
        UIManager:setDirty(nil, "ui")
        return true
    end
    function window:onHold(arg, ges_ev)
        return outside(ges_ev) and true or false
    end
    function window:onPan(arg, ges_ev)
        return outside(ges_ev) and true or false
    end

    menu.close_callback = function() ms:_closeModalMenu() end

    UIManager:scheduleIn(0.05, function()
        if self._chapter_menu_window == window then
            UIManager:show(window)
        end
    end)
    return menu
end

--- Android-safe chapter/playlist picker (paginated ButtonDialog).
--- Full Menu / giant ButtonDialog crashed on Boox; a short paginated
--- ButtonDialog is the same widget KOReader uses elsewhere and stays light.
function MediaSync:_showModalMenuButtonDialog(opts)
    local items = opts.items or {}
    if #items == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end

    local ok_bd, ButtonDialog = pcall(require, "ui/widget/buttondialog")
    if not ok_bd or not ButtonDialog then
        logger.err("MediaSync: ButtonDialog unavailable:", ButtonDialog)
        dlog("chapter: ButtonDialog missing:", tostring(ButtonDialog))
        UIManager:show(InfoMessage:new{
            text = _("Could not open chapter list.") .. "\nButtonDialog missing",
            timeout = 4,
        })
        return
    end

    local PAGE_SIZE = 8
    local page = 1
    local current = tonumber(opts.current) or 1
    if current < 1 then current = 1 end
    if current > #items then current = #items end
    page = math.floor((current - 1) / PAGE_SIZE) + 1

    local ms = self
    local dialog

    local function close_picker()
        if dialog then
            pcall(function() UIManager:close(dialog) end)
        end
        ms._chapter_menu_window = nil
        ms._chapter_menu = nil
        dialog = nil
    end

    local function show_page()
        local total_pages = math.max(1, math.ceil(#items / PAGE_SIZE))
        if page < 1 then page = 1 end
        if page > total_pages then page = total_pages end
        local first = (page - 1) * PAGE_SIZE + 1
        local last = math.min(#items, page * PAGE_SIZE)

        local buttons = {}
        for i = first, last do
            local item = items[i]
            if item then
                local label = tostring(item.text or (_("Item") .. " " .. i))
                if #label > 80 then
                    label = label:sub(1, 77) .. "..."
                end
                if i == current then
                    label = "> " .. label
                end
                local cb = item.callback
                table.insert(buttons, {{
                    text = label,
                    callback = function()
                        close_picker()
                        UIManager:scheduleIn(0.1, function()
                            if cb then pcall(cb) end
                        end)
                    end,
                }})
            end
        end

        -- Navigation row
        table.insert(buttons, {
            {
                text = _("Prev"),
                enabled = page > 1,
                callback = function()
                    page = page - 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
            {
                text = _("Close"),
                callback = close_picker,
            },
            {
                text = _("Next"),
                enabled = page < total_pages,
                callback = function()
                    page = page + 1
                    close_picker()
                    UIManager:scheduleIn(0.05, show_page)
                end,
            },
        })

        local title = string.format("%s (%d/%d)",
            tostring(opts.title or _("Chapters")), page, total_pages)

        local ok, err = pcall(function()
            dialog = ButtonDialog:new{
                title = title,
                buttons = buttons,
            }
            ms._chapter_menu_window = dialog
            ms._chapter_menu = nil
            UIManager:show(dialog)
        end)
        if not ok then
            logger.err("MediaSync: chapter ButtonDialog failed:", err)
            dlog("chapter: ButtonDialog:new failed:", tostring(err))
            ms._chapter_menu_window = nil
            UIManager:show(InfoMessage:new{
                text = _("Could not open chapter list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end

    UIManager:scheduleIn(0.2, function()
        local ok, err = pcall(show_page)
        if not ok then
            logger.err("MediaSync: chapter picker failed:", err)
            dlog("chapter: show_page failed:", tostring(err))
            UIManager:show(InfoMessage:new{
                text = _("Could not open chapter list.") .. "\n" .. tostring(err),
                timeout = 6,
            })
        end
    end)
end

function MediaSync:showChapterList()
    dlog("chapter: showChapterList overlay=", tostring(self.overlay_mode),
        "smil_n=", tostring(self.plugin and self.plugin._smil_overlay_chapters and #self.plugin._smil_overlay_chapters or 0),
        "chapters_n=", tostring(self.chapters and #self.chapters or 0),
        "playlist_n=", tostring(self.playlist_files and #self.playlist_files or 0))
    if self.overlay_mode and self.plugin and self.plugin._smil_overlay_chapters
        and #self.plugin._smil_overlay_chapters > 0 then
        self:showOverlayChapterList()
        return
    end
    if self.playlist_files and #self.playlist_files > 0 then
        self:showPlaylist()
        return
    end
    if not self.chapters or #self.chapters == 0 then
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end

    local current_chapter, current_idx = self:getCurrentChapter()
    local items = {}
    for i, ch in ipairs(self.chapters) do
        table.insert(items, {
            text = (ch.title or _("Chapter") .. " " .. i)
                .. "  (" .. self:_formatTime(ch.start_time) .. ")",
            callback = function()
                self:_closeModalMenu()
                self:seekToChapter(i)
            end,
        })
    end
    self:_showModalMenu{ title = _("Chapters"), items = items, current = current_idx }
end

--- Storyteller read-along: list every SMIL content-document chapter, not just
--- the four embedded MP4 audio segments shown in the playlist menu.
function MediaSync:showOverlayChapterList()
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not chapters or #chapters == 0 then
        dlog("chapter: overlay list empty")
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end

    -- Dedup by content document: one menu row per Storyteller chapter.
    -- Raw list has ~1 entry per MP4 part (often start_time=0 continuations).
    local unique = self:_uniqueOverlayChapters()
    if #unique == 0 then
        dlog("chapter: unique overlay list empty raw_n=", #chapters)
        UIManager:show(InfoMessage:new{
            text = _("No chapters available."),
            timeout = 2,
        })
        return
    end

    local current_idx = 1
    -- Do NOT name the first return `_`: that shadows gettext `_()` below.
    local cur_ch = select(1, self:_resolveOverlayChapter())
    local cur_key = overlayChapterKey(cur_ch)
    for i, u in ipairs(unique) do
        if overlayChapterKey(u.ch) == cur_key then
            current_idx = i
            break
        end
    end
    dlog("chapter: overlay list raw_n=", #chapters,
        "unique_n=", #unique, "current_idx=", current_idx)

    local items = {}
    for i, u in ipairs(unique) do
        local ch = u.ch
        local seek_idx = u.index
        table.insert(items, {
            text = (ch.title or _("Chapter") .. " " .. i)
                .. "  (" .. self:_formatTime(u.duration) .. ")",
            callback = function()
                self:_closeModalMenu()
                self:seekToOverlayChapter(seek_idx)
            end,
        })
    end
    local ok, err = pcall(function()
        self:_showModalMenu{ title = _("Chapters"), items = items, current = current_idx }
    end)
    if not ok then
        logger.err("MediaSync: showOverlayChapterList failed:", err)
        dlog("chapter: showOverlayChapterList failed:", tostring(err))
        UIManager:show(InfoMessage:new{
            text = _("Could not open chapter list.") .. "\n" .. tostring(err),
            timeout = 6,
        })
    end
end

function MediaSync:seekToOverlayChapter(index)
    local chapters = self.plugin and self.plugin._smil_overlay_chapters
    if not chapters or not chapters[index] then return end
    local ch = chapters[index]
    self:_seekToOverlayFileTime(ch.audio_path, ch.start_time or 0)
end

--- Scrubber pct is chapter-local (same scale as the overlay time display).
function MediaSync:seekToOverlayProgress(pct)
    pct = tonumber(pct) or 0
    if pct < 0 then pct = 0 end
    if pct > 1 then pct = 1 end
    local pos = self.media_engine and self.media_engine:getPosition() or 0
    local _, ch_dur = self:_overlayChapterProgress(pos)
    if not ch_dur or ch_dur <= 0 then
        local dur = self.media_engine and self.media_engine:getDuration() or 0
        if dur > 0 then
            self:seekToTime(pct * dur)
        end
        return
    end
    local ch = select(1, self:_resolveOverlayChapter())
    local key = overlayChapterKey(ch)
    local segments = self:_overlayChapterSegments(key)
    if not segments or #segments == 0 then
        local dur = self.media_engine and self.media_engine:getDuration() or 0
        if dur > 0 then
            self:seekToTime(pct * dur)
        end
        return
    end
    local target = pct * ch_dur
    local acc = 0
    local chosen
    for i, s in ipairs(segments) do
        local last = (i == #segments)
        if last or target <= acc + s.dur then
            local local_t = (s.start_time or 0) + (target - acc)
            if local_t < (s.start_time or 0) then local_t = s.start_time or 0 end
            if s.end_time and local_t > s.end_time then local_t = s.end_time end
            chosen = { path = s.audio_path, time = local_t }
            break
        end
        acc = acc + s.dur
    end
    if not chosen then return end
    logger.warn("MediaSync: overlay seek pct=", pct, "chapter_t=", target,
        "file=", chosen.path, "t=", chosen.time)
    dlog("overlay seek", "pct=", pct, "target=", target, "t=", chosen.time)
    self:_seekToOverlayFileTime(chosen.path, chosen.time)
end

function MediaSync:_seekToOverlayFileTime(audio_path, local_time)
    local_time = tonumber(local_time) or 0
    local function after_audio_ready()
        -- Let the new part settle before seeking (Kindle A2DP bridge needs it).
        UIManager:scheduleIn(0.2, function()
            self:seekToTime(local_time)
        end)
    end
    if audio_path and self.media_engine
        and self.media_engine.current_path ~= audio_path then
        -- Cross-file jump: BT reconnect then load the new audio part.
        self:_bridgeKindleA2dpForTrackChange(function()
            if self.plugin and self.plugin._playAudioFile then
                self.plugin:_playAudioFile(audio_path, self.playlist_files)
            end
            after_audio_ready()
        end)
        return
    end
    -- Same file: seek immediately, no settle delay.
    self:seekToTime(local_time)
end

function MediaSync:showPlaylist()
    if not self.playlist_files or #self.playlist_files == 0 then
        return
    end

    local items = {}
    for i, f in ipairs(self.playlist_files) do
        table.insert(items, {
            text = f.name,
            callback = function()
                -- Keep the playlist open when switching tracks.
                self:switchToPlaylistFile(i)
            end,
        })
    end
    self:_showModalMenu{
        title = _("Playlist"),
        items = items,
        current = self.current_playlist_idx or 1,
    }
end

-- ---------------------------------------------------------------------------
-- Progress / time queries
-- ---------------------------------------------------------------------------

function MediaSync:getProgress()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    if dur <= 0 then return 0 end
    local pos = self.media_engine:getPosition()
    return math.floor((pos / dur) * 100)
end

function MediaSync:getCurrentTime()
    local pos = self.media_engine and self.media_engine:getPosition() or 0
    return self:_formatTime(pos)
end

function MediaSync:getTotalTime()
    local dur = self.media_engine and self.media_engine:getDuration() or 0
    return self:_formatTime(dur)
end

function MediaSync:getSpeed()
    return self.media_engine and self.media_engine:getSpeed() or 1.0
end

function MediaSync:_formatTime(seconds)
    seconds = math.floor(seconds or 0)
    local mins = math.floor(seconds / 60)
    local secs = seconds % 60
    if mins >= 60 then
        local hours = math.floor(mins / 60)
        mins = mins % 60
        return string.format("%d:%02d:%02d", hours, mins, secs)
    end
    return string.format("%d:%02d", mins, secs)
end

-- ---------------------------------------------------------------------------
-- Chapter queries
-- ---------------------------------------------------------------------------

function MediaSync:getCurrentChapter()
    -- Storyteller / Media Overlay: prefer the flat SMIL chapter list so the
    -- title follows the content document across ~4 min audio-file boundaries.
    if self.overlay_mode then
        local ch, idx = self:_resolveOverlayChapter()
        if ch then return ch, idx end
    end
    if not self.chapters or #self.chapters == 0 then return nil end
    local pos = self.media_engine:getPosition()
    for i = #self.chapters, 1, -1 do
        local st = self.chapters[i].start_time or self.chapters[i].start or 0
        if pos >= st then
            return self.chapters[i], i
        end
    end
    return self.chapters[1], 1
end

--- Position/duration within the current SMIL chapter (seconds).
--- A Storyteller chapter (content document) can span several ~5 min audio
--- parts; sum those segments so the scrubber shows the full chapter.
function MediaSync:_overlayChapterProgress(pos)
    pos = tonumber(pos) or 0
    local ch, idx = self:_resolveOverlayChapter()
    if not ch then return nil, nil end

    local key = overlayChapterKey(ch)
    if not key then return nil, nil end

    local segments, total = self:_overlayChapterSegments(key)
    if #segments == 0 then return nil, nil end

    local current_path = self.media_engine and self.media_engine.current_path
    local path_order = {}
    if self.playlist_files then
        for pi, f in ipairs(self.playlist_files) do
            path_order[f.path] = pi
        end
    end
    local cur_order = (current_path and path_order[current_path]) or 0

    local ch_pos = 0
    for _, s in ipairs(segments) do
        local seg_order = (s.audio_path and path_order[s.audio_path]) or 0
        if s.audio_path == current_path then
            ch_pos = ch_pos + math.max(0, math.min(pos - s.start_time, s.dur))
            break
        elseif seg_order > 0 and cur_order > 0 and seg_order < cur_order then
            ch_pos = ch_pos + s.dur
        elseif cur_order == 0 and s.idx < (idx or 1) then
            ch_pos = ch_pos + s.dur
        end
    end

    ch_pos = math.max(0, math.min(ch_pos, total))
    return ch_pos, total
end

return MediaSync
