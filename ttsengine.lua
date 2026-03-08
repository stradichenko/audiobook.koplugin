--[[--
TTS Engine Module
Handles text-to-speech synthesis with timing metadata.

@module ttsengine
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local ffi = require("ffi")

-- Declare C functions needed for pipe buffer resize and Piper server FIFO I/O.
-- Each declaration is wrapped separately so a duplicate from another module
-- doesn't prevent the remaining declarations from being registered.
-- CRITICAL: fcntl MUST be declared as variadic (...) — on ARM EABI, variadic
-- args go on the stack while fixed args go in registers.  The old declaration
-- int fcntl(int fd, int cmd, int arg) put the size in register r2, but the
-- real libc fcntl read it from the stack → garbage → EINVAL.
pcall(function() ffi.cdef[[ int open(const char *pathname, int flags); ]] end)
pcall(function() ffi.cdef[[ int close(int fd); ]] end)
pcall(function() ffi.cdef[[ int fcntl(int fd, int cmd, ...); ]] end)
pcall(function() ffi.cdef[[ long write(int fd, const void *buf, unsigned long count); ]] end)
local logger = require("logger")
local time = require("ui/time")
local _ = require("gettext")

-- Shared utility modules (DRY: extracted from ttsengine, synccontroller, main)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local WavUtils = dofile(_utils_dir .. "wavutils.lua")
local PiperQueue = dofile(_utils_dir .. "piperqueue.lua")

local TTSEngine = {
    -- Supported TTS backends
    BACKENDS = {
        PICO = "pico",
        ESPEAK = "espeak", 
        FLITE = "flite",
        FESTIVAL = "festival",
        ANDROID = "android",
        PIPER = "piper",
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
    o.clause_pause = o.clause_pause or 0  -- extra pause at clause punctuation (seconds)
    o.backend = nil
    o.is_speaking = false
    o.is_paused = false
    o.current_audio_file = nil
    o.timing_data = {}
    o.on_word_callback = nil
    o.on_complete_callback = nil
    o.audio_pid = nil
    -- Piper TTS state
    o.piper_model = o.piper_model or nil  -- path or name of .onnx voice model
    o.piper_speaker = o.piper_speaker or 0  -- speaker id for multi-speaker models
    -- Prefetch state: holds pre-synthesized audio for the next sentence
    o._prefetch_file = nil
    o._prefetch_timing = nil
    o._prefetch_text = nil
    -- Piper async prefetch queue (extracted module)
    o._piper = PiperQueue:new{engine = o}
    
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

    -- Detect all available bundled engines first, then pick the best default.
    local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"

    -- Check for bundled espeak-ng
    local bundled_base = plugin_dir .. "/espeak-ng"
    local bundled_bin = bundled_base .. "/bin/espeak-ng"
    local found_espeak = false
    local f = io.open(bundled_bin, "r")
    if f then
        f:close()
        found_espeak = true
        self.backend_cmd = bundled_bin
        self.espeak_bin = bundled_bin  -- keep reference for fallback even when Piper is active
        self.espeak_lib_path = bundled_base .. "/lib"
        self.espeak_data_path = bundled_base .. "/share"
        self.espeak_linker = bundled_base .. "/lib/ld-linux-armhf.so.3"
        logger.dbg("TTSEngine: Found bundled espeak-ng at", bundled_bin)
    end

    -- Check for bundled Piper TTS binary
    local bundled_piper_bin = plugin_dir .. "/piper/piper"
    local found_piper = false
    f = io.open(bundled_piper_bin, "r")
    if f then
        f:close()
        found_piper = true
        self.piper_cmd = bundled_piper_bin
        self.piper_model_dir = plugin_dir .. "/piper"
        logger.dbg("TTSEngine: Found bundled Piper TTS at", bundled_piper_bin)
    end

    -- Pick default backend: espeak-ng first (lighter), then Piper
    if found_espeak then
        self.backend = self.BACKENDS.ESPEAK
        return
    elseif found_piper then
        self.backend = self.BACKENDS.PIPER
        self.backend_cmd = bundled_piper_bin
        return
    end

    -- Fall back to system PATH
    local backends_to_try = {
        {name = self.BACKENDS.ESPEAK, cmd = "espeak-ng"},
        {name = self.BACKENDS.ESPEAK, cmd = "espeak"},
        {name = self.BACKENDS.PIPER, cmd = "piper"},
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
Delegates to shared Utils module.
@param cmd string Command name
@return boolean
--]]
function TTSEngine:commandExists(cmd)
    return Utils.commandExists(cmd)
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

--[[
Set the extra pause at clause punctuation (commas, semicolons, etc.).
@param pause number Pause in seconds (0 = off)
--]]
function TTSEngine:setClausePause(pause)
    self.clause_pause = pause or 0
    logger.dbg("TTSEngine: Clause pause set to", self.clause_pause)
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
        -- Clause pause: inject SSML <break> tags after clause punctuation
        -- (, ; : — –).  Write SSML to a temp file and use -m -f to avoid
        -- shell escaping issues and ensure ebook text is XML-safe.
        local clause_pause = self.clause_pause or 0
        if clause_pause > 0 then
            local break_ms = math.floor(clause_pause * 1000)
            local break_tag = string.format('<break time="%dms"/>', break_ms)
            -- Minimal XML-escape: only & and < are strictly required in text
            -- nodes.  Strip < and > entirely (HTML artifacts from ebook) and
            -- escape &.  Avoid &apos;/&quot; which espeak-ng may not handle.
            local safe_text = text:gsub("&", "&amp;"):gsub("[<>]", "")
            -- Insert breaks after ASCII clause punctuation
            safe_text = safe_text:gsub("([,;:])(%s)", "%1" .. break_tag .. "%2")
            -- IMPORTANT: Use literal string gsub for multi-byte UTF-8 dashes.
            -- A Lua character class like [—–] matches individual BYTES, which
            -- would corrupt smart quotes, ellipsis, and other characters that
            -- share the 0xe2 0x80 prefix bytes.
            safe_text = safe_text:gsub("—(%s?)", "—" .. break_tag .. "%1")
            safe_text = safe_text:gsub("–(%s?)", "–" .. break_tag .. "%1")
            -- Wrap in SSML speak tags
            safe_text = '<speak>' .. safe_text .. '</speak>'
            -- Write SSML to a temp file (avoids shell escaping entirely)
            self.file_counter = (self.file_counter or 0) + 1
            local ssml_file = temp_dir .. "/audiobook_ssml_" .. os.time() .. "_" .. self.file_counter .. ".xml"
            local sf = io.open(ssml_file, "w")
            if sf then
                sf:write(safe_text)
                sf:close()
                cmd = string.format(
                    '%s%s -v %s -s %d -p %d -a %d%s -m -f "%s" -w "%s" 2>&1',
                    exec_prefix, self.backend_cmd, voice, speed, pitch, amplitude, gap_flag, ssml_file, audio_file
                )
                -- Clean up SSML file after synthesis completes
                self._ssml_temp_file = ssml_file
            end
        end
        if not cmd then
            cmd = string.format(
                '%s%s -v %s -s %d -p %d -a %d%s -w "%s" "%s" 2>&1',
                exec_prefix, self.backend_cmd, voice, speed, pitch, amplitude, gap_flag, audio_file, self:escapeText(text)
            )
        end
    elseif self.backend == self.BACKENDS.PIPER then
        local text_file
        cmd, text_file = self._piper:buildCommand(text, audio_file)
        self._piper_text_file = text_file
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
    
    -- Piper TTS is slow (~8-11s per sentence on Kobo ARM).
    -- Run it asynchronously so the UI stays responsive.
    if self.backend == self.BACKENDS.PIPER then
        -- Wrap: run synthesis in background, write a marker file when done
        local done_marker = audio_file .. ".done"
        local bg_cmd = string.format(
            '(%s; echo $? > "%s") &',
            cmd, done_marker
        )
        logger.dbg("TTSEngine: Launching Piper async:", bg_cmd)
        os.execute(bg_cmd)
        -- Save state for the async completion handler
        local piper_text_file = self._piper_text_file
        self._piper_text_file = nil  -- prevent premature cleanup
        local engine = self
        local poll_count = 0
        local max_polls = 120  -- 60 seconds max (120 × 0.5s)
        local function pollPiperDone()
            poll_count = poll_count + 1
            -- Check if the done marker file exists
            local mf = io.open(done_marker, "r")
            if mf then
                local exit_code = mf:read("*a"):gsub("%s+", "")
                mf:close()
                os.remove(done_marker)
                -- Clean up text input file
                if piper_text_file then
                    os.remove(piper_text_file)
                end
                -- Check if audio file was created
                local af = io.open(audio_file, "r")
                if af then
                    af:close()
                    local size = engine:getFileSize(audio_file)
                    if size and size > 0 then
                        engine.current_audio_file = audio_file
                        engine:generateTimingEstimates(text)
                        logger.dbg("TTSEngine: Piper async done, file size:", size)
                        -- Chain: launch next queued prefetch now that the process slot is free
                        engine:_launchNextPiperPrefetch()
                        if callback then
                            callback(true, engine.timing_data)
                        end
                        return
                    end
                end
                logger.err("TTSEngine: Piper async failed, exit_code:", exit_code)
                engine:_launchNextPiperPrefetch()
                if callback then
                    callback(false, nil)
                end
                return
            end
            -- Not done yet — keep polling
            if poll_count < max_polls then
                UIManager:scheduleIn(0.5, pollPiperDone)
            else
                logger.err("TTSEngine: Piper timed out after", max_polls * 0.5, "seconds")
                -- Clean up
                if piper_text_file then os.remove(piper_text_file) end
                os.remove(done_marker)
                engine:_launchNextPiperPrefetch()
                if callback then
                    callback(false, nil)
                end
            end
        end
        -- Start polling after a short initial delay
        UIManager:scheduleIn(0.5, pollPiperDone)
        -- Return nil (not false) to indicate async — caller should NOT
        -- treat this as an immediate failure.
        return nil
    end

    -- Non-Piper backends: run synchronously (espeak-ng is fast ~100ms)
    local result = os.execute(cmd)

    -- Clean up SSML temp file if one was created
    if self._ssml_temp_file then
        os.remove(self._ssml_temp_file)
        self._ssml_temp_file = nil
    end
    -- Clean up Piper text input file if one was created
    if self._piper_text_file then
        os.remove(self._piper_text_file)
        self._piper_text_file = nil
    end
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
Delegates to WavUtils.
@param path string File path
@return number|nil File size in bytes
--]]
function TTSEngine:getFileSize(path)
    return WavUtils.getFileSize(path)
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
Delegates to shared Utils module.
@param word string The word
@return number Syllable count
--]]
function TTSEngine:countSyllables(word)
    return Utils.countSyllables(word)
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
Append silence (zero samples) to the end of an existing WAV file.
Delegates to WavUtils.
@param path string  WAV file path
@param duration_ms number  Silence duration in milliseconds
@return boolean  true on success
--]]
function TTSEngine:appendSilenceToWav(path, duration_ms)
    return WavUtils.appendSilence(path, duration_ms)
