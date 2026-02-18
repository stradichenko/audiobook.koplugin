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
    o.pitch = o.pitch or 50  -- espeak-ng default pitch
    o.volume = o.volume or self.DEFAULT_VOLUME
    o.voice = o.voice or "en"  -- espeak-ng voice id
    o.word_gap = o.word_gap or 0  -- espeak-ng word gap (units of 10ms)
    o.backend = nil
    o.is_speaking = false
    o.is_paused = false
    o.current_audio_file = nil
    o.timing_data = {}
    o.on_word_callback = nil
    o.on_complete_callback = nil
    o.audio_pid = nil
    -- Prefetch state: holds pre-synthesized audio for the next sentence
    o._prefetch_file = nil
    o._prefetch_timing = nil
    o._prefetch_text = nil
    
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
    self.rate = math.max(0.25, math.min(2.0, rate))
    logger.dbg("TTSEngine: Rate set to", self.rate)
end

--[[--
Set speech pitch.
@param pitch number Pitch value (0 to 99, espeak-ng native range)
--]]
function TTSEngine:setPitch(pitch)
    self.pitch = math.max(0, math.min(99, pitch))
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
Set the espeak-ng voice/language.
@param voice string espeak-ng voice identifier (e.g. "en", "en-us")
--]]
function TTSEngine:setVoice(voice)
    self.voice = voice
    logger.dbg("TTSEngine: Voice set to", self.voice)
end

