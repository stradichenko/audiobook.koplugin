--[[--
Sync Controller Module
Coordinates TTS playback with text highlighting.
Reads text sentence-by-sentence for responsive, continuous playback.

@module synccontroller
--]]

local Event = require("ui/event")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")
local T = require("ffi/util").template

-- Shared utility modules (DRY: eliminates duplicated getPluginPath, ws)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local PLUGIN_PATH = _utils_dir

-- ── Constants ────────────────────────────────────────────────────────
-- Number of sentences to prefetch ahead for Piper TTS.
-- With BATCH_SIZE=1 and 2 servers × 4 pipeline depth = 8 slots,
-- we need at least 8 sentences queued to keep all slots fed.
-- 20 gives comfortable headroom so sentences are ready when needed.
local PIPER_LOOKAHEAD = 20

-- espeak-ng cold-start fallback:
-- espeak synthesizes in ~300ms vs Piper's 30-75s first batch on ARM.
-- The fallback keeps playing sentences via espeak until Piper delivers
-- its first result (_piper_warmed_up), so slow models on weak hardware
-- (e.g. French medium on single-core) never stall.

-- If Piper hasn't delivered any result after this many consecutive
-- espeak fallback sentences, kill the Piper server to free CPU/memory.
-- One Kobo page is typically 20-25 sentences; 30 gives Piper one full
-- page of breathing room before we give up.
local PIPER_ABANDON_THRESHOLD = 30

-- ── Accumulate-then-play buffering ───────────────────────────────────
-- Piper on ARM synthesizes at ~0.3-0.5× real-time (each 5 s sentence
-- takes 15-30 s).  Playing each sentence as soon as it's ready creates
-- a choppy "5 s audio → 10 s silence → 3 s audio" pattern.
--
-- Instead, when we must wait for a sentence anyway, we keep waiting
-- until several CONSECUTIVE sentences are ready, then concat them into
-- one smooth burst (e.g. 20 s of uninterrupted audio).  The user hears
-- longer but fewer pauses, with smooth playback in between.
local MIN_READY_AHEAD = 3         -- wait for 3+ more sentences after target
local BUFFER_FILL_TIMEOUT_S = 20  -- max seconds to wait after target is ready

-- ── RTF auto-degrade escalation ──────────────────────────────────────
-- PiperQueue tracks a rolling realtime factor (synthesis time / audio
-- duration).  Above this threshold Piper cannot keep up with playback.
-- Stage 1 applies low-resource mode + aggressive sentence splitting for
-- the session; stage 2 switches to espeak for the rest of the session.
-- Neither stage touches the user's saved settings.
local PIPER_RTF_DEGRADE_THRESHOLD = 1.2
-- Batches to wait after stage 1 before concluding it was not enough.
local PIPER_RTF_STAGE2_SAMPLES = 3

local SyncController = {
    -- Playback states
    STATE = {
        STOPPED = "stopped",
        PLAYING = "playing",
        PAUSED = "paused",
        LOADING = "loading",
    },
}

function SyncController:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self

    o.state = self.STATE.STOPPED
    o.parsed_data = nil
    o.current_word_index = 0
    o.current_sentence_index = 0
    -- Sentence-by-sentence queue
    o.reading_sentence_idx = 0
    o.total_sentences = 0
    o.current_sentence = nil
    -- Chain generation: incremented by beginSentencePlayback so stale
    -- completion callbacks and polling loops can detect they are outdated.
    o._chain_generation = 0
    -- Set to true once Piper delivers its first audio; prevents espeak
    -- cold-start from re-triggering on page turns.
    o._piper_warmed_up = false
    -- Piper abandonment: if espeak runs for too many sentences without
    -- Piper ever delivering, kill the server to free CPU on single-core.
    o._piper_abandoned = false
    o._espeak_fallback_count = 0
    -- RTF auto-degrade: 0 = not triggered, 1 = low-resource + splitting
    -- applied for the session, 2 = espeak session fallback active.
    o._piper_degrade_stage = 0
    o._piper_degrade_mark = nil
    -- Timing
    o.sentence_sync_start = nil
    o.pause_time = nil
    o.playback_bar = nil
    -- Xpointer of the page currently being read (for re-align)
    o.reading_page_xpointer = nil

    return o
end

--[[--
Start read-along for given text.
Parses text into sentences and reads them one-by-one, chaining automatically.
@param text string The text to read
--]]
function SyncController:start(text)
    -- If already playing/paused, stop TTS+highlights but keep the playback bar
    if self.state == self.STATE.PLAYING or self.state == self.STATE.PAUSED then
        pcall(function() self.tts_engine:stop() end)
        pcall(function() self.highlight_manager:clearHighlights() end)
    end

    self.state = self.STATE.LOADING
    logger.dbg("SyncController: Starting read-along with", #text, "characters")

    -- Log rotation baseline for diagnostics
    local Screen = require("device").screen
    local scr_w, scr_h = Screen:getWidth(), Screen:getHeight()
    logger.warn("SyncController: start() — screen", scr_w, "x", scr_h,
        "mode=", Screen:getScreenMode(),
        "rotation=", Screen.getRotationMode and Screen:getRotationMode() or "?")

    -- Create the bar BEFORE parsing: showing it reserves the bar's height in
    -- the page's bottom margin, which reflows/repaginates the page (fewer
    -- lines per page).  That repagination happens asynchronously in crengine,
    -- so capturing the page text on the very next line reads a transitional
    -- layout — sometimes the previous page.  Worse, the captured text then
    -- disagrees with where the view finally settles, so advanceToNextPage
    -- turns one page too far and skips the page on screen.  Fix: after a
    -- FRESH reservation, defer the text capture + read-start until the reflow
    -- settles (the same scheduleIn pattern advanceToNextPage uses).  On page
    -- advances the bar already exists / the margin is already reserved, so
    -- there is no reflow, no defer, and prefetched text stays valid.
    if not self.playback_bar then
        local was_reserved = self._bar_space_reserved
        self:showPlaybackBar()
        if self._bar_space_reserved and not was_reserved
           and self.plugin and self.plugin.getCurrentPageText then
            local controller = self
            UIManager:scheduleIn(0.25, function()
                if controller.state ~= controller.STATE.LOADING then
                    logger.dbg("SyncController: start deferral aborted, state=", controller.state)
                    return
                end
                local fresh = controller.plugin:getCurrentPageText()
                if fresh and fresh ~= "" then
                    logger.dbg("SyncController: re-fetched page text after margin reflow settle (",
                        #text, "->", #fresh, "chars)")
                    text = fresh
                end
                controller:_beginReading(text)
            end)
            return
        end
    end

    self:_beginReading(text)
end

--[[--
Parse the (settled) page text and begin sentence playback.  Split out of
start() so the initial margin reflow can settle before we capture and read
the page (see the deferral in start()).
@param text string The text to read
--]]
function SyncController:_beginReading(text)
    -- Parse the full text into sentences and words
    self.parsed_data = self.text_parser:parse(text)

    if not self.parsed_data or #self.parsed_data.sentences == 0 then
        logger.warn("SyncController: No sentences found in text")
        self.state = self.STATE.STOPPED
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = "No readable text found on this page.",
            timeout = 2,
        })
        return
    end

    self.total_sentences = #self.parsed_data.sentences
    self.reading_sentence_idx = 0
    self._chain_generation = (self._chain_generation or 0) + 1
    self._highest_dispatched_idx = nil
    -- Don't reset _piper_warmed_up here: it persists across page turns
    -- so espeak cold-start doesn't re-trigger when Piper is already warm.
    -- Honor espeak-only mode: if the user enabled the setting (or it was
    -- auto-enabled by a previous abandon), skip Piper from the start.
    if not self._piper_abandoned
            and self.plugin
            and self.plugin:getSetting("espeak_only_mode", false) then
        self._piper_abandoned = true
        logger.warn("SyncController: espeak-only mode enabled via settings")
        pcall(function() self.tts_engine._piper:shutdown() end)
    end
    self.current_word_index = 0
    self.current_sentence_index = 0
    self.current_sentence = nil

    -- Remember the xpointer of the page we're reading so the user can
    -- re-align the view after browsing away.
    if self.plugin and self.plugin.ui and self.plugin.ui.document
            and self.plugin.ui.rolling
            and self.plugin.ui.document.getXPointer then
        pcall(function()
            self.reading_page_xpointer = self.plugin.ui.document:getXPointer()
        end)
    end

    logger.dbg("SyncController: Parsed", self.total_sentences, "sentences")

    -- Show playback bar only if not already showing (preserves bar across page turns)
    if not self.playback_bar then
        self:showPlaybackBar()
    end

    -- Begin reading the first sentence
    self:readNextSentence()
end

