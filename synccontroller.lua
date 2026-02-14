--[[--
Sync Controller Module
Coordinates TTS playback with text highlighting.

@module synccontroller
--]]

local UIManager = require("ui/uimanager")
local logger = require("logger")

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
    o.playback_time = 0
    o.playback_bar = nil
    
    return o
end

--[[--
Start read-along for given text.
@param text string The text to read
--]]
function SyncController:start(text)
    if self.state == self.STATE.PLAYING then
        self:stop()
    end
    
    self.state = self.STATE.LOADING
    logger.dbg("SyncController: Starting read-along with", #text, "characters")
    
    -- Parse the text
    self.parsed_data = self.text_parser:parse(text)
    
    if not self.parsed_data or #self.parsed_data.words == 0 then
        logger.warn("SyncController: No words found in text")
        self.state = self.STATE.STOPPED
        local InfoMessage = require("ui/widget/infomessage")
        local UIManager = require("ui/uimanager")
        UIManager:show(InfoMessage:new{
            text = "No words found in text to read.",
            timeout = 2,
        })
        return
    end
    
    logger.dbg("SyncController: Parsed", #self.parsed_data.words, "words")
    
    -- Reference to self for callback
    local controller = self
    
    -- Synthesize speech (now synchronous)
    local success = self.tts_engine:synthesize(text, function(synth_success, timing_data)
        logger.dbg("SyncController: Synthesis callback, success:", synth_success)
        
        if not synth_success then
            logger.err("SyncController: TTS synthesis failed")
            controller.state = controller.STATE.STOPPED
            return
        end
        
        -- Apply timing data to parsed text
        controller.text_parser:applyTimingData(controller.parsed_data, timing_data)
        
        -- Start playback
        controller:beginPlayback()
    end)
    
    -- If synthesize returned false immediately (before callback), we failed
    if success == false then
        logger.err("SyncController: synthesize() returned false")
        self.state = self.STATE.STOPPED
    end
end

--[[--
Begin audio playback with synchronization.
--]]
function SyncController:beginPlayback()
    self.state = self.STATE.PLAYING
    self.current_word_index = 0
    self.current_sentence_index = 0
    self.playback_time = 0
    
    -- Show playback bar
    self:showPlaybackBar()
    
    -- Start TTS playback
    self.tts_engine:play(
        -- Word callback
        function(timing, word_index)
            self:onWordUpdate(timing, word_index)
        end,
        -- Complete callback
        function()
            self:onPlaybackComplete()
        end
    )
    
    -- Start sync loop
    self:startSyncLoop()
    
    logger.dbg("SyncController: Playback started")
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
Hide the playback control bar.
--]]
function SyncController:hidePlaybackBar()
    if self.playback_bar then
        self.playback_bar:hide()
        self.playback_bar = nil
    end
end

--[[--
Update the playback bar with current state.
--]]
function SyncController:updatePlaybackBar()
    if not self.playback_bar then
        return
    end
    
    -- Update current word display
    if self.parsed_data and self.current_word_index > 0 then
        local word = self.text_parser:getWordByIndex(self.parsed_data, self.current_word_index)
        if word then
            self.playback_bar:updateCurrentWord(word.text)
        end
    end
    
    -- Update progress
    self.playback_bar:updateProgress(self:getProgress())
    
    -- Update play/pause state
    self.playback_bar:updatePlayState(self:isPlaying())
end

--[[--
Start the synchronization loop.
--]]
function SyncController:startSyncLoop()
    self.sync_start_time = UIManager:getTime()
    
    local function syncUpdate()
        if self.state ~= self.STATE.PLAYING then
            return
        end
        
        -- Calculate elapsed time
        local elapsed = (UIManager:getTime() - self.sync_start_time) * 1000 -- ms
        self.playback_time = elapsed
        
        -- Find current word
        local word = self.text_parser:getWordAtTime(self.parsed_data, elapsed)
        
        if word and word.index ~= self.current_word_index then
            self:highlightCurrentWord(word)
        end
        
        -- Check if we need to highlight sentence
        if self.plugin and self.plugin:getSetting("highlight_sentences", false) then
            local sentence = self.text_parser:getSentenceAtTime(self.parsed_data, elapsed)
            if sentence and sentence.index ~= self.current_sentence_index then
                self:highlightCurrentSentence(sentence)
            end
        end
        
        -- Update playback bar
        self:updatePlaybackBar()
        
        -- Schedule next update
        UIManager:scheduleIn(0.03, syncUpdate) -- ~33fps
    end
    
    UIManager:scheduleIn(0.03, syncUpdate)
end

--[[--
Handle word timing update from TTS engine.
@param timing table Timing data for current word
@param word_index number Index of current word
--]]
function SyncController:onWordUpdate(timing, word_index)
    if self.state ~= self.STATE.PLAYING then
        return
    end
    
    local word = self.text_parser:getWordByIndex(self.parsed_data, word_index)
    if word then
        self:highlightCurrentWord(word)
    end
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
    
    logger.dbg("SyncController: Highlighting word", word.index, ":", word.text)
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
    
    logger.dbg("SyncController: Highlighting sentence", sentence.index)
end