end

--[[--
Append a gap (silence or audible tone) to a WAV file.
When "gap_test_mode" is enabled, writes a low tone instead of silence
so the user can hear exactly where each gap is placed.
Uses different frequencies for sentence vs paragraph gaps.
@param path string          WAV file path
@param duration_ms number   Gap duration in milliseconds
@param gap_type string      "sentence" or "paragraph"
@return boolean             true on success
--]]
function TTSEngine:appendGapToWav(path, duration_ms, gap_type)
    if self._gap_test_mode then
        -- Sentence gaps: 220 Hz (A3, low hum)
        -- Paragraph gaps: 330 Hz (E4, slightly higher)
        local freq = (gap_type == "paragraph") and 330 or 220
        return WavUtils.appendTone(path, duration_ms, freq, 2000)
    end
    return WavUtils.appendSilence(path, duration_ms)
end

--[[--
Quick espeak-ng synthesis for cold-start fallback.
Synthesizes text with the bundled espeak-ng binary (typically <300ms on ARM)
and returns the WAV file path, or nil on failure.
This works even when the active backend is Piper.
@param text string Text to synthesize
@return string|nil WAV file path on success
--]]
function TTSEngine:espeakSynthesizeFallback(text)
    if not self.espeak_bin then return nil end
    local temp_dir = "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_espeak_fb_" .. os.time() .. "_" .. self.file_counter .. ".wav"
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
    local speed = math.floor(175 * (self.rate or 1.0))
    local cmd = string.format(
        '%s%s -v en -s %d -a 100 -w "%s" "%s" 2>&1',
        exec_prefix, self.espeak_bin, speed, audio_file, self:escapeText(text)
    )
    logger.warn("TTSEngine: espeak fallback synthesis for cold-start")
    local handle = io.popen(cmd, "r")
    if handle then
        handle:read("*a")
        handle:close()
    end
    local f = io.open(audio_file, "r")
    if f then
        f:close()
        -- Smooth boundary clicks at start/end
        WavUtils.applyFade(audio_file, 15)
        -- Resample espeak output (22050Hz) to match Piper model rate if needed
        local target_sr = self._piper_sample_rate or 22050
        if target_sr ~= 22050 then
            WavUtils.resampleFile(audio_file, target_sr)
        end
        -- Generate timing estimates for the espeak audio
        self:generateTimingEstimates(text)
        self.current_audio_file = audio_file
        return audio_file
    end
    return nil