--[[--
Synthesize and play the next sentence in the queue.
Chains automatically: when a sentence finishes, this is called again.
--]]
function SyncController:readNextSentence()
    local next_idx = self.reading_sentence_idx + 1

    -- Guard: reject backward jumps caused by stale scheduled callbacks.
    -- _highest_dispatched_idx tracks the highest sentence index ever passed
    -- to beginSentencePlayback on the current page.  If a callback fires
    -- late and tries to read a sentence we already played, skip it.
    if self._highest_dispatched_idx and next_idx <= self._highest_dispatched_idx then
        logger.warn("SyncController: readNextSentence REJECTED stale idx=", next_idx,
            " (already dispatched up to", self._highest_dispatched_idx, ")")
        return
    end

    self.reading_sentence_idx = next_idx
    logger.warn("SyncController: readNextSentence idx=", self.reading_sentence_idx, "/", self.total_sentences, "state=", self.state)

    if self.reading_sentence_idx > self.total_sentences then
        -- All sentences on this page are done
        logger.warn("SyncController: All", self.total_sentences, "sentences done, auto_advance=", self.plugin and self.plugin:getSetting("auto_advance", true))
        if self.plugin and self.plugin:getSetting("auto_advance", true) then
            self:advanceToNextPage()
        else
            self:stop()
        end
        return
    end

    local sentence = self.parsed_data.sentences[self.reading_sentence_idx]
    if not sentence or not sentence.text or sentence.text == "" then
        -- Skip empty sentence
        self:readNextSentence()
        return
    end

    self.state = self.STATE.LOADING
    local controller = self

    -- espeak-only mode: skip all Piper queueing/waiting
    if self._piper_abandoned and self.tts_engine and self.tts_engine.espeak_bin then
        logger.dbg("SyncController: espeak-only mode, sentence", self.reading_sentence_idx)
        local fb_file = self.tts_engine:espeakSynthesizeFallback(sentence.text)
        if fb_file then
            controller:applySentenceTiming(sentence, self.tts_engine.timing_data)
            controller:beginSentencePlayback(sentence)
            return
        end
        -- espeak failed, skip sentence
        self:readNextSentence()
        return
    end

    logger.dbg("SyncController: Reading sentence",
        self.reading_sentence_idx, "/", self.total_sentences, ":",
        sentence.text:sub(1, 60))

    -- Check if we already prefetched this sentence's audio
    local used_prefetch = self.tts_engine:usePrefetched(sentence.text)
    if used_prefetch then
        -- Audio is ready — apply timing and start playback immediately
        logger.warn("SyncController: Using prefetched audio for sentence", self.reading_sentence_idx)
        self._piper_warmed_up = true
        controller:applySentenceTiming(sentence, self.tts_engine.timing_data)
        controller:beginSentencePlayback(sentence)
        return
    end

    -- For Piper: if a prefetch is pending/queued, wait for it instead of
    -- launching a duplicate synthesis (which wastes ~11s and RAM).
    local piper_status = self.tts_engine:getPiperPrefetchStatus(sentence.text)
    local my_chain_gen = self._chain_generation or 0
    if piper_status == "pending" or piper_status == "queued" then
        -- Low-resource mode: the currently needed sentence jumps ahead of
        -- queued lookahead entries so it is synthesized first.
        if piper_status == "queued"
                and self.tts_engine._piperLowResource
                and self.tts_engine:_piperLowResource() then
            self.tts_engine._piper:prioritize(sentence.text)
        end
        -- ── espeak cold-start fallback ─────────────────────────────
        -- While Piper hasn't delivered any audio yet, keep playing via
        -- espeak so the user never hits a dead stall on slow hardware.
        local use_espeak_early = self.plugin
            and self.plugin:getSetting("espeak_cold_start", true)
            and self.tts_engine.espeak_bin
            and not self._piper_warmed_up
        if use_espeak_early then
            logger.warn("SyncController: espeak cold-start fallback for sentence",
                self.reading_sentence_idx, "(early, Piper status:", piper_status, ")")
            local fb_file = self.tts_engine:espeakSynthesizeFallback(sentence.text)
            if fb_file then
                self._espeak_fallback_count = (self._espeak_fallback_count or 0) + 1
                self:_checkPiperAbandon()
                controller:applySentenceTiming(sentence, self.tts_engine.timing_data)
                controller:beginSentencePlayback(sentence)
                return
            end
            logger.warn("SyncController: espeak early fallback failed, waiting for Piper")
        end

        logger.warn("SyncController: Waiting for Piper prefetch (status:", piper_status,
            ") for sentence", self.reading_sentence_idx,
            "|", self.tts_engine:getPiperQueueSnapshot())
        local poll_count = 0
        local max_polls = 600  -- 150 s hard timeout (buffer wait can add time)
        local target_ready_at = nil  -- timestamp when target first became ready
        local _toast_shown = {}  -- track slow-synthesis toasts per sentence

        -- Count how many consecutive sentences AFTER the target are ready.
        local function countReadyAhead()
            local count = 0
            for offset = 1, MIN_READY_AHEAD + 2 do
                local ai = controller.reading_sentence_idx + offset
                if not controller.parsed_data or ai > controller.total_sentences then break end
                local s = controller.parsed_data.sentences[ai]
                if not s or not s.text or s.text == "" then break end
                local st = controller.tts_engine:getPiperPrefetchStatus(s.text)
                if st ~= "ready" then break end
                count = count + 1
            end
            return count
        end

        local function waitForPiperPrefetch()
            if controller.state == controller.STATE.STOPPED then return end
            if (controller._chain_generation or 0) ~= my_chain_gen then
                logger.warn("SyncController: waitForPiperPrefetch STALE gen=", my_chain_gen, ", bailing")
                return
            end
            poll_count = poll_count + 1

            -- Piper was abandoned mid-wait (RTF escalation stage 2): stop
            -- waiting for audio that will never arrive.
            if controller._piper_abandoned then
                controller:_playViaEspeakOrSkip(sentence, "piper abandoned mid-wait")
                return
            end

            -- Every ~4 s, check whether Piper is sustainably keeping up.
            if poll_count % 16 == 0 then
                controller:_checkPiperRtfEscalation()
                if controller._piper_abandoned then
                    controller:_playViaEspeakOrSkip(sentence, "piper too slow (rtf)")
                    return
                end
            end

            -- Slow-synthesis warning: on underpowered devices Piper can take
            -- 30-75s per sentence.  Warn the user so they don't think it's frozen.
            if poll_count == 20 and not _toast_shown.slow then
                _toast_shown.slow = true
                -- Estimate from measured synthesis speed when available:
                -- the old fixed "20-40 seconds" claim was wildly optimistic
                -- on single-core devices (real: 60-150 s).
                local pq = controller.tts_engine and controller.tts_engine._piper
                local avg_s = pq and pq.getAvgSentenceSynthS and pq:getAvgSentenceSynthS()
                local wait_text
                if avg_s and avg_s >= 1 then
                    wait_text = T(_("Neural synthesis in progress...\nThis device needs about %1 seconds per sentence."),
                        tostring(math.floor(avg_s + 0.5)))
                else
                    wait_text = _("Neural synthesis in progress...\nPlease wait.")
                end
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = wait_text,
                    timeout = 4,
                })
            elseif poll_count == 60 and not _toast_shown.veryslow then
                _toast_shown.veryslow = true
                local InfoMessage = require("ui/widget/infomessage")
                UIManager:show(InfoMessage:new{
                    text = _("Piper is still synthesizing.\nFor faster playback, switch to the espeak backend in Tools → Audiobook → TTS Engine."),
                    timeout = 6,
                })
            end

            -- Use non-consuming peek so we can delay playback for buffering
            local pf_file = controller.tts_engine:peekPrefetch(sentence.text)
            if pf_file then
                -- Target sentence is ready.
                if not target_ready_at then
                    target_ready_at = UIManager:getTime()
                end

                -- Accumulate buffer: wait for more consecutive sentences
                local ready_ahead = countReadyAhead()
                local remaining  = controller.total_sentences - controller.reading_sentence_idx
                local min_needed = math.min(MIN_READY_AHEAD, remaining)
                local enough     = ready_ahead >= min_needed
                local elapsed_s  = time.to_s(UIManager:getTime() - target_ready_at)
                local timed_out  = elapsed_s >= BUFFER_FILL_TIMEOUT_S

                if enough or timed_out then
                    -- Consume the prefetch and start playback
                    local ok = controller.tts_engine:usePrefetched(sentence.text)
                    if ok then
                        logger.warn("SyncController: Piper prefetch arrived for sentence",
                            controller.reading_sentence_idx, "after",
                            poll_count * 0.25, "s  buffer:",
                            ready_ahead, "ahead",
                            string.format("(%.1fs since ready, %s)",
                                elapsed_s, enough and "enough" or "timeout"),
                            "|", controller.tts_engine:getPiperQueueSnapshot())
                        controller._piper_warmed_up = true
                        controller:applySentenceTiming(sentence, controller.tts_engine.timing_data)
                        controller:beginSentencePlayback(sentence)
                        return
                    end
                end

                -- Keep waiting for more buffer to accumulate
                if poll_count < max_polls then
                    UIManager:scheduleIn(0.25, waitForPiperPrefetch)
                else
                    -- Hard timeout: play whatever we have
                    local ok = controller.tts_engine:usePrefetched(sentence.text)
                    if ok then
                        controller._piper_warmed_up = true
                        controller:applySentenceTiming(sentence, controller.tts_engine.timing_data)
                        controller:beginSentencePlayback(sentence)
                    else
                        logger.err("SyncController: Piper prefetch hard timeout, espeak fallback")
                        controller:_playViaEspeakOrSkip(sentence, "piper prefetch hard timeout")
                    end
                end
                return
            end

            -- Target not ready yet — check for failure
            local st = controller.tts_engine:getPiperPrefetchStatus(sentence.text)
            if st == "failed" or (not st) then
                -- Once Piper is known to be too slow (degrade stage >= 1),
                -- the direct synthesize fallback just stalls for 60 s and
                -- times out; go straight to espeak instead.
                if controller._piper_abandoned
                        or (controller._piper_degrade_stage or 0) >= 1 then
                    logger.warn("SyncController: Piper prefetch failed/gone, espeak fallback (degraded)")
                    controller:_playViaEspeakOrSkip(sentence, "piper prefetch failed")
                    return
                end
                logger.warn("SyncController: Piper prefetch failed/gone, falling back to synthesize")
                controller.tts_engine:synthesize(sentence.text, function(synth_success, timing_data)
                    if not synth_success then
                        controller:_playViaEspeakOrSkip(sentence, "piper synthesize failed")
                        return
                    end
                    controller:applySentenceTiming(sentence, timing_data)
                    controller:beginSentencePlayback(sentence)
                end)
                return
            end
            if poll_count < max_polls then
                UIManager:scheduleIn(0.25, waitForPiperPrefetch)
            else
                logger.err("SyncController: Piper prefetch wait timed out, espeak fallback")
                controller:_playViaEspeakOrSkip(sentence, "piper prefetch wait timeout")
            end
        end
        UIManager:scheduleIn(0.25, waitForPiperPrefetch)
        return
    end

    -- For Piper with no prefetch yet: route the CURRENT sentence through
    -- the prefetch queue (instead of synthesize()) so the serial queue
    -- processes it AND the lookahead sentences back-to-back.
    -- synthesize() would set _piper_synthesizing=true which blocks the
    -- entire prefetch queue during the initial ~11s synthesis — wasting
    -- the time that could be spent prefetching sentence 2+.
    if self.tts_engine and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
        logger.warn("SyncController: Queueing sentence", self.reading_sentence_idx,
            "via Piper prefetch queue (", sentence.text:sub(1,40), ")")
        -- Queue current sentence + lookahead
        self.tts_engine:piperPrefetchAsync(sentence.text)
        for offset = 1, PIPER_LOOKAHEAD do
            local ahead_idx = self.reading_sentence_idx + offset
            if self.parsed_data and ahead_idx <= self.total_sentences then
                local ahead_sent = self.parsed_data.sentences[ahead_idx]
                if ahead_sent and ahead_sent.text and ahead_sent.text ~= "" then
                    self.tts_engine:piperPrefetchAsync(ahead_sent.text)
                end
            end
        end
        -- Kick the launcher AFTER all sentences are queued so the batcher
        -- can group consecutive sentences per Piper call.
        self.tts_engine:_launchNextPiperPrefetch()

        -- ── espeak-ng cold-start fallback ──────────────────────────
        -- Piper batches take 30-70s to synthesize on ARM.  If the user
        -- enabled the fallback, play the first sentence immediately via
        -- espeak-ng (~300ms) so there's no dead silence while Piper
        -- warms up.  Subsequent sentences use Piper as normal.
        local use_espeak_fallback = self.plugin
            and self.plugin:getSetting("espeak_cold_start", true)
            and self.tts_engine.espeak_bin
            and not self._piper_warmed_up
        if use_espeak_fallback then
            logger.warn("SyncController: espeak cold-start fallback for sentence",
                self.reading_sentence_idx)
            local fb_file = self.tts_engine:espeakSynthesizeFallback(sentence.text)
            if fb_file then
                self._espeak_fallback_count = (self._espeak_fallback_count or 0) + 1
                self:_checkPiperAbandon()
                controller:applySentenceTiming(sentence, self.tts_engine.timing_data)
                controller:beginSentencePlayback(sentence)
                return  -- Piper keeps synthesizing in background; readNextSentence will pick up Piper audio
            end
            -- If espeak fallback failed, fall through to Piper wait
            logger.warn("SyncController: espeak fallback failed, waiting for Piper")
        end

        -- Show notification while waiting for Piper (no espeak fallback or it failed)
        local InfoMessage = require("ui/widget/infomessage")
        UIManager:show(InfoMessage:new{
            text = "Starting neural TTS, please wait…",
            timeout = 3,
        })

        -- Now wait for the current sentence to become ready
        local poll_count = 0
        local max_polls = 360  -- 90s timeout (batches can take 40-70s on ARM)
        local function waitForPiperSynth()
            if controller.state == controller.STATE.STOPPED then return end
            if (controller._chain_generation or 0) ~= my_chain_gen then
                logger.warn("SyncController: waitForPiperSynth STALE gen=", my_chain_gen, ", bailing")
                return
            end
            poll_count = poll_count + 1
            if controller._piper_abandoned then
                controller:_playViaEspeakOrSkip(sentence, "piper abandoned mid-wait")
                return
            end
            if poll_count % 16 == 0 then
                controller:_checkPiperRtfEscalation()
                if controller._piper_abandoned then
                    controller:_playViaEspeakOrSkip(sentence, "piper too slow (rtf)")
                    return
                end
            end
            local ok = controller.tts_engine:usePrefetched(sentence.text)
            if ok then
                logger.warn("SyncController: Piper queue delivered sentence",
                    controller.reading_sentence_idx, "after", poll_count * 0.25, "s",
                    "|", controller.tts_engine:getPiperQueueSnapshot())
                controller:applySentenceTiming(sentence, controller.tts_engine.timing_data)
                controller:beginSentencePlayback(sentence)
                return
            end
            local st = controller.tts_engine:getPiperPrefetchStatus(sentence.text)
            if st == "failed" or (not st) then
                logger.err("SyncController: Piper queue failed for sentence",
                    controller.reading_sentence_idx, ", espeak fallback")
                controller:_playViaEspeakOrSkip(sentence, "piper queue failed")
                return
            end
            if poll_count < max_polls then
                UIManager:scheduleIn(0.25, waitForPiperSynth)
            else
                logger.err("SyncController: Piper queue timed out for sentence",
                    controller.reading_sentence_idx, ", espeak fallback")
                controller:_playViaEspeakOrSkip(sentence, "piper queue timeout")
            end
        end
        UIManager:scheduleIn(0.25, waitForPiperSynth)
        return
    end

    -- No prefetch available — synthesize now (first sentence, or prefetch missed)
    logger.warn("SyncController: Synthesizing sentence", self.reading_sentence_idx, "(", sentence.text:sub(1,40), ")")

    local success = self.tts_engine:synthesize(sentence.text, function(synth_success, timing_data)
        if not synth_success then
            logger.warn("SyncController: Synthesis failed for sentence", controller.reading_sentence_idx)
            -- Piper failure: degrade the voice rather than drop book content
            if controller.tts_engine.backend == controller.tts_engine.BACKENDS.PIPER then
                controller:_playViaEspeakOrSkip(sentence, "piper synthesize failed")
            else
                controller:readNextSentence()
            end
            return
        end

        -- Apply timing data to this sentence's words
        controller:applySentenceTiming(sentence, timing_data)

        -- Begin audio playback for this sentence
        controller:beginSentencePlayback(sentence)
    end)

    if success == false then
        -- synthesize() returned false immediately (no backend, etc.)
        self:readNextSentence()
    end
