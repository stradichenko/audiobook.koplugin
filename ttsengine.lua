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
    -- Piper async prefetch queue: keyed by sentence text
    -- Each entry: {file=path, timing=table, status="pending"|"ready"|"failed"}
    o._piper_queue = {}
    o._piper_queue_order = {}  -- ordered list of texts for cleanup
    
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
        cmd, text_file = self:_buildPiperCommand(text, audio_file)
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
        -- Flag: block prefetch queue from launching concurrently
        self._piper_synthesizing = true
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
                        engine._piper_synthesizing = false
                        -- Chain: launch next queued prefetch now that the process slot is free
                        engine:_launchNextPiperPrefetch()
                        if callback then
                            callback(true, engine.timing_data)
                        end
                        return
                    end
                end
                logger.err("TTSEngine: Piper async failed, exit_code:", exit_code)
                engine._piper_synthesizing = false
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
                engine._piper_synthesizing = false
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
XML-escape text for safe embedding inside SSML markup.
Escapes &, <, >, ", ' so that ebook content cannot break the SSML parser.
@param text string Raw text
@return string XML-safe text
--]]
function TTSEngine:xmlEscapeText(text)
    text = text:gsub("&", "&amp;")
    text = text:gsub("<", "&lt;")
    text = text:gsub(">", "&gt;")
    text = text:gsub('"', "&quot;")
    text = text:gsub("'", "&apos;")
    return text
end