--[[--
Handle playback completion.
--]]
function SyncController:onPlaybackComplete()
    logger.dbg("SyncController: Playback complete")
    
    -- Clear highlights after a short delay
    UIManager:scheduleIn(0.5, function()
        if self.state ~= self.STATE.PLAYING then
            self.highlight_manager:clearHighlights()
        end
    end)
    
    -- Check for auto-advance
    if self.plugin and self.plugin:getSetting("auto_advance", true) then
        self:advanceToNextPage()
    else
        self.state = self.STATE.STOPPED
    end
end

--[[--
Advance to the next page and continue reading.
--]]
function SyncController:advanceToNextPage()
    if not self.plugin or not self.plugin.ui then
        self.state = self.STATE.STOPPED
        return
    end
    
    local ui = self.plugin.ui
    
    -- Try to go to next page
    if ui.document and ui.document:hasNextPage() then
        ui:handleEvent({
            handler = "onGotoPage",
            args = {ui.document:getCurrentPage() + 1}
        })
        
        -- Wait for page to render, then continue
        UIManager:scheduleIn(0.3, function()
            local text = self.plugin:getCurrentPageText()
            if text and text ~= "" then
                self:start(text)
            else
                self.state = self.STATE.STOPPED
            end
        end)
    else
        logger.dbg("SyncController: No more pages")
        self.state = self.STATE.STOPPED
    end
end

--[[--
Pause playback.
--]]
function SyncController:pause()
    if self.state == self.STATE.PLAYING then
        self.state = self.STATE.PAUSED
        self.pause_time = UIManager:getTime()
        self.tts_engine:pause()
        
        -- Update playback bar state
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
        -- Adjust start time for pause duration
        local pause_duration = UIManager:getTime() - self.pause_time
        self.sync_start_time = self.sync_start_time + pause_duration
        
        self.tts_engine:resume()
        
        -- Update playback bar state
        if self.playback_bar then
            self.playback_bar:updatePlayState(true)
        end
        
        self:startSyncLoop()
        logger.dbg("SyncController: Resumed")
    end
end

--[[--
Stop playback.
--]]
function SyncController:stop()
    if self.state ~= self.STATE.STOPPED then
        self.state = self.STATE.STOPPED
        self.tts_engine:stop()
        self.highlight_manager:clearHighlights()
        
        -- Hide playback bar
        self:hidePlaybackBar()
        
        self.parsed_data = nil
        self.current_word_index = 0
        self.current_sentence_index = 0
        self.playback_time = 0
        
        logger.dbg("SyncController: Stopped")
    end
end

--[[--
Jump to next sentence.
--]]
function SyncController:nextSentence()
    if not self.parsed_data or self.state == self.STATE.STOPPED then
        return
    end
    
    local next_index = self.current_sentence_index + 1
    local sentence = self.text_parser:getSentenceByIndex(self.parsed_data, next_index)
    
    if sentence and #sentence.words > 0 then
        local first_word = sentence.words[1]
        if first_word and first_word.start_time then
            self:seekToTime(first_word.start_time)
        end
    end
end

--[[--
Jump to previous sentence.
--]]
function SyncController:prevSentence()
    if not self.parsed_data or self.state == self.STATE.STOPPED then
        return
    end
    
    local prev_index = math.max(1, self.current_sentence_index - 1)
    local sentence = self.text_parser:getSentenceByIndex(self.parsed_data, prev_index)
    
    if sentence and #sentence.words > 0 then
        local first_word = sentence.words[1]
        if first_word and first_word.start_time then
            self:seekToTime(first_word.start_time)
        end
    end
end

--[[--
Seek to a specific time in the audio.
@param time_ms number Time in milliseconds
--]]
function SyncController:seekToTime(time_ms)
    -- Adjust sync start time to match seek position
    self.sync_start_time = UIManager:getTime() - (time_ms / 1000)
    self.playback_time = time_ms
    
    -- Update highlights immediately
    local word = self.text_parser:getWordAtTime(self.parsed_data, time_ms)
    if word then
        self:highlightCurrentWord(word)
    end
    
    local sentence = self.text_parser:getSentenceAtTime(self.parsed_data, time_ms)
    if sentence then
        self:highlightCurrentSentence(sentence)
    end
    
    logger.dbg("SyncController: Seeked to", time_ms, "ms")
end

--[[--
Update text when page changes.
@param text string New page text
--]]
function SyncController:updateText(text)
    -- This would handle dynamic text updates
    -- For now, just restart with new text
    self:stop()
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
Get current playback time in milliseconds.
@return number
--]]
function SyncController:getPlaybackTime()
    return self.playback_time
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
Get total duration in milliseconds.
@return number
--]]
function SyncController:getTotalDuration()
    if self.parsed_data and #self.parsed_data.words > 0 then
        local last_word = self.parsed_data.words[#self.parsed_data.words]
        return last_word.end_time or 0
    end
    return 0
end

--[[--
Get progress as percentage.
@return number 0-100
--]]
function SyncController:getProgress()
    local total = self:getTotalDuration()
    if total > 0 then
        return math.min(100, (self.playback_time / total) * 100)
    end
    return 0
end

return SyncController