end

--[[--
Apply timing information to the words of a sentence.
@param sentence table Sentence object from parsed_data
@param timing_data table Timing array from TTS engine (may be nil)
--]]
function SyncController:applySentenceTiming(sentence, timing_data)
    if timing_data and #timing_data > 0 then
        for i, word in ipairs(sentence.words) do
            if timing_data[i] then
                word.start_time = timing_data[i].start_time
                word.end_time = timing_data[i].end_time
                word.duration = timing_data[i].end_time - timing_data[i].start_time
            end
        end
    else
        -- Fallback: estimate timing when no TTS timing data is available.
        -- For Piper (neural TTS), use character-length proportional timing
        -- which better reflects uniform-rate neural synthesis than syllable
        -- counting.  Values are scaled to match real WAV duration later,
        -- so only the proportions between words matter.
        local current_time = 0
        local is_piper = self.tts_engine
            and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER
        for _, word in ipairs(sentence.words) do
            local duration
            if is_piper then
                local chars = #(word.clean_text or word.text:gsub("[%%p]", ""))
                duration = math.floor(chars * 80)
                if word.text:match("[,;:]$") then
                    duration = duration + 150
                elseif word.text:match("[%.%%?!]$") then
                    duration = duration + 200
                end
            else
                duration = self.text_parser:estimateWordDuration(word)
            end
            word.start_time = current_time
            word.end_time = current_time + duration
            word.duration = duration
            current_time = current_time + duration + (is_piper and 30 or 50)
        end
    end
end

