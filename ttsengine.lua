--[[--
TTS Engine Module
Handles text-to-speech synthesis with timing metadata.

@module ttsengine
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffiutil = require("ffi/util")
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

local TTSEngine = {
    -- Supported TTS backends
    BACKENDS = {
        PICO = "pico",
        ESPEAK = "espeak", 
        FLITE = "flite",
        FESTIVAL = "festival",
        ANDROID = "android",
    },
    
    -- Default settings
    DEFAULT_RATE = 1.0,
    DEFAULT_PITCH = 1.0,
    DEFAULT_VOLUME = 1.0,
    
    -- Status flags
    backend_error = nil,
    player_error = nil,
}

function TTSEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    
    o.rate = o.rate or self.DEFAULT_RATE
    o.pitch = o.pitch or self.DEFAULT_PITCH
    o.volume = o.volume or self.DEFAULT_VOLUME
    o.backend = nil
    o.is_speaking = false
    o.is_paused = false
    o.current_audio_file = nil
    o.timing_data = {}
    o.on_word_callback = nil
    o.on_complete_callback = nil
    
    o:detectBackend()
    
    return o
end

--[[--
Detect available TTS backend.
--]]
function TTSEngine:detectBackend()
    if Device:isAndroid() then
        self.backend = self.BACKENDS.ANDROID
        logger.dbg("TTSEngine: Using Android TTS")
        return
    end

    -- Check for bundled espeak-ng inside our own plugin directory
    -- Installed at: /mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/espeak-ng/
    local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
    local bundled_base = plugin_dir .. "/espeak-ng"
    local bundled_bin = bundled_base .. "/bin/espeak-ng"
    local f = io.open(bundled_bin, "r")
    if f then
        f:close()
        self.backend = self.BACKENDS.ESPEAK
        self.backend_cmd = bundled_bin
        self.espeak_lib_path = bundled_base .. "/lib"
        self.espeak_data_path = bundled_base .. "/share"
        self.espeak_linker = bundled_base .. "/lib/ld-linux-armhf.so.3"
        logger.dbg("TTSEngine: Found bundled espeak-ng at", bundled_bin)
        return
    end

    -- Fall back to system PATH
    local backends_to_try = {
        {name = self.BACKENDS.ESPEAK, cmd = "espeak-ng"},
        {name = self.BACKENDS.ESPEAK, cmd = "espeak"},
        {name = self.BACKENDS.PICO, cmd = "pico2wave"},
        {name = self.BACKENDS.FLITE, cmd = "flite"},
        {name = self.BACKENDS.FESTIVAL, cmd = "festival"},
    }
    
    for _, backend in ipairs(backends_to_try) do
        if self:commandExists(backend.cmd) then
            self.backend = backend.name
            self.backend_cmd = backend.cmd
            logger.dbg("TTSEngine: Using", backend.name, "backend with command:", backend.cmd)
            return
        end
    end
    
    -- Log what we searched for
    logger.warn("TTSEngine: No TTS backend found. Searched for: espeak-ng, espeak, pico2wave, flite, festival")
    self.backend = nil
    self.backend_error = _("No TTS engine found. Please install espeak-ng.")
end

--[[--
Check if a command exists in PATH.
@param cmd string Command name
@return boolean
--]]
function TTSEngine:commandExists(cmd)
    local handle = io.popen("which " .. cmd .. " 2>/dev/null")
    if handle then
        local result = handle:read("*a")
        handle:close()
        return result and result ~= ""
    end
    return false
end

--[[--
Get menu items for engine selection.
@return table Menu items
--]]
function TTSEngine:getEngineMenu()
    local menu = {}
    
    for name, backend in pairs(self.BACKENDS) do
        table.insert(menu, {
            text = name,
            checked_func = function()
                return self.backend == backend
            end,
            callback = function()
                self.backend = backend
                if self.plugin then
                    self.plugin:setSetting("tts_backend", backend)
                end
            end,
        })
    end
    
    return menu
end

--[[--
Set speech rate.
@param rate number Rate multiplier (0.5 to 2.0)
--]]
function TTSEngine:setRate(rate)
    self.rate = math.max(0.5, math.min(2.0, rate))
    logger.dbg("TTSEngine: Rate set to", self.rate)
end

--[[--
Set speech pitch.
@param pitch number Pitch multiplier (0.5 to 2.0)
--]]
function TTSEngine:setPitch(pitch)
    self.pitch = math.max(0.5, math.min(2.0, pitch))
    logger.dbg("TTSEngine: Pitch set to", self.pitch)
end

--[[--
Set speech volume.
@param volume number Volume level (0.0 to 1.0)
--]]
function TTSEngine:setVolume(volume)
    self.volume = math.max(0.0, math.min(1.0, volume))
    logger.dbg("TTSEngine: Volume set to", self.volume)
end

--[[--
Synthesize text and return timing metadata.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesize(text, callback)
    if not self.backend then
        logger.err("TTSEngine: No TTS backend available")
        -- Show error to user
        UIManager:show(InfoMessage:new{
            text = self.backend_error or _("No TTS engine available.\n\nOn Kobo, you need to install espeak-ng.\n\nSee README for instructions."),
            timeout = 5,
        })
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    self.timing_data = {}
    
    logger.dbg("TTSEngine: Starting synthesis with backend:", self.backend)
    
    if self.backend == self.BACKENDS.ANDROID then
        return self:synthesizeAndroid(text, callback)
    else
        return self:synthesizeCommand(text, callback)
    end
end

--[[--
Synthesize using command-line TTS.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesizeCommand(text, callback)
    -- /tmp always exists on Kobo; HOME and TMPDIR may point to nonexistent paths
    local temp_dir = "/tmp"
    local audio_file = temp_dir .. "/audiobook_tts_" .. os.time() .. ".wav"
    local timing_file = temp_dir .. "/audiobook_timing_" .. os.time() .. ".txt"
    
    local cmd
    
    -- Limit text length to avoid command line issues
    local max_text_len = 1000
    if #text > max_text_len then
        text = text:sub(1, max_text_len)
        logger.dbg("TTSEngine: Truncated text to", max_text_len, "chars")
    end
    
    if self.backend == self.BACKENDS.ESPEAK then
        -- espeak-ng supports word timing output
        local speed = math.floor(175 * self.rate) -- Default is 175 wpm
        -- Build invocation for bundled espeak-ng on Kobo:
        -- Use the bundled ld-linux to bypass the ancient system glibc (2.11)
        local exec_prefix = ""
        if self.espeak_linker then
            exec_prefix = string.format(
                "ESPEAK_DATA_PATH=%s %s --library-path %s ",
                self.espeak_data_path, self.espeak_linker, self.espeak_lib_path
            )
        elseif self.espeak_lib_path then
            exec_prefix = string.format(
                "LD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
                self.espeak_lib_path, self.espeak_data_path
            )
        end
        cmd = string.format(
            '%s%s -v en -s %d -w "%s" "%s" 2>&1',
            exec_prefix, self.backend_cmd, speed, audio_file, self:escapeText(text)
        )
    elseif self.backend == self.BACKENDS.PICO then
        cmd = string.format(
            'pico2wave -l en-US -w "%s" "%s" 2>&1',
            audio_file, self:escapeText(text)
        )
    elseif self.backend == self.BACKENDS.FLITE then
        cmd = string.format(
            'flite -t "%s" -o "%s" 2>&1',
            self:escapeText(text), audio_file
        )
    elseif self.backend == self.BACKENDS.FESTIVAL then
        cmd = string.format(
            'echo "%s" | text2wave -o "%s"',
            self:escapeText(text), audio_file
        )
    end
    
    if not cmd then
        logger.err("TTSEngine: Cannot create command for backend:", self.backend)
        UIManager:show(InfoMessage:new{
            text = _("TTS backend error: Cannot create synthesis command."),
            timeout = 3,
        })
        if callback then
            callback(false, nil)
        end
        return false
    end
    
    logger.dbg("TTSEngine: Running:", cmd)
    
    -- Run synthesis synchronously for reliability on e-ink devices
    local result = os.execute(cmd)
    logger.dbg("TTSEngine: Command result:", result)
    
    -- Check if file was created
    local file = io.open(audio_file, "r")
    if file then
        file:close()
        local size = self:getFileSize(audio_file)
        logger.dbg("TTSEngine: Audio file created, size:", size)
        
        if size and size > 0 then
            self.current_audio_file = audio_file
            -- Generate timing estimates since most engines don't provide timing
            self:generateTimingEstimates(text)
            if callback then
                callback(true, self.timing_data)
            end
            return true
        else
            logger.err("TTSEngine: Audio file is empty")
        end
    else
        logger.err("TTSEngine: Failed to create audio file at:", audio_file)
    end
    
    -- Show error to user
    UIManager:show(InfoMessage:new{
        text = _("TTS synthesis failed.\n\nCould not generate audio file.\nCheck that espeak-ng is installed."),
        timeout = 4,
    })
    if callback then
        callback(false, nil)
    end
    return false
end

--[[--
Get file size.
@param path string File path
@return number|nil File size in bytes
--]]
function TTSEngine:getFileSize(path)
    local file = io.open(path, "rb")
    if file then
        local size = file:seek("end")
        file:close()
        return size
    end
    return nil
end

--[[--
Synthesize using Android TTS.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesizeAndroid(text, callback)
    -- Android TTS integration would go here
    -- This requires JNI calls to Android's TextToSpeech API
    logger.dbg("TTSEngine: Android TTS synthesis")
    
    -- For now, generate timing estimates
    self:generateTimingEstimates(text)
    
    if callback then
        callback(true, self.timing_data)
    end
    
    return true
end

--[[--
Generate timing estimates for words in text.
@param text string The text being spoken
--]]
function TTSEngine:generateTimingEstimates(text)
    self.timing_data = {}
    local current_time = 0
    local pos = 1
    
    while pos <= #text do
        -- Skip whitespace
        while pos <= #text and text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        if pos > #text then
            break
        end
        
        -- Find word
        local word_start = pos
        while pos <= #text and not text:sub(pos, pos):match("%s") do
            pos = pos + 1
        end
        
        local word = text:sub(word_start, pos - 1)
        local clean_word = word:gsub("[%p]", "")
        
        if clean_word ~= "" then
            local syllables = self:countSyllables(clean_word)
            local duration = math.floor((syllables * 200) / self.rate)
            
            table.insert(self.timing_data, {
                word = word,
                start_pos = word_start,
                end_pos = pos - 1,
                start_time = current_time,
                end_time = current_time + duration,
            })
            
            current_time = current_time + duration + 50 -- 50ms gap
        end
    end
    
    logger.dbg("TTSEngine: Generated timing for", #self.timing_data, "words")
end

--[[--
Count syllables in a word.
@param word string The word
@return number Syllable count
--]]
function TTSEngine:countSyllables(word)
    if not word or word == "" then
        return 1
    end
    
    word = word:lower()
    local count = 0
    local prev_vowel = false
    
    for i = 1, #word do
        local char = word:sub(i, i)
        local is_vowel = char:match("[aeiouy]")
        
        if is_vowel and not prev_vowel then
            count = count + 1
        end
        prev_vowel = is_vowel
    end
    
    if word:sub(-1) == "e" and count > 1 then
        count = count - 1
    end
    
    return math.max(count, 1)
end

--[[--
Escape text for shell command.
@param text string Text to escape
@return string Escaped text
--]]
function TTSEngine:escapeText(text)
    -- Escape special characters for shell
    text = text:gsub("\\", "\\\\")
    text = text:gsub('"', '\\"')
    text = text:gsub("`", "\\`")
    text = text:gsub("%$", "\\$")
    return text
end

--[[--
Play the synthesized audio.
@param on_word function Callback for word timing updates
@param on_complete function Callback when playback completes
@return boolean Success
--]]
function TTSEngine:play(on_word, on_complete)
    if not self.current_audio_file then
        logger.err("TTSEngine: No audio file to play")
        UIManager:show(InfoMessage:new{
            text = _("No audio file to play."),
            timeout = 2,
        })
        return false
    end
    
    self.on_word_callback = on_word
    self.on_complete_callback = on_complete
    self.is_speaking = true
    self.is_paused = false
    
    -- Start playback using system player
    local player = self:findAudioPlayer()
    if not player then
        logger.err("TTSEngine: No audio player found")
        self.player_error = true
        UIManager:show(InfoMessage:new{
            text = _("No audio output available.\n\nKobo has no built-in speaker.\n\nPlease pair Bluetooth headphones:\nSettings → Bluetooth → Pair\n\nThen try again."),
            timeout = 8,
        })
        self.is_speaking = false
        if on_complete then
            on_complete()
        end
        return false
    end
    
    logger.dbg("TTSEngine: Using player:", player)
    logger.dbg("TTSEngine: Audio file:", self.current_audio_file)
    
    local cmd
    if self.audio_player_type == "gst-bt" then
        -- GStreamer pipeline: convert to S16LE/48kHz/stereo for Kobo BT A2DP sink
        cmd = string.format(
            'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink &',
            self.current_audio_file
        )
    else
        cmd = string.format('%s "%s" &', player, self.current_audio_file)
    end
    logger.dbg("TTSEngine: Playing:", cmd)
    
    local result = os.execute(cmd)
    logger.dbg("TTSEngine: Play command result:", result)
    
    -- Start timing loop
    self:startTimingLoop()
    
    return true
end

--[[--
Find available audio player.
Sets self.audio_player_type to "gst-bt", "aplay", or "generic".
@return string|nil Player command
--]]
function TTSEngine:findAudioPlayer()
    -- 1) GStreamer with Kobo Bluetooth A2DP sink (primary on Kobo Libra Colour etc.)
    if self:commandExists("gst-launch-1.0") then
        local handle = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -1")
        if handle then
            local result = handle:read("*a")
            handle:close()
            if result and result:match("Factory Details") then
                self.audio_player_type = "gst-bt"
                logger.dbg("TTSEngine: Found GStreamer with Bluetooth audio sink")
                return "gst-launch-1.0"
            end
        end
    end

    -- 2) Check if any ALSA soundcard exists (required for aplay)
    local has_soundcard = false
    local cards = io.open("/proc/asound/cards", "r")
    if cards then
        local content = cards:read("*a")
        cards:close()
        has_soundcard = content and not content:match("no soundcards")
    end

    -- Order by preference for e-ink/Kobo devices
    local players = {}
    if has_soundcard then
        table.insert(players, {cmd = "aplay", args = "-q -D default"})
        table.insert(players, {cmd = "aplay", args = "-q -D hw:0,0"})
        table.insert(players, {cmd = "aplay", args = "-q"})
    end
    table.insert(players, {cmd = "paplay", args = ""})
    table.insert(players, {cmd = "mpv", args = "--no-video --really-quiet"})
    table.insert(players, {cmd = "mplayer", args = "-really-quiet"})
    table.insert(players, {cmd = "play", args = "-q"})

    for _, player in ipairs(players) do
        if self:commandExists(player.cmd) then
            logger.dbg("TTSEngine: Found audio player:", player.cmd)
            self.audio_player_type = player.cmd == "aplay" and "aplay" or "generic"
            if player.args and player.args ~= "" then
                return player.cmd .. " " .. player.args
            end
            return player.cmd
        end
    end

    return nil
end

--[[--
Start the timing loop to call word callbacks.
--]]
function TTSEngine:startTimingLoop()
    self.playback_start_time = UIManager:getTime()
    self.current_word_index = 0
    self:_runTimingLoop()
end

--[[--
Run the timing update loop.
Separated from startTimingLoop so that resume can restart the loop
without resetting playback_start_time.
--]]
function TTSEngine:_runTimingLoop()
    local function updateTiming()
        if not self.is_speaking or self.is_paused then
            return
        end
        
        -- FTS values are plain numbers (µs precision); time.to_ms converts diff to ms
        local elapsed = time.to_ms(UIManager:getTime() - self.playback_start_time)
        
        -- Find current word based on timing
        for i, timing in ipairs(self.timing_data) do
            if elapsed >= timing.start_time and elapsed < timing.end_time then
                if i ~= self.current_word_index then
                    self.current_word_index = i
                    if self.on_word_callback then
                        self.on_word_callback(timing, i)
                    end
                end
                break
            end
        end
        
        -- Check if playback is complete
        if #self.timing_data > 0 then
            local last_timing = self.timing_data[#self.timing_data]
            if elapsed >= last_timing.end_time then
                self:onPlaybackComplete()
                return
            end
        end
        
        -- Schedule next update
        UIManager:scheduleIn(0.05, updateTiming) -- Update every 50ms
    end
    
    UIManager:scheduleIn(0.05, updateTiming)
end

--[[--
Handle playback completion.
--]]
function TTSEngine:onPlaybackComplete()
    logger.dbg("TTSEngine: Playback complete")
    self.is_speaking = false
    
    if self.on_complete_callback then
        self.on_complete_callback()
    end
    
    self:cleanup()
end

--[[--
Pause playback.
--]]
function TTSEngine:pause()
    if self.is_speaking and not self.is_paused then
        self.is_paused = true
        self.pause_time = UIManager:getTime()
        -- Freeze the audio player process (SIGSTOP) so it can resume in place
        if self.current_audio_file then
            os.execute("pkill -STOP -f '" .. self.current_audio_file .. "' 2>/dev/null")
        end
        logger.dbg("TTSEngine: Paused")
    end
end

--[[--
Resume playback.
--]]
function TTSEngine:resume()
    if self.is_speaking and self.is_paused then
        self.is_paused = false
        -- Adjust start time to account for the pause duration
        local pause_duration = UIManager:getTime() - self.pause_time
        self.playback_start_time = self.playback_start_time + pause_duration
        -- Unfreeze the audio player process (SIGCONT) — resumes exactly where it stopped
        if self.current_audio_file then
            os.execute("pkill -CONT -f '" .. self.current_audio_file .. "' 2>/dev/null")
        end
        -- Restart the timing loop (it exited when is_paused was true)
        self:_runTimingLoop()
        logger.dbg("TTSEngine: Resumed")
    end
end

--[[--
Stop playback.
--]]
function TTSEngine:stop()
    if self.is_speaking then
        self.is_speaking = false
        self.is_paused = false
        
        -- Kill audio player (matches both aplay and gst-launch-1.0 by filename)
        if self.current_audio_file then
            os.execute("pkill -f '" .. self.current_audio_file .. "' 2>/dev/null")
        end
        
        self:cleanup()
        logger.dbg("TTSEngine: Stopped")
    end
end

--[[--
Clean up temporary files.
--]]
function TTSEngine:cleanup()
    if self.current_audio_file then
        local f = io.open(self.current_audio_file, "r")
        if f then
            f:close()
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = nil
    end
end

--[[--
Check if currently speaking.
@return boolean
--]]
function TTSEngine:isSpeaking()
    return self.is_speaking and not self.is_paused
end

--[[--
Check if paused.
@return boolean
--]]
function TTSEngine:isPaused()
    return self.is_speaking and self.is_paused
end

--[[--
Get timing data.
@return table Timing data array
--]]
function TTSEngine:getTimingData()
    return self.timing_data
end

return TTSEngine