end

--[[--
Merge multiple WAV files into the current audio file.
Delegates to WavUtils.
@param concat_files table  Array of {file=path, duration_ms=number}
@return boolean  true if data was appended
--]]
function TTSEngine:mergeWavFiles(concat_files)
    if not self.current_audio_file or not concat_files or #concat_files == 0 then
        return false
    end
    return WavUtils.mergeFiles(self.current_audio_file, concat_files)
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
    -- Piper: delegate to the async queue-based prefetcher
    if self.backend == self.BACKENDS.PIPER then
        self._piper:enqueue(text)
        return true  -- launched (or already in queue)
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
    -- Check single-slot prefetch (espeak-ng)
    if self._prefetch_file and self._prefetch_text == text then
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = self._prefetch_file
        self.timing_data = self._prefetch_timing
        self._prefetch_file = nil
        self._prefetch_timing = nil
        self._prefetch_text = nil
        logger.dbg("TTSEngine: Using prefetched audio")
        return true
    end
    -- Check Piper async queue
    local piper_file, piper_timing = self._piper:useReady(text)
    if piper_file then
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = piper_file
        self.timing_data = piper_timing
        return true
    end
    return false
end

--[[--
Peek at the prefetched audio without consuming it.
Returns file path, timing data and WAV duration if the prefetch matches the
given text.  The prefetch slot is NOT cleared — call usePrefetched() or
_cleanPrefetch() when the file is no longer needed.
@param text string  Expected sentence text
@return string|nil  WAV file path (or nil)
@return table|nil   Timing data
@return number      Duration in ms
--]]
function TTSEngine:peekPrefetch(text)
    -- Check single-slot prefetch (espeak-ng)
    if self._prefetch_file and self._prefetch_text == text then
        local dur = self:getWavDurationMs(self._prefetch_file)
        return self._prefetch_file, self._prefetch_timing, dur
    end
    -- Check Piper async queue for ready entries
    return self._piper:peek(text)
end

--[[--
Diagnostic: return a summary string of the Piper prefetch queue state.
@return string  e.g. "queued=3 pending=2 ready=1 failed=0"
--]]
function TTSEngine:getPiperQueueSnapshot()
    return self._piper:getSnapshot()
end

--[[--
Get WAV duration from an arbitrary file path.
Delegates to WavUtils.
@param path string  WAV file path
@return number  Duration in ms, 0 on error
--]]
function TTSEngine:getWavDurationMs(path)
    return WavUtils.getDurationMs(path)
end

--[[--
Generate a WAV file containing silence of the given duration.
Delegates to WavUtils.
@param duration_ms number  Duration in milliseconds
@return string|nil  Path to the generated WAV file
--]]
function TTSEngine:generateSilenceWav(duration_ms)
    return WavUtils.generateSilence(nil, duration_ms)
end

--[[--
Clean up prefetch state.
--]]
function TTSEngine:_cleanPrefetch()
    if self._prefetch_file then
        if not self._prefetch_in_use then
            os.remove(self._prefetch_file)
        end
        self._prefetch_file = nil
    end
    self._prefetch_timing = nil
    self._prefetch_text = nil
    self._prefetch_in_use = false
    -- Clean Piper async queue
    self._piper:cleanQueue()
end

-- === Persistent BT Pipeline Constants ===
-- Instead of launching a new gst-launch for each sentence (which crashes
-- when BT A2DP disconnects during gaps), maintain a single persistent
-- pipeline.  A feeder script writes silence (keeping BT alive) and
-- switches to real audio on demand.  gst-launch never stops.
local PIPE_BUFFER_DELAY_64KB = 1500 -- 64KB pipe buffer at 44100 B/s ≈ 1.45s
local PIPE_BUFFER_DELAY_16KB = 370  -- 16KB pipe buffer at 44100 B/s ≈ 370ms

--- Compute pipe buffer delay for a given sample rate and buffer size.
-- @param sample_rate number  Audio sample rate (default 22050)
-- @param buf_kb number  Pipe buffer size in KB (16 or 64)
-- @return number  Delay in milliseconds
local function pipeBufferDelay(sample_rate, buf_kb)
    local byte_rate = (sample_rate or 22050) * 2  -- 16-bit mono
    return math.floor((buf_kb * 1024) / byte_rate * 1000)
end
local PIPELINE_CTRL_DIR = "/tmp/audiobook_ctrl"
local PIPELINE_FIFO = "/tmp/audiobook_fifo"
local PIPELINE_SCRIPT = "/tmp/audiobook_pipeline.sh"