--[[--
Begin audio playback for one sentence.
Uses GStreamer's concat element to chain ALL remaining sentences on the
page into a single BT stream, eliminating every A2DP re-negotiation gap.
@param sentence table Sentence object
--]]
function SyncController:beginSentencePlayback(sentence)
    -- ── Fatal firmware error guard ──────────────────────────────
    -- If the TTS engine detected a permanent MTK firmware error,
    -- stop playback gracefully instead of retrying and risking
    -- flash filesystem corruption (observed on Kobo MTK devices).
    if self.tts_engine.player_error == "bt_firmware_missing"
        or self.tts_engine._bt_fw_fatal_error then
        logger.warn("SyncController: Stopping playback due to fatal BT firmware error")
        self.state = self.STATE.STOPPED
        -- Show the error notification once per session
        if not self._bt_fw_error_shown then
            self._bt_fw_error_shown = true
            if self.plugin and self.plugin.bt_manager then
                self.plugin.bt_manager:_showFirmwareError()
            elseif self.tts_engine._showMtkFirmwareError then
                self.tts_engine:_showMtkFirmwareError()
            end
        end
        -- Emit stop event so the playback bar reflects the stopped state
        UIManager:sendEvent(Event:new("AudiobookSync", self, "stopped"))
        -- Also clear any scheduled readNextSentence callbacks
        self._chain_generation = (self._chain_generation or 0) + 1
        return
    end

    logger.warn("SyncController: beginSentencePlayback sentence", sentence.index,
        "has_audio=", self.tts_engine.current_audio_file ~= nil)
    self.state = self.STATE.PLAYING
    self.current_sentence = sentence
    self.current_sentence_index = sentence.index
    self.current_word_index = 0
    -- Bump chain generation so stale completion callbacks bail out.
    self._chain_generation = (self._chain_generation or 0) + 1
    -- Track highest sentence ever dispatched for the backward-jump guard.
    self._highest_dispatched_idx = sentence.index
    -- Remember the first sentence's text so _remapAfterRotation can find
    -- reading_sentence_idx in a re-parsed page.
    self._first_play_sentence_text = sentence.text

    local controller = self

    -- Update playback bar
    if self.playback_bar then
        self.playback_bar:updatePlayState(true)
        self.playback_bar:updateProgress(self:getProgress())
    end
    -- Apply visibility now: state has just transitioned to PLAYING and the
    -- "paused_only" mode needs to suppress the bar on the first sentence,
    -- not only after a manual pause/resume cycle.  Issue #15 (PB632).
    self:_applyBarVisibility()

    -- Build concat pipeline with ALL remaining sentences on the page.
    -- Each extra sentence takes ~100-300 ms to synthesize on ARM — far
    -- less than the ~1.5 s BT A2DP re-negotiation gap it eliminates.
    local concat_files = nil         -- array of {file, duration_ms} for play()
    local concat_sentences = {}      -- sentence objects (N+1, N+2, …)
    local concat_split_points = {}   -- cumulative-ms boundaries for the sync loop
    local concat_wav_files = {}      -- WAV paths to clean up later

    if self.parsed_data and self.tts_engine.audio_player_type == "gst-bt" then
        local synth_t0 = UIManager:getTime()
        local first_dur = self.tts_engine:getAudioDurationMs()
        local cumulative_ms = first_dur
        concat_files = {}

        -- Read pause settings (seconds → milliseconds)
        -- For Piper, use the neural-specific gap settings; for espeak, use the legacy ones.
        local is_piper_backend = self.tts_engine
            and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER
        local sent_pause_s, para_pause_s
        if is_piper_backend then
            sent_pause_s = (self.plugin and self.plugin:getSetting("piper_sentence_gap", 0.3)) or 0.3
            para_pause_s = (self.plugin and self.plugin:getSetting("piper_paragraph_gap", 1.0)) or 1.0
        else
            sent_pause_s = (self.plugin and self.plugin:getSetting("sentence_pause", 0.1)) or 0.1
            para_pause_s = (self.plugin and self.plugin:getSetting("paragraph_pause", 0.8)) or 0.8
        end
        local sent_pause_ms = math.floor(sent_pause_s * 1000)
        local para_pause_ms = math.floor(para_pause_s * 1000)

        -- The first sentence just started playing.  Determine the
        -- inter-sentence pause that follows it.
        local prev_sent = sentence
        -- Track whether we padded the first sentence's WAV so play()
        -- uses the original (speech-only) duration for word timing.
        local first_padded = false

        for idx = self.reading_sentence_idx + 1, self.total_sentences do
            local sent = self.parsed_data.sentences[idx]
            if not sent or not sent.text or sent.text == "" then
                break
            end

            -- Check prefetch availability BEFORE applying gap padding.
            -- This prevents double-padding: if the sentence isn't ready and
            -- we break, we haven't padded the previous sentence.  The
            -- trailing-gap code after the loop handles the final padding.
            local pf_file, pf_timing, pf_dur = self.tts_engine:peekPrefetch(sent.text)
            if not pf_file then
                if self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                    logger.warn("SyncController: Concat: Piper sentence", idx, "not ready yet, stopping concat")
                    break
                end
                self.tts_engine:prefetch(sent.text)
                pf_file, pf_timing, pf_dur = self.tts_engine:peekPrefetch(sent.text)
            end
            if not pf_file or pf_dur <= 0 then
                logger.warn("SyncController: Concat synthesis failed at sentence", idx)
                break
            end

            -- Cap concat duration BEFORE applying gap padding.
            -- Very large merged WAVs can overwhelm the MTK Bluetooth sink's
            -- internal buffer, causing mid-playback audio repeats on long
            -- paragraphs.  When the limit is reached we break here; the
            -- trailing-gap code after the loop supplies the final padding.
            local MAX_CONCAT_MS = 30000
            if cumulative_ms + pf_dur > MAX_CONCAT_MS then
                logger.warn("SyncController: Concat duration limit reached (",
                    cumulative_ms + pf_dur, "ms >", MAX_CONCAT_MS,
                    "ms) at sentence", idx, "— splitting into next group")
                break
            end

            -- Sentence is available — apply inter-sentence gap to the
            -- PREVIOUS sentence's WAV (trailing silence).
            local pause_ms = 0
            if prev_sent then
                if prev_sent.end_type == "paragraph" then
                    pause_ms = para_pause_ms
                else
                    pause_ms = sent_pause_ms
                end
            end
            if pause_ms > 0 then
                local g_type = (prev_sent.end_type == "paragraph") and "paragraph" or "sentence"
                if prev_sent == sentence then
                    self.tts_engine:appendGapToWav(self.tts_engine.current_audio_file, pause_ms, g_type)
                    first_padded = true
                elseif #concat_files > 0 then
                    local prev_cf = concat_files[#concat_files]
                    if prev_cf and prev_cf.file then
                        self.tts_engine:appendGapToWav(prev_cf.file, pause_ms, g_type)
                        prev_cf.duration_ms = prev_cf.duration_ms + pause_ms
                    end
                end
                cumulative_ms = cumulative_ms + pause_ms
            end

            -- Apply and scale timing so word highlighting works
            controller:applySentenceTiming(sent, pf_timing)
            if sent.words and #sent.words > 0 then
                local last_w = sent.words[#sent.words]
                if last_w.end_time and last_w.end_time > 0 then
                    local scale = pf_dur / last_w.end_time
                    for _, w in ipairs(sent.words) do
                        if w.start_time then w.start_time = math.floor(w.start_time * scale) end
                        if w.end_time   then w.end_time   = math.floor(w.end_time   * scale) end
                        if w.duration   then w.duration   = math.floor(w.duration   * scale) end
                    end
                end
            end

            table.insert(concat_split_points, cumulative_ms)   -- this sentence starts here
            cumulative_ms = cumulative_ms + pf_dur

            table.insert(concat_files, { file = pf_file, duration_ms = pf_dur })
            table.insert(concat_sentences, sent)
            table.insert(concat_wav_files, pf_file)
            prev_sent = sent

            -- Transfer ownership: if this came from the Piper queue, remove
            -- the entry so cleanQueue doesn't double-delete the file.
            -- The file is now owned by concat_wav_files.
            self.tts_engine:consumePiperQueueEntry(sent.text)

            -- Protect espeak-ng prefetch file from _cleanPrefetch deletion
            self.tts_engine._prefetch_in_use = true

            logger.warn("SyncController: Concat +sentence", idx,
                "dur=", pf_dur, "ms  cumulative=", cumulative_ms, "ms")
        end

        -- Pad the LAST sentence in the play group with trailing silence
        -- matching the inter-sentence/paragraph gap.  This keeps the
        -- pipeline continuously fed with real PCM data across concat
        -- boundaries, eliminating the ~500ms of feeder idle-silence that
        -- accumulates in the pipe buffer between play() calls.
        local trailing_gap_ms = 0
        if prev_sent then
            if prev_sent.end_type == "paragraph" then
                trailing_gap_ms = para_pause_ms
            else
                trailing_gap_ms = sent_pause_ms
            end
        end
        if trailing_gap_ms > 0 then
            local tg_type = (prev_sent and prev_sent.end_type == "paragraph") and "paragraph" or "sentence"
            if #concat_files > 0 then
                local last_cf = concat_files[#concat_files]
                if last_cf and last_cf.file then
                    self.tts_engine:appendGapToWav(last_cf.file, trailing_gap_ms, tg_type)
                    last_cf.duration_ms = last_cf.duration_ms + trailing_gap_ms
                end
            else
                -- Single sentence: pad the main audio file
                self.tts_engine:appendGapToWav(self.tts_engine.current_audio_file, trailing_gap_ms, tg_type)
                if not first_padded then
                    first_padded = true
                end
            end
            cumulative_ms = cumulative_ms + trailing_gap_ms
        end
        -- Store trailing gap so play() can log it for diagnostics.
        self.tts_engine._trailing_gap_ms = trailing_gap_ms

        if #concat_files == 0 then concat_files = nil end

        -- Tell play() to use the original (unpadded) duration for the first
        -- sentence's word-timing scaling if we padded it with silence.
        if first_padded then
            self.tts_engine._unpadded_duration_ms = first_dur
        end

        logger.warn("SyncController: Concat synthesis total:",
            time.to_ms(UIManager:getTime() - synth_t0), "ms for",
            #concat_sentences, "extra sentences, trailing_gap=", trailing_gap_ms,
            "ms, sent_gap=", sent_pause_ms, "ms, para_gap=", para_pause_ms, "ms")
    end

    local sentences_in_play = 1 + #concat_sentences
    local my_chain_gen = self._chain_generation or 0

    -- Start TTS audio playback with callbacks
    local play_ok = self.tts_engine:play(
        -- Word callback
        function(timing, word_index)
            local word = sentence.words[word_index]
            if word then
                controller:highlightCurrentWord(word)
            end
        end,
        -- Completion callback — entire concat stream finished
        function()
            -- Bail if a newer beginSentencePlayback superseded us
            if (controller._chain_generation or 0) ~= my_chain_gen then
                logger.warn("SyncController: Completion callback STALE gen=", my_chain_gen,
                    "current=", controller._chain_generation, ", ignoring")
                return
            end
            local last_idx = sentence.index + sentences_in_play - 1
            logger.warn("SyncController: Completion callback, concat ending at sentence",
                last_idx, "state=", controller.state)
            controller.highlight_manager:clearHighlights()
            controller:_cleanConcatFiles()

            -- Skip reading index past all sentences played in this concat
            controller.reading_sentence_idx = controller.reading_sentence_idx + (sentences_in_play - 1)

            -- If the screen was rotated while this concat was playing,
            -- the page now shows different text.  Re-read the current page,
            -- find the last sentence we actually played, and update
            -- total_sentences / reading_sentence_idx so the "end of page?"
            -- check in readNextSentence() uses the new layout.
            local last_sent = #concat_sentences > 0
                and concat_sentences[#concat_sentences] or sentence
            if controller._rotated_during_playback then
                controller._rotated_during_playback = false
                local fresh_text = controller.plugin and controller.plugin:getCurrentPageText()
                if fresh_text then
                    local fresh_parsed = controller.text_parser:parse(fresh_text)
                    if fresh_parsed and #fresh_parsed.sentences > 0 then
                        -- Find the last-played sentence in the new page parse
                        local last_text = Utils.ws(last_sent.text)
                        local found_idx = nil
                        for i, s in ipairs(fresh_parsed.sentences) do
                            if Utils.ws(s.text) == last_text then
                                found_idx = i
                                break
                            end
                        end
                        if found_idx then
                            logger.warn("SyncController: Post-rotation re-check: last played sentence",
                                found_idx, "/", #fresh_parsed.sentences, "in new layout")
                            controller.parsed_data = fresh_parsed
                            controller.total_sentences = #fresh_parsed.sentences
                            controller.reading_sentence_idx = found_idx
                            controller._highest_dispatched_idx = found_idx
                            -- readNextSentence() will +1 → found_idx+1
                            -- If > total_sentences → advance; else play remaining
                        else
                            -- Last played sentence not found on current page
                            -- (it scrolled off entirely) — force page advance
                            logger.warn("SyncController: Post-rotation: last sentence not on page, advancing")
                            controller.reading_sentence_idx = controller.total_sentences
                            controller._highest_dispatched_idx = controller.total_sentences
                        end
                    end
                end
            end

            -- Pause duration based on the LAST sentence in the concat
            -- For neural TTS (Piper), the trailing gap silence is already
            -- padded into the audio file by the concat builder.  Use a
            -- minimal UIManager delay so the next sentence starts right
            -- after the padded silence finishes playing.
            local is_neural = controller.tts_engine
                and controller.tts_engine.backend == controller.tts_engine.BACKENDS.PIPER
            local delay = 0.2
            if is_neural then
                -- Gap always padded into audio for Piper — minimal scheduling delay
                delay = 0.05
                logger.warn("SyncController: Piper gap padded in audio (", last_sent.end_type, "), delay=0.05s")
            elseif last_sent.end_type == "paragraph" then
                delay = (controller.plugin and controller.plugin:getSetting("paragraph_pause", 0.8)) or 0.8
            else
                delay = (controller.plugin and controller.plugin:getSetting("sentence_pause", 0.1)) or 0.1
            end
            logger.warn("SyncController: Scheduling next sentence in", delay, "s",
                "from sentence=", last_sent.index, "state=", controller.state)
            local chain_func = function()
                controller._pending_chain_func = nil
                -- Bail if a newer sentence started playing since this was scheduled
                if (controller._chain_generation or 0) ~= my_chain_gen then
                    logger.warn("SyncController: chain_func STALE gen=", my_chain_gen,
                        "current=", controller._chain_generation, ", ignoring")
                    return
                end
                if controller.state ~= controller.STATE.STOPPED then
                    controller:readNextSentence()
                else
                    logger.dbg("SyncController: chain timer fired after user-initiated stop",
                        "(was scheduled after sentence", last_sent.index, ")")
                end
            end
            -- Unschedule any stale chain_func from a previous completion
            if controller._pending_chain_func then
                UIManager:unschedule(controller._pending_chain_func)
            end
            controller._pending_chain_func = chain_func
            UIManager:scheduleIn(delay, chain_func)
        end,
        -- Failure callback
        function()
            logger.warn("SyncController: Async BT launch failure, stopping read-along")
            controller:_cleanConcatFiles()
            controller:stop()
        end,
        -- concat_files for gapless BT playback
        concat_files
    )

    if play_ok then
        -- Scale the FIRST sentence's word timings to match the real WAV
        -- duration.  play() scales engine.timing_data but the sync loop
        -- reads sentence.words which still have the raw espeak estimates.
        local first_dur = self.tts_engine._current_audio_duration_ms or 0
        if first_dur > 0 and sentence.words and #sentence.words > 0 then
            local last_w = sentence.words[#sentence.words]
            if last_w.end_time and last_w.end_time > 0 then
                local scale = first_dur / last_w.end_time
                for _, w in ipairs(sentence.words) do
                    if w.start_time then w.start_time = math.floor(w.start_time * scale) end
                    if w.end_time   then w.end_time   = math.floor(w.end_time   * scale) end
                    if w.duration   then w.duration   = math.floor(w.duration   * scale) end
                end
                logger.dbg("SyncController: Scaled sentence", sentence.index, "words by", scale)
            end
        end

        -- Track how many sentences are in this play() for progress reporting
        self._sentences_in_play = sentences_in_play

        if #concat_sentences > 0 then
            self._concat_sentences = concat_sentences
            self._concat_split_points = concat_split_points
            self._concat_boundary_idx = 0
            self._concat_wav_files = concat_wav_files
            -- For Piper: schedule prefetch for sentences BEYOND the concat
            -- batch so they'll be ready when this concat stream finishes.
            if self.tts_engine and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                local last_concat_idx = self.reading_sentence_idx + #concat_sentences
                for offset = 1, PIPER_LOOKAHEAD do
                    self:_prefetchNextSentence(last_concat_idx + offset)
                end
            end
            -- Schedule next-page prefetch in background so it's ready
            -- when we finish all sentences on this page.
            self:_prefetchNextPage()
        else
            self._concat_sentences = nil
            self._concat_split_points = nil
            self._concat_boundary_idx = nil
            self._concat_wav_files = nil
            -- Single sentence — prefetch upcoming ones.
            -- For Piper (~4-5× real-time on ARM), queue 20 sentences so
            -- both servers always have batches waiting.
            if self.tts_engine and self.tts_engine.backend == self.tts_engine.BACKENDS.PIPER then
                for offset = 1, PIPER_LOOKAHEAD do
                    self:_prefetchNextSentence(self.reading_sentence_idx + offset)
                end
            else
                self:_prefetchNextSentence()
            end
        end

        -- Highlight the sentence being read — show immediately so the user
        -- can see what is about to be spoken.  The highlight stays until the
        -- sync loop switches to the next sentence.
        if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
            -- Delay sentence highlight to roughly match when audio reaches
            -- the speaker.  For persistent BT pipeline the audio travels
            -- through a pipe buffer + BT codec; showing the highlight at
            -- that time keeps it synchronized with what the user hears.
            local hl_delay = 0.05
            if self.tts_engine._persistent_pipeline then
                hl_delay = math.max(0.05, (self.tts_engine.playback_latency_ms or 300) / 1000)
            end
            local hl_sched_time = UIManager:getTime()
            UIManager:scheduleIn(hl_delay, function()
                if controller.state == controller.STATE.STOPPED then return end
                local hl_delta = time.to_ms(UIManager:getTime() - hl_sched_time)
                logger.warn("SyncController: Highlighting sentence", sentence.index,
                    "(scheduled+" .. hl_delta .. "ms)")
                local ok, err = pcall(controller.highlightCurrentSentence, controller, sentence)
                if not ok then
                    logger.warn("SyncController: Sentence highlight failed:", err)
                end
            end)
        end

        -- Start sync loop for highlighting during this sentence
        self._latency_locked = false  -- will be computed from actual launch time
        self:startSentenceSyncLoop(sentence)
    else
        self:_cleanConcatFiles()
        logger.warn("SyncController: play() failed, stopping read-along")
        self:stop()
    end

    logger.dbg("SyncController: Playback started for sentence", sentence.index,
        #concat_sentences > 0 and ("(+concat " .. #concat_sentences .. " more)") or "")
end

--[[--
Prefetch a future sentence's audio in the background.
Called right after the current sentence starts playing, so espeak-ng
runs its synthesis while audio is streaming. When the current sentence
finishes, the next one's WAV is already on disk.
@param explicit_idx number|nil  If provided, prefetch this sentence index
                                instead of reading_sentence_idx + 1.
--]]
function SyncController:_prefetchNextSentence(explicit_idx)
    local next_idx = explicit_idx or (self.reading_sentence_idx + 1)
    if not self.parsed_data or next_idx > self.total_sentences then
        return -- nothing to prefetch
    end
    local next_sentence = self.parsed_data.sentences[next_idx]
    if not next_sentence or not next_sentence.text or next_sentence.text == "" then
        return
    end
    -- Defer prefetch so it doesn't block the UI thread.
    -- espeak-ng synthesis takes ~100-300ms - running it synchronously right
    -- after play() would freeze touch input.  A 200ms delay lets UIManager
    -- drain any queued touch/gesture events before the blocking synthesis
    -- starts.  The prefetched audio is still available well before a
    -- typical sentence finishes playing (~2-5s).
    local engine = self.tts_engine
    local text = next_sentence.text
    UIManager:scheduleIn(0.2, function()
        engine:prefetch(text)
    end)
end

--[[--
Clean up WAV files created for a multi-sentence concat pipeline.
Called when the pipeline finishes, is stopped, or is skipped.
--]]
function SyncController:_cleanConcatFiles()
    if self._concat_wav_files then
        for _, f in ipairs(self._concat_wav_files) do
            os.remove(f)
        end
    end
    self._concat_wav_files = nil
    self._concat_sentences = nil
    self._concat_split_points = nil
    self._concat_boundary_idx = nil
    -- Allow engine cleanup to proceed
    if self.tts_engine then
        self.tts_engine._prefetch_in_use = false
    end
end

--[[--
Prefetch the next page's text in the background.
Called when we're near the end of the current page's sentences so the
page transition is near-instant.
--]]
function SyncController:_prefetchNextPage()
    if self._next_page_prefetched then return end
    if not self.plugin or not self.plugin.ui then return end

    self._next_page_prefetched = true
    local plugin = self.plugin
    local controller = self

    -- Defer to avoid blocking the sync loop
    UIManager:scheduleIn(0.1, function()
        if controller.state == controller.STATE.STOPPED then return end
        local ui = plugin.ui
        if not ui or not ui.document then return end
        local Screen = require("device").screen

        if ui.rolling then
            -- Save position, peek forward one page, grab text, restore.
            -- No screen refresh occurs because we restore before UIManager
            -- gets a chance to repaint.
            local saved_pos = ui.document:getCurrentPos()
            -- Move the internal document position forward by one screen
            local page_height = Screen:getHeight()
            local next_pos = saved_pos + page_height
            ui.document:gotoPos(next_pos)
            local ok, res = pcall(ui.document.getTextFromPositions, ui.document,
                {x = 0, y = 0},
                {x = Screen:getWidth(), y = Screen:getHeight()},
                true)  -- do_not_draw_selection
            -- Restore immediately
            ui.document:gotoPos(saved_pos)

            if ok and res and res.text and res.text ~= "" then
                controller._next_page_text = res.text
                -- Parse the full next page and pre-queue ALL sentences.
                -- For Piper, this feeds them into the prefetch queue so
                -- both servers start synthesizing while the current page's
                -- audio is still playing.  By page-turn time, most or all
                -- of the next page's sentences will already be ready.
                local parsed = controller.text_parser:parse(res.text)
                if parsed and parsed.sentences and #parsed.sentences > 0 then
                    local is_piper = controller.tts_engine
                        and controller.tts_engine.backend == controller.tts_engine.BACKENDS.PIPER
                    if is_piper then
                        -- Queue the first 6 next-page sentences (2 batches
                        -- of 3) into the Piper prefetch system.  We don't
                        -- queue ALL sentences because that floods the queue
                        -- behind current-page work.  The remaining sentences
                        -- will be queued by readNextSentence's own lookahead
                        -- once the page actually turns.
                        local MAX_NEXT_PAGE_PREFETCH = 6
                        local queued = 0
                        for i, sent in ipairs(parsed.sentences) do
                            if i > MAX_NEXT_PAGE_PREFETCH then break end
                            if sent.text and sent.text ~= "" then
                                controller.tts_engine:piperPrefetchAsync(sent.text)
                                queued = queued + 1
                            end
                        end
                        -- Kick the launcher so batches start immediately
                        controller.tts_engine:_launchNextPiperPrefetch()
                        logger.warn("SyncController: Next page prefetched,",
                            #res.text, "chars,", queued, "of",
                            #parsed.sentences, "sentences queued for Piper")
                    else
                        -- espeak: just prefetch the first sentence (fast ~200ms)
                        local first_text = parsed.sentences[1].text
                        if first_text and first_text ~= "" then
                            controller.tts_engine:prefetch(first_text)
                        end
                        logger.warn("SyncController: Next page prefetched,", #res.text, "chars")
                    end
                end
            else
                logger.warn("SyncController: Next page prefetch — no text")
            end
        end
    end)
end

--[[--
Show the playback control bar.
--]]
--[[--
Reserve the playback bar's height in the document's bottom margin so the bar
never covers book text: the page reflows to end just above the bar.

We deliberately bypass ReaderTypeset's SetPageBottomMargin event — with "sync
top/bottom margins" enabled it would bump the TOP margin too, and it persists
to the user's configurable settings.  Instead we compute the same scaled values
ReaderTypeset:onSetPageMargins would and call document:setPageMargins directly:
nothing is persisted, and restoring is just re-sending the stock SetPageMargins
event with the user's own values.  Reflow on a slow e-ink CPU takes a moment,
which is acceptable at TTS start/stop (and is why start() defers, see above).

Rolling (CreDocument/EPUB) only — paged documents have fixed layout.
--]]
function SyncController:_reserveBarSpace()
    if self._bar_space_reserved then return end
    if not (self.plugin and self.plugin.ui and self.plugin.ui.rolling) then return end
    local ui = self.plugin.ui
    local tp = ui.typeset
    if not (tp and tp.unscaled_margins and ui.document and ui.document.setPageMargins) then return end
    if not (self.playback_bar and self.playback_bar.dimen) then return end
    local bar_h = self.playback_bar.dimen.h
    if not bar_h or bar_h <= 0 then return end
    local Screen = require("device").screen
    local m = tp.unscaled_margins
    -- Replicate ReaderTypeset:onSetPageMargins scaling (including footer height)
    local bottom = Screen:scaleBySize(m[4])
    if ui.view and ui.view.footer and not ui.view.footer.reclaim_height then
        bottom = bottom + ui.view.footer:getHeight()
    end
    local ok = pcall(ui.document.setPageMargins, ui.document,
        Screen:scaleBySize(m[1]), Screen:scaleBySize(m[2]),
        Screen:scaleBySize(m[3]), bottom + bar_h)
    if ok then
        self._bar_space_reserved = true
        ui:handleEvent(Event:new("UpdatePos"))
        logger.dbg("SyncController: reserved", bar_h, "px bottom margin for playback bar")
    end
end

--[[--
Give the reserved bottom-margin space back to the page.  Uses the stock
SetPageMargins event so the user's own margins (and repaint) are restored.
--]]
function SyncController:_releaseBarSpace()
    if not self._bar_space_reserved then return end
    self._bar_space_reserved = false
    if not (self.plugin and self.plugin.ui) then return end
    local ui = self.plugin.ui
    local tp = ui.typeset
    if tp and tp.unscaled_margins then
        ui:handleEvent(Event:new("SetPageMargins", tp.unscaled_margins))
        logger.dbg("SyncController: restored user page margins")
    end
end

function SyncController:showPlaybackBar()
    if self.playback_bar then
        self:hidePlaybackBar()
    end

    -- Load PlaybackBar module
    local PlaybackBar = dofile(PLUGIN_PATH .. "playbackbar.lua")

    self.playback_bar = PlaybackBar:new{
        sync_controller = self,
        on_play_pause = function()
            if self:isPlaying() then
                self:pause()
            elseif self:isPaused() then
                self:resume()
            end
        end,
        on_rewind = function()
            self:prevSentence()
        end,
        on_forward = function()
            self:nextSentence()
        end,
        on_close = function()
            self:stop()
        end,
        on_realign = function()
            self:realignToReadingPage()
        end,
    }

    self.playback_bar:show()

    -- Reflow the page so its text ends above the bar (nothing covered).
    self:_reserveBarSpace()

    -- Force an immediate UI refresh so the bar is painted on the very next
    -- cycle, even if another (toast) notification is still visible.
    UIManager:setDirty(self.playback_bar, "ui")

    -- Honor the visibility preference.  In "paused_only" mode the bar is
    -- created but immediately hidden so subsequent pause/resume calls can
    -- toggle it without re-creating the widget.
    self:_applyBarVisibility()
end

--[[--
Apply the playback_bar_visibility setting.  Called on bar creation, on
beginSentencePlayback (state -> PLAYING), and on every pause/resume so
the bar shows only while paused (or always) per the user preference.

Implementation note (issue #15, PB632 v0.1.5.79 regression):  earlier
versions toggled the bar by adding/removing it from the UIManager window
stack via show()/hide().  When the bar was hidden it lost its tap
interception, so taps fell through to the reader (page turn / dictionary)
and there was no way for the user to bring the bar back.  The overlay
auto-pause poller also misbehaved because the widget was no longer in the
stack.  We now keep the bar mounted at all times and only toggle painting
via setSuppressed(), so taps anywhere still pause and the menu/overlay
detection keeps working.
--]]
function SyncController:_applyBarVisibility()
    if not self.playback_bar then return end
    local mode = self.plugin and self.plugin:getSetting("playback_bar_visibility", "always")
        or "always"
    -- Make sure the bar is mounted.  showPlaybackBar() always mounts it on
    -- creation, but we re-show defensively here in case something else
    -- closed it.
    if not self.playback_bar:isVisible() then
        self.playback_bar:show()
    end
    local should_suppress = (mode == "paused_only") and self:isPlaying()
    self.playback_bar:setSuppressed(should_suppress)
end

--[[--
Hide the playback control bar and refresh the screen.
--]]
function SyncController:hidePlaybackBar()
    if self.playback_bar then
        self.playback_bar:hide()
        self.playback_bar = nil
    end
    -- Give the reserved bottom-margin space back to the page.
    self:_releaseBarSpace()
    -- Force full screen refresh on e-ink to cleanly remove bar and highlight artifacts
    UIManager:setDirty("all", "full")
end

--[[--
Navigate the view back to the page currently being read aloud.
Triggered by the re-align button on the PlaybackBar.
--]]
function SyncController:realignToReadingPage()
    if not self.reading_page_xpointer then
        logger.dbg("SyncController: No reading xpointer to realign to")
        return
    end
    if not self.plugin or not self.plugin.ui then return end
    local ui = self.plugin.ui
    if ui.rolling then
        ui:handleEvent(Event:new("GotoXPointer", self.reading_page_xpointer))
    end
    -- Re-apply sentence highlight after the page settles
    if self.current_sentence
            and self.plugin:getSetting("highlight_sentences", true) then
        local sentence = self.current_sentence
        UIManager:scheduleIn(0.3, function()
            pcall(self.highlightCurrentSentence, self, sentence)
        end)
    end
    self.current_word_index = 0  -- force word re-highlight
end

--[[--
Update the playback bar with current state.
--]]
function SyncController:updatePlaybackBar()
    if not self.playback_bar then
        return
    end

    -- Update current word display
    if self.current_sentence and self.current_word_index > 0 then
        for _, word in ipairs(self.current_sentence.words) do
            if word.index == self.current_word_index then
                self.playback_bar:updateCurrentWord(word.text)
                break
            end
        end
    end

    -- Update progress
    self.playback_bar:updateProgress(self:getProgress())

    -- Update play/pause state
    self.playback_bar:updatePlayState(self:isPlaying())
end

--[[--
Re-parse the visible page after a screen rotation and remap the currently-
playing sentence into the fresh parse.  Updates parsed_data, total_sentences,
reading_sentence_idx, current_sentence, and the concat_sentences array so
that highlight positioning, progress reporting, and page-end detection all
use the new layout.
--]]
function SyncController:_remapAfterRotation()
    if not self.plugin then return end

    local fresh_text = self.plugin:getCurrentPageText()
    if not fresh_text then
        logger.warn("SyncController: _remapAfterRotation — no page text")
        -- At minimum re-apply the highlight with the old sentence
        if self.current_sentence then
            pcall(self.highlightCurrentSentence, self, self.current_sentence)
        end
        return
    end

    local fresh_parsed = self.text_parser:parse(fresh_text)
    if not fresh_parsed or #fresh_parsed.sentences == 0 then
        logger.warn("SyncController: _remapAfterRotation — parse empty")
        if self.current_sentence then
            pcall(self.highlightCurrentSentence, self, self.current_sentence)
        end
        return
    end

    -- Find the currently-playing sentence in the fresh parse
    local cur_text = self.current_sentence and Utils.ws(self.current_sentence.text) or ""
    local found_idx = nil
    for i, s in ipairs(fresh_parsed.sentences) do
        if Utils.ws(s.text) == cur_text then
            found_idx = i
            break
        end
    end

    if not found_idx then
        -- Sentence scrolled off-screen after rotation.  Scan nearby pages
        -- (up to ±2 screens) to find it and scroll the view there.
        logger.warn("SyncController: _remapAfterRotation — sentence not on visible page, scanning nearby")
        local ui = self.plugin and self.plugin.ui
        if ui and ui.rolling and ui.document then
            local doc = ui.document
            local Screen = require("device").screen
            local page_h = Screen:getHeight()
            local saved_pos = doc:getCurrentPos()
            local target_pos = nil
            local scan_offsets = { -page_h, page_h, -2*page_h, 2*page_h }

            for _, offset in ipairs(scan_offsets) do
                local try_pos = math.max(0, saved_pos + offset)
                doc:gotoPos(try_pos)
                local ok, res = pcall(doc.getTextFromPositions, doc,
                    {x = 0, y = 0},
                    {x = Screen:getWidth(), y = Screen:getHeight()},
                    true)
                if ok and res and res.text then
                    local scan_parsed = self.text_parser:parse(res.text)
                    if scan_parsed then
                        for i, s in ipairs(scan_parsed.sentences) do
                            if Utils.ws(s.text) == cur_text then
                                found_idx = i
                                fresh_parsed = scan_parsed
                                fresh_text = res.text
                                target_pos = try_pos
                                logger.warn("SyncController: Found sentence at offset", offset, "idx", i)
                                break
                            end
                        end
                    end
                end
                if found_idx then break end
            end

            -- Always restore first — then navigate properly if we found it
            doc:gotoPos(saved_pos)

            if found_idx and target_pos then
                -- Navigate the view to the page containing our sentence.
                local delta_pages = math.floor((target_pos - saved_pos) / page_h + 0.5)
                if delta_pages ~= 0 then
                    ui:handleEvent(Event:new("GotoViewRel", delta_pages))
                    -- Update the reading xpointer for the re-align button
                    pcall(function()
                        self.reading_page_xpointer = doc:getXPointer()
                    end)
                    -- Re-read the actual visible text after navigation
                    -- (GotoViewRel may snap differently than raw gotoPos)
                    local nav_text = self.plugin:getCurrentPageText()
                    if nav_text then
                        local nav_parsed = self.text_parser:parse(nav_text)
                        if nav_parsed then
                            -- Re-find our sentence in the actual visible text
                            local nav_found = nil
                            for i, s in ipairs(nav_parsed.sentences) do
                                if Utils.ws(s.text) == cur_text then
                                    nav_found = i
                                    break
                                end
                            end
                            if nav_found then
                                found_idx = nav_found
                                fresh_parsed = nav_parsed
                            end
                        end
                    end
                end
            else
                -- Not found nearby — keep current view
                logger.warn("SyncController: Sentence not found within ±2 pages, keeping view")
                return
            end
        else
            return
        end
    end

    logger.warn("SyncController: _remapAfterRotation — mapped to sentence",
        found_idx, "/", #fresh_parsed.sentences)

    -- Carry forward the word timing from the old sentence objects into the
    -- matching new ones.  The concat audio is still playing, so the timing
    -- values (start_time, end_time) must stay identical.
    local old_sentences = self.parsed_data and self.parsed_data.sentences or {}
    for _, old_s in ipairs(old_sentences) do
        local old_t = Utils.ws(old_s.text)
        for _, new_s in ipairs(fresh_parsed.sentences) do
            if Utils.ws(new_s.text) == old_t then
                -- Copy word timings
                if old_s.words and new_s.words and #old_s.words == #new_s.words then
                    for wi, ow in ipairs(old_s.words) do
                        new_s.words[wi].start_time = ow.start_time
                        new_s.words[wi].end_time = ow.end_time
                        new_s.words[wi].duration = ow.duration
                    end
                end
                -- Copy end_type for pause calculation
                new_s.end_type = old_s.end_type or new_s.end_type
                break
            end
        end
    end

    -- Update core state
    self.parsed_data = fresh_parsed
    self.total_sentences = #fresh_parsed.sentences
    self.current_sentence = fresh_parsed.sentences[found_idx]
    self.current_sentence_index = found_idx

    -- The reading_sentence_idx tracks where the concat started — remap it
    -- so the completion callback's arithmetic stays correct.
    -- reading_sentence_idx currently points to the first sentence of the
    -- concat.  Find that sentence in the new parse too.
    if self._concat_sentences then
        -- Remap each concat sentence to its new-parse counterpart
        for ci, old_cs in ipairs(self._concat_sentences) do
            local ct = Utils.ws(old_cs.text)
            for _, new_s in ipairs(fresh_parsed.sentences) do
                if Utils.ws(new_s.text) == ct then
                    self._concat_sentences[ci] = new_s
                    break
                end
            end
        end
    end

    -- Fix reading_sentence_idx: it should point to the first sentence in
    -- the current play batch (the one before the concat extras)
    local first_text = self._first_play_sentence_text
    if first_text then
        for i, s in ipairs(fresh_parsed.sentences) do
            if Utils.ws(s.text) == Utils.ws(first_text) then
                self.reading_sentence_idx = i
                -- Update the backward-jump guard so post-rotation
                -- readNextSentence calls are accepted.
                self._highest_dispatched_idx = i
                break
            end
        end
    end

    -- Force word re-highlight on next tick
    self.current_word_index = 0

    -- Re-apply sentence highlight with the new sentence object
    if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
        self.highlight_manager:clearHighlights()
        pcall(self.highlightCurrentSentence, self, self.current_sentence)
    end

    -- Update progress bar
    if self.playback_bar then
        self.playback_bar:updateProgress(self:getProgress())
    end
end

--[[--
Sync loop for the current sentence.
Updates word highlighting based on elapsed time.
@param sentence table The sentence being played
--]]
function SyncController:startSentenceSyncLoop(sentence)
    -- Only set sentence_sync_start on a fresh start, not on resume.
    -- resume() already adjusts sentence_sync_start for pause duration.
    if not self._resuming_sync then
        self.sentence_sync_start = UIManager:getTime()
    end
    self._resuming_sync = false
    -- Generation counter: old sync loops exit when a new one starts
    self.sync_generation = (self.sync_generation or 0) + 1
    local my_generation = self.sync_generation

    local function syncUpdate()
        -- Only exit completely if stopped or superseded
        if self.state == self.STATE.STOPPED then
            return
        end
        if self.sync_generation ~= my_generation then
            return -- superseded by a newer sync loop
        end

        -- Auto-pause when a menu/dialog opens (we can't receive ShowConfigMenu events)
        -- IMPORTANT: this must run even when state==PAUSED so we can detect the
        -- overlay closing and call resume().  The old code checked state==PLAYING
        -- first, which caused the loop to exit permanently while paused.
        if self.playback_bar and self.playback_bar._isOverlayActive and self.playback_bar:_isOverlayActive() then
            if not self._auto_paused_by_overlay then
                self._auto_paused_by_overlay = true
                self:pause(true)   -- auto=true: overlay-initiated pause
            end
            -- Keep polling so we can resume when the overlay closes
            UIManager:scheduleIn(0.3, syncUpdate)
            return
        elseif self._auto_paused_by_overlay then
            self._auto_paused_by_overlay = false
            self:resume(true)      -- auto=true: only resumes if user didn't explicitly pause
            if self.state == self.STATE.PAUSED then
                -- User had explicitly paused — keep the sync loop alive
                -- but stay in the paused polling branch below.
                UIManager:scheduleIn(0.1, syncUpdate)
            end
            return -- if resume succeeded it restarts the sync loop itself
        end

        -- Detect screen rotation: CRe's native selection is wiped on redraw,
        -- and the visible text reflows (different sentences/word count on page).
        -- We must re-parse the page and remap all state to the new layout.
        local Screen = require("device").screen
        local cur_w, cur_h = Screen:getWidth(), Screen:getHeight()
        if self._last_screen_w and self._last_screen_h
                and (cur_w ~= self._last_screen_w or cur_h ~= self._last_screen_h) then
            self._last_screen_w = cur_w
            self._last_screen_h = cur_h
            -- Flag so the completion callback re-checks page boundaries
            self._rotated_during_playback = true
            -- Invalidate prefetched next page — page boundary shifted
            self._next_page_text = nil
            self._next_page_prefetched = false
            logger.warn("SyncController: Rotation detected during playback",
                "old=", self._last_screen_w, "x", self._last_screen_h,
                "new=", cur_w, "x", cur_h)

            -- Re-parse the visible page and remap current sentence
            local controller_ref = self
            UIManager:scheduleIn(0.3, function()
                if controller_ref.state == controller_ref.STATE.STOPPED then return end
                controller_ref:_remapAfterRotation()
            end)
        end
        self._last_screen_w = self._last_screen_w or cur_w
        self._last_screen_h = self._last_screen_h or cur_h

        -- Skip word-highlighting work when not actively playing
        if self.state ~= self.STATE.PLAYING then
            UIManager:scheduleIn(0.1, syncUpdate)
            return
        end

        -- Dynamic BT latency detection: poll GStreamer's stderr for the
        -- PLAYING transition.  Once detected, anchor the sync timer to NOW
        -- with only a small codec-buffering offset (~150ms).
        -- Fallback: if the process launched but we never see PLAYING (e.g.
        -- non-BT player), use 3000ms from launch as the static estimate.
        if not self._latency_locked then
            if self.tts_engine:isGstPlaying() then
                -- Audio output is about to flow (GStreamer PLAYING state or
                -- wav-play header confirmation).
                self.sentence_sync_start = UIManager:getTime()
                if self.tts_engine._persistent_pipeline then
                    -- Persistent pipeline: latency = feeder read delay +
                    -- pipe buffer + BT codec (~200ms).  Use engine's value.
                    self._locked_latency_ms = self.tts_engine.playback_latency_ms or 300
                elseif self.tts_engine.audio_player_type == "aplay" then
                    -- Direct ALSA playback (wav-play): virtually no latency
                    -- since audio starts as soon as frames are written.
                    self._locked_latency_ms = 100
                else
                    local warm = self.tts_engine._socket_clean
                    self._locked_latency_ms = warm and 500 or 1500
                end
                self._latency_locked = true
                logger.warn("SyncController: Sync anchored (persistent=",
                    self.tts_engine._persistent_pipeline ~= nil,
                    ", offset=", self._locked_latency_ms, "ms)")
            elseif self.tts_engine._audio_launched_at then
                -- Fallback: if 5s passed since launch without PLAYING, lock
                -- to the launch time with a static estimate.
                local since_launch = time.to_ms(UIManager:getTime() - self.tts_engine._audio_launched_at)
                if since_launch > 5000 then
                    self.sentence_sync_start = self.tts_engine._audio_launched_at
                    self._locked_latency_ms = 3000
                    self._latency_locked = true
                    logger.warn("SyncController: Sync fallback — 5s without PLAYING, using 3000ms")
                end
            end
            -- While waiting for PLAYING, don't advance highlighting at all.
            -- This prevents the highlight from rushing ahead on page transitions
            -- before BT audio actually starts.
            if not self._latency_locked then
                UIManager:scheduleIn(0.05, syncUpdate)
                return
            end
        end

        local elapsed = time.to_ms(UIManager:getTime() - self.sentence_sync_start)
        local latency = self._locked_latency_ms or self.tts_engine.playback_latency_ms or 0
        local adjusted = elapsed - latency

        -- Multi-sentence concat boundary detection: advance through split
        -- points as elapsed time crosses each one.
        if self._concat_sentences and self._concat_split_points then
            local switched = false
            while true do
                local next_b = (self._concat_boundary_idx or 0) + 1
                if next_b <= #self._concat_split_points
                        and adjusted >= self._concat_split_points[next_b] then
                    self._concat_boundary_idx = next_b
                    switched = true
                else
                    break
                end
            end
            if switched then
                local bi = self._concat_boundary_idx
                local next_sent = self._concat_sentences[bi]
                sentence = next_sent
                self.current_sentence = next_sent
                self.current_sentence_index = next_sent.index
                self.current_word_index = 0
                logger.warn("SyncController: Concat boundary → sentence", next_sent.index)
                -- Skip the separate clearHighlights() call — highlightSentence()
                -- already clears the old selection internally.  Calling both
                -- triggers TWO e-ink refreshes in rapid succession, which
                -- causes enough CPU load on ARM to starve the audio pipeline.
                if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
                    pcall(self.highlightCurrentSentence, self, next_sent)
                else
                    self.highlight_manager:clearHighlights()
                end
                if self.playback_bar then
                    self.playback_bar:updateProgress(self:getProgress())
                end
                -- When we reach the last 2 sentences, trigger next-page prefetch
                if bi >= #self._concat_sentences - 1 and not self._next_page_prefetched then
                    self:_prefetchNextPage()
                end
            end
        end

        -- Time offset for word lookup within the active concat sentence.
        -- Always read from self.current_sentence so that after rotation
        -- remapping the sync loop uses the fresh-parse sentence object.
        local active_sentence = self.current_sentence or sentence
        local time_offset = 0
        if self._concat_boundary_idx and self._concat_boundary_idx > 0
                and self._concat_split_points then
            time_offset = self._concat_split_points[self._concat_boundary_idx]
        end

        -- Find current word in the active sentence by time
        if adjusted > 0 then
            local word_time = adjusted - time_offset
            for _, word in ipairs(active_sentence.words) do
                if word.start_time and word.end_time then
                    if word_time >= word.start_time and word_time < word.end_time then
                        if word.index ~= self.current_word_index then
                            self:highlightCurrentWord(word)
                        end
                        break
                    end
                end
            end
        end

        -- Update playback bar
        self:updatePlaybackBar()

        -- Continue loop (20Hz is plenty for e-ink word highlighting)
        UIManager:scheduleIn(0.05, syncUpdate)
    end

    UIManager:scheduleIn(0.05, syncUpdate)
end

--[[--
Highlight the current word.
@param word table Word object
--]]
function SyncController:highlightCurrentWord(word)
    if not word then
        return
    end

    self.current_word_index = word.index

    if self.plugin and self.plugin:getSetting("highlight_words", true) then
        self.highlight_manager:highlightWord(word, self.parsed_data)
    end
end

--[[--
Highlight the current sentence.
@param sentence table Sentence object
--]]
function SyncController:highlightCurrentSentence(sentence)
    if not sentence then
        return
    end

    self.current_sentence_index = sentence.index
    self.highlight_manager:highlightSentence(sentence, self.parsed_data)
end

--[[--
Advance to the next page and continue reading.
--]]
function SyncController:advanceToNextPage()
    if not self.plugin or not self.plugin.ui then
        self:stop()
        return
    end

    -- Mark as loading during page transition
    self.state = self.STATE.LOADING

    -- Clear highlights from current page
    self.highlight_manager:clearHighlights()

    local ui = self.plugin.ui

    -- Navigate forward one page/view
    ui:handleEvent(Event:new("GotoViewRel", 1))

    -- If we prefetched the next page's text+audio, use it immediately
    -- after a minimal settle delay for the page turn animation.
    if self._next_page_text then
        local prefetched_text = self._next_page_text
        self._next_page_text = nil
        self._next_page_prefetched = false
        logger.warn("SyncController: Using prefetched next page text")
        UIManager:scheduleIn(0.05, function()
            if self.state == self.STATE.STOPPED then return end
            self:start(prefetched_text)
        end)
    else
        -- No prefetch available — wait for page render, get text, start.
        self._next_page_prefetched = false
        UIManager:scheduleIn(0.15, function()
            if self.state == self.STATE.STOPPED then return end
            local text = self.plugin:getCurrentPageText()
            if text and text ~= "" then
                self:start(text)
            else
                logger.dbg("SyncController: No more text to read")
                self:stop()
            end
        end)
    end
end

--[[--
Pause playback.
@param auto bool  true when called by the overlay auto-pause logic
--]]
function SyncController:pause(auto)
    if self.state == self.STATE.PLAYING then
        self.state = self.STATE.PAUSED
        self.pause_time = UIManager:getTime()
        self.tts_engine:pause()

        -- Track whether the pause originated from a user action (button tap)
        -- vs the automatic overlay detector.  On overlay close we only
        -- auto-resume when the user did NOT explicitly pause.
        if not auto then
            self._user_paused = true
        end

        if self.playback_bar then
            self.playback_bar:updatePlayState(false)
        end
        self:_applyBarVisibility()

        logger.dbg("SyncController: Paused (auto=", auto, ", user_paused=", self._user_paused, ")")
    end
end

--[[--
Resume playback.
@param auto bool  true when called by the overlay auto-resume logic
--]]
function SyncController:resume(auto)
    if self.state == self.STATE.PAUSED then
        -- If this is an auto-resume (overlay closed) but the user had
        -- explicitly paused, stay paused.
        if auto and self._user_paused then
            logger.dbg("SyncController: Skipping auto-resume — user paused")
            return
        end

        self.state = self.STATE.PLAYING
        -- Clear the user-paused flag on any successful resume
        self._user_paused = false

        -- Adjust sentence sync start to account for pause duration
        if self.sentence_sync_start and self.pause_time then
            local pause_duration = UIManager:getTime() - self.pause_time
            self.sentence_sync_start = self.sentence_sync_start + pause_duration
        end

        self.tts_engine:resume()

        if self.playback_bar then
            self.playback_bar:updatePlayState(true)
        end
        self:_applyBarVisibility()

        -- Re-apply sentence highlight — CRe's native selection is wiped
        -- whenever the page redraws (e.g. after rotation), so we must
        -- repaint it.
        if self.current_sentence
                and self.plugin
                and self.plugin:getSetting("highlight_sentences", true) then
            local sentence = self.current_sentence
            UIManager:scheduleIn(0.15, function()
                pcall(self.highlightCurrentSentence, self, sentence)
            end)
        end
        -- Reset current_word_index so the sync loop's "changed?" check
        -- will fire again and re-highlight the current word.
        self.current_word_index = 0

        -- Restart the sync loop for the current sentence.
        -- Set _resuming_sync so startSentenceSyncLoop doesn't reset
        -- the timing anchor that we just adjusted for pause duration.
        -- For the persistent BT pipeline add a short delay so gst-launch
        -- has time to drain the FIFO and the MTK sink stabilises before
        -- we start advancing word highlights.
        if self.current_sentence then
            self._resuming_sync = true
            local delay = (self.tts_engine and self.tts_engine._persistent_pipeline)
                and 0.25 or 0
            UIManager:scheduleIn(delay, function()
                if self.state == self.STATE.PLAYING then
                    self:startSentenceSyncLoop(self.current_sentence)
                end
            end)
        end

        logger.warn("SyncController: Resumed")
    end
end

--[[--
Play a sentence via the espeak fallback instead of dropping it.  Used when
Piper fails or times out for a sentence: silently skipping book content is
the worst possible failure mode, so degrade the voice instead.  Falls
through to readNextSentence() only when espeak is unavailable or fails.
@param sentence table
@param reason string  Log context
@return boolean  true when the sentence is being played via espeak
--]]
function SyncController:_playViaEspeakOrSkip(sentence, reason)
    if self.tts_engine and self.tts_engine.espeak_bin then
        logger.warn("SyncController: espeak fallback for sentence",
            self.reading_sentence_idx, "(", reason, ")")
        local fb_file = self.tts_engine:espeakSynthesizeFallback(sentence.text)
        if fb_file then
            self._espeak_fallback_count = (self._espeak_fallback_count or 0) + 1
            self:_checkPiperAbandon()
            self:applySentenceTiming(sentence, self.tts_engine.timing_data)
            self:beginSentencePlayback(sentence)
            return true
        end
        logger.warn("SyncController: espeak fallback failed (", reason,
            "), skipping sentence")
    else
        logger.warn("SyncController: no espeak fallback available (", reason,
            "), skipping sentence")
    end
    self:readNextSentence()
    return false
end

--[[--
RTF auto-degrade escalation.  PiperQueue's rolling realtime factor tells us
when synthesis is slower than playback and no amount of buffering will fix
the stall pattern:

  stage 0 → 1: apply low-resource mode and aggressive sentence splitting
               for the session, with a message explaining what changed.
               If the user already enabled both settings, there is nothing
               left to apply and we go straight to stage 2.
  stage 1 → 2: after PIPER_RTF_STAGE2_SAMPLES more batches are still above
               threshold, switch to espeak for the rest of the session.

Both stages are session-scoped: the user's saved settings are never
modified, and Piper is tried again on the next playback session.
--]]
function SyncController:_checkPiperRtfEscalation()
    if self._piper_abandoned then return end
    if not self.tts_engine or not self.tts_engine._piper then return end
    if self.tts_engine.backend ~= self.tts_engine.BACKENDS.PIPER then return end
    local pq = self.tts_engine._piper
    local rtf = pq:getRtf()
    if not rtf or rtf < PIPER_RTF_DEGRADE_THRESHOLD then return end

    local stage = self._piper_degrade_stage or 0
    local InfoMessage = require("ui/widget/infomessage")

    if stage == 0 then
        local already_low   = self.tts_engine:_piperLowResource()
        local already_split = self.tts_engine:_piperAggressiveSplit()
        if already_low and already_split then
            -- Nothing left to apply: the user already runs both mitigations
            -- and Piper still cannot keep up.  Skip stage 1: set the stage
            -- marker so the window check below passes immediately and we
            -- fall through to stage 2 in this same call.
            stage = 1
            self._piper_degrade_stage = 1
            self._piper_degrade_mark = pq:getRtfSampleCount() - PIPER_RTF_STAGE2_SAMPLES
        else
            if not already_low then self.tts_engine._session_low_resource = true end
            if not already_split then self.tts_engine._session_split_long = true end
            self._piper_degrade_stage = 1
            self._piper_degrade_mark = pq:getRtfSampleCount()
            local applied = {}
            if not already_low then table.insert(applied, _("low-resource mode")) end
            if not already_split then table.insert(applied, _("sentence splitting")) end
            logger.warn("SyncController: Piper RTF degrade stage 1, rtf=",
                string.format("%.2f", rtf), "applied:", table.concat(applied, ", "))
            UIManager:show(InfoMessage:new{
                text = T(_("Piper is synthesizing slower than playback (%1x realtime).\nApplying %2 to compensate (this session only)."),
                    string.format("%.1f", rtf), table.concat(applied, " + ")),
                timeout = 8,
            })
            return
        end
    end

    if stage == 1 then
        -- Give the stage-1 mitigations a fair window before concluding
        -- they are insufficient.
        if (pq:getRtfSampleCount() - (self._piper_degrade_mark or 0))
                < PIPER_RTF_STAGE2_SAMPLES then
            return
        end
        self._piper_degrade_stage = 2
        logger.warn("SyncController: Piper RTF degrade stage 2, rtf=",
            string.format("%.2f", rtf), "— espeak session fallback")
        self._piper_abandoned = true
        pcall(function() pq:shutdown() end)
        UIManager:show(InfoMessage:new{
            text = _("This device is too slow for Piper voices.\nSwitching to espeak for this session.\nPiper will be tried again the next time you start playback."),
            timeout = 8,
        })
    end
end

--[[--
Check whether Piper should be abandoned after too many consecutive espeak
fallbacks (i.e. Piper never delivered any audio).  Shows a one-time warning
explaining the situation, kills the Piper server to free CPU, and enables
the persistent "espeak-only mode" setting so subsequent sessions skip Piper.
Called from espeak fallback success paths in readNextSentence().
--]]
function SyncController:_checkPiperAbandon()
    if self._piper_abandoned then return end
    if (self._espeak_fallback_count or 0) < PIPER_ABANDON_THRESHOLD then return end

    self._piper_abandoned = true
    logger.warn("SyncController: Abandoning Piper after",
        self._espeak_fallback_count, "espeak fallbacks -- killing servers")
    pcall(function() self.tts_engine._piper:shutdown() end)

    -- Persist the setting so Piper is skipped on future sessions too
    if self.plugin then
        self.plugin:setSetting("espeak_only_mode", true)
    end

    -- Show a non-blocking warning so the user understands what happened
    local InfoMessage = require("ui/widget/infomessage")
    UIManager:show(InfoMessage:new{
        text = "Piper neural TTS could not keep up on this device "
            .. "(single-core ARM). After "
            .. tostring(self._espeak_fallback_count)
            .. " sentences, it still hadn't produced any audio.\n\n"
            .. "Switching to espeak-only mode for stable playback. "
            .. "To re-enable Piper, go to:\n"
            .. "  Audiobook > Voice settings > TTS engine",
        timeout = 10,
    })
end

--[[--
Stop playback completely.
--]]
function SyncController:stop()
    -- Log at WARN level with traceback when stopping from an active state
    -- so we can diagnose unexpected stops (e.g. "Chain BLOCKED" on Kindle).
    if self.state ~= self.STATE.STOPPED then
        local trace = debug.traceback("", 2)
        logger.warn("SyncController: stop() from state=", self.state,
            "sentence=", self.reading_sentence_idx, "/", self.total_sentences,
            "caller:", trace)
    end
    self.state = self.STATE.STOPPED

    -- Cancel any pending next-sentence timer so a stale closure cannot
    -- fire after stop (or worse, after a *new* session has started).
    if self._pending_chain_func then
        UIManager:unschedule(self._pending_chain_func)
        self._pending_chain_func = nil
    end

    if self.tts_engine then
        pcall(function() self.tts_engine:stop() end)
    end
    if self.highlight_manager then
        pcall(function() self.highlight_manager:clearHighlights() end)
    end

    -- Hide playback bar (also triggers full screen refresh)
    pcall(function() self:hidePlaybackBar() end)

    self.parsed_data = nil
    self.current_word_index = 0
    self.current_sentence_index = 0
    self.reading_sentence_idx = 0
    self._highest_dispatched_idx = nil
    self._piper_warmed_up = false
    self._piper_abandoned = false
    self._espeak_fallback_count = 0
    self._piper_degrade_stage = 0
    self._piper_degrade_mark = nil
    -- Session-scoped auto-degrade flags end with the session; the user's
    -- saved settings are never touched.
    if self.tts_engine then
        self.tts_engine._session_low_resource = nil
        self.tts_engine._session_split_long = nil
    end
    self.total_sentences = 0
    self.current_sentence = nil
    self.sentence_sync_start = nil
    self.pause_time = nil
    self.reading_page_xpointer = nil
    self._user_paused = false
    self._auto_paused_by_overlay = false
    self._latency_locked = false
    self._locked_latency_ms = nil
    self._next_page_text = nil
    self._next_page_prefetched = false
    self._last_screen_w = nil
    self._last_screen_h = nil
    self._rotated_during_playback = false
    self._first_play_sentence_text = nil
    self:_cleanConcatFiles()

    logger.warn("SyncController: Stopped")
end

--[[--
Jump to next sentence.
--]]
function SyncController:nextSentence()
    if not self.parsed_data or self.state == self.STATE.STOPPED then
        return
    end

    -- If we're mid-concat, advance reading index to the sentence currently
    -- being heard so readNextSentence skips past it.
    if self._concat_sentences and self._concat_boundary_idx
            and self._concat_boundary_idx > 0 then
        self.reading_sentence_idx = self._concat_sentences[self._concat_boundary_idx].index
    end

    self:_cleanConcatFiles()
    pcall(function() self.tts_engine:stop() end)
    self.highlight_manager:clearHighlights()

    -- User-initiated jump: reset backward-jump guard
    self._highest_dispatched_idx = nil
    -- readNextSentence() increments the index and starts the next one
    self:readNextSentence()
end

--[[--
Jump to previous sentence.
--]]
function SyncController:prevSentence()
    if not self.parsed_data or self.state == self.STATE.STOPPED then
        return
    end

    -- If mid-concat, figure out which sentence we're currently hearing
    local current_idx = self.reading_sentence_idx
    if self._concat_sentences and self._concat_boundary_idx
            and self._concat_boundary_idx > 0 then
        current_idx = self._concat_sentences[self._concat_boundary_idx].index
    end

    self:_cleanConcatFiles()
    pcall(function() self.tts_engine:stop() end)
    self.highlight_manager:clearHighlights()

    -- User-initiated jump: reset backward-jump guard
    self._highest_dispatched_idx = nil
    -- Go back 2 because readNextSentence() will increment by 1
    self.reading_sentence_idx = math.max(0, current_idx - 2)
    self:readNextSentence()
end

--[[--
Update text when page changes externally.
@param text string New page text
--]]
function SyncController:updateText(text)
    -- Restart with new text (preserves playback bar)
    self:start(text)
end

--[[--
Check if currently playing.
@return boolean
--]]
function SyncController:isPlaying()
    return self.state == self.STATE.PLAYING
end

--[[--
Check if currently paused.
@return boolean
--]]
function SyncController:isPaused()
    return self.state == self.STATE.PAUSED
end

--[[--
Check if stopped.
@return boolean
--]]
function SyncController:isStopped()
    return self.state == self.STATE.STOPPED
end

--[[--
Get current playback time within current sentence (ms).
@return number
--]]
function SyncController:getPlaybackTime()
    if self.sentence_sync_start then
        return time.to_ms(UIManager:getTime() - self.sentence_sync_start)
    end
    return 0
end

--[[--
Get current word index.
@return number
--]]
function SyncController:getCurrentWordIndex()
    return self.current_word_index
end

--[[--
Get current sentence index.
@return number
--]]
function SyncController:getCurrentSentenceIndex()
    return self.current_sentence_index
end

--[[--
Get total duration (not applicable for sentence-by-sentence, returns 0).
@return number
--]]
function SyncController:getTotalDuration()
    return 0
end

--[[--
Get progress as percentage (0-100).
Based on how many sentences of the current page have been read.
@return number
--]]
function SyncController:getProgress()
    if self.total_sentences > 0 then
        -- During a concat pipeline, the reading_sentence_idx points to
        -- sentence 1, but we may already be hearing sentence 5.  Use the
        -- concat boundary index to show real progress.
        local effective_idx = self.reading_sentence_idx
        if self._concat_sentences and self._concat_boundary_idx
                and self._concat_boundary_idx > 0 then
            effective_idx = self._concat_sentences[self._concat_boundary_idx].index
        end
        return math.min(100, (effective_idx / self.total_sentences) * 100)
    end
    return 0
end

return SyncController