--[[--
Set the espeak-ng word gap (extra silence between words).
@param gap number Gap in units of 10ms (0 = default)
--]]
function TTSEngine:setWordGap(gap)
    self.word_gap = gap or 0
    logger.dbg("TTSEngine: Word gap set to", self.word_gap)
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
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_tts_" .. os.time() .. "_" .. self.file_counter .. ".wav"
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
        local pitch = self.pitch or 50
        local amplitude = math.floor((self.volume or 1.0) * 100)
        local voice = self.voice or "en"
        local word_gap = self.word_gap or 0
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
        -- Build word-gap flag only if non-zero
        local gap_flag = ""
        if word_gap > 0 then
            gap_flag = string.format(" -g %d", word_gap)
        end
        cmd = string.format(
            '%s%s -v %s -s %d -p %d -a %d%s -w "%s" "%s" 2>&1',
            exec_prefix, self.backend_cmd, voice, speed, pitch, amplitude, gap_flag, audio_file, self:escapeText(text)
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
Pre-synthesize audio for the next sentence while the current one plays.
This runs espeak-ng to generate the WAV file and timing data in advance,
so when the current sentence finishes we can skip straight to playback.
@param text string Text of the next sentence
@return boolean Success
--]]
function TTSEngine:prefetch(text)
    if not self.backend or not text or text == "" then
        return false
    end
    -- Don't prefetch the same text twice
    if self._prefetch_text == text and self._prefetch_file then
        return true
    end
    -- Clean up any previous prefetch
    self:_cleanPrefetch()

    -- Save current audio file/timing so synthesizeCommand doesn't overwrite them
    local saved_file = self.current_audio_file
    local saved_timing = self.timing_data

    local ok = self:synthesizeCommand(text, function(success, timing)
        if success then
            -- Move the generated file into the prefetch slot
            self._prefetch_file = self.current_audio_file
            self._prefetch_timing = self.timing_data
            self._prefetch_text = text
            logger.dbg("TTSEngine: Prefetched audio for:", text:sub(1, 40))
        end
    end)

    -- Restore the current audio state (the playing sentence's file)
    self.current_audio_file = saved_file
    self.timing_data = saved_timing

    return ok
end

--[[--
Check if prefetched audio matches the given text and swap it in.
@param text string The sentence text to check
@return boolean true if prefetch was used
--]]
function TTSEngine:usePrefetched(text)
    if self._prefetch_file and self._prefetch_text == text then
        -- Clean up current audio file before swapping
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = self._prefetch_file
        self.timing_data = self._prefetch_timing
        -- Clear prefetch slot (now promoted to current)
        self._prefetch_file = nil
        self._prefetch_timing = nil
        self._prefetch_text = nil
        logger.dbg("TTSEngine: Using prefetched audio")
        return true
    end
    return false
end

--[[--
Clean up prefetch state.
--]]
function TTSEngine:_cleanPrefetch()
    if self._prefetch_file then
        os.remove(self._prefetch_file)
        self._prefetch_file = nil
    end
    self._prefetch_timing = nil
    self._prefetch_text = nil
end

--[[--
Play the synthesized audio.
@param on_word function Callback for word timing updates
@param on_complete function Callback when playback completes
@return boolean Success
--]]
function TTSEngine:play(on_word, on_complete, on_fail)
    logger.warn("TTSEngine: play() called, audio_file=", self.current_audio_file, "is_speaking=", self.is_speaking)
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
    self.on_fail_callback = on_fail
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
    
    -- Calculate real audio duration from WAV file
    local real_duration_ms = self:getAudioDurationMs()
    self._current_audio_duration_ms = real_duration_ms
    logger.dbg("TTSEngine: Real WAV duration:", real_duration_ms, "ms")
    
    -- BT audio has significant startup latency (A2DP negotiation)
    self.playback_latency_ms = (self.audio_player_type == "gst-bt") and 1500 or 0
    
    -- Scale timing data to match real audio duration
    if real_duration_ms > 0 and #self.timing_data > 0 then
        local estimated_total = self.timing_data[#self.timing_data].end_time
        if estimated_total > 0 then
            local scale = real_duration_ms / estimated_total
            for _, t in ipairs(self.timing_data) do
                t.start_time = math.floor(t.start_time * scale)
                t.end_time = math.floor(t.end_time * scale)
            end
            logger.dbg("TTSEngine: Scaled timing by", scale, "(estimated", estimated_total, "-> real", real_duration_ms, ")")
        end
    end
    
    -- Build command WITHOUT trailing &; we'll add '& echo $!' for PID capture
    local play_cmd
    if self.audio_player_type == "gst-bt" then
        -- GStreamer pipeline: convert to S16LE/48kHz/stereo for Kobo BT A2DP sink
        play_cmd = string.format(
            'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink',
            self.current_audio_file
        )
    else
        play_cmd = string.format('%s "%s"', player, self.current_audio_file)
    end
    
    -- Cancel any previously scheduled launchAndStart from an earlier play()
    -- call.  This prevents stale closures from firing after we supersede them.
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end

    -- Force-kill any lingering audio — SIGKILL + killall to release the
    -- @kobo:mtkbtmwrpc abstract socket held by stale gst-launch processes.
    self:_killAudioProcess()

    -- Bump generation to invalidate any stale timing/watcher loops
    self.play_generation = (self.play_generation or 0) + 1

    -- Build PID-capturing launch command and save for potential async retry
    local pid_cmd = play_cmd .. " >/dev/null 2>&1 & echo $!"
    self._last_pid_cmd = pid_cmd

    -- Launch the audio process, start timing loop and process watcher.
    -- This is extracted so BT can call it after a non-blocking socket-release
    -- delay, while non-BT calls it immediately.
    local engine = self
    local my_gen = self.play_generation
    local function launchAndStart()
        engine._pending_launch_fn = nil
        -- Guard: bail if a newer play()/stop() call superseded us
        if (engine.play_generation or 0) ~= my_gen then
            logger.warn("TTSEngine: launchAndStart ABORTED — stale gen", my_gen, "vs", engine.play_generation)
            return
        end
        if not engine.is_speaking then
            logger.warn("TTSEngine: launchAndStart ABORTED — not speaking")
            return
        end

        -- Launch in background and capture PID for reliable process tracking.
        -- io.popen runs: sh -c '<play_cmd> >/dev/null 2>&1 & echo $!'
        -- The shell backgrounds the player, prints its PID, and exits.
        logger.dbg("TTSEngine: Launching:", pid_cmd)
        local handle = io.popen(pid_cmd)
        local pid_str = handle and handle:read("*a") or ""
        if handle then handle:close() end
        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
        logger.dbg("TTSEngine: Audio PID:", engine.audio_pid)

        -- Start timing loop for word highlighting (does NOT detect completion)
        engine:startTimingLoop()

        -- Start process watcher — detects normal completion AND BT early-death.
        -- For BT, the watcher retries once if the process dies within 2s (A2DP
        -- negotiation failure). This replaces the old blocking os.execute("sleep")
        -- checks so the UI stays responsive for rotation, taps, etc.
        engine:_startProcessWatcher(true)
    end

    if self.audio_player_type == "gst-bt" then
        -- If the previous process exited normally (watcher confirmed it),
        -- the socket is already free — launch immediately.
        -- Only wait when we had to force-kill a live process in this play() call.
        if self._socket_clean then
            self._socket_clean = false
            logger.warn("TTSEngine: BT socket clean — launching immediately, gen=", self.play_generation)
            launchAndStart()
        else
            local need_wait = 0.3
            if self._last_audio_kill_time then
                local since_kill_ms = time.to_ms(UIManager:getTime() - self._last_audio_kill_time)
                need_wait = math.max(0, (300 - since_kill_ms) / 1000)
            end
            logger.warn("TTSEngine: BT socket wait =", need_wait, "s, gen=", self.play_generation)
            if need_wait > 0.02 then
                self._pending_launch_fn = launchAndStart
                UIManager:scheduleIn(need_wait, launchAndStart)
            else
                launchAndStart()
            end
        end
    else
        -- Non-BT: launch immediately (no socket contention)
        launchAndStart()
    end

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
    local my_gen = self.play_generation or 0
    local function updateTiming()
        if not self.is_speaking or self.is_paused then
            return
        end
        -- Exit if superseded by a newer play() call
        if (self.play_generation or 0) ~= my_gen then
            return
        end
        
        -- FTS values are plain numbers (µs precision); time.to_ms converts diff to ms
        local elapsed = time.to_ms(UIManager:getTime() - self.playback_start_time)
        -- Offset by BT latency: audio doesn't start until A2DP negotiation completes
        local adjusted = elapsed - (self.playback_latency_ms or 0)
        
        if adjusted > 0 then
            -- Find current word based on timing
            for i, timing in ipairs(self.timing_data) do
                if adjusted >= timing.start_time and adjusted < timing.end_time then
                    if i ~= self.current_word_index then
                        self.current_word_index = i
                        if self.on_word_callback then
                            self.on_word_callback(timing, i)
                        end
                    end
                    break
                end
            end
        end
        
        -- NOTE: Completion is detected by the process watcher, not here.
        -- Schedule next update
        UIManager:scheduleIn(0.05, updateTiming)
    end
    
    UIManager:scheduleIn(0.05, updateTiming)
end

--[[--
Get actual audio duration from the WAV file header.
@return number Duration in milliseconds, or 0 on error
--]]
function TTSEngine:getAudioDurationMs()
    if not self.current_audio_file then return 0 end
    local f = io.open(self.current_audio_file, "rb")
    if not f then return 0 end
    local size = f:seek("end")
    -- Read byte rate from WAV header (offset 28, 4 bytes little-endian)
    f:seek("set", 28)
    local raw = f:read(4)
    f:close()
    if not raw or #raw < 4 then return 0 end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    local byte_rate = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if byte_rate <= 0 then return 0 end
    local data_bytes = size - 44
    if data_bytes <= 0 then return 0 end
    return math.floor((data_bytes / byte_rate) * 1000)
end

--[[--
Force-kill the current audio process AND any orphan gst-launch-1.0 processes.
Uses SIGKILL (not SIGTERM) because gst-launch with mtkbtmwrpcaudiosink holds
an abstract UNIX socket (@kobo:mtkbtmwrpc) that isn't released on graceful
shutdown fast enough, causing "Address already in use" for the next launch.
--]]
function TTSEngine:_killAudioProcess()
    local had_pid = self.audio_pid ~= nil
    if self.audio_pid then
        os.execute("kill -9 " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    -- Always catch orphan gst-launch-1.0 processes, even if we lost our PID
    if self.audio_player_type == "gst-bt" then
        os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    end
    -- Record when we last killed a tracked process — used to skip redundant
    -- BT socket waits.  Only set when we had a real PID so that a no-op kill
    -- doesn't reset the timer and re-introduce the 0.3s wait.
    if had_pid then
        self._last_audio_kill_time = UIManager:getTime()
    end
end

--[[--
Check if the audio player process is still running.
@return boolean true if process is alive
--]]
function TTSEngine:_isAudioProcessRunning()
    if not self.audio_pid then return false end
    local ret = os.execute("kill -0 " .. self.audio_pid .. " 2>/dev/null")
    return ret == 0
end

--[[--
Poll for audio process exit. When the player process finishes,
trigger playback completion.

For Bluetooth audio, also detects "early death" — if gst-launch exits
within 2 seconds it means A2DP negotiation failed (no connected sink).
On first early death it retries once (kill, 0.5s socket wait, relaunch).
On second early death it shows an error and stops the reading chain.

All waits use UIManager:scheduleIn so the main loop stays responsive
for rotation, taps, and other input events.

@param bt_retry_allowed boolean Whether BT early-death retry is allowed
--]]
function TTSEngine:_startProcessWatcher(bt_retry_allowed)
    local my_gen = self.play_generation or 0
    local launch_time = UIManager:getTime()
    -- Real BT connection failures exit in <200ms (no A2DP sink).
    -- Normal audio takes at least 500ms+ (BT negotiation + playback).
    -- Keep this low so short sentences aren't mistaken for failures.
    local BT_EARLY_DEATH_MS = 500
    local engine = self

    local function checkProcess()
        if (engine.play_generation or 0) ~= my_gen then return end
        if not engine.is_speaking then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.5, checkProcess)
            return
        end

        if engine:_isAudioProcessRunning() then
            UIManager:scheduleIn(0.1, checkProcess)
        else
            local elapsed_ms = time.to_ms(UIManager:getTime() - launch_time)

            -- BT early-death detection: gst-launch exits in <200ms when
            -- there is no A2DP sink.  Normal playback always takes >500ms
            -- (BT overhead alone is ~1s).
            if engine.audio_player_type == "gst-bt" and elapsed_ms < BT_EARLY_DEATH_MS then
                if bt_retry_allowed then
                    logger.warn("TTSEngine: gst-launch died early (" .. elapsed_ms .. "ms), retrying…")
                    engine:_killAudioProcess()
                    -- Non-blocking 0.5s wait for socket release, then retry
                    UIManager:scheduleIn(0.5, function()
                        if (engine.play_generation or 0) ~= my_gen then return end
                        if not engine.is_speaking then return end
                        local handle = io.popen(engine._last_pid_cmd)
                        local pid_str = handle and handle:read("*a") or ""
                        if handle then handle:close() end
                        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
                        logger.dbg("TTSEngine: Retry PID:", engine.audio_pid)
                        -- Restart watcher WITHOUT retry (second chance only)
                        engine:_startProcessWatcher(false)
                    end)
                else
                    -- Retry also failed — BT not connected
                    logger.warn("TTSEngine: gst-launch died on retry — BT audio not connected")
                    engine.is_speaking = false
                    engine.audio_pid = nil
                    engine.play_generation = (engine.play_generation or 0) + 1
                    engine:cleanup()
                    UIManager:show(InfoMessage:new{
                        text = _("Bluetooth audio not connected.\n\nPlease make sure your Bluetooth headphones or speaker are:\n\n1. Powered on\n2. Paired in Kobo Settings → Bluetooth\n3. Connected and within range\n\nThen try again."),
                        timeout = 10,
                    })
                    -- Signal failure to SyncController so it stops the chain
                    if engine.on_fail_callback then
                        engine.on_fail_callback()
                    end
                end
            else
                -- Normal completion (process streamed successfully then exited)
                logger.warn("TTSEngine: Process watcher → normal completion, elapsed=", elapsed_ms, "ms")
                engine:onPlaybackComplete()
            end
        end
    end

    -- Short initial delay to let the process initialize
    UIManager:scheduleIn(0.15, checkProcess)
end

--[[--
Handle playback completion.
--]]
function TTSEngine:onPlaybackComplete()
    if not self.is_speaking then
        logger.warn("TTSEngine: onPlaybackComplete SKIPPED (not speaking, double-fire guard)")
        return
    end
    logger.warn("TTSEngine: onPlaybackComplete gen=", self.play_generation, "pid=", self.audio_pid)
    self.is_speaking = false
    -- Bump generation so stale watcher/timing loops exit
    self.play_generation = (self.play_generation or 0) + 1
    -- Force-kill the audio process (SIGKILL to release the BT socket immediately)
    self:_killAudioProcess()
    -- The process watcher confirmed the process exited, so the BT abstract
    -- socket is already released.  Mark clean so the next play() call skips
    -- the 300ms wait entirely.
    self._socket_clean = true
    self:cleanup()
    
    if self.on_complete_callback then
        self.on_complete_callback()
    end
end

--[[--
Pause playback.
--]]
function TTSEngine:pause()
    if self.is_speaking and not self.is_paused then
        self.is_paused = true
        self.pause_time = UIManager:getTime()
        -- Freeze the audio player process (SIGSTOP) so it can resume in place
        if self.audio_pid then
            os.execute("kill -STOP " .. self.audio_pid .. " 2>/dev/null")
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
        if self.audio_pid then
            os.execute("kill -CONT " .. self.audio_pid .. " 2>/dev/null")
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
    -- Always bump generation and clear state, even if not speaking.
    -- This ensures stale scheduled callbacks (launchAndStart, checkProcess,
    -- updateTiming) exit immediately regardless of what state we were in.
    self.is_speaking = false
    self.is_paused = false
    self.play_generation = (self.play_generation or 0) + 1

    -- Cancel any pending launchAndStart so it can't fire after stop()
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end
    
    -- Only clear _socket_clean if there was a live audio process to kill.
    -- If the process already exited naturally (onPlaybackComplete set
    -- _socket_clean=true), preserve that flag so the next play() can
    -- skip the 0.3s BT socket wait entirely.
    local had_process = self.audio_pid ~= nil
    self:_killAudioProcess()
    if had_process then
        self._socket_clean = false
    end
    
    self:fullCleanup()
    logger.dbg("TTSEngine: Stopped, had_process=", had_process, "_socket_clean=", self._socket_clean)
end

--[[--%
Unconditionally kill all gst-launch-1.0 processes and clean up.
Called on plugin teardown to prevent orphaned processes from holding
the BT A2DP socket when Nickel resumes after KOReader exits.
Uses SIGTERM (not SIGKILL) so GStreamer can close the BT audio sink
gracefully and not leave the BT firmware in a bad state.
--]]
function TTSEngine:forceKillAll()
    self._socket_clean = false
    -- Cancel any pending launchAndStart
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end
    if self.audio_pid then
        os.execute("kill -TERM " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    os.execute("killall -TERM gst-launch-1.0 2>/dev/null")
    self:fullCleanup()
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
    self.audio_pid = nil
end

--[[--
Full stop cleanup: also discard any prefetched audio.
Called by stop() and forceKillAll().
--]]
function TTSEngine:fullCleanup()
    self:cleanup()
    self:_cleanPrefetch()
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
