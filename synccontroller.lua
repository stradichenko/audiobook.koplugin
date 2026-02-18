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

-- Get plugin directory for relative requires
local function getPluginPath()
    local callerSource = debug.getinfo(1, "S").source
    if callerSource:find("^@") then
        return callerSource:gsub("^@(.*/)[^/]*", "%1")
    end
    return "./"
end
local PLUGIN_PATH = getPluginPath()

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
    self.reading_sentence_idx = self.reading_sentence_idx + 1
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

    logger.dbg("SyncController: Reading sentence",
        self.reading_sentence_idx, "/", self.total_sentences, ":",
        sentence.text:sub(1, 60))

    -- Check if we already prefetched this sentence's audio
    local used_prefetch = self.tts_engine:usePrefetched(sentence.text)
    if used_prefetch then
        -- Audio is ready — apply timing and start playback immediately
        logger.warn("SyncController: Using prefetched audio for sentence", self.reading_sentence_idx)
        controller:applySentenceTiming(sentence, self.tts_engine.timing_data)
        controller:beginSentencePlayback(sentence)
        return
    end

    -- No prefetch available — synthesize now (first sentence, or prefetch missed)
    logger.warn("SyncController: Synthesizing sentence", self.reading_sentence_idx, "(", sentence.text:sub(1,40), ")")
    local success = self.tts_engine:synthesize(sentence.text, function(synth_success, timing_data)
        if not synth_success then
            logger.warn("SyncController: Synthesis failed for sentence", controller.reading_sentence_idx)
            -- Skip failed sentence, try next
            controller:readNextSentence()
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
        -- Fallback: estimate timing from syllable count
        local current_time = 0
        for _, word in ipairs(sentence.words) do
            local duration = self.text_parser:estimateWordDuration(word)
            word.start_time = current_time
            word.end_time = current_time + duration
            word.duration = duration
            current_time = current_time + duration + 50
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
    logger.warn("SyncController: beginSentencePlayback sentence", sentence.index,
        "has_audio=", self.tts_engine.current_audio_file ~= nil)
    self.state = self.STATE.PLAYING
    self.current_sentence = sentence
    self.current_sentence_index = sentence.index
    self.current_word_index = 0

    local controller = self

    -- Update playback bar
    if self.playback_bar then
        self.playback_bar:updatePlayState(true)
        self.playback_bar:updateProgress(self:getProgress())
    end

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

        for idx = self.reading_sentence_idx + 1, self.total_sentences do
            local sent = self.parsed_data.sentences[idx]
            if not sent or not sent.text or sent.text == "" then
                break
            end

            -- Reuse existing prefetch, or synthesize synchronously
            local pf_file, pf_timing, pf_dur = self.tts_engine:peekPrefetch(sent.text)
            if not pf_file then
                self.tts_engine:prefetch(sent.text)
                pf_file, pf_timing, pf_dur = self.tts_engine:peekPrefetch(sent.text)
            end
            if not pf_file or pf_dur <= 0 then
                logger.warn("SyncController: Concat synthesis failed at sentence", idx)
                break
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

            -- Protect file from _cleanPrefetch deletion during next iteration
            self.tts_engine._prefetch_in_use = true

            logger.warn("SyncController: Concat +sentence", idx,
                "dur=", pf_dur, "ms  cumulative=", cumulative_ms, "ms")
        end

        if #concat_files == 0 then concat_files = nil end

        logger.warn("SyncController: Concat synthesis total:",
            time.to_ms(UIManager:getTime() - synth_t0), "ms for",
            #concat_sentences, "extra sentences")
    end

    local sentences_in_play = 1 + #concat_sentences

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
            local last_idx = sentence.index + sentences_in_play - 1
            logger.warn("SyncController: Completion callback, concat ending at sentence",
                last_idx, "state=", controller.state)
            controller.highlight_manager:clearHighlights()
            controller:_cleanConcatFiles()

            -- Skip reading index past all sentences played in this concat
            controller.reading_sentence_idx = controller.reading_sentence_idx + (sentences_in_play - 1)

            -- Pause duration based on the LAST sentence in the concat
            local last_sent = #concat_sentences > 0
                and concat_sentences[#concat_sentences] or sentence
            local delay = 0.2
            if last_sent.end_type == "paragraph" then
                delay = (controller.plugin and controller.plugin:getSetting("paragraph_pause", 0.8)) or 0.8
            else
                delay = (controller.plugin and controller.plugin:getSetting("sentence_pause", 0.1)) or 0.1
            end
            logger.warn("SyncController: Scheduling next sentence in", delay, "s")
            UIManager:scheduleIn(delay, function()
                if controller.state ~= controller.STATE.STOPPED then
                    controller:readNextSentence()
                else
                    logger.warn("SyncController: Chain BLOCKED — state is STOPPED when timer fired")
                end
            end)
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
            -- Schedule next-page prefetch in background so it's ready
            -- when we finish all sentences on this page.
            self:_prefetchNextPage()
        else
            self._concat_sentences = nil
            self._concat_split_points = nil
            self._concat_boundary_idx = nil
            self._concat_wav_files = nil
            -- Single sentence — prefetch the next one
            self:_prefetchNextSentence()
        end

        -- Highlight the sentence being read — show immediately so the user
        -- can see what is about to be spoken.  The highlight stays until the
        -- sync loop switches to the next sentence.
        if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
            UIManager:scheduleIn(0.05, function()
                if controller.state == controller.STATE.STOPPED then return end
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
    -- espeak-ng synthesis takes ~100-300ms — running it synchronously right
    -- after play() would freeze touch input.  Scheduling with a small delay
    -- lets UIManager process any pending touch events first.
    local engine = self.tts_engine
    local text = next_sentence.text
    UIManager:scheduleIn(0.05, function()
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
                -- Pre-synthesize the first sentence
                local parsed = controller.text_parser:parse(res.text)
                if parsed and parsed.sentences and #parsed.sentences > 0 then
                    local first_text = parsed.sentences[1].text
                    if first_text and first_text ~= "" then
                        controller.tts_engine:prefetch(first_text)
                    end
                end
                logger.warn("SyncController: Next page prefetched,", #res.text, "chars")
            else
                logger.warn("SyncController: Next page prefetch — no text")
            end
        end
    end)
end

--[[--
Show the playback control bar.
--]]
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

    -- Force an immediate UI refresh so the bar is painted on the very next
    -- cycle, even if another (toast) notification is still visible.
    UIManager:setDirty(self.playback_bar, "ui")
end

--[[--
Hide the playback control bar and refresh the screen.
--]]
function SyncController:hidePlaybackBar()
    if self.playback_bar then
        self.playback_bar:hide()
        self.playback_bar = nil
    end
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
Sync loop for the current sentence.
Updates word highlighting based on elapsed time.
@param sentence table The sentence being played
--]]
function SyncController:startSentenceSyncLoop(sentence)
    self.sentence_sync_start = UIManager:getTime()
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
                -- GStreamer just transitioned to PLAYING — audio is flowing.
                -- Offset for BT codec buffering + transmission to earbuds.
                self.sentence_sync_start = UIManager:getTime()
                self._locked_latency_ms = 1500
                self._latency_locked = true
                logger.warn("SyncController: Sync anchored to GST PLAYING state")
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
                self.highlight_manager:clearHighlights()
                if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
                    pcall(self.highlightCurrentSentence, self, next_sent)
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

        -- Time offset for word lookup within the active concat sentence
        local active_sentence = sentence
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

        -- Restart the sync loop for the current sentence
        if self.current_sentence then
            self:startSentenceSyncLoop(self.current_sentence)
        end

        logger.dbg("SyncController: Resumed")
    end
end

--[[--
Stop playback completely.
--]]
function SyncController:stop()
    self.state = self.STATE.STOPPED

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
    self:_cleanConcatFiles()

    logger.dbg("SyncController: Stopped")
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