--[[--
Play the synthesized audio.
@param on_word function Callback for word timing updates
@param on_complete function Callback when playback completes
@param on_fail function Callback on async BT launch failure
@param concat_files table|nil Optional extra WAV files for seamless concat playback
       Each entry: {file=path, duration_ms=number}
@return boolean Success
--]]
function TTSEngine:play(on_word, on_complete, on_fail, concat_files)
    local t0 = UIManager:getTime()
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
    
    -- Start playback using system player (cached after first probe)
    local player = self._cached_player or self:findAudioPlayer()
    if player then
        self._cached_player = player
    end
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
    logger.warn("TTSEngine: play() findPlayer took", time.to_ms(UIManager:getTime() - t0), "ms")
    
    -- Calculate real audio duration from WAV file.
    -- If _unpadded_duration_ms is set, the WAV was padded with trailing
    -- silence by SyncController.  Use the original (speech-only) duration
    -- for word-timing scaling so highlights stay correct.
    local real_duration_ms = self._unpadded_duration_ms or self:getAudioDurationMs()
    self._unpadded_duration_ms = nil
    self._current_audio_duration_ms = real_duration_ms
    logger.dbg("TTSEngine: Real WAV duration:", real_duration_ms, "ms (unpadded)")
    
    -- BT audio has significant startup latency (A2DP negotiation).
    -- On chained sentences the socket is still warm, so latency is lower.
    if self.audio_player_type == "gst-bt" then
        self.playback_latency_ms = self._socket_clean and 500 or 1500
    else
        self.playback_latency_ms = 0
    end
    
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
    
    -- === PERSISTENT BT PIPELINE PATH ===
    -- For Bluetooth: use a single persistent gst-launch that never stops.
    -- A feeder script writes silence between sentences to keep BT A2DP alive,
    -- and switches to real audio on demand via a control file.
    if self.audio_player_type == "gst-bt" then
        -- Handle WAV merge for concatenated sentences
        if concat_files and #concat_files > 0 then
            self:mergeWavFiles(concat_files)
            self._concat_durations = { self._current_audio_duration_ms }
            for _, cf in ipairs(concat_files) do
                table.insert(self._concat_durations, cf.duration_ms)
            end
            logger.warn("TTSEngine: Merged", 1 + #concat_files, "sentences, durations=",
                table.concat(self._concat_durations, "+"))
        else
            self._concat_durations = nil
        end

        -- Calculate expected audio duration from actual WAV file.
        -- After mergeWavFiles(), the main WAV includes all silence padding
        -- (inter-sentence gaps, first-sentence padding, trailing gap).
        -- Reading the WAV header gives the true total duration, avoiding
        -- the bug where first-sentence padding was excluded from the sum.
        self._expected_play_duration_ms = self:getAudioDurationMs()

        -- Cancel any pending callbacks from previous play()
        if self._completion_timer_fn then
            UIManager:unschedule(self._completion_timer_fn)
            self._completion_timer_fn = nil
        end
        if self._pending_launch_fn then
            UIManager:unschedule(self._pending_launch_fn)
            self._pending_launch_fn = nil
        end

        -- Ensure the persistent pipeline is running
        if not self:_ensurePersistentPipeline() then
            logger.err("TTSEngine: Failed to start persistent pipeline")
            self.is_speaking = false
            if on_fail then on_fail() end
            return false
        end

        -- Bump generation to invalidate stale callbacks
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation

        -- BT latency: pipe buffer + ring buffer (~200ms)
        self.playback_latency_ms = (self._pipe_buffer_delay_ms or PIPE_BUFFER_DELAY_64KB) + 200

        logger.warn("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")

        -- Feed audio to the persistent pipeline
        os.remove(PIPELINE_CTRL_DIR .. "/done")
        local ctrl_f = io.open(PIPELINE_CTRL_DIR .. "/play", "w")
        if ctrl_f then
            ctrl_f:write(self.current_audio_file)
            ctrl_f:close()
        end

        self._audio_launched_at = UIManager:getTime()
        logger.warn("TTSEngine: play() fed to pipeline, dur=",
            self._expected_play_duration_ms, "ms, gen=", my_gen,
            "piper_q=", self:getPiperQueueSnapshot())

        -- Poll for feeder 'done' file — logs when feeder finished writing
        -- PCM to the FIFO.  This tells us the real latency from play() to
        -- audio-data-in-pipeline.  Does NOT affect completion timing.
        local feed_start = UIManager:getTime()
        local feed_gen = my_gen
        local feed_engine = self
        local function pollFeederDone()
            if (feed_engine.play_generation or 0) ~= feed_gen then return end
            local df = io.open(PIPELINE_CTRL_DIR .. "/done", "r")
            if df then
                df:close()
                local feed_ms = time.to_ms(UIManager:getTime() - feed_start)
                logger.warn("TTSEngine: Feeder done in", feed_ms, "ms (gen=", feed_gen, ")")
                return
            end
            UIManager:scheduleIn(0.05, pollFeederDone)
        end
        UIManager:scheduleIn(0.1, pollFeederDone)

        -- Start timing loop for word highlighting
        self:startTimingLoop()

        -- Duration-based completion: fire onPlaybackComplete when the
        -- SPEECH portion of the audio has finished playing through the
        -- speaker.
        --
        -- The expected duration includes all silence padding (inter-sentence
        -- gaps + trailing gap).  We SUBTRACT the trailing gap so that
        -- readNextSentence can start preparing the next audio while the
        -- trailing gap silence is still draining through the pipe buffer.
        -- This eliminates ~700ms of extra dead silence that would otherwise
        -- accumulate between concat groups: without the subtraction, the
        -- feeder idles (writing silence) during the trailing gap + the
        -- completion margin, and that idle silence fills the pipe buffer,
        -- delaying the start of the next sentence's audio.
        --
        -- The pipe buffer adds ~512ms of latency.  Add it plus a small
        -- margin so the speech audio has fully drained to the speaker.
        local pipe_buf_ms = self._pipe_buffer_delay_ms or PIPE_BUFFER_DELAY_64KB
        local trailing_gap_ms = self._trailing_gap_ms or 0
        self._trailing_gap_ms = nil
        local completion_delay_s = (self._expected_play_duration_ms / 1000)
            - (trailing_gap_ms / 1000)
            + (pipe_buf_ms / 1000) + 0.15
        local engine = self
        local function fireCompletion()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.5, fireCompletion)
                return
            end
            logger.warn("TTSEngine: Pipeline completion (duration-based,",
                engine._expected_play_duration_ms, "ms - trailing_gap",
                trailing_gap_ms, "ms + pipe_buf",
                pipe_buf_ms, "ms)")
            engine:onPlaybackComplete()
        end
        engine._completion_timer_fn = fireCompletion
        UIManager:scheduleIn(completion_delay_s, fireCompletion)

        return true
    end

    -- === LEGACY PATH (non-Bluetooth audio) ===
    -- Build command WITHOUT trailing &; we'll add '& echo $!' for PID capture
    local play_cmd
    if self.audio_player_type == "gst-bt" then
        -- GStreamer pipeline: convert to S16LE/48kHz/stereo for Kobo BT A2DP sink.
        -- When concat_files is provided, merge them into the main WAV file
        -- (raw PCM append + header update) to avoid the GStreamer concat
        -- element which crashes on Kobo BT (exits <1 s, corrupts socket).
        if concat_files and #concat_files > 0 then
            self:mergeWavFiles(concat_files)
            -- Store per-sentence durations so the sync controller can
            -- track split points for word highlighting across sentences.
            self._concat_durations = { self._current_audio_duration_ms }
            for _, cf in ipairs(concat_files) do
                table.insert(self._concat_durations, cf.duration_ms)
            end
            logger.warn("TTSEngine: Merged", 1 + #concat_files, "sentences, durations=",
                table.concat(self._concat_durations, "+"))
        else
            self._concat_durations = nil
        end
        -- Always use a single-file pipeline (merged or original)
        play_cmd = string.format(
            'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink',
            self.current_audio_file
        )
    else
        play_cmd = string.format('%s "%s"', player, self.current_audio_file)
        self._concat_durations = nil
    end

    -- Store expected total audio duration so the process watcher can
    -- detect premature exits (gst-launch crashing after BT idle gap).
    if self._concat_durations then
        local total = 0
        for _, d in ipairs(self._concat_durations) do total = total + d end
        self._expected_play_duration_ms = total
    else
        self._expected_play_duration_ms = self._current_audio_duration_ms
    end
    
    -- Cancel any previously scheduled launchAndStart from an earlier play()
    -- call.  This prevents stale closures from firing after we supersede them.
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end

    -- Stop BT keepalive (if running or scheduled).  If the keepalive was
    -- holding the socket, _socket_clean is already false and the normal
    -- kill+wait logic below will handle the socket release delay.
    self:_stopBtKeepalive()

    -- Force-kill any lingering audio — SIGKILL + killall to release the
    -- @kobo:mtkbtmwrpc abstract socket held by stale gst-launch processes.
    -- Skip when socket is clean — process already exited, nothing to kill.
    if not self._socket_clean then
        self:_killAudioProcess()
    end

    -- Bump generation to invalidate any stale timing/watcher loops
    self.play_generation = (self.play_generation or 0) + 1

    logger.warn("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")

    -- Build PID-capturing launch command and save for potential async retry.
    -- Redirect stderr to a status file so the sync controller can detect
    -- when GStreamer transitions to PLAYING (= audio is actually flowing).
    self._gst_status_file = "/tmp/.gst_status"
    os.remove(self._gst_status_file)
    local pid_cmd = play_cmd .. ' >/dev/null 2>>' .. self._gst_status_file .. ' & echo $!'
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
        local launch_t0 = UIManager:getTime()
        logger.dbg("TTSEngine: Launching:", pid_cmd)
        local handle = io.popen(pid_cmd)
        local pid_str = handle and handle:read("*a") or ""
        if handle then handle:close() end
        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
        -- Record when the audio process was actually launched so the
        -- sync controller can anchor its timing to reality, not an estimate.
        engine._audio_launched_at = UIManager:getTime()
        logger.warn("TTSEngine: io.popen launch took", time.to_ms(UIManager:getTime() - launch_t0), "ms, PID=", engine.audio_pid)

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
NOTE: The actual word-highlight polling is handled by SyncController's
sync loop (startSentenceSyncLoop) which already runs at 20Hz.  This
method now only records the playback_start_time so that pause/resume
can adjust it correctly.  The 20Hz polling loop was removed to cut
redundant CPU wakeups and save battery.
--]]
function TTSEngine:startTimingLoop()
    self.playback_start_time = UIManager:getTime()
    self.current_word_index = 0
    -- No polling loop — SyncController handles word highlighting.
