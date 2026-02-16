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

    if self.reading_sentence_idx > self.total_sentences then
        -- All sentences on this page are done
        logger.dbg("SyncController: All", self.total_sentences, "sentences done")
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

    -- Synthesize this single sentence
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
@param sentence table Sentence object
--]]
function SyncController:beginSentencePlayback(sentence)
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

    -- Start TTS audio playback with callbacks
    local play_ok = self.tts_engine:play(
        -- Word callback
        function(timing, word_index)
            local word = sentence.words[word_index]
            if word then
                controller:highlightCurrentWord(word)
            end
        end,
        -- Completion callback — chain to next sentence after a short delay
        -- (gives BT audio device time to release, prevents deep synchronous call chains)
        function()
            controller.highlight_manager:clearHighlights()
            UIManager:scheduleIn(0.2, function()
                if controller.state ~= controller.STATE.STOPPED then
                    controller:readNextSentence()
                end
            end)
        end
    )

    if play_ok then
        -- Highlight the sentence being read (deferred so it doesn't block audio)
        if self.plugin and self.plugin:getSetting("highlight_sentences", true) then
            UIManager:scheduleIn(0.1, function()
                local ok, err = pcall(controller.highlightCurrentSentence, controller, sentence)
                if not ok then
                    logger.warn("SyncController: Sentence highlight failed:", err)
                end
            end)
        end
        -- Start sync loop for highlighting during this sentence
        self:startSentenceSyncLoop(sentence)
    else
        -- play() failed (BT not connected, no audio device, etc.)
        -- Stop the entire reading chain rather than skipping endlessly.
        logger.warn("SyncController: play() failed, stopping read-along")
        self:stop()
    end

    logger.dbg("SyncController: Playback started for sentence", sentence.index)
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
    }

    self.playback_bar:show()
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
        if self.state ~= self.STATE.PLAYING then
            return
        end
        if self.sync_generation ~= my_generation then
            return -- superseded by a newer sync loop
        end

        local elapsed = time.to_ms(UIManager:getTime() - self.sentence_sync_start)
        -- Offset by BT latency — audio doesn't start until A2DP connects
        local latency = self.tts_engine.playback_latency_ms or 0
        local adjusted = elapsed - latency

        -- Find current word in this sentence by time
        if adjusted > 0 then
            for _, word in ipairs(sentence.words) do
                if word.start_time and word.end_time then
                    if adjusted >= word.start_time and adjusted < word.end_time then
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

        -- Continue loop
        UIManager:scheduleIn(0.03, syncUpdate)
    end

    UIManager:scheduleIn(0.03, syncUpdate)
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

    -- Wait for page to render, then continue reading the new page
    UIManager:scheduleIn(0.5, function()
        -- Bail out if the user pressed stop during the page advance
        if self.state == self.STATE.STOPPED then
            return
        end
        local text = self.plugin:getCurrentPageText()
        if text and text ~= "" then
            self:start(text) -- start() preserves playback bar across pages
        else
            logger.dbg("SyncController: No more text to read")
            self:stop()
        end
    end)
end

--[[--
Pause playback.
--]]
function SyncController:pause()
    if self.state == self.STATE.PLAYING then
        self.state = self.STATE.PAUSED
        self.pause_time = UIManager:getTime()
        self.tts_engine:pause()

        if self.playback_bar then
            self.playback_bar:updatePlayState(false)
        end

        logger.dbg("SyncController: Paused")
    end
end

--[[--
Resume playback.
--]]
function SyncController:resume()
    if self.state == self.STATE.PAUSED then
        self.state = self.STATE.PLAYING

        -- Adjust sentence sync start to account for pause duration
        if self.sentence_sync_start and self.pause_time then
            local pause_duration = UIManager:getTime() - self.pause_time
            self.sentence_sync_start = self.sentence_sync_start + pause_duration
        end

        self.tts_engine:resume()

        if self.playback_bar then
            self.playback_bar:updatePlayState(true)
        end

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

    pcall(function() self.tts_engine:stop() end)
    pcall(function() self.highlight_manager:clearHighlights() end)

    -- Hide playback bar (also triggers full screen refresh)
    self:hidePlaybackBar()

    self.parsed_data = nil
    self.current_word_index = 0
    self.current_sentence_index = 0
    self.reading_sentence_idx = 0
    self.total_sentences = 0
    self.current_sentence = nil
    self.sentence_sync_start = nil
    self.pause_time = nil

    logger.dbg("SyncController: Stopped")
end

--[[--
Jump to next sentence.
--]]
function SyncController:nextSentence()
    if not self.parsed_data or self.state == self.STATE.STOPPED then
        return
    end

    -- Stop current sentence playback
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

    -- Stop current sentence playback
    pcall(function() self.tts_engine:stop() end)
    self.highlight_manager:clearHighlights()

    -- Go back 2 because readNextSentence() will increment by 1
    self.reading_sentence_idx = math.max(0, self.reading_sentence_idx - 2)
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
        return math.min(100, ((self.reading_sentence_idx - 1) / self.total_sentences) * 100)
    end
    return 0
end

return SyncController