--[[--
Append silence (zero samples) to the end of an existing WAV file.
Reads the byte rate from the WAV header to match the file's format exactly,
then appends zero bytes and updates the RIFF/data chunk sizes.
This is used to bake inter-sentence pauses directly into speech WAV files,
avoiding separate silence files in the GStreamer concat pipeline.
@param path string  WAV file path
@param duration_ms number  Silence duration in milliseconds
@return boolean  true on success
--]]
function TTSEngine:appendSilenceToWav(path, duration_ms)
    if not path or not duration_ms or duration_ms <= 0 then return false end

    local f = io.open(path, "r+b")
    if not f then return false end

    -- Read byte rate from WAV header (offset 28, 4 bytes LE)
    f:seek("set", 28)
    local raw = f:read(4)
    if not raw or #raw < 4 then f:close(); return false end
    local b1, b2, b3, b4 = raw:byte(1, 4)
    local byte_rate = b1 + b2 * 256 + b3 * 65536 + b4 * 16777216
    if byte_rate <= 0 then f:close(); return false end

    -- Read block align from WAV header (offset 32, 2 bytes LE)
    f:seek("set", 32)
    raw = f:read(2)
    if not raw or #raw < 2 then f:close(); return false end
    local ba1, ba2 = raw:byte(1, 2)
    local block_align = ba1 + ba2 * 256
    if block_align <= 0 then block_align = 2 end  -- fallback for 16-bit mono

    -- Current file size
    local file_size = f:seek("end")

    -- Calculate silence bytes (aligned to block_align)
    local silence_bytes = math.floor(byte_rate * (duration_ms / 1000))
    silence_bytes = silence_bytes - (silence_bytes % block_align)
    if silence_bytes <= 0 then f:close(); return false end

    -- Append zero bytes at end of file
    f:seek("end")
    local chunk_size = 8192
    local chunk = string.rep("\0", chunk_size)
    local written = 0
    while written < silence_bytes do
        local to_write = math.min(chunk_size, silence_bytes - written)
        if to_write < chunk_size then
            f:write(chunk:sub(1, to_write))
        else
            f:write(chunk)
        end
        written = written + to_write
    end

    -- Update RIFF file size at offset 4
    local new_file_size = file_size + silence_bytes
    local function le32(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
                           math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    end
    f:seek("set", 4)
    f:write(le32(new_file_size - 8))

    -- Update data chunk size at offset 40
    f:seek("set", 40)
    f:write(le32(new_file_size - 44))

    f:close()
    logger.dbg("TTSEngine: Appended", duration_ms, "ms silence to", path,
        "(", silence_bytes, "bytes)")
    return true
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
        self:piperPrefetchAsync(text)
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
    local entry = self._piper_queue[text]
    if entry and entry.status == "ready" and entry.file then
        if self.current_audio_file then
            os.remove(self.current_audio_file)
        end
        self.current_audio_file = entry.file
        self.timing_data = entry.timing
        -- Remove from queue (promoted to current)
        self._piper_queue[text] = nil
        for i, t in ipairs(self._piper_queue_order) do
            if t == text then table.remove(self._piper_queue_order, i); break end
        end
        logger.dbg("TTSEngine: Using Piper queued audio")
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
    if self._prefetch_file and self._prefetch_text == text then
        local dur = self:getWavDurationMs(self._prefetch_file)
        return self._prefetch_file, self._prefetch_timing, dur
    end
    return nil, nil, 0
end

--[[--
Get WAV duration from an arbitrary file path.
@param path string  WAV file path
@return number  Duration in ms, 0 on error
--]]
function TTSEngine:getWavDurationMs(path)
    if not path then return 0 end
    local f = io.open(path, "rb")
    if not f then return 0 end
    local size = f:seek("end")
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
Generate a WAV file containing silence of the given duration.
Matches espeak-ng output format: 22050 Hz, mono, 16-bit PCM.
@param duration_ms number  Duration in milliseconds
@return string|nil  Path to the generated WAV file
--]]
function TTSEngine:generateSilenceWav(duration_ms)
    if not duration_ms or duration_ms <= 0 then return nil end
    local temp_dir = "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local path = temp_dir .. "/audiobook_silence_" .. os.time() .. "_" .. self.file_counter .. ".wav"

    local sample_rate = 22050
    local channels = 1
    local bits_per_sample = 16
    local num_samples = math.floor(sample_rate * (duration_ms / 1000))
    local data_size = num_samples * channels * (bits_per_sample / 8)
    local file_size = 36 + data_size

    local function le32(n)
        return string.char(n % 256, math.floor(n / 256) % 256,
                           math.floor(n / 65536) % 256, math.floor(n / 16777216) % 256)
    end
    local function le16(n)
        return string.char(n % 256, math.floor(n / 256) % 256)
    end

    local byte_rate = sample_rate * channels * (bits_per_sample / 8)
    local block_align = channels * (bits_per_sample / 8)

    local header = "RIFF" .. le32(file_size) .. "WAVE"
                 .. "fmt " .. le32(16)
                 .. le16(1)
                 .. le16(channels)
                 .. le32(sample_rate)
                 .. le32(byte_rate)
                 .. le16(block_align)
                 .. le16(bits_per_sample)
                 .. "data" .. le32(data_size)

    local f = io.open(path, "wb")
    if not f then return nil end
    f:write(header)
    local chunk = string.rep("\0", math.min(data_size, 8192))
    local written = 0
    while written < data_size do
        local to_write = math.min(#chunk, data_size - written)
        f:write(chunk:sub(1, to_write))
        written = written + to_write
    end
    f:close()
    return path
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
    self:_cleanPiperQueue()
end

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
    
    -- Build command WITHOUT trailing &; we'll add '& echo $!' for PID capture
    local play_cmd
    if self.audio_player_type == "gst-bt" then
        -- GStreamer pipeline: convert to S16LE/48kHz/stereo for Kobo BT A2DP sink.
        -- When concat_files is provided, use the concat element to chain multiple
        -- WAV files into a single continuous BT stream (no A2DP re-negotiation gap).
        if concat_files and #concat_files > 0 then
            -- Multi-sentence concat pipeline
            local sink = 'audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink'
            local sources = string.format('filesrc location="%s" ! wavparse ! c. ', self.current_audio_file)
            for _, cf in ipairs(concat_files) do
                sources = sources .. string.format('filesrc location="%s" ! wavparse ! c. ', cf.file)
            end
            play_cmd = string.format('gst-launch-1.0 concat name=c ! %s %s', sink, sources)
            -- Store combined duration for the sync controller
            self._concat_durations = { self._current_audio_duration_ms }
            for _, cf in ipairs(concat_files) do
                table.insert(self._concat_durations, cf.duration_ms)
            end
            logger.warn("TTSEngine: Concat pipeline with", 1 + #concat_files, "files, durations=",
                table.concat(self._concat_durations, "+"))
        else
            -- Single-sentence pipeline (fallback / non-concat)
            play_cmd = string.format(
                'gst-launch-1.0 filesrc location="%s" ! wavparse ! audioconvert ! audioresample ! "audio/x-raw,format=S16LE,rate=48000,channels=2" ! mtkbtmwrpcaudiosink',
                self.current_audio_file
            )
            self._concat_durations = nil
        end
    else
        play_cmd = string.format('%s "%s"', player, self.current_audio_file)
        self._concat_durations = nil
    end
    
    -- Cancel any previously scheduled launchAndStart from an earlier play()
    -- call.  This prevents stale closures from firing after we supersede them.
    if self._pending_launch_fn then
        UIManager:unschedule(self._pending_launch_fn)
        self._pending_launch_fn = nil
    end

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
    -- The process watcher confirmed the process exited naturally, so the BT
    -- abstract socket is already released.  No need to killall — that would
    -- just waste ~200ms spawning a shell on the ARM CPU.
    self.audio_pid = nil
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
    
    -- Kill any background Piper synthesis processes immediately
    if self.backend == self.BACKENDS.PIPER then
        self:_killPiperProcesses()
        self._piper_synthesizing = false
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
    if self.audio_pid then
        os.execute("kill -TERM " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    os.execute("killall -TERM gst-launch-1.0 2>/dev/null")
    -- Kill any background Piper synthesis processes
    self:_killPiperProcesses()
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

-- ── Piper TTS helpers ────────────────────────────────────────────────

--[[--
Resolve the Piper voice model path.
Searches for .onnx files in the bundled piper/ directory and any
user-configured model path.
@return string|nil Absolute path to .onnx file, or nil
--]]
function TTSEngine:_resolvePiperModel()
    -- Explicit model path set by user or config
    if self.piper_model then
        -- If it's already an absolute path, use it directly
        if self.piper_model:sub(1, 1) == "/" then
            local f = io.open(self.piper_model, "r")
            if f then f:close(); return self.piper_model end
        end
        -- Try relative to model dir
        if self.piper_model_dir then
            local try = self.piper_model_dir .. "/" .. self.piper_model
            local f = io.open(try, "r")
            if f then f:close(); return try end
            -- Also try with .onnx suffix
            try = try .. ".onnx"
            f = io.open(try, "r")
            if f then f:close(); return try end
        end
    end
    -- Auto-detect: find the first .onnx file in the piper model dir
    if self.piper_model_dir then
        local handle = io.popen('find "' .. self.piper_model_dir .. '" -name "*.onnx" -type f 2>/dev/null | head -1')
        if handle then
            local result = handle:read("*a"):gsub("%s+$", "")
            handle:close()
            if result and result ~= "" then
                logger.dbg("TTSEngine: Auto-detected Piper model:", result)
                return result
            end
        end
    end
    return nil
end

--[[--
Set the Piper voice model.
@param model string Model name or path (e.g. "en_US-lessac-medium" or full path)
--]]
function TTSEngine:setPiperModel(model)
    self.piper_model = model
    logger.dbg("TTSEngine: Piper model set to", self.piper_model)
end

--[[--
Set the Piper speaker id (for multi-speaker models).
@param id number Speaker id (0-based)
--]]
function TTSEngine:setPiperSpeaker(id)
    self.piper_speaker = id or 0
    logger.dbg("TTSEngine: Piper speaker set to", self.piper_speaker)
end

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

--[[--
List available Piper voice models in the bundled piper/ directory.
Returns an array of {name=, path=, size=} tables.
@return table Array of voice info tables
--]]
function TTSEngine:listPiperVoices()
    local voices = {}
    if not self.piper_model_dir then return voices end
    local handle = io.popen('find "' .. self.piper_model_dir .. '" -name "*.onnx" -type f 2>/dev/null')
    if handle then
        for line in handle:lines() do
            local path = line:gsub("%s+$", "")
            if path ~= "" then
                -- Extract a friendly name from the filename
                local name = path:match("([^/]+)%.onnx$") or path
                local size = self:getFileSize(path)
                table.insert(voices, {
                    name = name,
                    path = path,
                    size = size,
                })
            end
        end
        handle:close()
    end
    return voices
end

-- ── Piper command builder & async prefetch queue ─────────────────────

--[[--
Build the shell command for Piper TTS synthesis.
Extracts the command construction so both synthesizeCommand() and
piperPrefetchAsync() can reuse it.
@param text string  Text to synthesize
@param audio_file string  Output WAV file path
@return string cmd  Shell command
@return string text_file  Path to the temporary text input file
--]]
function TTSEngine:_buildPiperCommand(text, audio_file)
    local temp_dir = "/tmp"
    local piper_bin = self.piper_cmd or self.backend_cmd or "piper"
    local model_flag = ""
    local model_path = self:_resolvePiperModel()
    if model_path then
        model_flag = string.format(' --model "%s"', model_path)
    end
    local speaker_flag = ""
    if self.piper_speaker and self.piper_speaker > 0 then
        speaker_flag = string.format(' --speaker %d', self.piper_speaker)
    end
    local length_scale = 1.0 / math.max(0.25, self.rate)
    local length_flag = ""
    if math.abs(length_scale - 1.0) > 0.01 then
        length_flag = string.format(' --length_scale %.2f', length_scale)
    end
    -- Piper ships its own libs (onnxruntime, espeak-ng phonemizer data).
    -- On Kobo, Piper needs the bundled glibc/libstdc++ (from espeak-ng/lib).
    -- We invoke Piper through the bundled ld-linux-armhf.so.3 dynamic linker.
    local exec_prefix = ""
    if self.piper_model_dir then
        local piper_lib = self.piper_model_dir .. "/lib"
        local probe = io.open(piper_lib .. "/libonnxruntime.so.1.14.1", "r")
        if not probe then
            probe = io.open(self.piper_model_dir .. "/libonnxruntime.so.1.14.1", "r")
            if probe then piper_lib = self.piper_model_dir end
        end
        if probe then probe:close() end
        local plugin_dir = self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin"
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
        local ld_f = io.open(ld_linux, "r")
        if ld_f then
            ld_f:close()
            local lib_path = piper_lib .. ":" .. espeak_lib
            exec_prefix = string.format(
                '"%s" --library-path "%s" ',
                ld_linux, lib_path
            )
            local espeak_data_dir = self.piper_model_dir .. "/espeak-ng-data"
            local ed_f = io.open(espeak_data_dir .. "/phontab", "r")
            if ed_f then
                ed_f:close()
                model_flag = model_flag .. string.format(' --espeak_data "%s"', espeak_data_dir)
            end
        else
            exec_prefix = string.format(
                'LD_LIBRARY_PATH="%s" ESPEAK_DATA_PATH="%s" ',
                piper_lib, self.piper_model_dir
            )
        end
    end
    -- Write text to a temp file to avoid shell escaping issues
    self.file_counter = (self.file_counter or 0) + 1
    local text_file = temp_dir .. "/audiobook_piper_in_" .. os.time() .. "_" .. self.file_counter .. ".txt"
    local tf = io.open(text_file, "w")
    if tf then
        local clean = text:gsub("\n", " "):gsub("\r", "")
        tf:write(clean .. "\n")
        tf:close()
    end
    local cmd = string.format(
        '%s%s%s%s%s --output_file "%s" < "%s" 2>&1',
        exec_prefix, piper_bin, model_flag, speaker_flag, length_flag, audio_file, text_file
    )
    return cmd, text_file
end

--[[--
Add a sentence to the Piper prefetch queue.  Only ONE Piper process
runs at a time (each instance loads the full ONNX model into RAM).
When the running process finishes, the next queued entry is launched
automatically via _launchNextPiperPrefetch().
@param text string  Sentence text
--]]
function TTSEngine:piperPrefetchAsync(text)
    if not text or text == "" then return end
    -- Already in queue (queued / pending / ready)?
    if self._piper_queue[text] then return end

    local temp_dir = "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_piper_pf_" .. os.time() .. "_" .. self.file_counter .. ".wav"
    local done_marker = audio_file .. ".done"

    -- Register in queue as "queued" (waiting to be launched)
    self._piper_queue[text] = {
        file = audio_file,
        text_file = nil,       -- filled in when launched
        done_marker = done_marker,
        timing = nil,
        status = "queued",
    }
    table.insert(self._piper_queue_order, text)

    logger.dbg("TTSEngine: Piper prefetch queued:", text:sub(1, 40),
        "(queue size:", #self._piper_queue_order, ")")

    -- Kick the serial launcher — it will start this entry if nothing
    -- else is currently running.
    self:_launchNextPiperPrefetch()
end

--[[--
Launch the next queued Piper prefetch entry, but only if no other
entry is currently "pending" (= actively synthesising).
Called after piperPrefetchAsync() adds an entry, and again when a
running synthesis finishes.
--]]
function TTSEngine:_launchNextPiperPrefetch()
    -- Don't launch if a main synthesis is in progress
    if self._piper_synthesizing then
        return
    end
    -- Check if something is already running
    for _, entry in pairs(self._piper_queue) do
        if entry.status == "pending" then
            return  -- one process at a time
        end
    end

    -- Find the first "queued" entry in insertion order
    local text_to_launch = nil
    for _, text in ipairs(self._piper_queue_order) do
        local entry = self._piper_queue[text]
        if entry and entry.status == "queued" then
            text_to_launch = text
            break
        end
    end
    if not text_to_launch then return end  -- nothing to do

    local entry = self._piper_queue[text_to_launch]
    local audio_file = entry.file
    local done_marker = entry.done_marker

    local cmd, text_file = self:_buildPiperCommand(text_to_launch, audio_file)
    entry.text_file = text_file
    entry.status = "pending"

    local bg_cmd = string.format('(%s; echo $? > "%s") &', cmd, done_marker)
    logger.dbg("TTSEngine: Piper prefetch launching:", text_to_launch:sub(1, 40))
    os.execute(bg_cmd)

    -- Poll for completion, then chain to the next queued entry
    local engine = self
    local poll_count = 0
    local max_polls = 120  -- 60s timeout
    local function pollDone()
        local e = engine._piper_queue[text_to_launch]
        if not e then
            -- Cleaned while pending — tidy temp files
            os.remove(audio_file)
            os.remove(done_marker)
            if text_file then os.remove(text_file) end
            -- Chain: maybe more entries were queued in the meantime
            engine:_launchNextPiperPrefetch()
            return
        end
        poll_count = poll_count + 1
        local mf = io.open(done_marker, "r")
        if mf then
            local exit_code = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(done_marker)
            if text_file then os.remove(text_file) end
            local af = io.open(audio_file, "r")
            if af then
                af:close()
                local size = engine:getFileSize(audio_file)
                if size and size > 0 then
                    engine:generateTimingEstimates(text_to_launch)
                    e.timing = engine.timing_data
                    e.status = "ready"
                    logger.dbg("TTSEngine: Piper prefetch ready:",
                        text_to_launch:sub(1, 40), "size:", size)
                    -- ── Chain: launch next queued entry ──
                    engine:_launchNextPiperPrefetch()
                    return
                end
            end
            e.status = "failed"
            logger.err("TTSEngine: Piper prefetch failed:",
                text_to_launch:sub(1, 40), "exit:", exit_code)
            engine:_launchNextPiperPrefetch()
            return
        end
        if poll_count < max_polls then
            UIManager:scheduleIn(0.5, pollDone)
        else
            e.status = "failed"
            logger.err("TTSEngine: Piper prefetch timed out:", text_to_launch:sub(1, 40))
            if text_file then os.remove(text_file) end
            os.remove(done_marker)
            engine:_launchNextPiperPrefetch()
        end
    end
    UIManager:scheduleIn(0.5, pollDone)
end

--[[--
Kick off Piper prefetch for multiple upcoming sentences.
@param texts table  Array of sentence texts to prefetch
--]]
function TTSEngine:piperPrefetchBatch(texts)
    if self.backend ~= self.BACKENDS.PIPER then return end
    for _, text in ipairs(texts) do
        if text and text ~= "" then
            self:piperPrefetchAsync(text)
        end
    end
end

--[[--
Check if a Piper prefetch entry is ready for the given text.
@param text string
@return boolean
--]]
function TTSEngine:isPiperPrefetchReady(text)
    local entry = self._piper_queue[text]
    return entry and entry.status == "ready"
end

--[[--
Check if a Piper prefetch entry exists (pending or ready) for the given text.
@param text string
@return string|nil  "ready", "pending", "queued", "failed", or nil
--]]
function TTSEngine:getPiperPrefetchStatus(text)
    local entry = self._piper_queue[text]
    if entry then return entry.status end
    return nil
end

--[[--
Clean up the Piper async prefetch queue.
Removes all WAV files and cancels pending entries.
--]]
function TTSEngine:_cleanPiperQueue()
    -- Kill any running piper processes FIRST, before removing their files
    self:_killPiperProcesses()
    for text, entry in pairs(self._piper_queue) do
        if entry.file then
            os.remove(entry.file)
        end
        if entry.done_marker then
            os.remove(entry.done_marker)
        end
        if entry.text_file then
            os.remove(entry.text_file)
        end
    end
    self._piper_queue = {}
    self._piper_queue_order = {}
end

--[[--
Kill all running piper TTS processes.
Called when playback is stopped/cancelled to prevent orphaned piper
processes from consuming CPU and memory in the background.
--]]
function TTSEngine:_killPiperProcesses()
    os.execute("killall -9 piper 2>/dev/null")
    logger.dbg("TTSEngine: Killed all piper processes")
end

return TTSEngine