end

--[[--
Restart the timing bookkeeping after a resume (no polling loop needed).
--]]
function TTSEngine:_runTimingLoop()
    -- No-op: SyncController's sync loop handles word highlighting.
    -- Kept as a function so resume() doesn't need changes.
end

--[[--
Get actual audio duration from the current WAV file.
@return number Duration in milliseconds, or 0 on error
--]]
function TTSEngine:getAudioDurationMs()
    return self:getWavDurationMs(self.current_audio_file)
end

--[[--
Force-kill the current audio process AND any orphan gst-launch-1.0 processes.
Uses SIGKILL (not SIGTERM) because gst-launch with mtkbtmwrpcaudiosink holds
an abstract UNIX socket (@kobo:mtkbtmwrpc) that isn't released on graceful
shutdown fast enough, causing "Address already in use" for the next launch.
--]]
function TTSEngine:_killAudioProcess()
    -- Don't kill the persistent pipeline's gst-launch
    if self._persistent_pipeline then return end
    local had_pid = self.audio_pid ~= nil
    if self.audio_pid then
        os.execute("kill -9 " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    -- Always catch orphan gst-launch-1.0 processes, even if we lost our PID
    if self.audio_player_type == "gst-bt" then
        os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    end
    -- Also clear keepalive PID since killall caught it
    self._bt_keepalive_pid = nil
    -- Record when we last killed a tracked process — used to skip redundant
    -- BT socket waits.  Only set when we had a real PID so that a no-op kill
    -- doesn't reset the timer and re-introduce the 0.3s wait.
    if had_pid then
        self._last_audio_kill_time = UIManager:getTime()
    end
end

--[[--%nStart a BT keepalive process that plays silence to hold the A2DP
connection alive.  Without this, the BT audio sink disconnects after
~1-2s of idle time, causing the next gst-launch to crash.
Called from onPlaybackComplete via a short delay — if the next sentence
is immediately ready, play() cancels this before it starts.
--]]
function TTSEngine:_startBtKeepalive()
    if self.audio_player_type ~= "gst-bt" then return end
    -- Don't start if there's already a keepalive running
    if self._bt_keepalive_pid then return end
    -- Create a long silence WAV once (120 seconds, covers any Piper wait)
    if not self._keepalive_wav then
        self._keepalive_wav = self:generateSilenceWav(120000)
    end
    if not self._keepalive_wav then return end
    local cmd = string.format(
        'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample'
        .. ' ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink'
        .. ' >/dev/null 2>/dev/null & echo $!',
        self._keepalive_wav
    )
    local h = io.popen(cmd)
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._bt_keepalive_pid = tonumber(pid_str:match("(%d+)"))
    -- Socket is now held by keepalive — NOT clean
    self._socket_clean = false
    logger.warn("TTSEngine: BT keepalive started, PID=", self._bt_keepalive_pid)
end

--[[--%nStop the BT keepalive silence process.
--]]
function TTSEngine:_stopBtKeepalive()
    -- Cancel any pending scheduled start
    if self._keepalive_scheduled_fn then
        UIManager:unschedule(self._keepalive_scheduled_fn)
        self._keepalive_scheduled_fn = nil
    end
    if self._bt_keepalive_pid then
        os.execute("kill -9 " .. self._bt_keepalive_pid .. " 2>/dev/null")
        self._bt_keepalive_pid = nil
        self._last_audio_kill_time = UIManager:getTime()
        logger.warn("TTSEngine: BT keepalive stopped")
    end
end

--[[--
Write the persistent BT pipeline feeder script to /tmp.
The script starts gst-launch reading from a named FIFO and feeds it
raw PCM (silence when idle, real audio when playing).
--]]
function TTSEngine:_writePipelineScript()
    local sr = self._piper_sample_rate or 22050
    -- Silence chunk: ~50ms at sample rate, 16-bit mono
    -- MUST be even (multiple of block_align=2) to preserve PCM sample alignment!
    local silence_samples = math.floor(sr * 0.05)
    local silence_bytes = silence_samples * 2
    local script = string.format([=[
#!/bin/sh
CTRL="/tmp/audiobook_ctrl"
FIFO="/tmp/audiobook_fifo"
mkdir -p "$CTRL"
rm -f "$CTRL/stop" "$CTRL/play" "$CTRL/done" "$CTRL/gst_pid"
rm -f "$FIFO"
mkfifo "$FIFO"
# Silence chunk: ~50ms at %dHz 16-bit mono = %d samples × 2 bytes = %d bytes
dd if=/dev/zero bs=%d count=1 of="$CTRL/s.raw" 2>/dev/null
# Start gst-launch reading raw PCM from FIFO.
# sync=true (default) — the sink renders buffers at the timestamp rate.
# Because the feeder writes silence CONTINUOUSLY (blocked by the pipe at
# 1x when the buffer is full), the byte-offset timestamps from
# rawaudioparse stay in sync with the GStreamer clock.  The BT A2DP
# transport always has data — never suspends.
# The Lua caller shrinks the pipe buffer to 16KB via
# fcntl(F_SETPIPE_SZ) to reduce latency while keeping enough headroom
# to absorb CPU stalls during Piper synthesis.
gst-launch-1.0 filesrc location="$FIFO" \
  ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=1 \
  ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! mtkbtmwrpcaudiosink >/dev/null 2>/dev/null &
GST_PID=$!
# Open FIFO write end — keeps it alive between individual writes.
# This BLOCKS until gst-launch opens the read end (filesrc start).
exec 3>"$FIFO"
# Signal Lua AFTER the FIFO is fully set up (both ends open).
# Lua uses the gst_pid file as a "ready" indicator before trying to
# open(O_WRONLY|O_NONBLOCK) on the FIFO for pipe buffer resize.
echo $GST_PID > "$CTRL/gst_pid"
cleanup() { exec 3>&- 2>/dev/null; kill $GST_PID 2>/dev/null; rm -f "$FIFO" "$CTRL/s.raw" "$CTRL/gst_pid"; }
trap cleanup EXIT TERM
# Track total bytes written to detect/fix alignment
TOTAL_BYTES=0
# Feeder loop: continuous silence when idle, real audio when play file appears.
# usleep 1000 (1ms) prevents CPU busy-spin during initial pipe fill.
while kill -0 $GST_PID 2>/dev/null && [ ! -f "$CTRL/stop" ]; do
  if [ -f "$CTRL/play" ]; then
    FILE=$(cat "$CTRL/play")
    rm -f "$CTRL/play" "$CTRL/done"
    # If total bytes written so far is odd, write 1 zero byte to re-align
    ODD=$((TOTAL_BYTES %% 2))
    if [ "$ODD" -ne 0 ]; then
      printf '\0' >&3
      TOTAL_BYTES=$((TOTAL_BYTES + 1))
    fi
    # Get audio data size (file size minus 44-byte WAV header)
    FSIZE=$(wc -c < "$FILE")
    DSIZE=$((FSIZE - 44))
    # Skip 44-byte WAV header, output raw PCM
    tail -c +45 "$FILE" >&3
    TOTAL_BYTES=$((TOTAL_BYTES + DSIZE))
    touch "$CTRL/done"
  else
    cat "$CTRL/s.raw" >&3
    TOTAL_BYTES=$((TOTAL_BYTES + %d))
    usleep 1000
  fi
done
]=], sr, silence_samples, silence_bytes, silence_bytes, sr, silence_bytes)
    local f = io.open(PIPELINE_SCRIPT, "w")
    if not f then return false end
    f:write(script)
    f:close()
    os.execute("chmod +x " .. PIPELINE_SCRIPT)
    return true
end

--[[--
Start the persistent BT audio pipeline.
Creates the feeder script, launches it (piping silence/audio to gst-launch
via a named FIFO), and waits for gst-launch to initialise.
@return boolean true if pipeline started successfully
--]]
function TTSEngine:_startPersistentPipeline()
    self:_stopPersistentPipeline()
    if not self:_writePipelineScript() then
        logger.err("TTSEngine: Cannot write pipeline script")
        return false
    end
    -- Clean control files
    os.execute("rm -f " .. PIPELINE_CTRL_DIR .. "/stop " .. PIPELINE_CTRL_DIR .. "/play " .. PIPELINE_CTRL_DIR .. "/done")
    -- Launch pipeline in background
    local h = io.popen(PIPELINE_SCRIPT .. " >/dev/null 2>/dev/null & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._pipeline_wrapper_pid = tonumber(pid_str:match("(%d+)"))
    -- Wait for gst-launch PID file to appear (up to 3s)
    local gst_pid = nil
    for _ = 1, 60 do  -- 60 × 50ms = 3s
        local pf = io.open(PIPELINE_CTRL_DIR .. "/gst_pid", "r")
        if pf then
            local pid = pf:read("*a")
            pf:close()
            gst_pid = tonumber((pid or ""):match("(%d+)"))
            if gst_pid then break end
        end
        os.execute("usleep 50000")
    end
    self._pipeline_gst_pid = gst_pid
    self.audio_pid = gst_pid  -- for pause/resume compatibility
    self._socket_clean = false
    self._persistent_pipeline = true

    -- Shrink the FIFO pipe buffer from 64KB to 16KB.
    -- At 22050Hz mono 16-bit (44100 B/s): 16KB ≈ 370ms.
    -- At 16000Hz mono 16-bit (32000 B/s): 16KB ≈ 512ms.
    -- Balances low latency with headroom for Piper CPU stalls.
    local sr = self._piper_sample_rate or 22050
    self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 64)  -- default: assume 64KB
    if gst_pid then
        local O_WRONLY    = 1
        local O_NONBLOCK  = 2048  -- 0x800
        local F_SETPIPE_SZ = 1031
        local fd = ffi.C.open(PIPELINE_FIFO, bit.bor(O_WRONLY, O_NONBLOCK))
        if fd >= 0 then
            -- Pass size as cdata int — required for variadic fcntl on ARM EABI.
            local ret = ffi.C.fcntl(fd, F_SETPIPE_SZ, ffi.new("int", 16384))
            if ret >= 0 then
                self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 16)
                logger.warn("TTSEngine: Pipe buffer shrunk to 16KB, ret=", ret,
                    "delay=", self._pipe_buffer_delay_ms, "ms at", sr, "Hz")
            else
                logger.warn("TTSEngine: fcntl F_SETPIPE_SZ failed, ret=", ret,
                    "errno=", ffi.errno(), ", trying shell fallback")
                ffi.C.close(fd)
                -- Shell fallback: python3 or direct /proc write
                local rc = os.execute(string.format(
                    'python3 -c "import fcntl,os; fd=os.open(\'%s\',os.O_WRONLY|os.O_NONBLOCK); fcntl.fcntl(fd,1031,16384); os.close(fd)" 2>/dev/null',
                    PIPELINE_FIFO))
                if rc == 0 then
                    self._pipe_buffer_delay_ms = pipeBufferDelay(sr, 16)
                    logger.warn("TTSEngine: Pipe buffer shrunk to 16KB via python3")
                else
                    logger.warn("TTSEngine: All pipe resize methods failed, using 64KB delay")
                end
                fd = -1  -- already closed
            end
            if fd >= 0 then ffi.C.close(fd) end
        else
            logger.warn("TTSEngine: Could not open FIFO for pipe resize, errno=",
                ffi.errno(), ", using 64KB delay")
        end
    end

    logger.warn("TTSEngine: Persistent pipeline started, wrapper=",
        self._pipeline_wrapper_pid, "gst=", self._pipeline_gst_pid)
    return gst_pid ~= nil
end

--[[--
Stop the persistent BT audio pipeline.
Kills the feeder script and gst-launch, cleans up the FIFO.
--]]
function TTSEngine:_stopPersistentPipeline()
    if not self._persistent_pipeline then return end
    -- Signal feeder to stop
    local sf = io.open(PIPELINE_CTRL_DIR .. "/stop", "w")
    if sf then sf:write("1"); sf:close() end
    -- Kill processes
    if self._pipeline_gst_pid then
        os.execute("kill -9 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    end
    if self._pipeline_wrapper_pid then
        os.execute("kill -9 " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
    end
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    -- Clean up
    os.execute("rm -f " .. PIPELINE_FIFO .. " " .. PIPELINE_CTRL_DIR .. "/gst_pid")
    self._pipeline_gst_pid = nil
    self._pipeline_wrapper_pid = nil
    self._persistent_pipeline = false
    self.audio_pid = nil
    self._socket_clean = false
    logger.warn("TTSEngine: Persistent pipeline stopped")
end

--[[--
Check if the persistent BT pipeline is alive.
@return boolean
--]]
function TTSEngine:_isPipelineAlive()
    if not self._persistent_pipeline or not self._pipeline_gst_pid then
        return false
    end
    local ret = os.execute("kill -0 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    return ret == 0
end

--[[--
Ensure the persistent BT pipeline is running, (re)starting if needed.
@return boolean true if pipeline is alive
--]]
function TTSEngine:_ensurePersistentPipeline()
    if self:_isPipelineAlive() then
        return true
    end
    logger.warn("TTSEngine: Pipeline not alive, (re)starting...")
    return self:_startPersistentPipeline()
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
function TTSEngine:_startProcessWatcher(bt_retry_allowed, skip_on_fail)
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
                elseif skip_on_fail then
                    -- Retry of a premature-exit also failed fast — skip
                    -- sentence and continue playback instead of showing error.
                    logger.warn("TTSEngine: gst-launch retry failed fast ("
                        .. elapsed_ms .. "ms), skipping sentence")
                    engine._socket_clean = false
                    engine:onPlaybackComplete()
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
            elseif engine.audio_player_type == "gst-bt" and engine._expected_play_duration_ms
                    and engine._expected_play_duration_ms > 2000
                    and elapsed_ms < engine._expected_play_duration_ms * 0.4 then
                -- Premature exit: gst-launch crashed (BT sink went idle
                -- during Piper synthesis wait, A2DP re-negotiation failed).
                -- The socket is NOT clean — kill and retry with a delay.
                if bt_retry_allowed then
                    logger.warn("TTSEngine: gst-launch premature exit ("
                        .. elapsed_ms .. "ms vs expected "
                        .. engine._expected_play_duration_ms .. "ms), killing BT & retrying…")
                    engine._socket_clean = false
                    engine:_killAudioProcess()
                    -- 2s wait for BT A2DP re-establishment
                    UIManager:scheduleIn(2.0, function()
                        if (engine.play_generation or 0) ~= my_gen then return end
                        if not engine.is_speaking then return end
                        local handle = io.popen(engine._last_pid_cmd)
                        local pid_str = handle and handle:read("*a") or ""
                        if handle then handle:close() end
                        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
                        launch_time = UIManager:getTime()
                        logger.warn("TTSEngine: BT premature-exit retry PID:", engine.audio_pid)
                        -- On failure, skip sentence (don't show BT error)
                        engine:_startProcessWatcher(false, true)
                    end)
                else
                    -- Retry also crashed — skip this sentence so playback
                    -- can continue (next play will get a fresh socket).
                    logger.warn("TTSEngine: gst-launch retry also crashed ("
                        .. elapsed_ms .. "ms), skipping sentence")
                    engine._socket_clean = false
                    engine:onPlaybackComplete()
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
    -- The process watcher confirmed the process exited naturally, so the BT
    -- abstract socket is already released.  No need to killall — that would
    -- just waste ~200ms spawning a shell on the ARM CPU.
    if self._persistent_pipeline then
        -- Pipeline keeps running (playing silence) — audio_pid stays set
        -- and socket stays held by the pipeline.  No keepalive needed.
    else
        self.audio_pid = nil
        self._socket_clean = true
    end
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
        -- Freeze the audio pipeline/process (SIGSTOP) so it can resume in place
        if self._persistent_pipeline then
            if self._pipeline_gst_pid then
                os.execute("kill -STOP " .. self._pipeline_gst_pid .. " 2>/dev/null")
            end
            if self._pipeline_wrapper_pid then
                os.execute("kill -STOP " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
            end
        elseif self.audio_pid then
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
        -- Unfreeze the audio pipeline/process (SIGCONT)
        if self._persistent_pipeline then
            if self._pipeline_gst_pid then
                os.execute("kill -CONT " .. self._pipeline_gst_pid .. " 2>/dev/null")
            end
            if self._pipeline_wrapper_pid then
                os.execute("kill -CONT " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
            end
        elseif self.audio_pid then
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

    -- Cancel completion timer
    if self._completion_timer_fn then
        UIManager:unschedule(self._completion_timer_fn)
        self._completion_timer_fn = nil
    end

    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline()
    else
        self:_stopBtKeepalive()
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
    
    -- Kill any background Piper synthesis processes immediately
    if self.backend == self.BACKENDS.PIPER then
        self._piper:killOrphanProcesses()
    end
    
    -- Clear concat/prefetch-in-use flag so fullCleanup can delete files
    self._prefetch_in_use = false
    self._concat_durations = nil
    self._audio_launched_at = nil
    self._gst_status_file = nil
    self:fullCleanup()
    logger.dbg("TTSEngine: Stopped, had_process=", had_process, "_socket_clean=", self._socket_clean)
end

--[[--
Check if GStreamer has reached the PLAYING state by reading its stderr
output.  Returns true once the pipeline is actually outputting audio.
@return boolean
--]]
function TTSEngine:isGstPlaying()
    -- Persistent pipeline is always in PLAYING state
    if self._persistent_pipeline then return true end
    if not self._gst_status_file then return false end
    local f = io.open(self._gst_status_file, "r")
    if not f then return false end
    local content = f:read("*a")
    f:close()
    return content and content:find("PLAYING") ~= nil
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
    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline()
    else
        self:_stopBtKeepalive()
    end
    if self.audio_pid then
        os.execute("kill -TERM " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    os.execute("killall -TERM gst-launch-1.0 2>/dev/null")
    -- Full Piper shutdown: stop persistent servers AND kill per-process instances
    self._piper:shutdown()
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

-- ── Piper TTS delegates (implementation in piperqueue.lua) ───────────

function TTSEngine:setPiperModel(model) self._piper:setModel(model) end
function TTSEngine:setPiperSpeaker(id)  self._piper:setSpeaker(id) end

--[[--
Switch the active TTS backend.
@param backend string One of TTSEngine.BACKENDS values
--]]
function TTSEngine:setBackend(backend)
    -- Validate
    local valid = false
    for _, v in pairs(self.BACKENDS) do
        if v == backend then valid = true; break end
    end
    if not valid then
        logger.warn("TTSEngine: Invalid backend:", backend)
        return
    end
    self.backend = backend
    logger.dbg("TTSEngine: Backend switched to", backend)
    -- Restore correct backend_cmd for the selected backend
    if backend == self.BACKENDS.PIPER then
        self.backend_cmd = self.piper_cmd or "piper"
    elseif backend == self.BACKENDS.ESPEAK then
        -- Restore bundled espeak-ng path if available
        local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local bundled_bin = plugin_dir .. "/espeak-ng/bin/espeak-ng"
        local f = io.open(bundled_bin, "r")
        if f then
            f:close()
            self.backend_cmd = bundled_bin
        else
            self.backend_cmd = "espeak-ng"
        end
    end
end

function TTSEngine:getPiperSampleRate()  return self._piper:getSampleRate() end
function TTSEngine:listPiperVoices()     return self._piper:listVoices() end

-- Thin delegates — keep the public API surface unchanged for synccontroller
function TTSEngine:piperPrefetchAsync(text)     self._piper:enqueue(text) end
function TTSEngine:_launchNextPiperPrefetch()    self._piper:launchNext() end
function TTSEngine:consumePiperQueueEntry(text)  return self._piper:consume(text) end
function TTSEngine:getPiperPrefetchStatus(text)  return self._piper:getStatus(text) end

return TTSEngine
