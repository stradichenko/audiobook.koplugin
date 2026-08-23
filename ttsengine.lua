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
-- LIPC FFI: direct binding to Kindle's liblipc.so for native TTS playback.
-- CLI tools (lipc-set-prop) use anonymous, transient LIPC connections.
-- VoiceView uses named, persistent connections via the C API.
-- playermgr may only trigger TTS for named LIPC sources.
pcall(function() ffi.cdef[[
    typedef struct _LIPC LIPC;
    LIPC *LipcOpenEx(const char *service_name, int *code);
    LIPC *LipcOpenNoName(int *code);
    int LipcClose(LIPC *lipc);
    int LipcSetStringProperty(LIPC *lipc, const char *source, const char *prop, const char *value);
    int LipcGetIntProperty(LIPC *lipc, const char *source, const char *prop, int *value);
    int LipcGetStringProperty(LIPC *lipc, const char *source, const char *prop, char **value);
    void LipcFreeString(char *str);
]] end)
local _lipc_lib  -- loaded lazily on first Kindle native TTS use
-- InkView audio FFI: PocketBook audio daemon integration.
-- PlayFile routes through mpd.app instead of opening ALSA directly,
-- avoiding the amplifier corruption that kills PB700c speakers.
-- Declared separately so a missing symbol doesn't block other cdefs.
pcall(function() ffi.cdef[[ void PlayFile(const char *file); ]] end)
pcall(function() ffi.cdef[[ int GetPlayerState(void); ]] end)
local _inkview_audio  -- loaded lazily on first PB InkView use
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")
local T = require("ffi/util").template
-- Shared utility modules (DRY: extracted from ttsengine, synccontroller, main)
local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
local WavUtils = dofile(_utils_dir .. "wavutils.lua")
local PiperQueue = dofile(_utils_dir .. "piperqueue.lua")
local AndroidTts = dofile(_utils_dir .. "androidtts.lua")
local TTSEngine = {
    -- Supported TTS backends
    BACKENDS = {
        PICO = "pico",
        ESPEAK = "espeak",
        FLITE = "flite",
        FESTIVAL = "festival",
        ANDROID = "android",
        PIPER = "piper",
        KINDLE_NATIVE = "kindle-native",
        NATIVE = "platform-native",
    },
    -- Default settings
    DEFAULT_RATE = 1.0,
    DEFAULT_PITCH = 1.0,
    DEFAULT_VOLUME = 1.0,
    -- Status flags
    backend_error = nil,
    player_error = nil,
}

-- CP1252 characters that differ from ISO-8859-1 (bytes 0x80-0x9F).
-- Used by the platform-native backend when the configured helper expects
-- CP1252 input instead of UTF-8.  This is pure encoding data.
local CP1252_UNICODE = {
    [0x20AC] = 0x80, -- €
    [0x201A] = 0x82, -- ‚
    [0x0192] = 0x83, -- ƒ
    [0x201E] = 0x84, -- „
    [0x2026] = 0x85, -- …
    [0x2020] = 0x86, -- †
    [0x2021] = 0x87, -- ‡
    [0x02C6] = 0x88, -- ˆ
    [0x2030] = 0x89, -- ‰
    [0x0160] = 0x8A, -- Š
    [0x2039] = 0x8B, -- ‹
    [0x0152] = 0x8C, -- Œ
    [0x017D] = 0x8E, -- Ž
    [0x2018] = 0x91, -- ‘
    [0x2019] = 0x92, -- ’
    [0x201C] = 0x93, -- “
    [0x201D] = 0x94, -- ”
    [0x2022] = 0x95, -- •
    [0x2013] = 0x96, -- en dash
    [0x2014] = 0x97, -- em dash
    [0x02DC] = 0x98, -- ˜
    [0x2122] = 0x99, -- ™
    [0x0161] = 0x9A, -- š
    [0x203A] = 0x9B, -- ›
    [0x0153] = 0x9C, -- œ
    [0x017E] = 0x9E, -- ž
    [0x0178] = 0x9F, -- Ÿ
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
    -- Android TTS wrapper (initialized lazily in detectBackend)
    o._android_tts = nil
    -- Platform-native TTS daemon PID (only used in daemon/FIFO mode)
    o.native_daemon_pid = nil
    -- Load persisted "gst-play is broken" flag so we don't re-probe a
    -- hanging pipeline on every KOReader restart (issue #22, PW5).
    -- Clear broken flags when the plugin is updated so fixes can be re-tested.
    if o.plugin then
        local last_version = o.plugin:getSetting("_last_plugin_version") or ""
        local meta_ok, meta = pcall(dofile, _utils_dir .. "_meta.lua")
        local current_version = (meta_ok and meta and meta.version) or ""
        if current_version ~= "" and current_version ~= last_version then
            logger.warn("TTSEngine: plugin updated from", last_version, "to", current_version,
                "-- clearing broken flags for re-test")
            o.plugin:setSetting("_gst_play_broken", false)
            o.plugin:setSetting("_ttssrc_broken", false)
            o.plugin:setSetting("_last_plugin_version", current_version)
            o._gst_play_broken = false
            o._ttssrc_broken = false
        else
            o._gst_play_broken = o.plugin:getSetting("_gst_play_broken") or false
            o._ttssrc_broken = o.plugin:getSetting("_ttssrc_broken") or false
        end
    end
    -- Startup garbage collection: remove stale temp files left behind by
    -- previous crashed or force-quit sessions (issue #22).
    if Device:isKindle() then
        os.execute("rm -f /var/tmp/audiobook_*.wav /var/tmp/audiobook_*.xml /var/tmp/audiobook_*.txt /var/tmp/audiobook_*.done /var/tmp/piper_server_* /var/tmp/.gst_play_last.log /var/tmp/.ttssrc_* /var/tmp/audiomgrd.err /var/tmp/*.tmp 2>/dev/null")
        -- Truncate audiomgrd's deleted stderr log via /proc fd.
        -- audiomgrd holds the file open after deletion, so rm -f cannot
        -- reclaim the space. Truncating via /proc frees it (issue #22).
        local am_pid_h = io.popen("cat /var/run/audiomgrd.pid 2>/dev/null")
        local am_pid = am_pid_h and am_pid_h:read("*a"):match("%d+")
        if am_pid_h then am_pid_h:close() end
        if am_pid then
            os.execute(": > /proc/" .. am_pid .. "/fd/2 2>/dev/null")
        end
    end
    -- On Kindle, /usr/lib/tts is in ld.so.conf so the system linker resolves
    -- libIvonaEInkAPI.so.1.0, but the bundled ld-linux used to run gst-play
    -- only honours --library-path and LD_LIBRARY_PATH, not ld.so.conf.
    -- Detect the library at startup and cache the path so every gst-play
    -- --ttssrc invocation prepends it to LD_LIBRARY_PATH unconditionally.
    if Device:isKindle() then
        local ivona_lib = "/usr/lib/tts/libIvonaEInkAPI.so.1.0"
        local ivona_f = io.open(ivona_lib, "r")
        if ivona_f then
            ivona_f:close()
            o._ttssrc_ivona_lib_path = "/usr/lib/tts"
            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 found, will set LD_LIBRARY_PATH=/usr/lib/tts for ttssrc")
        end
    end
    o:detectBackend()
    return o
end
--[[--
Check whether a user-supplied platform-native helper is configured and exists.
@return boolean
--]]
function TTSEngine:_nativeHelperConfigured()
    local path = self.plugin and self.plugin:getSetting("native_helper_path", "")
    if not path or path == "" then return false end
    local f = io.open(path, "r")
    if f then
        f:close()
        return true
    end
    -- Some devices cannot io.open executables; fall back to test -x.
    local rc = os.execute("test -x '" .. path .. "' 2>/dev/null")
    return rc == 0 or rc == true
end
--[[--
Detect available TTS backend.
--]]
function TTSEngine:detectBackend()
    local is_android = Device:isAndroid()
    --- Check if a file exists, with shell fallback for devices where
    --- io.open may fail on binary files (observed on some Kindle models).
    local function fileAccessible(path)
        local f, err = io.open(path, "r")
        if f then
            f:close()
            return true
        end
        -- io.open failed -- try shell-based check as fallback
        local rc = os.execute("test -f '" .. path .. "' 2>/dev/null")
        if rc == 0 or rc == true then
            logger.warn("TTSEngine: io.open failed for", path, "(" .. tostring(err) .. ") but test -f succeeded")
            return true
        end
        return false
    end
    --- Rename a .bin-suffixed file back to its original name.
    -- The release zip ships ELF binaries with a .bin extension so they
    -- survive Windows extraction / antivirus.  On first run we rename
    -- them back.  Returns true if the file now exists at `path`.
    local function ensureBinary(path)
        local bin_path = path .. ".bin"
        if fileAccessible(path) and fileAccessible(bin_path) then
            -- Both exist: a fresh .bin arrived via an update while the
            -- renamed binary from the previous version is still in place.
            -- The .bin only ever appears from a fresh zip extraction, so
            -- it is always the newer build.  Without this replacement,
            -- updating users keep running the old binary forever (issue
            -- #49: the wav-play conversion flags never reached the device).
            logger.warn("TTSEngine: replacing stale binary with updated", bin_path)
            os.remove(path)
        end
        if fileAccessible(path) then return true end
        if fileAccessible(bin_path) then
            local ok = os.rename(bin_path, path)
            if ok then
                os.execute("chmod +x '" .. path .. "' 2>/dev/null")
                logger.warn("TTSEngine: renamed", bin_path, "->", path)
                return true
            end
            -- os.rename failed (cross-device?), try shell mv
            local rc = os.execute("mv '" .. bin_path .. "' '" .. path .. "' 2>/dev/null")
            if rc == 0 or rc == true then
                os.execute("chmod +x '" .. path .. "' 2>/dev/null")
                logger.warn("TTSEngine: mv renamed", bin_path, "->", path)
                return true
            end
            logger.warn("TTSEngine: found .bin but rename failed:", bin_path)
        end
        return false
    end
    -- On Android, the bundled espeak-ng/Piper binaries are compiled for Linux
    -- (glibc) and won't run on Android's Bionic libc.  Skip bundled binaries
    -- and go straight to system PATH detection.
    if not is_android then
        -- Detect all available bundled engines first, then pick the best default.
        local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin")
        logger.warn("TTSEngine: detectBackend plugin_dir =", plugin_dir)
        -- Check for bundled espeak-ng (rename .bin -> original if needed)
        local bundled_base = plugin_dir .. "/espeak-ng"
        local bundled_bin = bundled_base .. "/bin/espeak-ng"
        local found_espeak = false
        if ensureBinary(bundled_bin) then
            found_espeak = true
            self.backend_cmd = bundled_bin
            self.espeak_bin = bundled_bin  -- keep reference for fallback even when Piper is active
            self.espeak_bin_path = bundled_base .. "/bin"
            self.espeak_lib_path = bundled_base .. "/lib"
            self.espeak_data_path = bundled_base .. "/share"
            self.espeak_linker = bundled_base .. "/lib/ld-linux-armhf.so.3"
            logger.dbg("TTSEngine: Found bundled espeak-ng at", bundled_bin)
        else
            logger.warn("TTSEngine: bundled espeak-ng not found at", bundled_bin)
        end
        -- Check for bundled Piper TTS binary (rename .bin -> original if needed)
        local piper_dir = plugin_dir .. "/piper"
        local bundled_piper_bin = piper_dir .. "/piper"
        local found_piper = false
        if ensureBinary(bundled_piper_bin) then
            -- Also rename Piper's helper binaries (.bin -> original)
            ensureBinary(piper_dir .. "/piper_phonemize")
            ensureBinary(piper_dir .. "/espeak-ng")
            found_piper = true
            self.piper_cmd = bundled_piper_bin
            self.piper_model_dir = piper_dir
            logger.dbg("TTSEngine: Found bundled Piper TTS at", bundled_piper_bin)
        else
            logger.warn("TTSEngine: bundled Piper not found at", bundled_piper_bin)
        end
        -- Check for bundled wav-play (ALSA player for devices without aplay)
        local wav_play_bin = plugin_dir .. "/wav-play/wav-play"
        if ensureBinary(wav_play_bin) then
            self._wav_play_bin = wav_play_bin
            self._wav_play_lib = plugin_dir .. "/wav-play/lib"
            logger.dbg("TTSEngine: Found bundled wav-play at", wav_play_bin)
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
    end
    -- Fall back to system PATH (also the primary path on Android)
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
    -- On Android, select the system TTS backend but DO NOT load the helper
    -- .dex / TextToSpeech engine here.  DexClassLoader + TTS binder init at
    -- document-open time hard-crashes KOReader on some Boox devices (Go 10.3).
    -- Real init happens lazily in _ensureAndroidTts() on first speak().
    -- EPUB Media Overlay playback uses AndroidPlayer and never needs this.
    if is_android then
        self.backend = self.BACKENDS.ANDROID
        self._android_tts = nil
        self._android_tts_deferred = true
        logger.warn("TTSEngine: Android TTS selected (deferred init until first speak)")
        return
    end
    -- Platform-native TTS: user-supplied helper that drives a device-native,
    -- licensed engine (e.g. PocketBook ReadSpeaker).  This is a last-resort
    -- fallback when no bundled/system engine is found, but it is intentionally
    -- checked before Kindle native so a configured helper takes priority.
    if self:_nativeHelperConfigured() then
        self.backend = self.BACKENDS.NATIVE
        self.backend_cmd = self.plugin:getSetting("native_helper_path")
        logger.warn("TTSEngine: Using platform-native backend:", self.backend_cmd)
        return
    end
    -- Kindle native TTS: Amazon's Ivona SDK via tts.orchestrator/playermgr.
    -- Last resort when no bundled or system TTS binaries are found.
    -- The Kindle's built-in TTS handles both synthesis and audio output.
    if Device:isKindle() and self:commandExists("lipc-get-prop") then
        local h = io.popen("lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>/dev/null")
        if h then
            local val = h:read("*a") or ""; h:close()
            if val:match("^%s*1") then
                self.backend = self.BACKENDS.KINDLE_NATIVE
                logger.warn("TTSEngine: Using Kindle native TTS (Ivona SDK via tts.orchestrator)")
                return
            end
        end
    end
    self.backend = nil
    if is_android then
        self.backend_error = _("No TTS engine available on this device.\n\nThe Android TTS helper (.dex) was not found at the expected path.\n\nPlease verify that tts_helper.dex exists inside the plugin's android/ folder.\n\nAs a workaround, install espeak-ng via Termux:\n  pkg install espeak-ng\n\nThen add Termux to your PATH before launching KOReader.")
    else
        -- Check if the user has .onnx voice models but no binaries.
        -- This usually means a source-code install or incomplete extraction.
        local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
        local has_onnx = false
        local lh = io.popen("ls '" .. plugin_dir .. "'/piper/*.onnx 2>/dev/null")
        if lh then
            local lr = lh:read("*a") or ""
            lh:close()
            has_onnx = lr:match("%.onnx")
        end
        if has_onnx then
            self.backend_error = _("No TTS engine found.\n\nVoice model files were found but the TTS binaries (espeak-ng, piper) are missing.\n\nPlease download the .zip file (audiobook-koplugin-v*.zip) from:\nhttps://github.com/stradichenko/audiobook.koplugin/releases/latest\n\nDo not download 'Source code' -- it does not include the TTS engines.\n\nIf you already installed from the .zip, please generate a bug report from the plugin menu and post it on GitHub.")
        else
            self.backend_error = _("No TTS engine found. Please install espeak-ng.")
        end
    end
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

--- Detect whether this device is a PocketBook.
-- KOReader's Device:isPocketBook() is reliable on most builds, but some
-- firmware versions do not set the device flag correctly.  Use fallback
-- heuristics (/ebrmain, hostname, koreader install path) to catch them.
-- @treturn bool
function TTSEngine:isPocketBook()
    if Device.isPocketBook and Device:isPocketBook() then
        return true
    end
    local d = io.open("/ebrmain/config/device.cfg", "r")
    if d then d:close(); return true end
    local h = io.open("/etc/hostname", "r")
    if h then
        local name = h:read("*l") or ""
        h:close()
        if name:lower():find("pocketbook") then return true end
    end
    local k = io.open("/mnt/ext1/applications/koreader", "r")
    if k then k:close(); return true end
    return false
end

--- Try to load the PocketBook InkView PlayFile FFI library.
-- Returns true and sets audio_player_type if InkView is available.
-- @treturn bool
function TTSEngine:_tryInkView()
    if not _inkview_audio then
        local ok, lib = pcall(ffi.load, "inkview")
        if ok then
            local pf_ok = pcall(function() local _ = lib.PlayFile end)
            local gs_ok = pcall(function() local _ = lib.GetPlayerState end)
            if pf_ok and gs_ok then
                _inkview_audio = lib
            else
                logger.warn("TTSEngine: InkView loaded but PlayFile/GetPlayerState not exported")
            end
        else
            logger.dbg("TTSEngine: libinkview.so not available:", lib)
        end
    end
    if _inkview_audio then
        self.audio_player_type = "pb-inkview"
        self._pb_has_tts_sm = false
        logger.warn("TTSEngine: Using InkView PlayFile (PB audio daemon)")
        return true
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
Return the ESPEAK_DATA_PATH. All languages are bundled with the plugin,
so this is just the bundled data directory.
@return string  Directory to use as ESPEAK_DATA_PATH
--]]
function TTSEngine:_resolveEspeakDataPath()
    return self.espeak_data_path or "/usr/share"
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
            text = self.backend_error or _("No TTS engine available.\n\nOn Kobo/Kindle, install espeak-ng or use the pre-built release.\nOn Android, TTS is not yet supported.\n\nSee README for details."),
            timeout = 5,
        })
        if callback then
            callback(false, nil)
        end
        return false
    end
    self.timing_data = {}
    -- Store the text for all backends so that Kindle native TTS fallback
    -- (used when WAV playback fails on stripped GStreamer firmware) has
    -- the sentence text available.  See kindle-native-tts-fallback in
    -- findAudioPlayer() and play().
    self._native_tts_text = text
    -- Kindle native TTS: text goes directly to playermgr (no WAV synthesis).
    -- The Kindle's Ivona SDK handles both synthesis and audio output.
    if self.backend == self.BACKENDS.KINDLE_NATIVE then
        self:generateTimingEstimates(text)
        local dur_ms = 0
        if #self.timing_data > 0 then
            dur_ms = self.timing_data[#self.timing_data].end_time
        end
        self._current_audio_duration_ms = dur_ms
        self.current_audio_file = "/tmp/.kindle_native_tts"
        logger.warn("TTSEngine: Kindle native TTS queued:", text:sub(1, 60),
            "est_dur=", dur_ms, "ms")
        if callback then callback(true, self.timing_data) end
        return true
    end
    logger.dbg("TTSEngine: Starting synthesis with backend:", self.backend)
    return self:synthesizeCommand(text, callback)
end

--[[--
Convert a UTF-8 string to a CP1252 byte string.
Unsupported characters are replaced with '?' (0x3F).
@return string
--]]
function TTSEngine:_utf8ToCp1252(text)
    local out = {}
    local i = 1
    local n = #text
    while i <= n do
        local b1 = text:byte(i)
        local cp, len
        if b1 < 0x80 then
            cp, len = b1, 1
        elseif b1 < 0xC0 then
            -- Invalid continuation byte; skip it.
            cp, len = 0xFFFD, 1
        elseif b1 < 0xE0 then
            cp = (b1 % 0x20) * 0x40 + ((text:byte(i + 1) or 0) % 0x40)
            len = 2
        elseif b1 < 0xF0 then
            cp = (b1 % 0x10) * 0x1000
                 + ((text:byte(i + 1) or 0) % 0x40) * 0x40
                 + ((text:byte(i + 2) or 0) % 0x40)
            len = 3
        else
            cp = (b1 % 0x08) * 0x40000
                 + ((text:byte(i + 1) or 0) % 0x40) * 0x1000
                 + ((text:byte(i + 2) or 0) % 0x40) * 0x40
                 + ((text:byte(i + 3) or 0) % 0x40)
            len = 4
        end

        local byte_val
        if cp <= 0x7F then
            byte_val = cp
        elseif cp >= 0xA0 and cp <= 0xFF then
            byte_val = cp
        else
            byte_val = CP1252_UNICODE[cp]
        end

        table.insert(out, string.char(byte_val or 0x3F))
        i = i + len
    end
    return table.concat(out)
end

--[[--
Synthesize using the user-supplied platform-native helper.
@param text string Text to synthesize
@param audio_file string Output WAV file path
@param callback function Callback when synthesis is complete
@return boolean|nil Success, or nil if async
--]]
function TTSEngine:_synthesizeNative(text, audio_file, callback)
    -- Optional device-specific preparation (e.g. restarting alsaloop on PocketBook).
    local pre_step = self.plugin:getSetting("native_prestep_command", "")
    if pre_step ~= "" then
        os.execute(pre_step .. " 2>/dev/null")
    end

    local encoding = self.plugin:getSetting("native_input_encoding", "utf-8")
    if encoding == "cp1252" then
        text = self:_utf8ToCp1252(text)
    end

    local speed = string.format("%.3f", self.rate or 1.0)
    local mode = self.plugin:getSetting("native_speed_mode", "oneshot")

    if mode == "daemon" then
        return self:_synthesizeNativeDaemon(text, audio_file, speed, callback)
    else
        return self:_synthesizeNativeOneshot(text, audio_file, speed, callback)
    end
end

--[[--
Platform-native helper one-shot mode.
Runs the helper once per sentence and polls a .done marker.
--]]
function TTSEngine:_synthesizeNativeOneshot(text, audio_file, speed, callback)
    local temp_dir = "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local input_file = temp_dir .. "/audiobook_native_" .. os.time() .. "_" .. self.file_counter .. ".txt"

    local f = io.open(input_file, "wb")
    if not f then
        logger.err("TTSEngine: cannot write native input file")
        if callback then callback(false, nil) end
        return false
    end
    f:write(text)
    f:close()

    local helper = self.backend_cmd
    if not helper or helper == "" then
        logger.err("TTSEngine: native helper path not configured")
        os.remove(input_file)
        if callback then callback(false, nil) end
        return false
    end

    local cmd = string.format(
        "'%s' --input '%s' --output '%s' --speed '%s'",
        helper:gsub("'", "'\\''"),
        input_file:gsub("'", "'\\''"),
        audio_file:gsub("'", "'\\''"),
        speed
    )
    local done_marker = audio_file .. ".done"
    local log_file = "/tmp/.native_tts_last.log"
    local bg_cmd = string.format(
        '(%s > "%s" 2>&1; echo $? > "%s") &',
        cmd, log_file, done_marker
    )

    logger.dbg("TTSEngine: native one-shot command:", cmd)
    os.execute(bg_cmd)

    local engine = self
    local poll_count = 0
    local max_polls = 120
    local function pollNativeDone()
        poll_count = poll_count + 1
        local mf = io.open(done_marker, "r")
        if mf then
            local exit_code = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(done_marker)
            os.remove(input_file)

            local af = io.open(audio_file, "r")
            local size = 0
            if af then
                af:seek("end", 0)
                size = af:seek()
                af:close()
            end

            if size > 0 then
                engine.current_audio_file = audio_file
                engine:generateTimingEstimates(engine._native_tts_text or text)
                os.remove(log_file)
                if callback then callback(true, engine.timing_data) end
                return
            end

            logger.err("TTSEngine: native one-shot failed, exit_code:", exit_code)
            local log_f = io.open(log_file, "r")
            if log_f then
                logger.err("TTSEngine: native helper log:", log_f:read("*a"))
                log_f:close()
            end
            os.remove(log_file)
            if callback then callback(false, nil) end
            return
        end

        if poll_count < max_polls then
            UIManager:scheduleIn(0.5, pollNativeDone)
        else
            logger.err("TTSEngine: native one-shot timed out")
            os.remove(done_marker)
            os.remove(input_file)
            os.remove(log_file)
            if callback then callback(false, nil) end
        end
    end

    UIManager:scheduleIn(0.3, pollNativeDone)
    return nil
end

--[[--
Return the configured FIFO path for the native TTS daemon.
--]]
function TTSEngine:_nativeFifoPath()
    local configured = self.plugin:getSetting("native_fifo_path", "")
    if configured and configured ~= "" then
        return configured
    end
    return "/tmp/audiobook_native_tts.fifo"
end

--[[--
Platform-native helper daemon/FIFO mode.
The helper is started once and kept running; requests are sent via FIFO
and completion is signaled through a .done marker file so the UI thread
never blocks on a FIFO read.
--]]
function TTSEngine:_synthesizeNativeDaemon(text, audio_file, speed, callback)
    if not self:_ensureNativeDaemon() then
        logger.err("TTSEngine: native daemon not available")
        if callback then callback(false, nil) end
        return false
    end

    local temp_dir = "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local input_file = temp_dir .. "/audiobook_native_" .. os.time() .. "_" .. self.file_counter .. ".txt"
    local f = io.open(input_file, "wb")
    if not f then
        logger.err("TTSEngine: cannot write native daemon input file")
        if callback then callback(false, nil) end
        return false
    end
    f:write(text)
    f:close()

    local req_fifo = self:_nativeFifoPath()
    local done_marker = audio_file .. ".done"

    -- Remove any stale done marker before sending the request.
    os.remove(done_marker)

    local request = string.format("SYNTH|%s|%s|%s\n",
        input_file:gsub("|", "\\|"),
        audio_file:gsub("|", "\\|"),
        speed)

    -- Write the request in the background so the UI thread never blocks
    -- waiting for the daemon to open the FIFO for reading.
    local write_cmd = string.format(
        "printf '%%s' '%s' > '%s' 2>/dev/null &",
        request:gsub("'", "'\\''"),
        req_fifo:gsub("'", "'\\''")
    )
    os.execute(write_cmd)

    logger.dbg("TTSEngine: native daemon request:", request:gsub("%s+$", ""))

    local engine = self
    local poll_count = 0
    local max_polls = 120
    local function pollNativeDone()
        poll_count = poll_count + 1
        local mf = io.open(done_marker, "r")
        if mf then
            local result = mf:read("*a"):gsub("%s+", "")
            mf:close()
            os.remove(done_marker)
            os.remove(input_file)

            local status, msg = result:match("^([^|]+)|?(.*)$")
            local af = io.open(audio_file, "r")
            local size = 0
            if af then
                af:seek("end", 0)
                size = af:seek()
                af:close()
            end

            if status == "OK" and size > 0 then
                engine.current_audio_file = audio_file
                engine:generateTimingEstimates(engine._native_tts_text or text)
                if callback then callback(true, engine.timing_data) end
                return
            else
                logger.err("TTSEngine: native daemon error:", result)
                if callback then callback(false, nil) end
                return
            end
        end

        if poll_count < max_polls then
            UIManager:scheduleIn(0.5, pollNativeDone)
        else
            logger.err("TTSEngine: native daemon response timed out")
            os.remove(input_file)
            if callback then callback(false, nil) end
        end
    end

    UIManager:scheduleIn(0.3, pollNativeDone)
    return nil
end

--[[--
Start or verify the platform-native helper daemon.
This is intentionally non-blocking; it returns immediately and the first
request will time out gracefully if the daemon is not yet ready.
--]]
function TTSEngine:_ensureNativeDaemon()
    local helper = self.backend_cmd
    if not helper or helper == "" then return false end

    local pid_file = "/tmp/audiobook_native_daemon.pid"
    local lock_file = "/tmp/audiobook_native_daemon.lock"
    local log_file = "/tmp/audiobook_native_daemon.log"
    local req_fifo = self:_nativeFifoPath()

    -- Check existing daemon.
    local pf = io.open(pid_file, "r")
    if pf then
        local pid = tonumber(pf:read("*a"))
        pf:close()
        if pid and io.open("/proc/" .. pid .. "/stat", "r") then
            return true
        end
    end

    -- Create the request FIFO and remove stale PID file.
    os.execute("mkfifo '" .. req_fifo:gsub("'", "'\\''") .. "' 2>/dev/null")
    os.remove(pid_file)

    local has_flock = self:commandExists("flock")
    local start_cmd
    if has_flock then
        start_cmd = string.format(
            "flock -n '%s' -c '%s --daemon --fifo %s' >'%s' 2>&1 & echo $!",
            lock_file:gsub("'", "'\\''"),
            helper:gsub("'", "'\\''"),
            req_fifo:gsub("'", "'\\''"),
            log_file:gsub("'", "'\\''")
        )
    else
        -- Fallback: start helper directly.  The helper itself is expected to
        -- reject duplicate instances if it needs single-instancing.
        start_cmd = string.format(
            "'%s' --daemon --fifo '%s' >'%s' 2>&1 & echo $!",
            helper:gsub("'", "'\\''"),
            req_fifo:gsub("'", "'\\''"),
            log_file:gsub("'", "'\\''")
        )
    end

    local h = io.popen(start_cmd)
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    local pid = tonumber(pid_str:match("(%d+)"))
    if not pid then
        logger.err("TTSEngine: failed to start native daemon")
        return false
    end

    local wf = io.open(pid_file, "w")
    if wf then
        wf:write(tostring(pid))
        wf:close()
    end
    self.native_daemon_pid = pid
    logger.warn("TTSEngine: started native daemon pid", pid)
    return true
end

--[[--
Stop the platform-native helper daemon.
--]]
function TTSEngine:_stopNativeDaemon()
    local pid_file = "/tmp/audiobook_native_daemon.pid"
    local pf = io.open(pid_file, "r")
    if pf then
        local pid = tonumber(pf:read("*a"))
        pf:close()
        if pid then
            os.execute("kill -TERM " .. pid .. " 2>/dev/null")
            os.execute("(sleep 1; kill -9 " .. pid .. " 2>/dev/null) >/dev/null 2>&1 &")
        end
    end
    os.remove(pid_file)
    self.native_daemon_pid = nil
end

--[[--
Synthesize using command-line TTS.
@param text string Text to synthesize
@param callback function Callback when synthesis is complete
@return boolean Success
--]]
function TTSEngine:synthesizeCommand(text, callback)
    -- Use Android cache dir when running on Android (no /tmp); otherwise /tmp
    local temp_dir = self._android_tts and self._android_tts:getTempDir() or "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_tts_" .. os.time() .. "_" .. self.file_counter .. ".wav"
    local timing_file = temp_dir .. "/audiobook_timing_" .. os.time() .. ".txt"
    local cmd
    -- Limit text length to avoid command line issues and MBROLA phoneme
    -- buffer overflow.  MBROLA's internal buffer is small; very long
    -- input can cause playback artifacts on some firmware.
    local max_text_len = 1000
    if self.voice and self.voice:match("^mb%-") then
        max_text_len = 300
    end
    if #text > max_text_len then
        text = text:sub(1, max_text_len)
        logger.dbg("TTSEngine: Truncated text to", max_text_len, "chars")
    end
    -- Preflight: check that /tmp has enough free space.  On Kindle /tmp is
    -- a symlink to /var/tmp; a full /var causes synthesis to silently fail
    -- because espeak-ng and Piper cannot write their output WAV files.
    -- Issue #22 / #23.
    if Device:isKindle() then
        local df_h = io.popen("df /var 2>/dev/null | tail -1")
        if df_h then
            local df_line = df_h:read("*a") or ""; df_h:close()
            local _fs, _blocks, _used, avail, pct = df_line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
            local use_pct = tonumber(pct and pct:match("(%d+)"))
            local avail_kb = tonumber(avail)
            if use_pct and (use_pct >= 90 or (avail_kb and avail_kb < 5120)) then
                logger.warn("TTSEngine: /var is", use_pct, "% full (", avail_kb, "KB free) -- running cleanup")
                -- Aggressive cleanup of known temp file patterns from previous
                -- sessions (crashes, force-quits) that leak into /var/tmp.
                os.execute("rm -f /var/tmp/audiobook_*.wav /var/tmp/audiobook_*.xml /var/tmp/audiobook_*.txt /var/tmp/audiobook_*.done /var/tmp/piper_server_* /var/tmp/.gst_play_last.log /var/tmp/.ttssrc_* /var/tmp/audiomgrd.err /var/tmp/*.tmp 2>/dev/null")
                -- Re-check after cleanup; abort only if still critically full.
                local df_h2 = io.popen("df /var 2>/dev/null | tail -1")
                if df_h2 then
                    local df_line2 = df_h2:read("*a") or ""; df_h2:close()
                    local use_pct2 = tonumber(df_line2:match("(%d+)%%"))
                    if use_pct2 and use_pct2 >= 95 then
                        logger.warn("TTSEngine: /var still", use_pct2, "% full after cleanup")
                        UIManager:show(InfoMessage:new{
                            text = _("Temporary storage is critically full (" .. use_pct .. "% used).\n\nTTS synthesis needs space in /tmp to create audio files.\n\nPlease reboot your Kindle to clear temporary files, then try again."),
                            timeout = 12,
                        })
                        if callback then callback(false, nil) end
                        return false
                    end
                end
            end
        end
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
        local esp_data = self:_resolveEspeakDataPath()
        if self.espeak_linker then
            local path_prefix = ""
            if self.espeak_bin_path then
                path_prefix = string.format("PATH=%s:$PATH ", self.espeak_bin_path)
            end
            -- Explicitly unset LD_LIBRARY_PATH so that forked children
            -- (e.g. /bin/sh spawned by espeak-ng's mbrowrap) don't try to
            -- load system binaries against the bundled libs.
            -- XDG_DATA_DIRS is needed so espeak-ng's MBROLA voice lookup
            -- finds voice databases in the plugin's share/mbrola/ directory
            -- (the fallback search uses XDG_DATA_DIRS, not ESPEAK_DATA_PATH).
            exec_prefix = string.format(
                "%sLD_LIBRARY_PATH= XDG_DATA_DIRS=%s ESPEAK_DATA_PATH=%s %s --library-path %s ",
                path_prefix, esp_data, esp_data, self.espeak_linker, self.espeak_lib_path
            )
        elseif self.espeak_lib_path then
            local path_prefix = ""
            if self.espeak_bin_path then
                path_prefix = string.format("PATH=%s:$PATH ", self.espeak_bin_path)
            end
            exec_prefix = string.format(
                "%sLD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
                path_prefix, self.espeak_lib_path, esp_data
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
    elseif self.backend == self.BACKENDS.ANDROID then
        -- Android TTS via JNI: synthesize to WAV file asynchronously
        return self:synthesizeAndroid(text, audio_file, callback)
    elseif self.backend == self.BACKENDS.NATIVE then
        -- Platform-native TTS via user-supplied helper binary/script.
        return self:_synthesizeNative(text, audio_file, callback)
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
        -- Wrap: run synthesis in background, write a marker file when done.
        -- Capture stderr to a log file so we can detect ONNX Runtime errors
        -- (e.g. "Protobuf parsing failed") and provide better diagnostics.
        local done_marker = audio_file .. ".done"
        local piper_log = "/tmp/.piper_last.log"
        local bg_cmd = string.format(
            '(%s > "%s" 2>&1; echo $? > "%s") &',
            cmd, piper_log, done_marker
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
                        os.remove(piper_log)
                        -- Chain: launch next queued prefetch now that the process slot is free
                        engine:_launchNextPiperPrefetch()
                        if callback then
                            callback(true, engine.timing_data)
                        end
                        return
                    end
                end
                logger.err("TTSEngine: Piper async failed, exit_code:", exit_code)
                -- Check for ONNX Runtime incompatibility (Protobuf parsing failed).
                -- Auto-fallback to espeak-ng so the user still gets audio.
                local log_f = io.open(piper_log, "r")
                local log_text = log_f and log_f:read("*a") or ""
                if log_f then log_f:close() end
                if log_text:match("Protobuf parsing failed")
                    or log_text:match("ONNX") then
                    engine._piper_onnx_broken = true
                    logger.warn("TTSEngine: Piper ONNX error detected, auto-falling back to espeak-ng")
                    os.remove(piper_log)
                    -- Switch to espeak-ng for this session
                    engine.backend = engine.BACKENDS.ESPEAK
                    engine.backend_cmd = engine.espeak_cmd
                    engine.backend_name = "espeak-ng"
                    UIManager:show(InfoMessage:new{
                        text = _(
                            "Piper voice model is incompatible with this device (ONNX Runtime error).\n\n"
                            .. "Switching to espeak-ng. You can select a different voice in Audiobook settings."
                        ),
                        timeout = 6,
                    })
                    -- Retry synthesis with espeak-ng
                    return engine:synthesizeCommand(text, callback)
                end
                os.remove(piper_log)
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
                os.remove(piper_log)
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
    -- Non-Piper backends: run synchronously (espeak-ng is fast ~100ms).
    -- Use io.popen so we can capture stderr for diagnostics.
    local synth_handle = io.popen(cmd, "r")
    local synth_output = ""
    if synth_handle then
        synth_output = synth_handle:read("*a") or ""
        synth_handle:close()
    end
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
    -- Check if file was created
    local file = io.open(audio_file, "r")
    if file then
        file:close()
        local size = self:getFileSize(audio_file)
        logger.dbg("TTSEngine: Audio file created, size:", size)
        if size and size > 0 then
            self.current_audio_file = audio_file
            -- Warn if espeak-ng reported voice issues even though it produced
            -- a file (can happen when MBROLA voice is missing and espeak falls
            -- back to default voice).
            if synth_output and synth_output:match("[Vv]oice") then
                logger.warn("TTSEngine: espeak voice warning:", synth_output:sub(1, 200))
            end
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
    if synth_output and #synth_output > 0 then
        logger.err("TTSEngine: Synthesis output:", synth_output:sub(1, 400))
    end
    -- Show error to user
    local err_msg = _("TTS synthesis failed.\n\nCould not generate audio file.\n\nCommon causes:\n• The TTS engine is not installed\n• /tmp or /var is full (reboot to clear)\n• Insufficient free memory")
    if synth_output and #synth_output > 0 then
        err_msg = err_msg .. _("\n\nError output:\n") .. synth_output:sub(1, 200)
    end
    UIManager:show(InfoMessage:new{
        text = err_msg,
        timeout = 6,
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
Synthesize using Android TTS via JNI.
Dispatches synthesis to the TtsHelper, then polls for completion.
Runs asynchronously via UIManager:scheduleIn so the UI stays responsive.
@param text string Text to synthesize
@param audio_file string Output WAV file path
@param callback function Callback(success, timing_data)
@return nil  (async -- caller should not treat as immediate failure)
--]]
-- CJK script detection as raw UTF-8 byte patterns (no unicode library):
--   Han U+4E00-U+9FFF:      lead byte E4-E9 + two continuation bytes
--   Kana U+3040-U+30FF:     E3 + 81-83 + continuation byte
--   Hangul U+AC00-U+D7A3:   lead byte EA-ED + two continuation bytes
-- These blocks are disjoint, so match order between them does not matter.
local RE_HAN    = "[\228-\233][\128-\191][\128-\191]"
local RE_KANA   = "\227[\129-\131][\128-\191]"
local RE_HANGUL = "[\234-\237][\128-\191][\128-\191]"

--[[--
Book language from document metadata (EPUB dc:language etc.), normalized to
a BCP-47 tag usable with Android's Locale.forLanguageTag.  Bare CJK tags get
a region because Google's TTS needs one to pick a voice.  Cached per engine
instance (the engine is recreated per document).
@return string|nil
--]]
function TTSEngine:_androidBookLanguage()
    if self._android_book_lang ~= nil then
        return self._android_book_lang or nil
    end
    local lang
    pcall(function()
        local doc = self.plugin and self.plugin.ui and self.plugin.ui.document
        local props = doc and doc.getProps and doc:getProps()
        lang = props and props.language
    end)
    if type(lang) ~= "string" then lang = nil end
    if lang then
        lang = lang:lower():gsub("_", "-"):match("^%s*(.-)%s*$")
        if lang == "" then lang = nil end
    end
    local aliases = {
        zh = "zh-CN", ja = "ja-JP", ko = "ko-KR", en = "en-US",
        fr = "fr-FR", de = "de-DE", es = "es-ES", it = "it-IT",
        pt = "pt-BR", nl = "nl-NL", pl = "pl-PL", cs = "cs-CZ",
        uk = "uk-UA", hi = "hi-IN", ar = "ar-JO", ca = "ca-ES",
        da = "da-DK", fi = "fi-FI", ru = "ru-RU", el = "el-GR",
        no = "no-NO", nb = "no-NO", nn = "no-NO", sv = "sv-SE",
        tr = "tr-TR", hu = "hu-HU", ro = "ro-RO",
    }
    if lang and aliases[lang] then lang = aliases[lang] end
    self._android_book_lang = lang or false
    logger.dbg("TTSEngine: Android book language =", lang or "(unknown)")
    return lang
end

--[[--
Resolve the Android TTS language for one text chunk.
Priority: explicit user setting > CJK script detection > book metadata >
"en-US".  Han characters are shared between Chinese and Japanese, so the
book language breaks the tie; kana and hangul are unambiguous on their own.
@param text string
@return string  BCP-47 tag
--]]
function TTSEngine:_androidChunkLanguage(text)
    local override = self.plugin
        and self.plugin:getSetting("android_tts_language", "auto")
    if override and override ~= "auto" then
        return override
    end
    local book = self:_androidBookLanguage()
    if text:find(RE_KANA) then return "ja-JP" end
    if text:find(RE_HANGUL) then return "ko-KR" end
    if text:find(RE_HAN) then
        if book == "ja-JP" then return "ja-JP" end
        if book and (book:find("^zh%-tw") or book:find("^zh%-hant")
                or book:find("^zh%-hk") or book:find("^zh%-mo")) then
            return "zh-TW"
        end
        return "zh-CN"
    end
    return book or "en-US"
end

--[[--
Whether Android playback uses the persistent PCM streamer: the menu
setting (persisted, default off) or the session-only stall auto-degrade
(issue #44).  Applied at every pipeline dispatch so mid-session toggles
and the auto-degrade both take effect from the next sentence.
@return boolean
--]]
function TTSEngine:_androidPcmActive()
    if self._android_pcm_auto then return true end
    return self.plugin and self.plugin:getSetting("android_pcm_stream", false) or false
end

--- Lazy-load AndroidTts (dex + TextToSpeech). Safe to call repeatedly.
--- @return table|nil AndroidTts instance, or nil on failure
function TTSEngine:_ensureAndroidTts()
    if self._android_tts then return self._android_tts end
    if self._android_tts_failed then return nil end

    local atts = AndroidTts:new{
        plugin_dir = self.plugin_dir or ".",
    }
    local ok, err = pcall(function()
        if not atts:init() then
            error("AndroidTts:init returned false")
        end
        if not atts:waitForInit(3000) then
            atts:shutdown()
            error("AndroidTts:waitForInit failed")
        end
    end)
    if not ok then
        self._android_tts_failed = true
        self._android_tts_deferred = false
        logger.err("TTSEngine: Android TTS deferred init failed:", err)
        return nil
    end

    self._android_tts = atts
    self._android_tts_deferred = false
    logger.warn("TTSEngine: Android TTS helper ready (lazy init)")
    return atts
end

function TTSEngine:synthesizeAndroid(text, audio_file, callback)
    local atts = self:_ensureAndroidTts()
    if not atts then
        logger.err("TTSEngine: Android TTS not initialized")
        if callback then callback(false, nil) end
        return false
    end
    -- Forward rate/pitch settings to the Android engine
    atts:setRate(self.rate or 1.0)
    -- espeak-ng pitch is 0-99 (default 50); Android pitch is a multiplier
    -- around 1.0.  Map 0-99 to 0.5-2.0 range.
    local android_pitch = 0.5 + ((self.pitch or 50) / 99) * 1.5
    atts:setPitch(android_pitch)
    -- Playback path: per-sentence MediaPlayer by default, persistent PCM
    -- stream when the user enabled it or a stall was auto-detected (#44).
    atts:setPcmMode(self:_androidPcmActive())
    -- Language: the Java helper initializes with Locale.US and nothing ever
    -- changed it, so non-English books were read with the en-US voice or
    -- stayed silent (issue #45).  Resolve per chunk (manual override > CJK
    -- script detection > book metadata) and only cross JNI when the
    -- language actually changes.
    -- Time the JNI calls: on some devices the TTS engine's binder calls can
    -- block (issue #44); the timings pinpoint the culprit in logcat.
    local jni_t0 = UIManager:getTime()
    local chunk_lang = self:_androidChunkLanguage(text)
    local voice_name = self.plugin
        and self.plugin:getSetting("android_tts_voice", "")
        or ""
    if voice_name ~= "" then
        if voice_name ~= self._android_tts_voice then
            local res = atts:setVoice(voice_name)
            logger.dbg("TTSEngine: Android TTS voice =", voice_name, "result:", res)
            if res and res >= 0 then
                self._android_tts_voice = voice_name
                self._android_tts_lang = "voice:" .. voice_name
            else
                -- Voice name unknown to this engine; fall back to language.
                self._android_tts_voice = false
                logger.warn("TTSEngine: Android TTS setVoice failed for", voice_name)
            end
        end
    elseif chunk_lang and chunk_lang ~= self._android_tts_lang then
        local res = atts:setLanguage(chunk_lang)
        self._android_tts_lang = chunk_lang
        self._android_tts_voice = nil
        logger.dbg("TTSEngine: Android TTS language =", chunk_lang, "result:", res)
        if res and res < 0 and not self._android_lang_warned then
            -- LANG_MISSING_DATA / LANG_NOT_SUPPORTED: voice data not
            -- installed for this language in the system TTS engine.
            self._android_lang_warned = true
            logger.err("TTSEngine: Android TTS setLanguage(", chunk_lang,
                ") failed, code:", res)
            UIManager:show(InfoMessage:new{
                text = T(_("Android TTS: no voice available for %1.\nInstall the matching voice data in Android's Text-to-speech settings, or pick a different language in Voice settings."), chunk_lang),
                timeout = 8,
            })
        end
    end
    logger.dbg("TTSEngine: Android TTS pipeline for:", text:sub(1, 60))
    -- Dispatch synth-then-play pipeline.  The Java side synthesizes the
    -- WAV and starts MediaPlayer automatically, without needing a Lua
    -- round-trip between synthesis and playback.  This keeps audio going
    -- even when the Lua event loop is throttled (app backgrounded).
    local dispatch = atts:synthesizeAndPlay(text, audio_file)
    -- Right after lazy init / setLanguage the engine can still report
    -- not-ready (-1).  Brief retries beat skipping the first sentences.
    if dispatch == -1 then
        for _ = 1, 8 do
            os.execute("usleep 50000")
            dispatch = atts:synthesizeAndPlay(text, audio_file)
            if dispatch == 0 then break end
        end
    end
    local jni_ms = time.to_ms(UIManager:getTime() - jni_t0)
    if jni_ms > 300 then
        logger.warn("TTSEngine: Android TTS JNI calls blocked for", jni_ms, "ms")
    else
        logger.dbg("TTSEngine: Android TTS JNI calls took", jni_ms, "ms")
    end
    if dispatch ~= 0 then
        logger.err("TTSEngine: Android TTS pipeline dispatch failed, code:", dispatch)
        if callback then callback(false, nil) end
        return false
    end
    -- Poll for the pipeline to reach "playing" status.
    -- The synth-to-play transition happens in Java, so even if these polls
    -- are delayed (backgrounded), playback will have started on its own.
    local engine = self
    self._android_synth_gen = (self._android_synth_gen or 0) + 1
    local my_gen = self._android_synth_gen
    local poll_count = 0
    local max_polls = 120  -- 60 seconds max (120 x 0.5s)
    local function pollPipelineReady()
        -- Stale poll guard: another synthesis was dispatched
        if (engine._android_synth_gen or 0) ~= my_gen then return end
        poll_count = poll_count + 1
        local status = atts:getPipelineStatus()
        if status == 1 or status == 2 then
            -- Pipeline is playing (or already finished if Lua was slow).
            -- Get the real duration from the pipeline.
            local dur_ms = atts:getPipelineDurationMs()
            engine._android_pipeline_duration_ms = dur_ms
            engine.current_audio_file = audio_file
            engine:generateTimingEstimates(text)
            logger.dbg("TTSEngine: Android pipeline playing, duration:", dur_ms, "ms")
            if callback then
                callback(true, engine.timing_data)
            end
        elseif status == 3 then
            logger.err("TTSEngine: Android TTS pipeline error")
            if callback then callback(false, nil) end
        elseif poll_count < max_polls then
            UIManager:scheduleIn(0.5, pollPipelineReady)
        else
            logger.err("TTSEngine: Android TTS pipeline timed out after", max_polls * 0.5, "s")
            atts:stopPipeline()
            if callback then callback(false, nil) end
        end
    end
    UIManager:scheduleIn(0.3, pollPipelineReady)
    -- Return nil to signal async (same convention as Piper)
    return nil
end
--[[--
Generate timing estimates for words in text.
@param text string The text being spoken
--]]
function TTSEngine:generateTimingEstimates(text)
    self.timing_data = {}
    local current_time = 0
    local pos = 1
    local is_piper = self.backend == self.BACKENDS.PIPER
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
            local duration
            if is_piper then
                -- Neural TTS: character-length proportional estimation.
                -- Piper synthesizes at a fairly uniform rate per character,
                -- so character count gives better proportional distribution
                -- than syllable count.  These raw values are later scaled to
                -- match the real WAV duration — only the ratios matter.
                duration = math.floor(#clean_word * 80)
                -- Punctuation after a word causes Piper to insert a natural
                -- pause — model that for better within-sentence proportions.
                if word:match("[,;:]$") then
                    duration = duration + 150
                elseif word:match("[%.%?!]$") then
                    duration = duration + 200
                end
            else
                local syllables = self:countSyllables(clean_word)
                duration = math.floor((syllables * 200) / self.rate)
            end
            table.insert(self.timing_data, {
                word = word,
                start_pos = word_start,
                end_pos = pos - 1,
                start_time = current_time,
                end_time = current_time + duration,
            })
            current_time = current_time + duration + (is_piper and 30 or 50)
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
    local temp_dir = self._android_tts and self._android_tts:getTempDir() or "/tmp"
    self.file_counter = (self.file_counter or 0) + 1
    local audio_file = temp_dir .. "/audiobook_espeak_fb_" .. os.time() .. "_" .. self.file_counter .. ".wav"
    local exec_prefix = ""
    local esp_data = self:_resolveEspeakDataPath()
    if self.espeak_linker then
        local path_prefix = ""
        if self.espeak_bin_path then
            path_prefix = string.format("PATH=%s:$PATH ", self.espeak_bin_path)
        end
        exec_prefix = string.format(
            "%sLD_LIBRARY_PATH= XDG_DATA_DIRS=%s ESPEAK_DATA_PATH=%s %s --library-path %s ",
            path_prefix, esp_data, esp_data, self.espeak_linker, self.espeak_lib_path
        )
    elseif self.espeak_lib_path then
        local path_prefix = ""
        if self.espeak_bin_path then
            path_prefix = string.format("PATH=%s:$PATH ", self.espeak_bin_path)
        end
        exec_prefix = string.format(
            "%sLD_LIBRARY_PATH=%s ESPEAK_DATA_PATH=%s ",
            path_prefix, self.espeak_lib_path, esp_data
        )
    end
    local speed = math.floor(175 * (self.rate or 1.0))
    local voice = self.voice or "en"
    local cmd = string.format(
        '%s%s -v %s -s %d -a 100 -w "%s" "%s" 2>&1',
        exec_prefix, self.espeak_bin, voice, speed, audio_file, self:escapeText(text)
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
        -- Keep _native_tts_text intact: the Kindle native TTS fallback path
        -- (used when gst-play is broken on stripped GStreamer firmware) needs
        -- the sentence text.  Clearing it here causes "no text to speak".
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
function TTSEngine:prefetch(text, use_espeak)
    if not self.backend or not text or text == "" then
        return false
    end
    -- Android TTS: skip prefetch.  synthesizeAndroid() is async, but
    -- prefetch() assumes synchronous completion (save/restore of
    -- current_audio_file).  The async callback overwrites current_audio_file,
    -- then cleanup() deletes the prefetched WAV, breaking the chain.
    -- Android TTS synthesis is fast enough that prefetching isn't needed.
    if self.backend == self.BACKENDS.ANDROID then
        return false
    end
    -- Piper: delegate to the async queue-based prefetcher
    if self.backend == self.BACKENDS.PIPER and not use_espeak then
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
    local ok
    if use_espeak then
        -- espeak session fallback (Piper abandoned): pre-synthesize the
        -- next fallback sentence while the current one plays, so the chain
        -- does not stall on blocking synthesis between sentences (#49).
        local fb_file = self:espeakSynthesizeFallback(text)
        ok = fb_file ~= nil
        if ok then
            self._prefetch_file = self.current_audio_file
            self._prefetch_timing = self.timing_data
            self._prefetch_text = text
            logger.dbg("TTSEngine: Prefetched espeak fallback for:", text:sub(1, 40))
        end
    else
        ok = self:synthesizeCommand(text, function(success, timing)
            if success then
                -- Move the generated file into the prefetch slot
                self._prefetch_file = self.current_audio_file
                self._prefetch_timing = self.timing_data
                self._prefetch_text = text
                logger.dbg("TTSEngine: Prefetched audio for:", text:sub(1, 40))
            end
        end)
    end
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
-- Persistent BT pipeline retry and error handling.
-- These limit how often we retry the pipeline, prevent rapid retry loops
-- from corrupting flash storage, and detect fatal firmware errors.
local MAX_PIPELINE_RETRIES = 3
local PIPELINE_RETRY_COOLDOWN_S = 30  -- minimum seconds between retry attempts

-- MTK firmware-specific error patterns in gst-launch stderr that indicate
-- a permanent hardware/firmware issue (not a transient failure).
-- On Kobo MTK devices these errors occur when the stock OS (Nickel) has
-- not initialized the Bluetooth firmware, leaving required configuration
-- files missing or kernel FIFO channels uninitialized.
local MTK_FATAL_ERRORS = {
    "init mtx error",
    "bt_fw_fatures",
    "bt_fw_features",
    "FifoManager:initMtx",
    "init mtx error No such file or directory",
}

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

--- Show a modal error informing the user that the MTK Bluetooth firmware
-- file is missing and they need to boot into Nickel to initialize it.
-- This is shown when the pipeline fails with a fatal firmware error so
-- the user has a clear, actionable message instead of a silent failure.
function TTSEngine:_showMtkFirmwareError()
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    UIManager:show(InfoMessage:new{
        text = _(
            "Bluetooth audio pipeline failed.\n\n"
            .. "Your Kobo's Bluetooth firmware is not initialized. "
            .. "This happens when KOReader is used without first "
            .. "running the stock Kobo OS (Nickel).\n\n"
            .. "To fix this:\n"
            .. "1. Fully power off your Kobo\n"
            .. "2. Turn it on and boot normally into Nickel\n"
            .. "3. Go to Settings → Bluetooth and turn it ON\n"
            .. "4. If you have Bluetooth headphones, pair them now\n"
            .. "5. Once Bluetooth is working in Nickel, reboot into "
            .. "KOReader\n\n"
            .. "Read-along audio playback has been stopped."
        ),
        timeout = 15,
    })
    -- Also flag player_error so the sync controller / playback bar
    -- can show a persistent status indicator.
    self.player_error = "bt_firmware_missing"
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
    -- Register the TTS audio file with the session recorder, if active.
    if self.plugin and self.plugin.session_recorder and self.current_audio_file then
        local is_real_wav = self.current_audio_file ~= "/tmp/.kindle_native_tts"
            and self.current_audio_file:match("%.wav$")
        if is_real_wav then
            self.plugin.session_recorder:registerAudioFile(self.current_audio_file, "tts")
        end
    end
    -- Detect duplicate play() calls that could cause audio repeats.
    if self.is_speaking then
        logger.err("TTSEngine: DUPLICATE play() called while already speaking! gen=",
            self.play_generation, "audio=", self.current_audio_file)
    end
    logger.dbg("TTSEngine: play() called, audio_file=", self.current_audio_file,
        "is_speaking=", self.is_speaking)
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
    else
        -- Clear cache so next attempt re-probes (user may pair BT between tries)
        self._cached_player = nil
    end
    if not player then
        logger.err("TTSEngine: No audio player found")
        self.player_error = true
        local msg
        if Device:isKindle() then
            msg = _("No audio output available.\n\nKindle has no built-in speaker. Audio needs Bluetooth headphones connected via Kindle Settings.\n\nPlease generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue -- it will help identify the correct audio path for this Kindle model.")
        elseif Device:isKobo() then
            msg = _("No audio output available.\n\nKobo has no built-in speaker.\n\nPlease pair Bluetooth headphones:\nSettings → Bluetooth → Pair\n\nThen try again.")
        elseif self:isPocketBook() then
            msg = _("No audio output available.\n\nNo working audio path was found on this PocketBook.\n\nTry changing the audio device:\nAudiobook > Audio device settings > System player (InkView)\n\nIf that does not help, generate a bug report (Audiobook > Generate bug report) and share it on GitHub.")
        else
            msg = _("No audio output available.\n\nNo supported audio player found (aplay, paplay, mpv, mplayer).\n\nIf using Bluetooth, make sure headphones are paired and connected.")
        end
        UIManager:show(InfoMessage:new{
            text = msg,
            timeout = 8,
        })
        self.is_speaking = false
        -- Do NOT call on_complete here — returning false tells
        -- beginSentencePlayback to handle the error.  Calling both
        -- on_complete and returning false creates a race: the completion
        -- callback schedules readNextSentence, then beginSentencePlayback
        -- calls stop(), so the scheduled timer finds state==STOPPED.
        return false
    end
    logger.dbg("TTSEngine: Using player:", player)
    logger.dbg("TTSEngine: Audio file:", self.current_audio_file)
    logger.dbg("TTSEngine: play() findPlayer took", time.to_ms(UIManager:getTime() - t0), "ms")
    -- Block playback when no real audio output exists and no BT device is
    -- connected.  On single-core Kobos (no speaker), silently looping
    -- through aplay for every sentence wastes CPU and can crash the device.
    if self._no_real_audio_output then
        -- Kindle rescue: some firmwares need aggressive initialization
        -- before audiomgrd recognizes BT output (issue #32).
        local rescued_player = nil
        if Device:isKindle() and not self._kindle_rescue_attempted then
            self._kindle_rescue_attempted = true
            logger.warn("TTSEngine: play() attempting Kindle rescue probe")
            rescued_player = self:_kindleRescueProbe()
            if rescued_player then
                self._cached_player = rescued_player
                player = rescued_player
            end
        end

        if not rescued_player then
            local bt_connected = false
            -- Kindle does not use BlueZ; BT audio is managed by audiomgrd.
            -- Query audiomgrd directly via LIPC to detect system-level BT connections.
            if Device:isKindle() and not bt_connected then
                local h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
                if h then
                    local val = h:read("*a") or ""
                    h:close()
                    if val:match("1") then
                        bt_connected = true
                        logger.warn("TTSEngine: Kindle BT audio connected (audiomgrd)")
                    end
                end
                -- Also check audioCurrentOutput == 1 (A2DP / BT output)
                if not bt_connected then
                    local h2 = io.popen("lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>/dev/null")
                    if h2 then
                        local val2 = h2:read("*a") or ""
                        h2:close()
                        if val2:match("1") then
                            bt_connected = true
                            logger.warn("TTSEngine: Kindle BT output selected (audiomgrd)")
                        end
                    end
                end
            end
            local btm = self.plugin and self.plugin.bt_manager
            if btm and not bt_connected then
                local ok, devices = pcall(btm.listAudioDevices, btm)
                if ok and devices then
                    for _, dev in ipairs(devices) do
                        if dev.connected then
                            bt_connected = true
                            break
                        end
                    end
                end
            end
            if bt_connected then
                -- BT device appeared after initial findAudioPlayer (e.g.
                -- connected externally).  Re-probe the audio player so
                -- bluealsa can be started and used.
                logger.warn("TTSEngine: BT device connected, re-probing audio player")
                self._cached_player = nil
                self._no_real_audio_output = false
                player = self:findAudioPlayer()
                if not player then
                    logger.warn("TTSEngine: re-probe failed, no audio player found")
                    self.is_speaking = false
                    return false
                end
            else
                logger.warn("TTSEngine: No soundcard and no BT connected - refusing to play")
                self.is_speaking = false
                local msg
                if Device:isKindle() then
                    msg = _("No audio output available.\n\nKindle has no built-in speaker. Please connect Bluetooth headphones via Kindle Settings, then try again.\n\nIf you already have headphones connected, please generate a bug report (Audiobook > Generate bug report) and share it on GitHub — it will help identify the correct audio path for this Kindle model.")
                else
                    msg = _("No audio output available.\n\nThis device has no built-in speaker. Please connect a Bluetooth audio device first:\n\n1. Go to Audiobook > Bluetooth settings > Bluetooth\n2. Turn Bluetooth on\n3. Scan and pair your headphones/speaker\n4. Then start read-along again.")
                end
                UIManager:show(InfoMessage:new{
                    text = msg,
                    timeout = 10,
                })
                return false
            end
        end
    end
    -- PocketBook pre-flight: on devices with a Bluetooth adapter
    -- (PB632, PB700c), direct ALSA playback via wav-play is harmful.
    -- PB632 has no speaker; PB700c's amplifier state corrupts on any
    -- ALSA open/drain/close.  Block playback unless BT audio is connected.
    -- Devices without BT hardware (PB740, PB631) use wired audio through
    -- tts_sm successfully, so skip the check for those.
    local is_pb = self:isPocketBook()
    -- Detect BT adapter via multiple signals.  /sys/class/bluetooth/hci0
    -- only appears when the BT daemon is actively running, so it misses
    -- PB devices that ship with BT hardware while the daemon is stopped
    -- (PB700K3 reported has_bt_adapter=false even though Era-Color is a
    -- BT-equipped device, then wav-play ran into the internal speaker
    -- and damaged the amplifier).  Use any positive signal: sysfs scan
    -- across all hci* nodes, /etc/rfkill listings, or the PocketBook
    -- device.cfg "bluetooth_device_name=" entry which identifies BT
    -- hardware regardless of daemon state.
    local has_bt_adapter = false
    local bt_detect_source = "none"
    do
        for i = 0, 3 do
            local hci_f = io.open("/sys/class/bluetooth/hci" .. i .. "/address", "r")
            if hci_f then
                local addr = hci_f:read("*l") or ""
                hci_f:close()
                if #addr > 0 then
                    has_bt_adapter = true
                    bt_detect_source = "sysfs:hci" .. i
                    break
                end
            end
        end
    end
    if not has_bt_adapter then
        local cfg_f = io.open("/ebrmain/config/device.cfg", "r")
        if cfg_f then
            local content = cfg_f:read("*a") or ""
            cfg_f:close()
            if content:find("bluetooth_device_name%s*=") then
                has_bt_adapter = true
                bt_detect_source = "device.cfg"
            end
        end
    end
    if not has_bt_adapter then
        local rf_h = io.popen("rfkill list bluetooth 2>/dev/null")
        if rf_h then
            local out = rf_h:read("*a") or ""
            rf_h:close()
            if out:find("[Bb]luetooth") then
                has_bt_adapter = true
                bt_detect_source = "rfkill"
            end
        end
    end
    -- ── Kindle BT prerequisite check ─────────────────────────────────
    -- Kindles have no internal speaker; audio only routes through BT
    -- headphones via audiomgrd.  Warn once per session if BT is not
    -- connected and there are no ALSA soundcards (no built-in speaker).
    if Device:isKindle() and not self._kindle_bt_warned then
        local has_soundcard = false
        local sc = io.popen("aplay -l 2>/dev/null")
        if sc then
            local sout = sc:read("*a") or ""
            sc:close()
            -- aplay -l on Kindle with no soundcards prints:
            -- "aplay: device_list:223: no soundcards found..."
            if not sout:find("no soundcards") then
                has_soundcard = true
            end
        end
        if not has_soundcard then
            local am_h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
            local am_out = ""
            if am_h then
                am_out = am_h:read("*a") or ""
                am_h:close()
            end
            local connected = am_out:match("1")
            if not connected then
                self._kindle_bt_warned = true
                logger.warn("TTSEngine: Kindle has no soundcards and BT not connected")
                UIManager:show(InfoMessage:new{
                    text = _("No Bluetooth headphones detected.\n\nThis Kindle has no built-in speaker. Connect Bluetooth headphones in Settings → Wi-Fi & Bluetooth before playing."),
                    timeout = 8,
                })
            end
        end
    end
    -- The pre-flight blocks every direct-ALSA / InkView wav-play attempt
    -- on PocketBooks that have a BT adapter (PB632, PB700c, PB700K3).
    -- We always require an active BT audio connection on these devices,
    -- regardless of audio_player_type.  Earlier versions allowed pt =
    -- gst-bt or bluealsa to bypass the BT-connected check, but a stale
    -- selection from a previous session would let synthesis fall through
    -- with no audio device, producing silent failures (PB632 regression
    -- in v0.1.5.77).
    local pt = self.audio_player_type
    local pt_is_bt_routed = (pt == "gst-bt" or pt == "bluealsa")
    self._pb_pre_flight_state = {
        is_pb = is_pb,
        has_bt_adapter = has_bt_adapter,
        bt_detect_source = bt_detect_source,
        has_tts_sm = self._pb_has_tts_sm and true or false,
        no_real_audio = self._no_real_audio_output and true or false,
        player_type = pt or "nil",
        pt_is_bt_routed = pt_is_bt_routed,
    }
    logger.dbg("TTSEngine: PB pre-flight:",
        "is_pb=", is_pb,
        "has_bt_adapter=", has_bt_adapter,
        "bt_detect_source=", bt_detect_source,
        "has_tts_sm=", self._pb_has_tts_sm,
        "no_real_audio=", self._no_real_audio_output,
        "player_type=", pt,
        "pt_is_bt_routed=", pt_is_bt_routed)
    if is_pb and has_bt_adapter and not self._no_real_audio_output then
        local bt_connected = false
        local btm = self.plugin and self.plugin.bt_manager
        if btm then
            local ok, devices = pcall(btm.listAudioDevices, btm)
            if ok and devices then
                for _, dev in ipairs(devices) do
                    if dev.connected then bt_connected = true; break end
                end
            end
        else
            logger.warn("TTSEngine: PB pre-flight: bt_manager is nil")
        end
        if not bt_connected then
            -- Deliberate opt-in ("Allow speaker playback without Bluetooth"):
            -- daemon-routed devices (tts_sm, hwout_mix) belong to neither
            -- damage class this gate protects against (no mixer access, no
            -- direct hw:0), so the user may lift the BT requirement for
            -- those routes only.  Direct-hardware routes stay refused.
            if self.plugin and self.plugin:getSetting("pb_speaker_without_bt", false)
                    and self:_pbDaemonRouted() then
                logger.warn("TTSEngine: no BT, speaker playback allowed",
                    "for daemon-routed device (opt-in):",
                    self._wav_play_force_prefix and "sticky fallback" or self._wav_play_device)
            else
                logger.warn("TTSEngine: PocketBook with BT adapter but no BT audio - refusing to play",
                    "(player_type=", self.audio_player_type,
                    "wav_play_cmd=", self._wav_play_cmd and "set" or "nil",
                    "bt_detect_source=", bt_detect_source,
                    "no_real_audio=", self._no_real_audio_output, ")")
                self.is_speaking = false
                UIManager:show(InfoMessage:new{
                    text = _("No audio output available.\n\nOn this PocketBook, direct ALSA playback can damage the audio subsystem. Please connect Bluetooth headphones first, then try again."),
                    timeout = 10,
                })
                return false
            end
        end
        -- BT is connected but selected player type isn't BT-routed.
        -- This means audio_player_type cache is stale (e.g. user paired
        -- BT after the first sentence).  Force a re-probe so gst-bt or
        -- bluealsa is selected instead of the dangerous direct-ALSA path.
        if not pt_is_bt_routed then
            logger.warn("TTSEngine: BT connected but player_type=", pt,
                "is not BT-routed; re-probing to switch to gst-bt/bluealsa")
            self._cached_player = nil
            local new_player = self:findAudioPlayer()
            if new_player then
                player = new_player
                self._cached_player = new_player
                pt = self.audio_player_type
                logger.warn("TTSEngine: re-probe selected player_type=", pt)
            end
        end
    end
    -- === KINDLE NATIVE TTS PLAYBACK PATH ===
    -- Send text directly to Amazon's Ivona SDK via playermgr PlayParameter.
    -- Protocol discovered from VoiceView LIPC event capture:
    -- text → PlayParameter(JSON) → ttssrc → Ivona → mixersink → audiomgrd → BT
    --
    -- v0.1.5.37: Use liblipc.so FFI with a named LIPC source.  CLI tools
    -- (lipc-set-prop) use anonymous transient connections; playermgr may
    -- only trigger TTS for named sources (VoiceView uses the C API).
    if self.audio_player_type == "kindle-native-tts"
        or self.audio_player_type == "kindle-native-tts-fallback" then
        local text = self._native_tts_text
        -- Stale-cache guard: when a WAV audio file was synthesized
        -- (e.g. by Piper or espeak) but the player_type is still
        -- "kindle-native-tts" from an earlier session or backend mismatch,
        -- the native Ivona path cannot play WAVs.  Falling through to
        -- "no text to speak" loses the audio entirely.  Switch to
        -- kindle-gst-play (or kindle-lipc) if available so the WAV plays.
        -- NOTE: kindle-native-tts-fallback INTENTIONALLY uses Ivona even
        -- when a WAV exists (that's the whole point -- the WAV player is
        -- broken on stripped GStreamer firmware like PW5 / Colorsoft).
        -- kindle-ttssrc (Colorsoft) also bypasses WAV playback and uses
        -- the native Ivona voice, so treat it like a fallback path.
        local is_fallback = self.audio_player_type == "kindle-native-tts-fallback"
            or self.audio_player_type == "kindle-ttssrc"
        local is_real_wav = self.current_audio_file
            and self.current_audio_file ~= "/tmp/.kindle_native_tts"
            and self.current_audio_file:match("%.wav$")
            and not is_fallback
        if is_real_wav then
            if not self._kindle_gst_play_bin then
                local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
                local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                local gf = io.open(gst_play_bin, "r")
                if gf then
                    gf:close()
                    if self.espeak_linker then
                        self._kindle_gst_play_bin = string.format(
                            "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                            self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                    else
                        self._kindle_gst_play_bin = gst_play_bin
                    end
                end
            end
            if self._kindle_gst_play_bin then
                logger.warn("TTSEngine: kindle-native-tts cannot play WAV, switching to kindle-gst-play:", self.current_audio_file)
                self.audio_player_type = "kindle-gst-play"
                self._cached_player = nil
                self.is_speaking = false
                return self:play(on_word, on_complete, on_fail, concat_files)
            end
            -- No gst-play available -- try kindle-lipc re-probe
            logger.warn("TTSEngine: kindle-native-tts cannot play WAV and gst-play missing, clearing player cache")
            self.audio_player_type = nil
            self._cached_player = nil
            self.is_speaking = false
            return self:play(on_word, on_complete, on_fail, concat_files)
        end
        if not text or text == "" then
            logger.err("TTSEngine: Kindle native TTS -- no text to speak")
            self:onPlaybackComplete()
            return true
        end
        -- Notify once per session when using the degraded fallback.
        if is_fallback and not self._native_fallback_warned then
            self._native_fallback_warned = true
            local fallback_text
            if self._kindle_wav_playback_limited then
                local backend_name = self.backend_name or self.backend or "selected"
                fallback_text = _(
                    "Using Kindle's built-in voice.\n\n"
                    .. backend_name .. " TTS is selected, but this Kindle model "
                    .. "cannot play WAV files because GStreamer is stripped. "
                    .. "Audio will use the built-in Kindle voice instead.\n\n"
                    .. "Word highlighting may be slightly less precise with the built-in voice."
                )
            else
                fallback_text = _(
                    "Using Kindle's built-in voice.\n\n"
                    .. "Your Kindle model's audio system cannot play the selected voice "
                    .. "(espeak-ng or Piper).  Falling back to the Kindle's native "
                    .. "Ivona TTS, which works on all Kindle models.\n\n"
                    .. "Word highlighting may be slightly less precise with the built-in voice."
                )
            end
            UIManager:show(InfoMessage:new{
                text = fallback_text,
                timeout = 8,
            })
        end
        self._concat_durations = nil
        -- Duration was already estimated during synthesis
        local dur_ms = self._current_audio_duration_ms or 5000
        self._expected_play_duration_ms = dur_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 500
        logger.warn("TTSEngine: Kindle native TTS play:", text:sub(1, 60),
            "est_dur=", dur_ms, "ms")
        -- Tiered /var free space check (issue #22).
        -- /var is a 64MB tmpfs on Kindle. System daemons (audiomgrd) hold
        -- deleted files open, so rm -f cannot reclaim the space. We check
        -- frequently when approaching full, and back off when healthy.
        local do_check = false
        if not self._var_check_counter then
            self._var_check_counter = 0
        end
        self._var_check_counter = self._var_check_counter + 1
        if self._var_last_pct and self._var_last_pct >= 80 then
            do_check = true
        elseif self._var_check_counter % 5 == 0 then
            do_check = true
        end
        if do_check then
            local df_h = io.popen("df /var 2>/dev/null | tail -1")
            if df_h then
                local df_line = df_h:read("*a") or ""; df_h:close()
                local _fs, _blocks, _used, avail, pct = df_line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
                local use_pct = tonumber(pct and pct:match("(%d+)"))
                local avail_kb = tonumber(avail)
                self._var_last_pct = use_pct
                if use_pct and (use_pct >= 90 or (avail_kb and avail_kb < 5120)) then
                    logger.warn("TTSEngine: /var is", use_pct, "% full (", avail_kb, "KB free) -- running cleanup")
                    -- Aggressive cleanup of known temp file patterns.
                    os.execute("rm -f /var/tmp/audiobook_*.wav /var/tmp/audiobook_*.xml /var/tmp/audiobook_*.txt /var/tmp/audiobook_*.done /var/tmp/piper_server_* /var/tmp/.gst_play_last.log /var/tmp/.ttssrc_* /var/tmp/audiomgrd.err /var/tmp/*.tmp 2>/dev/null")
                    -- Truncate audiomgrd's deleted stderr log via /proc fd.
                    -- audiomgrd holds the file open after deletion, so rm -f
                    -- cannot reclaim the space. Truncating via /proc frees it.
                    local am_pid_h = io.popen("cat /var/run/audiomgrd.pid 2>/dev/null")
                    local am_pid = am_pid_h and am_pid_h:read("*a"):match("%d+")
                    if am_pid_h then am_pid_h:close() end
                    if am_pid then
                        os.execute(": > /proc/" .. am_pid .. "/fd/2 2>/dev/null")
                        logger.warn("TTSEngine: truncated audiomgrd stderr (pid=", am_pid, ")")
                    end
                    -- Re-check after cleanup; abort only if still critically full.
                    local df_h2 = io.popen("df /var 2>/dev/null | tail -1")
                    if df_h2 then
                        local df_line2 = df_h2:read("*a") or ""; df_h2:close()
                        local use_pct2 = tonumber(df_line2:match("(%d+)%%"))
                        self._var_last_pct = use_pct2
                        if use_pct2 and use_pct2 >= 95 then
                            logger.warn("TTSEngine: /var still", use_pct2, "% full after cleanup")
                            self._var_full = true
                            UIManager:show(InfoMessage:new{
                                text = _("/var is critically full (" .. use_pct .. "% used).\n\nThe Kindle's native TTS engine needs temporary space in /var to synthesize speech. With /var full, playback will silently fail.\n\nPlease reboot your Kindle to clear /var, then try again."),
                                timeout = 15,
                            })
                            self.is_speaking = false
                            self:onPlaybackComplete()
                            return true
                        end
                    end
                end
            end
        end
        -- Skip native TTS entirely when /var is full and gst-play is available.
        -- Ivona SDK cannot synthesize without temp space, so going through the
        -- 10s strategy+timeout loop is pointless.  Fall back immediately.
        -- IMPORTANT: if gst-play is already known to hang on this device
        -- (issue #22, PW5), do NOT try it again -- that just causes another
        -- hang and a second error dialog.  Let the native TTS path fail
        -- gracefully (the /var-full warning was already shown above).
        if self._var_full and not self._gst_play_broken then
            if not self._kindle_gst_play_bin then
                local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
                local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                local gf = io.open(gst_play_bin, "r")
                if gf then
                    gf:close()
                    if self.espeak_linker then
                        self._kindle_gst_play_bin = string.format(
                            "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                            self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                    else
                        self._kindle_gst_play_bin = gst_play_bin
                    end
                end
            end
            if self._kindle_gst_play_bin and self.current_audio_file then
                logger.warn("TTSEngine: /var full, skipping native TTS, using kindle-gst-play")
                self.audio_player_type = "kindle-gst-play"
                self._no_real_audio_output = false
                self.is_speaking = false
                self:play()
                return true
            end
        end
        -- v0.1.6.5: On Colorsoft (and other devices where kindle-gst-play
        -- --ttssrc is available), bypass playermgr entirely and use ttssrc
        -- directly.  ttssrc connects to the TTS orchestrator (Ivona SDK) and
        -- routes audio through mixersink → audiomgrd → BT, bypassing the
        -- broken playermgr Open/PlayParameter path (issue #23).
        if is_fallback and self._kindle_gst_play_bin and not self._ttssrc_broken then
            logger.warn("TTSEngine: Kindle native TTS via kindle-gst-play --ttssrc")

            local function escapeForGst(s)
                return s:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub("\n", " ")
            end
            local function shellEsc(s)
                return "'" .. s:gsub("'", "'\\''") .. "'"
            end
            local escaped_text = escapeForGst(text)

            local done_file = "/tmp/.ttssrc_done_" .. my_gen
            local gst_log = "/tmp/.ttssrc_fallback.log"
            os.remove(done_file)

            -- Simplified subshell: single background job writes exit code on
            -- completion.  Avoids the complex double-background pattern that
            -- may confuse minimal busybox shells (issue #35).
            -- If libIvonaEInkAPI.so.1.0 was found at a non-default path on a
            -- previous attempt, prepend it to LD_LIBRARY_PATH so GStreamer can
            -- load the ttssrc plugin successfully (PW5/PW6 firmware).
            local ivona_env = ""
            if self._ttssrc_ivona_lib_path then
                ivona_env = "LD_LIBRARY_PATH=" .. self._ttssrc_ivona_lib_path .. ":$LD_LIBRARY_PATH "
                logger.warn("TTSEngine: kindle-gst-play --ttssrc using LD_LIBRARY_PATH=", self._ttssrc_ivona_lib_path)
            end
            local cmd = string.format(
                "(%s%s --ttssrc %s >%s 2>&1; echo $? > %s) & echo $!",
                ivona_env, self._kindle_gst_play_bin, shellEsc(escaped_text), gst_log,
                done_file)
            local h = io.popen(cmd)
            local pid_str = h and h:read("*a") or ""
            if h then h:close() end
            local pid = tonumber(pid_str:match("(%d+)"))
            logger.warn("TTSEngine: kindle-gst-play --ttssrc launched, PID=", pid)

            self._audio_launched_at = UIManager:getTime()
            self:startTimingLoop()

            local engine = self
            local poll_count = 0
            local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
            local startup_polls = 15
            local has_retried = false
            local function pollTtsSrcDone()
                if (engine.play_generation or 0) ~= my_gen then return end
                if not engine.is_speaking then return end
                if engine.is_paused then
                    UIManager:scheduleIn(0.3, pollTtsSrcDone)
                    return
                end
                poll_count = poll_count + 1

                -- Detect completion: process gone from /proc OR done file exists.
                local proc_exists = pid and io.open("/proc/" .. pid .. "/status", "r")
                if proc_exists then proc_exists:close() end

                local done_ready = not proc_exists
                if not done_ready and poll_count > startup_polls then
                    local df = io.open(done_file, "r")
                    if df then
                        local rc = df:read("*a") or ""
                        df:close()
                        if rc:match("%d") then done_ready = true end
                    end
                end

                if done_ready then
                    local exit_code = 1
                    local df = io.open(done_file, "r")
                    if df then
                        local rc = df:read("*a") or ""
                        df:close()
                        os.remove(done_file)
                        exit_code = tonumber(rc:match("(%d+)")) or 1
                    end

                    if exit_code == 0 then
                        logger.warn("TTSEngine: kindle-gst-play --ttssrc completed")
                        engine._ttssrc_consec_fails = 0
                        engine:onPlaybackComplete()
                        return
                    end

                    logger.err("TTSEngine: kindle-gst-play --ttssrc failed, code=", exit_code)

                    -- Retry once without the bundled linker wrapper on
                    -- 126/127.  Some Kindles (e.g. KT5) cannot execute the
                    -- binary through the bundled ld-linux-armhf.so.3 but the
                    -- system linker works fine (issue #35).
                    if (exit_code == 126 or exit_code == 127) and not has_retried then
                        local bare_bin = engine._kindle_gst_play_bin:match("(/%S-/gst%-play)$")
                            or engine._kindle_gst_play_bin
                        if bare_bin ~= engine._kindle_gst_play_bin then
                            has_retried = true
                            engine:_diagnoseGstPlayFailure(engine._kindle_gst_play_bin, gst_log)
                            logger.warn("TTSEngine: retrying --ttssrc with bare binary:", bare_bin)
                            os.remove(done_file)
                            local retry_cmd = string.format(
                                "('%s' --ttssrc %s >%s 2>&1; echo $? > %s) & echo $!",
                                bare_bin, shellEsc(escaped_text), gst_log,
                                done_file)
                            local retry_h = io.popen(retry_cmd)
                            local retry_pid_str = retry_h and retry_h:read("*a") or ""
                            if retry_h then retry_h:close() end
                            pid = tonumber(retry_pid_str:match("(%d+)"))
                            poll_count = 0
                            logger.warn("TTSEngine: retry PID=", pid)
                            UIManager:scheduleIn(0.1, pollTtsSrcDone)
                            return
                        end
                    end

                    -- Log stderr for diagnostics
                    local log_fh = io.open(gst_log, "r")
                    local log_text = ""
                    if log_fh then
                        log_text = log_fh:read("*a") or ""
                        log_fh:close()
                        if log_text ~= "" then
                            logger.warn("TTSEngine: --ttssrc stderr:", log_text:sub(1, 500))
                        end
                    end

                    -- KT5 firmware omits libIvonaEInkAPI.so.1.0, so ttssrc loads
                    -- in --probe but real pipelines fail.  On PW5/PW6 the library
                    -- exists at /usr/lib/tts/ but that path is not in the default
                    -- LD_LIBRARY_PATH so GStreamer cannot find it at plugin load time.
                    -- Check before giving up: if the library is present on disk we
                    -- can retry with LD_LIBRARY_PATH set; only mark broken if it is
                    -- genuinely absent.
                    if log_text:match("libIvonaEInkAPI%.so%.1%.0") then
                        local ivona_lib = "/usr/lib/tts/libIvonaEInkAPI.so.1.0"
                        local ivona_f = io.open(ivona_lib, "r")
                        if ivona_f then
                            ivona_f:close()
                            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 found at /usr/lib/tts but not on LD_LIBRARY_PATH; will retry with path set")
                            engine._ttssrc_ivona_lib_path = "/usr/lib/tts"
                            -- do NOT mark broken -- next launch will use the path
                        else
                            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 genuinely absent; disabling ttssrc")
                            engine._ttssrc_broken = true
                            if engine.plugin then
                                engine.plugin:setSetting("_ttssrc_broken", true)
                                logger.warn("TTSEngine: persisted _ttssrc_broken=true")
                            end
                        end
                    end

                    -- Exit codes 126/127 mean the binary is not executable or
                    -- not found.  Disable permanently after diagnostics.
                    if exit_code == 126 or exit_code == 127 then
                        logger.warn("TTSEngine: --ttssrc binary not executable (code ", exit_code, "), disabling permanently")
                        engine:_diagnoseGstPlayFailure(engine._kindle_gst_play_bin, gst_log)
                        engine._kindle_gst_play_bin = nil
                        engine._ttssrc_broken = true
                        if engine.plugin then
                            engine.plugin:setSetting("_ttssrc_broken", true)
                            logger.warn("TTSEngine: persisted _ttssrc_broken=true")
                        end
                        engine.is_speaking = false
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        UIManager:show(InfoMessage:new{
                            text = _("Kindle native TTS failed.\n\nThe text-to-speech helper binary could not be executed. Please generate a bug report and share it on GitHub."),
                            timeout = 10,
                        })
                        return
                    end
                    engine._ttssrc_consec_fails = (engine._ttssrc_consec_fails or 0) + 1
                    if engine._ttssrc_consec_fails >= 2 then
                        engine._kindle_gst_play_bin = nil
                        engine.is_speaking = false
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        UIManager:show(InfoMessage:new{
                            text = _("Kindle native TTS failed.\n\nThe text-to-speech engine could not produce audio. Please generate a bug report and share it on GitHub."),
                            timeout = 10,
                        })
                        return
                    end
                    engine:onPlaybackComplete()
                    return
                end

                if poll_count >= max_polls then
                    logger.warn("TTSEngine: kindle-gst-play --ttssrc timed out")
                    if pid then
                        os.execute("kill " .. pid .. " 2>/dev/null")
                    end
                    os.remove(done_file)
                    engine:onPlaybackComplete()
                else
                    UIManager:scheduleIn(0.1, pollTtsSrcDone)
                end
            end
            UIManager:scheduleIn(0.1, pollTtsSrcDone)
            return true
        end

        -- JSON-escape the text for the PlayParameter payload
        local json_text = text:gsub('\\', '\\\\'):gsub('"', '\\"')
                              :gsub('\n', '\\n'):gsub('\r', '\\r'):gsub('\t', '\\t')
        -- Build VoiceView-compatible PlayParameter payload
        local payload = '{"type":"TTS","data":{"paramName":"textsource","paramValue":"'
            .. json_text .. '"}}'
        -- --- LIPC FFI helpers (persistent named connection) ---
        -- Lazy-load liblipc.so on first use
        if _lipc_lib == nil then
            _lipc_lib = false  -- mark as attempted
            local ok, lib = pcall(ffi.load, "lipc")
            if ok then _lipc_lib = lib; logger.warn("TTSEngine: loaded liblipc.so via FFI") end
        end
        -- Get or create a persistent named LIPC handle
        local lipc_h = self._lipc_handle
        if not lipc_h and _lipc_lib then
            local open_ok, open_err = pcall(function()
                local code = ffi.new("int[1]")
                local h = _lipc_lib.LipcOpenEx("com.lab126.koreader.tts", code)
                if h ~= nil and code[0] == 0 then
                    self._lipc_handle = h
                    lipc_h = h
                    logger.warn("TTSEngine: opened named LIPC connection (com.lab126.koreader.tts)")
                else
                    logger.warn("TTSEngine: LipcOpenEx failed, code=", code[0], ", trying anonymous")
                    h = _lipc_lib.LipcOpenNoName(code)
                    if h ~= nil and code[0] == 0 then
                        self._lipc_handle = h
                        lipc_h = h
                        logger.warn("TTSEngine: opened anonymous LIPC connection")
                    else
                        logger.warn("TTSEngine: LipcOpenNoName also failed, code=", code[0])
                    end
                end
            end)
            if not open_ok then
                logger.warn("TTSEngine: LIPC FFI open crashed:", open_err, "-- disabling FFI")
                _lipc_lib = false
            end
        end
        local function ffiSetProp(service, prop, value)
            if lipc_h and _lipc_lib then
                local ok, rc = pcall(_lipc_lib.LipcSetStringProperty, lipc_h, service, prop, value)
                if ok then return rc end
                logger.warn("TTSEngine: LIPC FFI set crashed:", rc)
                return nil
            end
            return nil  -- signal: use shell fallback
        end
        local function ffiGetInt(service, prop)
            if lipc_h and _lipc_lib then
                local ok, result = pcall(function()
                    local val = ffi.new("int[1]")
                    local rc = _lipc_lib.LipcGetIntProperty(lipc_h, service, prop, val)
                    if rc == 0 then return val[0] end
                    return nil
                end)
                if ok then return result end
                logger.warn("TTSEngine: LIPC FFI get crashed:", result)
            end
            return nil  -- signal: use shell fallback
        end
        local function getTtsState()
            local st = ffiGetInt("com.lab126.playermgr", "TTS_State")
            if st ~= nil then return st end
            -- Shell fallback
            local h = io.popen("lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null")
            if h then
                local val = h:read("*a") or ""; h:close()
                return tonumber(val:match("(%d+)")) or 0
            end
            return 0
        end
        -- Stop previous playback + request audio focus
        if ffiSetProp("com.lab126.playermgr", "Stop", "") == nil then
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        end
        if ffiSetProp("com.lab126.audiomgrd", "setFocus", "tts") == nil then
            os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")
        end
        -- Strategy A: PlayParameter only (VoiceView's steady-state protocol).
        -- For kindle-native-tts-fallback (used on PW5/Colorsoft where WAV
        -- players are broken), skip the minimal Strategy A and go straight to
        -- the full Open+PlayParameter+Play sequence.  Some newer Kindle
        -- firmware (Colorsoft) ignores PlayParameter alone and needs an
        -- explicit Open + Play handshake (issue #23).
        local using_ffi = lipc_h ~= nil
        local tts_state = 0
        if not is_fallback then
            logger.warn("TTSEngine: Kindle native TTS strategy A: PlayParameter",
                using_ffi and "(FFI)" or "(shell)")
            if using_ffi then
                ffiSetProp("com.lab126.playermgr", "PlayParameter", payload)
            else
                -- Shell-safe single-quote escaping (only ' needs escaping in '...')
                local function shellEsc(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
                local function lipc_cmd(cmd)
                    local h = io.popen(cmd .. " 2>&1")
                    local out = ""
                    if h then out = h:read("*a") or ""; h:close() end
                    return out
                end
                lipc_cmd("lipc-set-prop com.lab126.playermgr PlayParameter " .. shellEsc(payload))
            end
            tts_state = getTtsState()
        end
        -- Strategy B: Open TTS session + PlayParameter + Play (shell)
        if tts_state == 0 and not using_ffi then
            local function shellEsc(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
            local function lipc_cmd(cmd)
                local h = io.popen(cmd .. " 2>&1")
                local out = ""
                if h then out = h:read("*a") or ""; h:close() end
                return out
            end
            logger.warn("TTSEngine: Kindle native TTS strategy B: Open+PlayParam+Play (shell)")
            lipc_cmd("lipc-set-prop com.lab126.playermgr Open " ..
                shellEsc('{"type":"TTS"}'))
            lipc_cmd("lipc-set-prop com.lab126.playermgr PlayParameter " ..
                shellEsc(payload))
            lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
            tts_state = getTtsState()
        end
        -- Strategy C (FFI): Open + PlayParameter + Play via FFI
        if tts_state == 0 and using_ffi then
            logger.warn("TTSEngine: Kindle native TTS strategy C: Open+PlayParam+Play (FFI)")
            ffiSetProp("com.lab126.playermgr", "Open", '{"type":"TTS"}')
            ffiSetProp("com.lab126.playermgr", "PlayParameter", payload)
            ffiSetProp("com.lab126.playermgr", "Play", "")
            tts_state = getTtsState()
        end
        logger.warn("TTSEngine: Kindle native TTS after strategies, TTS_State=", tts_state,
            using_ffi and "(FFI)" or "(shell)")
        self._audio_launched_at = UIManager:getTime()
        self:startTimingLoop()
        -- Poll TTS_State for completion
        local engine = self
        local poll_count = 0
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        local startup_polls = 15  -- 1.5s for native TTS to start
        local ever_speaking = false
        local function pollNativeTtsDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollNativeTtsDone)
                return
            end
            poll_count = poll_count + 1
            if poll_count > startup_polls then
                local state = getTtsState()
                if state > 0 then
                    ever_speaking = true
                elseif state == 0 and ever_speaking then
                    -- Was speaking, now done
                    logger.warn("TTSEngine: Kindle native TTS complete, polls=", poll_count)
                    engine._lipc_consec_fails = 0
                    engine:onPlaybackComplete()
                    return
                elseif state == 0 and not ever_speaking then
                    local elapsed_ms = 0
                    if engine._audio_launched_at then
                        elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                            - (engine._total_pause_ms or 0)
                    end
                    if elapsed_ms > 5000 then
                        -- Never started after 5s
                        engine._lipc_consec_fails = (engine._lipc_consec_fails or 0) + 1
                        logger.err("TTSEngine: Kindle native TTS never started, elapsed=",
                            elapsed_ms, "ms, fails=", engine._lipc_consec_fails)
                        -- Try falling back to kindle-gst-play on the first
                        -- failure.  Some Kindle devices have the Ivona SDK
                        -- service running (orchestratorStarted=1) but the
                        -- playermgr never transitions TTS_State out of 0.
                        -- Waiting for a second failure wastes ~10s of silence.
                        -- Issue #18.
                        if not engine._kindle_gst_play_bin and not engine._ttssrc_broken then
                            local plugin_dir = engine.plugin_dir or "."
                            local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                            local gf = io.open(gst_play_bin, "r")
                            if gf then
                                gf:close()
                                if engine.espeak_linker then
                                    engine._kindle_gst_play_bin = string.format(
                                        "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                                        engine.espeak_linker, engine.espeak_lib_path, gst_play_bin)
                                else
                                    engine._kindle_gst_play_bin = gst_play_bin
                                end
                            end
                        end
                        -- Do NOT fall back to gst-play WAV mode if ttssrc is
                        -- available (it is more reliable than WAV on stripped
                        -- GStreamer firmware) or if gst-play is known broken.
                        local use_ttssrc = engine._ttssrc_available
                        if not use_ttssrc and not engine._gst_play_broken
                            and engine._kindle_gst_play_bin and engine.current_audio_file then
                            logger.warn("TTSEngine: native TTS failed, falling back to kindle-gst-play (issue #18)")
                            engine.audio_player_type = "kindle-gst-play"
                            engine._no_real_audio_output = false
                            -- Replay the current audio file via gst-play
                            engine.is_speaking = false
                            engine:play()
                            return
                        end
                        -- v0.1.9.7: On Colorsoft (and any device where ttssrc
                        -- is available), playermgr may be non-functional.
                        -- Fall back to kindle-ttssrc which bypasses playermgr
                        -- entirely (issue #23).
                        if use_ttssrc and engine._kindle_gst_play_bin
                            and not engine._ttssrc_broken then
                            logger.warn("TTSEngine: native TTS failed, falling back to kindle-ttssrc (issue #23)")
                            engine.audio_player_type = "kindle-ttssrc"
                            engine._no_real_audio_output = false
                            engine.is_speaking = false
                            engine:play()
                            return
                        end
                        if engine._lipc_consec_fails >= 2 then
                            engine.is_speaking = false
                            engine.play_generation = (engine.play_generation or 0) + 1
                            engine:cleanup()
                            UIManager:show(InfoMessage:new{
                                text = _("Kindle native TTS failed.\n\nThe device has a TTS engine (Ivona SDK) but playback could not be triggered via any strategy (FFI and shell).\n\nPlease generate a bug report and share it on GitHub."),
                                timeout = 10,
                            })
                            return
                        end
                        engine:onPlaybackComplete()
                        return
                    end
                end
            end
            if poll_count >= max_polls then
                logger.warn("TTSEngine: Kindle native TTS timed out after",
                    poll_count * 0.1, "s")
                ffiSetProp("com.lab126.playermgr", "Stop", "")
                os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollNativeTtsDone)
            end
        end
        UIManager:scheduleIn(0.1, pollNativeTtsDone)
        return true
    end

    -- === KINDLE TTSSRC PATH (Colorsoft, issue #23) ===
    -- When playermgr is non-functional (Colorsoft firmware 5.18.x),
    -- bypass it entirely and feed text directly to the ttssrc GStreamer
    -- element.  ttssrc → Ivona SDK → mixersink → audiomgrd → BT.
    -- This reuses the gst-play helper with --ttssrc flag.
    if self.audio_player_type == "kindle-ttssrc" then
        local text = self._native_tts_text
        if not text or text == "" then
            logger.err("TTSEngine: kindle-ttssrc -- no text to speak")
            self:onPlaybackComplete()
            return true
        end
        self._concat_durations = nil
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        local dur_ms = self._current_audio_duration_ms or 5000
        self._expected_play_duration_ms = dur_ms
        self.playback_latency_ms = 300
        logger.warn("TTSEngine: kindle-ttssrc:", text:sub(1, 60),
            "est_dur=", dur_ms, "ms")
        -- Request audio focus
        os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")
        -- Shell-safe single-quote escaping
        local function shellEsc(s) return "'" .. s:gsub("'", "'\\''") .. "'" end
        local gst_log = "/tmp/.gst_play_last.log"
        -- If libIvonaEInkAPI.so.1.0 was found at a non-default path, prepend it
        -- to LD_LIBRARY_PATH so GStreamer can load ttssrc (PW5/PW6 firmware).
        local ivona_env = ""
        if self._ttssrc_ivona_lib_path then
            ivona_env = "LD_LIBRARY_PATH=" .. self._ttssrc_ivona_lib_path .. ":$LD_LIBRARY_PATH "
            logger.warn("TTSEngine: kindle-ttssrc using LD_LIBRARY_PATH=", self._ttssrc_ivona_lib_path)
        end
        local cmd = string.format(
            '%s%s --ttssrc %s >%s 2>&1 & echo $!',
            ivona_env, self._kindle_gst_play_bin, shellEsc(text), gst_log)
        local h = io.popen(cmd)
        local pid_str = h and h:read("*a") or ""
        if h then h:close() end
        local pid = tonumber(pid_str:match("(%d+)"))
        self._gst_play_pid = pid
        logger.warn("TTSEngine: kindle-ttssrc launched, PID=", pid)
        self._audio_launched_at = UIManager:getTime()
        self:startTimingLoop()
        -- Poll /proc/<pid> for process completion (same as kindle-gst-play)
        local engine = self
        local poll_count = 0
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        local function pollTtsSrcDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollTtsSrcDone)
                return
            end
            poll_count = poll_count + 1
            local proc_fh = pid and io.open("/proc/" .. pid .. "/status", "r")
            if proc_fh then
                proc_fh:close()
                if poll_count >= max_polls then
                    logger.warn("TTSEngine: kindle-ttssrc timed out after",
                        poll_count * 0.1, "s -- killing")
                    os.execute("kill " .. pid .. " 2>/dev/null")
                    engine._gst_play_pid = nil
                    engine:onPlaybackComplete()
                else
                    UIManager:scheduleIn(0.1, pollTtsSrcDone)
                end
            else
                local log_text = ""
                local log_fh = io.open("/tmp/.gst_play_last.log", "r")
                if log_fh then
                    log_text = log_fh:read("*a") or ""
                    log_fh:close()
                    if log_text ~= "" then
                        logger.warn("TTSEngine: kindle-ttssrc stderr:", log_text:sub(1, 500))
                    end
                end
                local has_error = log_text:match("Failed to load plugin")
                    or log_text:match("undefined symbol")
                    or log_text:match("gst%-play: ttssrc element not found")
                    or log_text:match("gst%-play: ttssrc pipeline creation failed")
                    or log_text:match("gst%-play: cannot load libgstreamer")
                    or log_text:match("gst%-play: GStreamer error:")
                if has_error then
                    logger.err("TTSEngine: kindle-ttssrc exited with error")
                    engine._gst_play_pid = nil
                    engine.is_speaking = false
                    engine.play_generation = (engine.play_generation or 0) + 1
                    engine:cleanup()
                    engine._ttssrc_broken = true
                    if engine.plugin then
                        engine.plugin:setSetting("_ttssrc_broken", true)
                    end
                    UIManager:show(InfoMessage:new{
                        text = _("Audio playback failed on this Kindle model.\n\nThe ttssrc TTS pipeline could not start. Please generate a bug report and share it on the GitHub issue."),
                        timeout = 10,
                    })
                    if engine.on_fail_callback then
                        engine.on_fail_callback()
                    end
                    return
                end
                logger.warn("TTSEngine: kindle-ttssrc finished, polls=", poll_count)
                engine._gst_play_pid = nil
                engine:onPlaybackComplete()
            end
        end
        UIManager:scheduleIn(0.2, pollTtsSrcDone)
        return true
    end

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
    -- === ANDROID MEDIAPLAYER PATH ===
    -- Audio is already playing via the synthesizeAndPlay pipeline.
    -- We just need to set up word-timing and poll for completion.
    if self.audio_player_type == "android" then
        local atts = self._android_tts or self:_ensureAndroidTts()
        if not atts then
            logger.err("TTSEngine: Android TTS helper not available for playback")
            self.is_speaking = false
            return false
        end
        self._concat_durations = nil
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 0
        -- Use the pipeline's real duration for timing; fall back to WAV estimate
        local dur_ms = self._android_pipeline_duration_ms
            or self._current_audio_duration_ms or 5000
        self._expected_play_duration_ms = dur_ms
        self._android_pipeline_duration_ms = nil
        -- Consumed by the sentence controller to replay a cut sentence.
        self._android_early_death = nil
        -- Check if playback already finished (Lua was slow to call play())
        local pipeline_status = atts:getPipelineStatus()
        if pipeline_status == 2 or pipeline_status == 3 then
            logger.dbg("TTSEngine: Android pipeline already done (status=", pipeline_status, ")")
            self._audio_launched_at = UIManager:getTime()
            self:onPlaybackComplete()
            return true
        end
        self._audio_launched_at = UIManager:getTime()
        logger.dbg("TTSEngine: Android pipeline playback in progress, duration:", dur_ms, "ms")
        -- Start timing loop for word highlighting
        self:startTimingLoop()
        -- Poll for pipeline completion
        local engine = self
        local poll_count = 0
        local played_ms = 0  -- accumulated on unpaused polls only
        local pcm_active = engine:_androidPcmActive()
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        local function pollPipelineDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollPipelineDone)
                return
            end
            poll_count = poll_count + 1
            played_ms = played_ms + 100  -- 0.1 s poll cadence
            local status = atts:getPipelineStatus()
            if status == 1 and played_ms > dur_ms + 1500 and not pcm_active then
                -- Stall signature from issue #44: the clip should have
                -- finished long ago but no completion ever arrives (the
                -- HAL tore down the MediaPlayer track mid-sentence).
                -- Switch to the persistent PCM stream for the rest of the
                -- session and flag the sentence for a replay: the audio
                -- died with the track, not just its tail.
                logger.warn("TTSEngine: Android playback stalled", played_ms,
                    "ms into a", dur_ms, "ms clip with no completion; switching to PCM stream playback for this session (issue #44)")
                engine._android_pcm_auto = true
                engine._android_early_death = true
                atts:setPcmMode(true)
                atts:stopPipeline()
                engine:onPlaybackComplete()
                return
            end
            if (status == 2 or status == 3) and not pcm_active
                and played_ms >= 100 and played_ms < dur_ms - 800 then
                -- Mid-clip teardown signature from issue #44: the pipeline
                -- reported completion (or an error) far before the WAV
                -- duration, so the MTK HAL killed the MediaPlayer track.
                -- Switch to the persistent PCM stream for the rest of the
                -- session and flag the sentence for a replay.
                logger.warn("TTSEngine: Android clip cut short at", played_ms,
                    "ms of", dur_ms, "ms; switching to PCM stream playback for this session (issue #44)")
                engine._android_pcm_auto = true
                engine._android_early_death = true
                atts:setPcmMode(true)
                atts:stopPipeline()
                engine:onPlaybackComplete()
                return
            end
            if status == 2 then
                logger.dbg("TTSEngine: Android pipeline complete")
                engine:onPlaybackComplete()
            elseif status == 3 then
                logger.warn("TTSEngine: Android pipeline error during playback")
                engine:onPlaybackComplete()
            elseif poll_count >= max_polls then
                logger.warn("TTSEngine: Android pipeline timed out after",
                    poll_count * 0.1, "s, forcing completion")
                atts:stopPipeline()
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollPipelineDone)
            end
        end
        UIManager:scheduleIn(0.1, pollPipelineDone)
        return true
    end
    -- === KINDLE LIPC PLAYBACK PATH ===
    -- Use Amazon's playermgr LIPC service (GStreamer-based) to play WAV
    -- files through the Kindle audio stack → audiomgrd → BT headphones.
    if self.audio_player_type == "kindle-lipc" then
        self._concat_durations = nil
        self._expected_play_duration_ms = self._current_audio_duration_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 300  -- LIPC + GStreamer startup
        logger.warn("TTSEngine: Kindle LIPC play:", self.current_audio_file,
            "dur=", self._expected_play_duration_ms, "ms")
        -- Verify the WAV file exists and log its size (helps debug smoke test)
        local file_path = self.current_audio_file
        local fh = io.open(file_path, "rb")
        if fh then
            local size = fh:seek("end")
            fh:close()
            logger.warn("TTSEngine: Kindle LIPC wav_size=", size, "bytes")
        else
            logger.err("TTSEngine: Kindle LIPC WAV file does not exist:", file_path)
        end
        -- Stop any previous playback first
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        -- Request audio focus from audiomgrd.  playermgr may refuse to
        -- play unless its client has audio focus granted by the system
        -- mixer.  The setFocus property takes a client name string.
        os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null")
        -- Enable GStreamer debug logging so errors appear in crash.log
        -- (gstLogLevel: 0=none, 1=error, 2=warning, 3=info, 4=debug)
        os.execute("lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>/dev/null")
        -- playermgr uses GStreamer internally, which handles WAV decoding.
        -- Use io.popen to capture output for diagnostics.
        local file_uri = "file://" .. file_path
        -- Strategy 1: Open with file:// URI + Play (GStreamer prefers URIs)
        local function lipc_cmd(cmd)
            local h = io.popen(cmd .. " 2>&1")
            local out = ""
            if h then out = h:read("*a") or ""; h:close() end
            return out
        end
        logger.warn("TTSEngine: Kindle LIPC trying URI:", file_uri)
        local open_out = lipc_cmd(string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_uri))
        local play_out = lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
        logger.warn("TTSEngine: Kindle LIPC Open(URI):", open_out, "Play:", play_out)
        -- Check if playback started
        local in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
        local started = in_play:match("^%s*(%d+)") == "1"
        logger.warn("TTSEngine: Kindle LIPC InPlayback after URI:", in_play)
        -- Strategy 2: Open with bare path + Play
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying bare path:", file_path)
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            open_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Open '%s'", file_path))
            play_out = lipc_cmd("lipc-set-prop com.lab126.playermgr Play ''")
            logger.warn("TTSEngine: Kindle LIPC Open(path):", open_out, "Play:", play_out)
            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after path:", in_play)
        end
        -- Strategy 3: Play with URI directly (no Open)
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying Play(URI) directly")
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            play_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Play '%s'", file_uri))
            logger.warn("TTSEngine: Kindle LIPC Play(URI):", play_out)
            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after Play(URI):", in_play)
        end
        -- Strategy 4: Play with bare path directly (no Open)
        if not started then
            logger.warn("TTSEngine: Kindle LIPC trying Play(path) directly")
            os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
            play_out = lipc_cmd(string.format(
                "lipc-set-prop com.lab126.playermgr Play '%s'", file_path))
            logger.warn("TTSEngine: Kindle LIPC Play(path):", play_out)
            in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
            started = in_play:match("^%s*(%d+)") == "1"
            logger.warn("TTSEngine: Kindle LIPC InPlayback after Play(path):", in_play)
        end
        if not started then
            logger.warn("TTSEngine: Kindle LIPC — none of 4 strategies got InPlayback=1")
            -- Diagnose: check if audiomgrd denied the focus request.
            local focus_out = lipc_cmd("lipc-get-prop com.lab126.audiomgrd getFocus 2>/dev/null")
            logger.warn("TTSEngine: Kindle LIPC audiomgrd focus:", focus_out)
            -- None of the 4 strategies worked.  This is an immediate failure:
            -- there is no point starting the polling loop because InPlayback
            -- will never become 1.  Treat as consecutive failure so we show an
            -- error after 2 attempts instead of silently advancing sentences.
            self._lipc_consec_fails = (self._lipc_consec_fails or 0) + 1
            if self._lipc_consec_fails >= 2 then
                -- Try auto-fallback to kindle-gst-play once
                if self._kindle_gst_play_bin and not self._lipc_gst_fallback_tried then
                    self._lipc_gst_fallback_tried = true
                    logger.warn("TTSEngine: kindle-lipc failed twice (no InPlayback), falling back to kindle-gst-play")
                    self.audio_player_type = "kindle-gst-play"
                    self._cached_player = nil
                    self._no_real_audio_output = false
                    self._lipc_consec_fails = 0
                    self.is_speaking = false
                    self:play(self.on_word_callback, self.on_complete_callback,
                        self.on_fail_callback, concat_files)
                    return true
                end
                self.is_speaking = false
                self.play_generation = (self.play_generation or 0) + 1
                self:cleanup()
                local msg = _("Kindle audio playback failed.\n\nThe playermgr service accepted commands but audio never started.\n\nPossible causes:\n1. GStreamer cannot find the wavparse plugin on this firmware\n2. audiomgrd denied audio focus to the plugin\n3. No audio sink is configured (built-in speaker absent, BT not connected)\n\nTry: Connect Bluetooth headphones via Kindle Settings first, then start read-along.\n\nIf this persists, please generate a bug report (Audiobook > Generate bug report) and share it on GitHub.")
                -- If we have kindle-gst-play available, suggest falling back
                if self._kindle_gst_play_bin then
                    msg = msg .. "\n\nAlternatively, try switching to 'gst-play' audio player in Audiobook settings (if available)."
                end
                UIManager:show(InfoMessage:new{
                    text = msg,
                    timeout = 10,
                })
                if self.on_fail_callback then
                    self.on_fail_callback()
                end
                return true  -- return true so play() doesn't continue to polling
            end
            -- First failure: advance to next sentence (may work on next call
            -- if the state machine was in a transient state)
            self:onPlaybackComplete()
            return true
        else
            -- At least one strategy worked -- reset consecutive failure counter
            self._lipc_consec_fails = 0
        end
        self._audio_launched_at = UIManager:getTime()
        -- Start timing loop for word highlighting
        self:startTimingLoop()
        -- Poll InPlayback property for completion detection.
        -- Also use a safety timeout based on WAV duration.
        local engine = self
        local poll_count = 0
        local dur_ms = self._expected_play_duration_ms or 5000
        -- Max polls: at least 300 (30s) or 3x expected duration at 100ms interval
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        -- Allow a brief startup period before checking InPlayback
        local startup_polls = 5  -- 500ms for LIPC + GStreamer to open file
        local ever_playing = false  -- track if InPlayback was ever 1
        local function pollLipcDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollLipcDone)
                return
            end
            poll_count = poll_count + 1
            -- Check InPlayback: 1 = playing, 0 = idle/completed/failed
            if poll_count > startup_polls then
                local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
                if h then
                    local val = h:read("*a") or ""
                    h:close()
                    val = val:match("(%d+)")
                    if val and tonumber(val) == 1 then
                        ever_playing = true
                    elseif val and tonumber(val) == 0 then
                        local elapsed_ms = 0
                        if engine._audio_launched_at then
                            elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                                - (engine._total_pause_ms or 0)
                        end
                        if ever_playing then
                            -- Was playing, now stopped → playback completed normally
                            logger.warn("TTSEngine: Kindle LIPC playback complete, elapsed=",
                                elapsed_ms, "ms")
                            engine._lipc_consec_fails = 0
                            engine:onPlaybackComplete()
                            return
                        elseif elapsed_ms > 3000 then
                            -- Never started playing after 3 seconds → failure
                            engine._lipc_consec_fails = (engine._lipc_consec_fails or 0) + 1
                            logger.err("TTSEngine: Kindle LIPC playback never started, elapsed=",
                                elapsed_ms, "ms, consec_fails=", engine._lipc_consec_fails)
                            if engine._lipc_consec_fails >= 2 then
                                -- 2 consecutive failures.  Try auto-fallback to
                                -- kindle-gst-play once (issue #2 / #22: PW4/PW5 where
                                -- playermgr accepts commands but has no audio sink).
                                if engine._kindle_gst_play_bin and not engine._lipc_gst_fallback_tried then
                                    engine._lipc_gst_fallback_tried = true
                                    logger.warn("TTSEngine: kindle-lipc failed twice, falling back to kindle-gst-play")
                                    engine.audio_player_type = "kindle-gst-play"
                                    engine._cached_player = nil
                                    engine._no_real_audio_output = false
                                    engine._lipc_consec_fails = 0
                                    engine.is_speaking = false
                                    -- Replay current audio via gst-play
                                    engine:play(engine.on_word_callback, engine.on_complete_callback,
                                        engine.on_fail_callback, concat_files)
                                    return
                                end
                                -- Stop after 2 consecutive failures
                                engine.is_speaking = false
                                engine.play_generation = (engine.play_generation or 0) + 1
                                engine:cleanup()
                                local msg
                                if engine._no_real_audio_output then
                                    msg = _("Kindle audio playback failed.\n\nThis Kindle model's GStreamer installation cannot decode audio files (no wavparse plugin). Audio may work if:\n\n1. You have connected Bluetooth headphones via Kindle Settings\n2. VoiceView is enabled (Settings > Accessibility > VoiceView)\n3. You switch to espeak TTS backend (Audiobook > Voice settings > TTS engine)\n\nPlease generate a bug report (Audiobook > Generate bug report) and share it on GitHub.")
                                else
                                    msg = _("Kindle audio playback failed.\n\nThe playermgr service accepted commands but audio never started.\n\nPossible causes:\n1. GStreamer cannot find the wavparse plugin on this firmware\n2. audiomgrd denied audio focus to the plugin\n3. No audio sink is configured (built-in speaker absent, BT not connected)\n\nTry: Connect Bluetooth headphones via Kindle Settings first, then start read-along.\n\nIf this persists, please generate a bug report (Audiobook > Generate bug report) and share it on GitHub.")
                                end
                                if engine._kindle_gst_play_bin then
                                    msg = msg .. "\n\nTry: Switch to gst-play in Audiobook settings if available."
                                end
                                UIManager:show(InfoMessage:new{
                                    text = msg,
                                    timeout = 10,
                                })
                                if engine.on_fail_callback then
                                    engine.on_fail_callback()
                                end
                                return
                            end
                            -- First failure -- try advancing to next sentence
                            engine:onPlaybackComplete()
                            return
                        end
                    end
                end
            end
            if poll_count >= max_polls then
                logger.warn("TTSEngine: Kindle LIPC playback timed out after",
                    poll_count * 0.1, "s -- forcing completion")
                os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
                engine:onPlaybackComplete()
            else
                UIManager:scheduleIn(0.1, pollLipcDone)
            end
        end
        UIManager:scheduleIn(0.1, pollLipcDone)
        return true
    end
    -- === KINDLE GST-PLAY PATH ===
    -- Bundled C helper that feeds raw PCM to GStreamer mixersink via dlopen.
    -- Used on Kindle devices that have GStreamer + mixersink but no wavparse.
    -- The helper reads the WAV header, strips it, and plays raw PCM.
    if self.audio_player_type == "kindle-gst-play" then
        self._concat_durations = nil
        self._expected_play_duration_ms = self._current_audio_duration_ms
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation
        self.playback_latency_ms = 300
        local file_path = self.current_audio_file
        logger.warn("TTSEngine: kindle-gst-play:", file_path,
            "dur=", self._expected_play_duration_ms, "ms")
        -- Audio focus ('Music') is taken once per session by
        -- _ensureKindleKeepalive below — NOT per sentence: every setFocus
        -- makes audiomgrd re-ramp gain to its stored level, which reset
        -- the headset volume to max on every sentence boundary.
        -- Prefer the system gst-launch-0.10 pipeline: on PW5/PW6 the working
        -- recipe is mixersink stream-type=Music sync=true (the bundled
        -- gst-play binary sets neither and hangs in commit).  Fall back to
        -- the bundled binary only when the system pipeline cannot launch.
        local pid = nil
        if self:commandExists("gst-launch-0.10") then
            -- Keep the A2DP datapath up across sentence boundaries so the
            -- next stream starts instantly instead of losing its opening
            -- to the datapath resume.
            self:_ensureKindleKeepalive()
            local sys_pid, raw_file = self:_trySystemGstLaunch(file_path)
            if sys_pid then
                pid = sys_pid
                self._gst_system_raw_file = raw_file
                -- The raw stream carries 0.25 s of lead-in silence (see
                -- _trySystemGstLaunch), so word highlighting must start
                -- correspondingly later.
                self.playback_latency_ms = 550
                logger.warn("TTSEngine: kindle-gst-play using system gst-launch, PID=", pid)
            end
        end
        if not pid and self._kindle_gst_play_bin then
            -- Launch gst-play in background, capture PID.
            -- Capture stderr to a log file for diagnostics (was previously
            -- discarded, making it impossible to debug silent failures).
            local gst_log = "/tmp/.gst_play_last.log"
            local cmd = string.format(
                '%s "%s" >%s 2>&1 & echo $!',
                self._kindle_gst_play_bin, file_path, gst_log)
            local h = io.popen(cmd)
            local pid_str = h and h:read("*a") or ""
            if h then h:close() end
            pid = tonumber(pid_str:match("(%d+)"))
            logger.warn("TTSEngine: kindle-gst-play launched, PID=", pid)
        end
        if not pid then
            -- Neither the system pipeline nor a bundled binary could launch
            -- (system-pipeline-only selection where gst-launch failed at
            -- runtime, or no binary present).  Fail fast instead of entering
            -- the poll loop with a nil pid, which would misread a stale log
            -- as an early exit or a silent completion.
            logger.err("TTSEngine: kindle-gst-play could not launch any pipeline")
            self._gst_play_pid = nil
            self.is_speaking = false
            self:cleanup()
            if self.on_fail_callback then
                self.on_fail_callback()
            end
            return false
        end
        self._gst_play_pid = pid
        self._audio_launched_at = UIManager:getTime()
        self:startTimingLoop()
        -- Poll /proc/<pid> for process completion.
        -- When the process exits, check its status to distinguish
        -- success (exit 0 = EOS) from failure (exit 3/4).
        local engine = self
        local poll_count = 0
        local dur_ms = self._expected_play_duration_ms or 5000
        local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
        -- Health-check: if the process is still running after this many polls
        -- but the log hasn't progressed beyond initial loading, assume hung.
        local health_check_polls = 25   -- 2.5s (poll interval is 0.1s)
        local health_checked = false
        local function pollGstPlayDone()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.3, pollGstPlayDone)
                return
            end
            poll_count = poll_count + 1
            -- Check if process still running via /proc
            local proc_fh = pid and io.open("/proc/" .. pid .. "/status", "r")
            if proc_fh then
                proc_fh:close()
                -- Still running -- perform a health check after a few seconds.
                if not health_checked and poll_count >= health_check_polls then
                    health_checked = true
                    local log_text = ""
                    local log_fh = io.open("/tmp/.gst_play_last.log", "r")
                    if log_fh then
                        log_text = log_fh:read("*a") or ""
                        log_fh:close()
                    end
                    -- If the log only contains the initial loader message and
                    -- (for the new helper) the pipeline description, but no
                    -- playback progress, the pipeline is likely hung in state
                    -- change or caps negotiation (missing audioconvert/audioresample).
                    local has_playback_activity = log_text:match("GStreamer error")
                        or log_text:match("EOS")
                        or log_text:match("playback")
                    local is_hung = not has_playback_activity
                        and log_text:match("gst%-play: loaded libgstreamer")
                    if is_hung then
                        logger.err("TTSEngine: kindle-gst-play hung after",
                            poll_count * 0.1, "s, log=", log_text:gsub("\n", " "):sub(1, 200))
                        os.execute("kill " .. pid .. " 2>/dev/null")

                        -- Try system gst-launch-0.10 fallback once (issue #32).
                        -- The bundled gst-play hangs on some firmwares, but the
                        -- system gst-launch-0.10 with raw PCM works.
                        if not engine._gst_play_system_fallback_tried then
                            engine._gst_play_system_fallback_tried = true
                            logger.warn("TTSEngine: kindle-gst-play hung, trying system gst-launch-0.10 fallback")
                            local sys_pid, raw_file = engine:_trySystemGstLaunch(engine.current_audio_file)
                            if sys_pid then
                                engine._gst_play_pid = sys_pid
                                engine._gst_system_raw_file = raw_file
                                pid = sys_pid
                                health_checked = false
                                UIManager:scheduleIn(0.1, pollGstPlayDone)
                                return
                            end
                            logger.warn("TTSEngine: system gst-launch-0.10 fallback also failed")
                        end

                        engine._gst_play_pid = nil
                        engine._gst_play_broken = true
                        if engine.plugin then
                            engine.plugin:setSetting("_gst_play_broken", true)
                            logger.warn("TTSEngine: persisted _gst_play_broken=true")
                        end
                        engine.is_speaking = false
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        local msg = _("Audio playback failed on this Kindle model.\n\nThe GStreamer pipeline started but could not produce audio. This usually means the firmware's GStreamer installation is too stripped (missing audioconvert / audioresample plugins).\n\nPlease generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue.")
                        UIManager:show(InfoMessage:new{
                            text = msg,
                            timeout = 12,
                        })
                        if engine.on_fail_callback then
                            engine.on_fail_callback()
                        end
                        return
                    end
                end
                if poll_count >= max_polls then
                    logger.warn("TTSEngine: kindle-gst-play timed out after",
                        poll_count * 0.1, "s -- killing")
                    os.execute("kill " .. pid .. " 2>/dev/null")
                    engine._gst_play_pid = nil
                    engine:onPlaybackComplete()
                else
                    UIManager:scheduleIn(0.1, pollGstPlayDone)
                end
            else
                -- Process exited -- check for early failure before treating as completion.
                local elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                local expected_ms = engine._expected_play_duration_ms or 5000
                local is_early_exit = elapsed_ms < math.min(1000, expected_ms * 0.2)
                -- Read the stderr log for diagnostics (helps debug silent failures).
                local log_text = ""
                local log_fh = io.open("/tmp/.gst_play_last.log", "r")
                if log_fh then
                    log_text = log_fh:read("*a") or ""
                    log_fh:close()
                    if log_text ~= "" then
                        logger.warn("TTSEngine: kindle-gst-play stderr:", log_text:sub(1, 500))
                    end
                end
                local has_error = log_text:match("Failed to load plugin")
                    or log_text:match("undefined symbol")
                    or log_text:match("gst%-play: pipeline creation failed")
                    or log_text:match("gst%-play: cannot load libgstreamer")
                    or log_text:match("gst%-play: GStreamer error:")
                if is_early_exit and has_error then
                    logger.err("TTSEngine: kindle-gst-play exited early (", elapsed_ms,
                        "ms) with error, expected ~", expected_ms, "ms")

                    -- Try system gst-launch-0.10 fallback once (issue #32).
                    if not engine._gst_play_system_fallback_tried then
                        engine._gst_play_system_fallback_tried = true
                        logger.warn("TTSEngine: kindle-gst-play exited early, trying system gst-launch-0.10 fallback")
                        local sys_pid, raw_file = engine:_trySystemGstLaunch(engine.current_audio_file)
                        if sys_pid then
                            engine._gst_play_pid = sys_pid
                            engine._gst_system_raw_file = raw_file
                            pid = sys_pid
                            -- Reset state and continue polling with system process
                            engine.is_speaking = true
                            engine.play_generation = my_gen
                            UIManager:scheduleIn(0.1, pollGstPlayDone)
                            return
                        end
                        logger.warn("TTSEngine: system gst-launch-0.10 fallback also failed")
                    end

                    engine._gst_play_pid = nil
                    engine.is_speaking = false
                    engine.play_generation = (engine.play_generation or 0) + 1
                    engine:cleanup()
                    local err_hint = log_text:match("gst%-play: GStreamer error:%s*(.+)")
                        or log_text:match("gst%-play: ([^\n]+)") or ""
                    if #err_hint > 80 then
                        err_hint = err_hint:sub(1, 80) .. "..."
                    end
                    local msg = _("Audio playback failed on this Kindle model.\n\nThe GStreamer audio pipeline could not start")
                    if err_hint ~= "" then
                        msg = msg .. " (" .. err_hint .. ")."
                    else
                        msg = msg .. "."
                    end
                    msg = msg .. _("\n\nThis is often a system library compatibility issue. Try connecting Bluetooth headphones via Kindle Settings, switch to the espeak backend (Tools → Audiobook → Voice settings → TTS engine), or generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue.")
                    UIManager:show(InfoMessage:new{
                        text = msg,
                        timeout = 12,
                    })
                    if engine.on_fail_callback then
                        engine.on_fail_callback()
                    end
                    return
                end
                logger.warn("TTSEngine: kindle-gst-play finished, polls=", poll_count)
                engine._gst_play_pid = nil
                -- Clean up system fallback raw PCM file if present
                if engine._gst_system_raw_file then
                    os.remove(engine._gst_system_raw_file)
                    engine._gst_system_raw_file = nil
                end
                engine:onPlaybackComplete()
            end
        end
        UIManager:scheduleIn(0.2, pollGstPlayDone)
        return true
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
            logger.dbg("TTSEngine: Merged", 1 + #concat_files, "sentences, durations=",
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
        -- Detect the actual sample rate of the audio file so the persistent
        -- pipeline's rawaudioparse element uses the correct rate.
        -- MBROLA voices typically output at 16000 Hz, not 22050 Hz.
        if self.current_audio_file then
            self._target_sample_rate = WavUtils.readSampleRateFromPath(self.current_audio_file)
            if self._target_sample_rate <= 0 then
                self._target_sample_rate = 22050
            end
        end
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
        logger.dbg("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")
        -- Feed audio to the persistent pipeline
        os.remove(PIPELINE_CTRL_DIR .. "/done")
        local ctrl_f = io.open(PIPELINE_CTRL_DIR .. "/play", "w")
        if ctrl_f then
            ctrl_f:write(self.current_audio_file)
            ctrl_f:close()
        end
        self._audio_launched_at = UIManager:getTime()
        self._total_pause_ms = 0  -- reset accumulated pause time for this sentence
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
        local needed_ms = engine._expected_play_duration_ms
            - trailing_gap_ms + pipe_buf_ms + 150
        local function fireCompletion()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.5, fireCompletion)
                return
            end
            -- Verify enough real playback time has elapsed (excluding
            -- time spent paused via SIGSTOP).  Without this check,
            -- resuming from pause fires completion immediately and
            -- overlaps the next sentence with the current one.
            if engine._audio_launched_at then
                local wall_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                local real_ms = wall_ms - (engine._total_pause_ms or 0)
                if real_ms < needed_ms then
                    local wait_s = (needed_ms - real_ms) / 1000
                    if wait_s < 0.2 then wait_s = 0.2 end
                    UIManager:scheduleIn(wait_s, fireCompletion)
                    return
                end
            end
            logger.dbg("TTSEngine: Pipeline completion (duration-based,",
                engine._expected_play_duration_ms, "ms - trailing_gap",
                trailing_gap_ms, "ms + pipe_buf",
                pipe_buf_ms, "ms)")
            engine:onPlaybackComplete()
        end
        engine._completion_timer_fn = fireCompletion
        UIManager:scheduleIn(completion_delay_s, fireCompletion)

        return true
    end

    -- === POCKETBOOK INKVIEW PLAYFILE PATH ===
    -- Routes audio through the PocketBook audio daemon (mpd.app) via the
    -- InkView PlayFile FFI call.  Uses duration-based completion with
    -- GetPlayerState polling as a cross-check.
    if self.audio_player_type == "pb-inkview" and _inkview_audio then
        self._concat_durations = nil
        self.play_generation = (self.play_generation or 0) + 1
        local my_gen = self.play_generation

        -- Cancel pending callbacks from previous play()
        if self._completion_timer_fn then
            UIManager:unschedule(self._completion_timer_fn)
            self._completion_timer_fn = nil
        end

        logger.warn("TTSEngine: play() pre-launch took", time.to_ms(UIManager:getTime() - t0), "ms")

        -- Play via InkView audio daemon
        local ok, err = pcall(_inkview_audio.PlayFile, self.current_audio_file)
        if not ok then
            logger.err("TTSEngine: InkView PlayFile failed:", err)
            self.is_speaking = false
            if on_fail then on_fail() end
            return false
        end

        self._audio_launched_at = UIManager:getTime()
        self._total_pause_ms = 0
        self._expected_play_duration_ms = self._current_audio_duration_ms or 5000

        logger.warn("TTSEngine: InkView PlayFile started, dur=",
            self._expected_play_duration_ms, "ms, gen=", my_gen)

        -- Start word-highlighting timing loop
        self:startTimingLoop()

        -- Poll GetPlayerState for completion with duration-based fallback.
        -- Player states: MP_STOPPED=0, MP_PLAYING=2, MP_PAUSED=3, MP_TRACK_FINISHED=6
        local dur_ms = self._expected_play_duration_ms
        local poll_interval = 0.3
        local engine = self
        local function pollInkviewState()
            if (engine.play_generation or 0) ~= my_gen then return end
            if not engine.is_speaking then return end
            if engine.is_paused then
                UIManager:scheduleIn(0.5, pollInkviewState)
                return
            end
            -- Check if InkView player finished
            local gs_ok, state = pcall(_inkview_audio.GetPlayerState)
            if gs_ok and (state == 0 or state == 6) then
                -- MP_STOPPED or MP_TRACK_FINISHED
                -- Only fire if enough time has passed (avoid false 0 at start)
                local elapsed_ms = 0
                if engine._audio_launched_at then
                    elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                        - (engine._total_pause_ms or 0)
                end
                if elapsed_ms > 500 then
                    logger.warn("TTSEngine: InkView playback finished, state=", state,
                        "elapsed=", elapsed_ms, "ms")
                    engine:onPlaybackComplete()
                    return
                end
            end
            -- Duration-based fallback: fire if well past expected duration
            if engine._audio_launched_at then
                local elapsed_ms = time.to_ms(UIManager:getTime() - engine._audio_launched_at)
                    - (engine._total_pause_ms or 0)
                if elapsed_ms > dur_ms + 2000 then
                    logger.warn("TTSEngine: InkView duration-based completion at", elapsed_ms, "ms")
                    engine:onPlaybackComplete()
                    return
                end
            end
            UIManager:scheduleIn(poll_interval, pollInkviewState)
        end
        engine._completion_timer_fn = pollInkviewState
        UIManager:scheduleIn(poll_interval, pollInkviewState)

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
        -- If a crash-retry proved a specific device/conversion combo works
        -- on this device (issue #49), use it from the start this session.
        local effective_player = player
        if self._wav_play_force_prefix and self._wav_play_cmd
                and player == self._wav_play_cmd then
            effective_player = self._wav_play_force_prefix
        end
        play_cmd = string.format('%s "%s"', effective_player, self.current_audio_file)
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

--- Try to select the Kindle native Ivona TTS as an audio fallback.
-- Routes text -> ttssrc -> Ivona -> mixersink -> audiomgrd -> BT, which
-- bypasses the (often stripped) GStreamer WAV plugins.  Used when no WAV
-- playback path is available on a speakerless Kindle.  Works regardless of
-- the selected synthesis backend because the sentence text is always stored
-- in self._native_tts_text; the trade-off is that audio is spoken in the
-- Ivona voice with estimated word timing.
--
-- Two independent signals select the fallback:
--   * orchestratorStarted=1: the Ivona orchestrator is up and ready.
--   * self._ttssrc_available: ttssrc was confirmed during a gst-play probe.
--     (issue #26 / PW6: ttssrc connects to Ivona directly and works even when
--     orchestratorStarted reports 0.)
-- @param context string  Short tag for logging (why the fallback was tried)
-- @treturn string|nil  "kindle-native-tts-fallback" if selected, else nil
function TTSEngine:_tryKindleNativeTtsFallback(context)
    if not Device:isKindle() then return nil end
    local orch_ok = false
    local h = io.popen("lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>/dev/null")
    if h then
        local v = h:read("*a") or ""
        h:close()
        if v:match("^%s*1") then orch_ok = true end
    end
    if orch_ok or self._ttssrc_available then
        self.audio_player_type = "kindle-native-tts-fallback"
        self._no_real_audio_output = false
        logger.warn("TTSEngine: Kindle native TTS fallback selected (",
            orch_ok and "orchestratorStarted=1" or "ttssrc available",
            ", context=", tostring(context or "?"), ")")
        return "kindle-native-tts-fallback"
    end
    return nil
end

--[[--
Find available audio player.
Sets self.audio_player_type to "kindle-native-tts", "kindle-lipc", "gst-bt",
"bluealsa", "aplay", "android", or "generic".
@return string|nil Player command
--]]
function TTSEngine:findAudioPlayer()
    -- 0) Android: playback goes through TtsHelper's MediaPlayer or PCM
    -- stream; there is no CLI player to probe.  Do not gate this on
    -- self._android_tts: the helper initializes lazily at first
    -- synthesis (v0.1.17.23), so the startup probe would fall through
    -- to the Linux checks and report a false "no audio device" (issue #44).
    -- A real TTS init failure surfaces later at synthesis time.
    if Device:isAndroid() then
        self.audio_player_type = "android"
        logger.dbg("TTSEngine: Using Android MediaPlayer for audio")
        return "android"
    end

    -- 0b) Kindle native TTS: Amazon's Ivona SDK via tts.orchestrator/playermgr.
    -- VoiceView uses this pipeline (confirmed via LIPC event capture):
    -- text → PlayParameter(JSON) → ttssrc (GStreamer) → Ivona SDK →
    -- mixersink → audiomgrd → A2DP → BT headphones.
    -- Bypasses the stripped GStreamer (no wavparse) entirely.
    -- ONLY usable when the synthesis backend is the Kindle native TTS itself,
    -- because Ivona only knows how to synthesize from text -- it cannot play
    -- pre-rendered WAV files produced by Piper/espeak.  When the user selected
    -- a WAV-producing backend (Piper, espeak), skip Ivona and fall through to
    -- a real audio player (kindle-lipc / kindle-gst-play) so the WAV can be
    -- decoded and routed to the speaker/BT.
    --
    -- v0.1.9.7: On Colorsoft, playermgr is non-functional (issue #23).
    -- Skip the playermgr-based native TTS path and fall through to the
    -- kindle-ttssrc path which bypasses playermgr entirely.
    -- KOReader may not detect Colorsoft model (returns "unknown"), so also
    -- use kernel version as a heuristic.
    local kernel_version = ""
    local kh = io.popen("uname -r 2>/dev/null")
    if kh then kernel_version = kh:read("*a") or ""; kh:close() end
    kernel_version = kernel_version:gsub("^%s+", ""):gsub("%s+$", "")
    local is_colorsoft = Device:isKindle() and (
        Device.model == "KindleColorSoft"
        or kernel_version:match("^5%.15%.")  -- Colorsoft kernel signature
    )
    if Device:isKindle() and self:commandExists("lipc-set-prop")
        and self:commandExists("lipc-get-prop")
        and self.backend == self.BACKENDS.KINDLE_NATIVE
        and not is_colorsoft then
        local h = io.popen("lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>/dev/null")
        if h then
            local val = h:read("*a") or ""; h:close()
            if val:match("^%s*1") then
                self.audio_player_type = "kindle-native-tts"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Found Kindle native TTS (Ivona SDK, orchestratorStarted=1)")
                return "kindle-native-tts"
            end
        end
    end

    -- 0c) Kindle LIPC: use Amazon's playermgr service via lipc-set-prop.
    -- playermgr uses GStreamer internally and routes audio through
    -- audiomgrd → audio.a2dp.default.so → BT headphones.
    -- This is the native way to play audio files on Kindle devices
    -- (which have no ALSA soundcard, no BlueZ, no PulseAudio).
    if Device:isKindle() and self:commandExists("lipc-set-prop")
        and self:commandExists("lipc-get-prop") then
        -- Verify playermgr service exists by reading InPlayback property.
        -- Use io.popen (not os.execute) because Lua 5.1 os.execute return
        -- values are unreliable across builds (some return raw wait status).
        local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>&1")
        if h then
            local val = h:read("*a") or ""
            h:close()
            val = val:match("^%s*(%d+)")
            if val then
                -- playermgr uses GStreamer to decode audio files.  On some
                -- Kindle models the GStreamer installation is stripped to only
                -- ttssrc+mixersink+audiblesrc -- no wavparse or audioconvert.
                -- Without wavparse, playermgr cannot decode WAV files and
                -- kindle-lipc will silently fail on every play attempt.
                -- Detect this by checking whether wavparse exists in the
                -- GStreamer plugin directory.
                local has_wavparse = false
                local gst_dirs = {"/usr/lib/gstreamer-1.0", "/usr/lib/gstreamer-0.10"}
                for _, dir in ipairs(gst_dirs) do
                    local lsh = io.popen("ls " .. dir .. "/libgstwav* 2>/dev/null")
                    if lsh then
                        local ls_out = lsh:read("*a") or ""
                        lsh:close()
                        if ls_out:match("libgstwav") then
                            has_wavparse = true
                            break
                        end
                    end
                end

                if has_wavparse then
                    self.audio_player_type = "kindle-lipc"
                    self._no_real_audio_output = false  -- LIPC routes through BT
                    logger.warn("TTSEngine: Found Kindle LIPC playermgr service, InPlayback=", val,
                        "wavparse=", has_wavparse)
                    return "kindle-lipc"
                end

                -- No wavparse -- playermgr cannot decode WAV.  Check for our
                -- bundled gst-play helper which feeds raw PCM to mixersink
                -- directly, bypassing the missing wavparse plugin.
                -- Skip if we already know it hangs on this device (detected at
                -- runtime during a previous playback attempt).
                -- On Kindle Colorsoft, playermgr is non-functional (issue #23).
                -- We need either ttssrc (bypasses playermgr) or mixersink
                -- (for raw PCM WAV playback).  Do NOT pre-emptively skip WAV
                -- mode; earlier "known broken" assumptions were based on an
                -- older gst-play binary and may no longer apply.
                if is_colorsoft then
                    local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
                    local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                    local gf = io.open(gst_play_bin, "r")
                    if gf then
                        gf:close()
                        local gst_play_cmd = gst_play_bin
                        if self.espeak_linker then
                            gst_play_cmd = string.format(
                                "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                                self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                        end
                        self._kindle_gst_play_bin = gst_play_cmd
                        if not self._ttssrc_broken then
                            local ph = io.popen(gst_play_cmd .. " --probe 2>&1")
                            if ph then
                                local probe = ph:read("*a") or ""
                                ph:close()
                                local ttssrc_ok = probe:match("ttssrc=found")
                                local ttssrc_broken = probe:match("ttssrc=broken")
                                local mixersink_ok = probe:match("mixersink=found")
                                local mixersink_broken = probe:match("mixersink=broken")
                                if ttssrc_broken then
                                    logger.warn("TTSEngine: Colorsoft ttssrc is broken (missing dependencies), disabling")
                                    self._ttssrc_broken = true
                                    if self.plugin then
                                        self.plugin:setSetting("_ttssrc_broken", true)
                                    end
                                end
                                if ttssrc_ok and mixersink_ok then
                                    self._ttssrc_available = true
                                    self.audio_player_type = "kindle-ttssrc"
                                    self._no_real_audio_output = false
                                    logger.warn("TTSEngine: Colorsoft ttssrc+mixersink confirmed, selecting kindle-ttssrc")
                                    return "kindle-ttssrc"
                                elseif mixersink_ok and not self._gst_play_broken then
                                    logger.warn("TTSEngine: Colorsoft ttssrc unavailable, falling back to kindle-gst-play WAV mode")
                                    self.audio_player_type = "kindle-gst-play"
                                    self._no_real_audio_output = false
                                    return "kindle-gst-play"
                                elseif mixersink_broken then
                                    logger.warn("TTSEngine: Colorsoft mixersink is broken, no GStreamer audio path available")
                                else
                                    logger.warn("TTSEngine: Colorsoft probe failed:", probe:gsub("\n", " "))
                                end
                            end
                        else
                            logger.warn("TTSEngine: kindle-ttssrc skipped (marked broken on this device)")
                            if not self._gst_play_broken then
                                logger.warn("TTSEngine: Colorsoft falling back to kindle-gst-play WAV mode")
                                self.audio_player_type = "kindle-gst-play"
                                self._no_real_audio_output = false
                                return "kindle-gst-play"
                            end
                        end
                    end
                elseif not self._gst_play_broken then
                    local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
                    local gst_play_bin = plugin_dir .. "/kindle/gst-play"
                    local gf = io.open(gst_play_bin, "r")
                    if gf then
                        gf:close()
                        -- Wrap through bundled ld-linux to bypass old system glibc.
                        -- Include /usr/lib:/lib so dlopen can find system libgstreamer.
                        local gst_play_cmd = gst_play_bin
                        if self.espeak_linker then
                            gst_play_cmd = string.format(
                                "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                                self.espeak_linker, self.espeak_lib_path, gst_play_bin)
                        end
                        -- Run --probe to verify GStreamer loads and mixersink exists.
                        -- Capture stderr (2>&1) so plugin load failures are visible.
                        local ph = io.popen(gst_play_cmd .. " --probe 2>&1")
                        if ph then
                            local probe = ph:read("*a") or ""
                            ph:close()
                            local has_plugin_error = probe:match("Failed to load plugin")
                                or probe:match("undefined symbol")
                                or probe:match("GStreamer%-WARNING")
                            if has_plugin_error then
                                logger.warn("TTSEngine: kindle-gst-play probe found plugin load error:", probe:gsub("\n", " "))
                            elseif probe:match("mixersink=found") then
                                -- Detect ttssrc availability for robust fallback on
                                -- devices where playermgr is non-functional (issue #23).
                                -- We check here so the fallback works even when
                                -- Device.model does not match "KindleColorSoft".
                                if probe:match("ttssrc=found") then
                                    self._ttssrc_available = true
                                elseif probe:match("ttssrc=broken") then
                                    logger.warn("TTSEngine: ttssrc is broken on this device (missing dependencies), disabling")
                                    self._ttssrc_broken = true
                                    if self.plugin then
                                        self.plugin:setSetting("_ttssrc_broken", true)
                                    end
                                end
                                -- Preemptive skip on PW5-like stripped firmware:
                                -- If wavparse, audioconvert, and audioresample are
                                -- all missing, the gst-play WAV pipeline will hang.
                                local has_wavparse = not probe:match("wavparse=not_found")
                                local has_audioconvert = not probe:match("audioconvert=not_found")
                                local has_audioresample = not probe:match("audioresample=not_found")
                                if not has_wavparse and not has_audioconvert and not has_audioresample then
                                    logger.warn("TTSEngine: PW5 signature detected (wavparse+audioconvert+audioresample missing)")
                                    -- Keep the binary reference for --ttssrc fallback
                                    self._kindle_gst_play_bin = gst_play_cmd
                                    -- On this firmware family WAV playback through
                                    -- mixersink works (stream-type=Music sync=true
                                    -- with audiomgrd focused on 'Music'), while the
                                    -- native ttssrc path does NOT, even when
                                    -- libIvonaEInkAPI.so.1.0 is present on disk:
                                    -- the underlying libtts_engine.so is the neural
                                    -- engine that exports no tts_engine_create, so
                                    -- every ttssrc pipeline fails after a ~5s stall.
                                    -- (Gating on the lib's presence used to strand
                                    -- PW5 on a permanently dead native-tts player.)
                                    -- Always select WAV mode here; fall through to
                                    -- native TTS only if WAV provably cannot work.
                                    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")
                                    if self:commandExists("gst-launch-0.10") then
                                        self.audio_player_type = "kindle-gst-play"
                                        self._no_real_audio_output = false
                                        logger.warn("TTSEngine: Selected kindle-gst-play (system gst-launch pipeline) on PW5-signature firmware")
                                        return "kindle-gst-play"
                                    end
                                    if self:_probeKindleGstPlayWav(gst_play_cmd) then
                                        self.audio_player_type = "kindle-gst-play"
                                        self._no_real_audio_output = false
                                        logger.warn("TTSEngine: Selected kindle-gst-play WAV mode on stripped firmware")
                                        return "kindle-gst-play"
                                    end
                                    logger.warn("TTSEngine: gst-play WAV mode failed on stripped firmware")
                                    -- Flag that this Kindle cannot play WAV files produced by
                                    -- external TTS backends (Piper, espeak).  Used to show a
                                    -- clearer pre-synthesis warning in main.lua.
                                    if self.backend ~= self.BACKENDS.KINDLE_NATIVE then
                                        self._kindle_wav_playback_limited = true
                                    end
                                    -- Fall through to kindle-native-tts-fallback below
                                else
                                    self.audio_player_type = "kindle-gst-play"
                                    self._kindle_gst_play_bin = gst_play_cmd
                                    self._gst_play_variant = "compat"
                                    self._no_real_audio_output = false
                                    logger.warn("TTSEngine: Found kindle-gst-play with mixersink, probe:", probe:gsub("\n", " "))
                                    return "kindle-gst-play"
                                end
                            else
                                logger.warn("TTSEngine: kindle-gst-play probe failed:", probe:gsub("\n", " "))
                            end
                        end
                    end
                else
                    logger.warn("TTSEngine: kindle-gst-play skipped (marked broken on this device)")
                end

                -- SATISFACTORY FALLBACK for PW5 / Colorsoft (issues #22, #23):
                -- When GStreamer is stripped (no wavparse) and gst-play hangs
                -- (missing audioconvert / audioresample), but the Ivona SDK
                -- is available, fall back to the Kindle's native TTS.  This
                -- routes text → ttssrc → Ivona → mixersink → audiomgrd → BT,
                -- bypassing ALL missing plugins.  Audio works; word timing
                -- comes from our estimates (may be slightly off since Ivona
                -- speaks at a different rate than espeak/Piper).
                -- Covers both the orchestratorStarted=1 case and the issue #26
                -- (PW6) ttssrc-without-orchestrator case.  The same helper is
                -- called again after this block so the fallback is still
                -- reachable when playermgr never answered InPlayback.
                local native_fb = self:_tryKindleNativeTtsFallback("playermgr-no-wav-path")
                if native_fb then return native_fb end

                -- No wavparse AND no gst-play helper (or mixersink not found)
                -- AND no Ivona SDK.  Do NOT select kindle-lipc here; on this
                -- firmware it cannot decode WAV files, so it would only fail
                -- (and previously crashed when the fallback used a nil global).
                -- Fall through to the Kindle rescue probe and generic players
                -- instead: aplay may see an ALSA PCM after audiomgrd focus
                -- (issue #28).
                self.audio_player_type = nil
                self._no_real_audio_output = true
                logger.warn("TTSEngine: Kindle playermgr found but GStreamer lacks wavparse and no gst-play helper")
                logger.warn("TTSEngine: Falling through to rescue probe / generic players, InPlayback=", val,
                    "wavparse=false, gst_play=not_found")
                -- fall through
            else
                logger.warn("TTSEngine: lipc-get-prop playermgr InPlayback returned:", val)
            end
        end
    end

    -- 0c-ii) Kindle gst-play WITHOUT playermgr (issue #28): on PW4-class
    -- firmware playermgr never answers InPlayback, so the gst-play detection
    -- nested inside 0c is unreachable and probing falls through to a bare
    -- aplay on a device with zero ALSA cards -- every TTS attempt then dies
    -- with "No audio output available" even though the SAME bundled gst-play
    -- (mixersink -> audiomgrd -> BT) plays music files fine via MediaEngine,
    -- which probes it without any playermgr gate.  Mirror that probe here so
    -- TTS WAV playback uses the working path and keeps the user's voice.
    -- Runs before the rescue probe: a confirmed mixersink path beats
    -- aggressive audiomgrd initialization, and the probe only loads GStreamer
    -- plugins (no audio focus taken).
    if Device:isKindle() and not self.audio_player_type then
        local gst_play_cmd = nil
        if not self._gst_play_broken then
            gst_play_cmd = self:_probeKindleGstPlayBin()
        end
        local has_system_gst = self:commandExists("gst-launch-0.10")
        if gst_play_cmd or has_system_gst then
            self.audio_player_type = "kindle-gst-play"
            -- May be nil when only the system pipeline exists; play()
            -- prefers _trySystemGstLaunch and skips a nil binary.
            self._kindle_gst_play_bin = gst_play_cmd
            self._no_real_audio_output = false
            logger.warn("TTSEngine: selected kindle-gst-play without playermgr (issue #28), bin=",
                tostring(gst_play_cmd), "system_gst=", has_system_gst)
            return "kindle-gst-play"
        end
    end

    -- 0d) Kindle rescue probe: when all native paths fail, try aggressive
    -- initialization sequences to wake up audiomgrd or force ALSA card
    -- registration.  Some firmwares (e.g. PW11 5.17.1.0.3) need a specific
    -- LIPC focus sequence before audioOutputConnected becomes 1 (issue #32).
    if Device:isKindle() then
        local rescued = self:_kindleRescueProbe()
        if rescued then
            return rescued
        end
    end

    -- 0e) Kindle native TTS fallback when no real WAV/ALSA path was found.
    -- On heavily stripped firmware (e.g. PW4) the playermgr InPlayback probe
    -- can return nothing, so the orchestrator/ttssrc fallback nested inside
    -- that block is never reached and audio silently dies even though the
    -- Ivona path (ttssrc -> mixersink -> audiomgrd -> BT) would work.  This
    -- runs AFTER the rescue probe on purpose: if a real ALSA/WAV path can be
    -- found it preserves the user's selected Piper/espeak voice; only when
    -- every WAV route fails do we accept the Ivona voice as the last resort
    -- before giving up.  The Ivona route does not depend on playermgr.
    if Device:isKindle() and self:commandExists("lipc-get-prop")
        and not self.audio_player_type then
        local native_fb = self:_tryKindleNativeTtsFallback("no-wav-path")
        if native_fb then return native_fb end
    end

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

    -- 1b) BlueALSA: bundled BT audio bridge for BlueZ Kobo devices.
    -- When bluealsa daemon is running, aplay can route audio to BT
    -- headphones via the "bluealsa" ALSA PCM device.
    local bt = self.plugin and self.plugin.bt_manager
    if self:commandExists("aplay") and bt then
        -- If bluealsa is not running but bundled, start it now.
        -- BlueALSA can run without an active BT device; it simply
        -- registers the A2DP profile with BlueZ and creates the ALSA
        -- PCM device.  When headphones connect later, audio works
        -- immediately.  Previously we gated this on an active connection,
        -- which meant paired-but-idle devices never triggered startup
        -- and audio fell through to a bare aplay with "no soundcards"
        -- (issue #8).
        if not bt:isBluealsaRunning()
            and bt:hasBluealsaBundled()
            and bt:getStackType() == "bluez" then
            logger.warn("TTSEngine: BlueALSA bundled but not running, starting it")
            local ba_ok = bt:startBluealsa()
            if not ba_ok then
                -- startBluealsa() polls internally, but on single-core Kobos
                -- the daemon may still be registering with D-Bus/ALSA.  Give
                -- it one more grace period before we fall through.
                logger.warn("TTSEngine: BlueALSA startup reported false, waiting 3s")
                os.execute("sleep 3")
            end
        end

        if bt:isBluealsaRunning() then
            local plugin_dir = bt:getBluealsaPluginDir()
            local ba_dev = bt:getBluealsaDevice()
            -- ALSA_PLUGIN_DIR tells libasound where to find the bluealsa
            -- PCM plugin .so. The PCM type "bluealsa" is defined in
            -- /etc/asound.conf (installed by startBluealsa).
            -- LD_LIBRARY_PATH is needed so that when aplay loads the PCM
            -- plugin, the plugin's own deps (libsbc, libglib, libdbus,
            -- libbluetooth) can be resolved from our bundled libs.
            local lib_dir = plugin_dir and plugin_dir:gsub("/alsa%-lib$", "")
            local env = ""
            if plugin_dir then
                env = "ALSA_PLUGIN_DIR=" .. plugin_dir .. " "
            end
            if lib_dir then
                env = "LD_LIBRARY_PATH=" .. lib_dir .. " " .. env
            end
            self.audio_player_type = "bluealsa"
            self._bluealsa_env = env
            self._no_real_audio_output = false
            logger.warn("TTSEngine: Found BlueALSA audio bridge, device:", ba_dev)
            return env .. "aplay -q -D " .. ba_dev
        end
    end

    -- 2) Check if any ALSA soundcard exists
    local has_soundcard = false
    local cards = io.open("/proc/asound/cards", "r")
    if cards then
        local content = cards:read("*a")
        cards:close()
        has_soundcard = content and not content:match("no soundcards")
    end

    local is_kindle = Device:isKindle()

    -- Kindle audio device probing.
    -- /proc/asound/cards may say "no soundcards" even when BT audio
    -- is paired -- Amazon manages BT audio at the OS level via its own
    -- daemon (btfd/Lab126 IPC) and does NOT expose a standard ALSA PCM
    -- device.  Probe aplay -l, aplay -L, /dev/snd/ and PulseAudio for
    -- any dynamically registered device that appears when a BT headset
    -- connects.  If found, use it with an explicit -D argument; if
    -- nothing is found, flag _no_real_audio_output so the process
    -- watcher can detect rapid aplay failures instead of silently
    -- cycling through sentences.
    local kindle_audio_device = nil  -- explicit -D value when found
    if is_kindle and not has_soundcard then
        local has_aplay = self:commandExists("aplay")
        -- 1) aplay -l: registered ALSA cards (may include BT)
        if has_aplay then
            local al = io.popen("aplay -l 2>/dev/null")
            if al then
                local al_out = al:read("*a") or ""
                al:close()
                local card, dev = al_out:match("card (%d+):.+device (%d+):")
                if card and dev then
                    kindle_audio_device = "hw:" .. card .. "," .. dev
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found ALSA hw device:", kindle_audio_device)
                end
            end
        end
        -- 2) aplay -L: named PCM devices.  Prefer BT-related names
        --    (bluealsa:*, bluetooth, a2dp) over generic ones; skip
        --    default / null / surround* which are not real sinks on a
        --    speakerless Kindle.
        if has_aplay and not has_soundcard then
            local aL = io.popen("aplay -L 2>/dev/null")
            if aL then
                local pcm_list = aL:read("*a") or ""
                aL:close()
                local bt_pcm, first_pcm = nil, nil
                for line in pcm_list:gmatch("([^\n]+)") do
                    local name = line:match("^(%S+)$")
                    if name then
                        local lower = name:lower()
                        if lower:match("blue") or lower:match("a2dp") or lower:match("bt") then
                            bt_pcm = name
                            break  -- BT device found, stop searching
                        end
                        if not first_pcm
                            and lower ~= "default" and lower ~= "null"
                            and not lower:match("^surround") then
                            first_pcm = name
                        end
                    end
                end
                kindle_audio_device = bt_pcm or first_pcm
                if kindle_audio_device then
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found PCM device:", kindle_audio_device)
                end
            end
        end
        -- 3) /dev/snd/ pcm nodes
        if not has_soundcard then
            local snd = io.popen("ls /dev/snd/ 2>/dev/null")
            if snd then
                local snd_out = snd:read("*a") or ""
                snd:close()
                if snd_out:match("pcm") then
                    has_soundcard = true
                    logger.warn("TTSEngine: Kindle found /dev/snd/ pcm node")
                end
            end
        end
        -- 4) PulseAudio: check for a running sink (Amazon may route BT
        --    through PulseAudio on newer firmware).
        if not has_soundcard and self:commandExists("pactl") then
            local pa = io.popen("pactl list sinks short 2>/dev/null")
            if pa then
                local pa_out = pa:read("*a") or ""
                pa:close()
                if pa_out:match("%S") then
                    has_soundcard = true
                    self._kindle_use_pulseaudio = true
                    logger.warn("TTSEngine: Kindle found PulseAudio sink")
                end
            end
        end
        if not has_soundcard then
            logger.warn("TTSEngine: Kindle - no ALSA card, no PCM device, "
                        .. "no /dev/snd pcm, no PulseAudio. Audio will likely fail.")
        end
    end

    -- On Kindle, parse /etc/asound.conf for named PCM devices.
    -- v0.1.5.24 diagnostics revealed dmix0 on hw:0,0 at 44100 Hz.
    local kindle_asound_pcms = {}
    if is_kindle then
        local ac = io.open("/etc/asound.conf", "r")
        if ac then
            local content = ac:read("*a") or ""
            ac:close()
            -- Match pcm.<name> { ... } top-level definitions
            for name in content:gmatch("pcm%.(%w+)%s*{") do
                if name ~= "default" and name ~= "null" then
                    table.insert(kindle_asound_pcms, name)
                end
            end
            if #kindle_asound_pcms > 0 then
                logger.warn("TTSEngine: Kindle asound.conf PCMs:",
                            table.concat(kindle_asound_pcms, ", "))
            end
        end
    end

    -- Build player candidate list, ordered by preference.
    local players = {}
    -- Kindle-discovered device with explicit -D (highest priority)
    if is_kindle and kindle_audio_device then
        table.insert(players, {cmd = "aplay", args = "-q -D " .. kindle_audio_device})
    end
    -- Kindle asound.conf named PCMs (e.g. dmix0 found in v0.1.5.24)
    for _, pcm_name in ipairs(kindle_asound_pcms) do
        table.insert(players, {cmd = "aplay", args = "-q -D " .. pcm_name})
    end
    -- Kindle with PulseAudio: try paplay before generic aplay
    if is_kindle and self._kindle_use_pulseaudio then
        table.insert(players, {cmd = "paplay", args = ""})
    end
    if has_soundcard or is_kindle then
        table.insert(players, {cmd = "aplay", args = "-q -D default"})
        table.insert(players, {cmd = "aplay", args = "-q -D hw:0,0"})
        table.insert(players, {cmd = "aplay", args = "-q"})
    end
    table.insert(players, {cmd = "paplay", args = ""})
    table.insert(players, {cmd = "mpv", args = "--no-video --really-quiet"})
    table.insert(players, {cmd = "mplayer", args = "-really-quiet"})
    table.insert(players, {cmd = "play", args = "-q"})
    -- Last resort: try aplay even without a detected soundcard
    if not has_soundcard and not is_kindle then
        table.insert(players, {cmd = "aplay", args = "-q"})
    end
    -- Flag no real audio output for rapid-fail detection.
    if not has_soundcard then
        self._no_real_audio_output = true
    end

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

    -- PocketBook InkView PlayFile: routes audio through the PocketBook
    -- audio daemon (mpd.app) instead of opening ALSA directly.  This
    -- avoids corrupting the amplifier state on devices like PB700c where
    -- any direct ALSA access kills the built-in speaker until reboot.
    -- Triggered when the user selects "System player (InkView)" in the
    -- PocketBook audio device menu.
    if self:isPocketBook() then
        local alsa_device = self.plugin and self.plugin:getSetting("pb_alsa_device", "")
        if alsa_device == "inkview" then
            if self:_tryInkView() then
                return "pb-inkview"
            else
                logger.warn("TTSEngine: InkView not available, falling through to wav-play")
            end
        end
    end

    -- Bundled wav-play: minimal ALSA player for devices that have a
    -- soundcard + libasound but ship no aplay (e.g. PocketBook).
    -- Uses the bundled ld-linux wrapper.  Bundled libasound gets priority
    -- so we avoid "internal error" when the system libasound is built
    -- against an older glibc than our bundled ld-linux.  System dirs are
    -- still in the path as fallback for other shared objects.
    if has_soundcard and self._wav_play_bin then
        local wav_play_cmd = self._wav_play_bin
        if self.espeak_linker and self._wav_play_lib then
            -- The bundled libasound (Nix cross-compiled) has Nix store
            -- paths compiled in for ALSA_PLUGIN_DIR and the default
            -- config.  Prefer /usr/share/alsa/alsa.conf: it registers
            -- base PCM types (plug, softvol, dmix, hw, etc.) and
            -- includes /etc/asound.conf for device-specific PCMs.
            -- Without the base types, ALSA reports "Unknown PCM" for
            -- every PCM type defined in /etc/asound.conf.
            -- The @hooks in alsa.conf call snd_dlopen(NULL) which uses
            -- dladdr(); this works now that --library-path is absolute.
            local alsa_env = ""
            local alsa_conf_candidates = {
                "/usr/share/alsa/alsa.conf",
                "/etc/alsa/alsa.conf",
                "/etc/asound.conf",
            }
            for _, path in ipairs(alsa_conf_candidates) do
                local f = io.open(path, "r")
                if f then
                    f:close()
                    alsa_env = "ALSA_CONFIG_PATH=" .. path
                    logger.warn("TTSEngine: Using ALSA config:", path)
                    break
                end
            end
            -- ALSA_PLUGIN_DIR: override the Nix store plugin path
            -- compiled into the bundled libasound.  Point to the
            -- system's ALSA plugin directory (may not exist, but
            -- prevents attempts to load from /nix/store/...).
            local plugin_dir_candidates = {
                "/usr/lib/alsa-lib",
                "/usr/lib/arm-linux-gnueabihf/alsa-lib",
                "/usr/lib/alsa",
            }
            for _, path in ipairs(plugin_dir_candidates) do
                local d = io.open(path, "r")
                if d then
                    d:close()
                    alsa_env = alsa_env .. " ALSA_PLUGIN_DIR=" .. path
                    logger.warn("TTSEngine: Using ALSA plugin dir:", path)
                    break
                end
            end
            if alsa_env ~= "" then alsa_env = alsa_env .. " " end
            -- Use absolute paths in --library-path so the dynamic linker
            -- stores absolute paths in dladdr().  ALSA's snd_dlopen(NULL)
            -- calls dladdr() to find libasound.so.2; when the returned
            -- path is relative (starts without '/'), snd_dlopen prepends
            -- ALSA_PLUGIN_DIR creating a broken path like:
            --   /usr/lib/alsa-lib/plugins/.../wav-play/lib/libasound.so.2
            -- When the path is absolute, snd_dlopen calls dlopen()
            -- directly on the already-loaded library and it succeeds.
            local abs_linker = self.espeak_linker
            local abs_wav_lib = self._wav_play_lib
            local abs_esp_lib = self.espeak_lib_path
            local abs_wav_bin = self._wav_play_bin
            if abs_wav_lib:sub(1, 1) ~= "/" then
                local h = io.popen("pwd")
                if h then
                    local cwd = h:read("*l")
                    h:close()
                    if cwd and cwd ~= "" then
                        abs_linker = cwd .. "/" .. abs_linker
                        abs_wav_lib = cwd .. "/" .. abs_wav_lib
                        abs_esp_lib = cwd .. "/" .. abs_esp_lib
                        abs_wav_bin = cwd .. "/" .. abs_wav_bin
                    end
                end
            end
            wav_play_cmd = string.format(
                "%s%s --library-path %s:%s:/usr/lib:/lib %s",
                alsa_env, abs_linker, abs_wav_lib,
                abs_esp_lib, abs_wav_bin)
        end
        self.audio_player_type = "aplay"
        self._wav_play_cmd = wav_play_cmd
        -- PocketBook ALSA device override: tts_sm routes through the
        -- PocketBook audio pipeline (softvol, dmix, proper resampling).
        -- Only default to tts_sm when the device actually defines it in
        -- asound.conf; devices like PB632 lack tts_sm entirely and would
        -- fall through to plughw:0/hw:0 which bypasses BT routing.
        -- hwout_mix (the dmix feeding the Loopback the audio daemon reads)
        -- is probed too: it is the crash-fallback route when the nested
        -- plug chain above tts_sm aborts in alsa-lib (issue #49).
        local pb_default = ""
        if not self._pb_has_tts_sm_probed then
            self._pb_has_tts_sm_probed = true
            self._pb_has_tts_sm = false
            self._pb_has_hwout_mix = false
            for _, conf in ipairs({"/etc/asound.conf", "/usr/share/alsa/asound.conf"}) do
                local fh = io.open(conf, "r")
                if fh then
                    local content = fh:read("*a")
                    fh:close()
                    if content and content:find("pcm%.tts_sm") then
                        self._pb_has_tts_sm = true
                        logger.warn("TTSEngine: tts_sm PCM found in", conf)
                    end
                    if content and content:find("pcm%.hwout_mix") then
                        self._pb_has_hwout_mix = true
                        logger.warn("TTSEngine: hwout_mix PCM found in", conf)
                    end
                    if self._pb_has_tts_sm and self._pb_has_hwout_mix then break end
                end
            end
            if not self._pb_has_tts_sm then
                logger.warn("TTSEngine: tts_sm PCM not found in asound.conf, using Auto")
            end
        end
        if self._pb_has_tts_sm then pb_default = "tts_sm" end
        local alsa_device = self.plugin and self.plugin:getSetting("pb_alsa_device", pb_default)
        -- "inkview" is handled above via the InkView FFI path.  If we reach
        -- this point with alsa_device == "inkview" it means InkView failed
        -- to load.  Treat it as "Auto" so wav-play does NOT receive "-D inkview"
        -- (an invalid ALSA device that causes the fallback chain to open hw:0
        -- and corrupt the PocketBook amplifier state).
        local alsa_str = tostring(alsa_device or "")
        if alsa_str == "inkview" or alsa_str:find("inkview") then
            logger.warn("TTSEngine: InkView unavailable, falling back to Auto for wav-play",
                "(raw type=", type(alsa_device), "val=", alsa_device, ")")
            alsa_device = pb_default
        end
        -- When "Auto" is selected (empty string) but tts_sm exists, use
        -- tts_sm.  Falling through to wav-play's "default" device on
        -- PocketBook can trigger the hw:0/plughw:0 fallback chain which
        -- bypasses the PocketBook audio pipeline, causing clicking,
        -- inaudible TTS, and persistent audio state corruption.
        if (not alsa_device or alsa_device == "") and self._pb_has_tts_sm then
            alsa_device = "tts_sm"
        end
        -- On PocketBook, skip wav-play's mixer setup/restore to avoid
        -- corrupting amplifier state.  The PocketBook audio daemon manages
        -- hw:0 natively; touching the mixer kills the speaker system-wide
        -- until reboot on devices like PB700c.  This applies to all device
        -- choices, not only tts_sm, because setup_mixer always targets hw:0
        -- regardless of which PCM device is opened for playback.
        wav_play_cmd = wav_play_cmd .. " --no-mixer"
        -- Retain the device-less base command and the chosen device so the
        -- crash-retry ladder can rebuild variants (conversion flags, other
        -- devices) without string surgery on the full command.
        self._wav_play_base_cmd = wav_play_cmd
        self._wav_play_device = (alsa_device and alsa_device ~= "") and alsa_device or nil
        if self._wav_play_device then
            wav_play_cmd = wav_play_cmd .. " -D " .. alsa_device
            if alsa_device == "hwout_mix" then
                -- The dmix is fixed at 48000/S16_LE/2ch; feed it
                -- pre-converted audio so no plug refinement runs at all
                -- (issue #49: this firmware's alsa-lib aborts in it).
                wav_play_cmd = wav_play_cmd .. " --rate 48000 --channels 2"
            end
            self._wav_play_cmd = wav_play_cmd
            logger.warn("TTSEngine: PocketBook ALSA device override:", alsa_device)
        else
            self._wav_play_cmd = wav_play_cmd
        end
        logger.warn("TTSEngine: Using bundled wav-play for ALSA playback")
        -- Do NOT pass -q: we need stderr output for diagnostics.
        -- Errors are captured via the process-watcher stderr log below.
        return wav_play_cmd
    end

    -- On PocketBook, ALSA may not be exposed at all (Era Color, some
    -- firmware revisions).  InkView PlayFile is the only viable path.
    -- Try it automatically when no ALSA player was found, so users do
    -- not need to discover the menu option manually.
    if self:isPocketBook() then
        logger.warn("TTSEngine: No ALSA player on PocketBook; trying InkView fallback")
        if self:_tryInkView() then
            return "pb-inkview"
        end
    end

    logger.warn("TTSEngine: No audio player found. has_soundcard=", has_soundcard,
                "is_kindle=", is_kindle, "checked:", #players, "candidates")
    return nil
end

--[[--
Kindle rescue probe: when all standard audio paths fail, try aggressive
initialization sequences to wake up audiomgrd or force ALSA card
registration.  Some firmwares (e.g. PW11 5.17.1.0.3) need a specific
LIPC focus sequence before audioOutputConnected becomes 1 (issue #32).
@return string|nil  Audio player command if rescue succeeded, nil otherwise
--]]
--- Probe the native-glibc gst-play variant (kindle/gst-play-native) and, if its
-- mixersink factory loads, select it as the kindle-gst-play backend.
--
-- This is the KinAMP-parity fallback for audio-less Kindles (PW4-class) where
-- the compat gst-play -- cross-built against a modern glibc and run through the
-- bundled ld-linux -- crashes loading the device's old-glibc libgstmixersink.so.
-- The native binary is built with koxtoolchain and runs under the SYSTEM linker
-- like KinAMP, so there is no glibc mixing.  We probe it exactly like the compat
-- binary (mixersink=found) but launch it plainly (bare, under the system linker;
-- no espeak-linker wrapper, which is what triggers the glibc mixing).
--
-- Purely additive: this is reached only from _kindleRescueProbe (i.e. after a
-- device was already classified _no_real_audio_output), so devices that already
-- select kindle-gst-play normally never run this and cannot regress.
--
-- Probe one native-glibc gst-play binary.  Returns "kindle-gst-play" and
-- configures the engine if the binary reports mixersink=found, otherwise nil.
-- @tparam string native_bin absolute path to the binary
-- @tparam string variant short name for logs/diagnostics (e.g. "native-pw2")
-- @treturn string|nil
function TTSEngine:_probeOneNativeGstPlay(native_bin, variant)
    local nf = io.open(native_bin, "r")
    if not nf then
        logger.dbg("TTSEngine: no bundled kindle/gst-play-" .. variant)
        return nil
    end
    nf:close()

    -- KinAMP-style launch: run the native binary PLAINLY under the system
    -- linker.  Its ELF interpreter is the device's system linker (not a
    -- nonexistent nix path like the compat binary), so bare execution works,
    -- and it dlopens libgstreamer-0.10 by absolute /usr/lib path -- no
    -- LD_LIBRARY_PATH needed (KinAMP doesn't add /usr/lib either).  Deliberately
    -- NO espeak-linker --library-path wrapper: that wrapper is what triggers the
    -- glibc mixing this variant exists to avoid.  Keeping it bare also avoids a
    -- double LD_LIBRARY_PATH= when the --ttssrc path prepends its own ivona_env.
    local native_cmd = native_bin

    local ph = io.popen(native_cmd .. " --probe 2>&1")
    if not ph then return nil end
    local probe = ph:read("*a") or ""
    ph:close()
    -- Retain the most recent probe output for the bug report.
    self._native_gst_play_probe = probe
    self._native_gst_play_variant = variant

    local has_plugin_error = probe:match("Failed to load plugin")
        or probe:match("undefined symbol")
        or probe:match("GStreamer%-WARNING")
    if has_plugin_error then
        logger.warn("TTSEngine: gst-play-" .. variant .. " probe found plugin load error:", probe:gsub("\n", " "))
        return nil
    end
    if not probe:match("mixersink=found") then
        logger.warn("TTSEngine: gst-play-" .. variant .. " probe lacks mixersink:", probe:gsub("\n", " "))
        return nil
    end

    -- Mirror the compat path's ttssrc detection so the native binary can also
    -- serve --ttssrc fallbacks on devices that expose it.
    if probe:match("ttssrc=found") then
        self._ttssrc_available = true
    elseif probe:match("ttssrc=broken") then
        self._ttssrc_broken = true
        if self.plugin then self.plugin:setSetting("_ttssrc_broken", true) end
    end

    -- Take 'Music' focus so mixersink -> audiomgrd -> BT has a sink, exactly as
    -- the compat path does before selecting kindle-gst-play.
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")

    self._kindle_gst_play_bin = native_cmd
    self._gst_play_variant = variant
    self.audio_player_type = "kindle-gst-play"
    self._no_real_audio_output = false
    logger.warn("TTSEngine: Selected kindle-gst-play " .. variant .. " variant (mixersink found), probe:",
        probe:gsub("\n", " "))
    return "kindle-gst-play"
end

-- @treturn string|nil "kindle-gst-play" if selected, nil otherwise
function TTSEngine:_probeNativeGstPlay()
    if not Device:isKindle() then return nil end
    -- NOTE: deliberately NOT gated on self._gst_play_broken.  That flag means
    -- the COMPAT (or system) gst-play pipeline hung during playback -- which is
    -- exactly the glibc-mixing failure this native variant exists to fix -- so
    -- suppressing native here would block the fallback on the devices that need
    -- it most.  (Safe: this helper only runs from _kindleRescueProbe, i.e. after
    -- _no_real_audio_output, so working devices never reach it.)
    local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")

    -- Try soft-float kindlepw2 binary first: PW2/PW3/PW4 on firmware < 5.16.3.
    local pw2_bin = plugin_dir .. "/kindle/gst-play-native-pw2"
    local selected = self:_probeOneNativeGstPlay(pw2_bin, "native-pw2")
    if selected then return selected end

    -- Fall back to hard-float kindlehf binary: PW4+ on firmware >= 5.16.3.
    local hf_bin = plugin_dir .. "/kindle/gst-play-native"
    selected = self:_probeOneNativeGstPlay(hf_bin, "native")
    if selected then return selected end

    return nil
end

function TTSEngine:_kindleRescueProbe()
    if not Device:isKindle() then return nil end
    logger.warn("TTSEngine: Kindle rescue probe starting (issue #32)")

    -- KinAMP-parity fallback FIRST: the native-glibc gst-play variant can reach
    -- mixersink on audio-less Kindles (PW4-class) where the compat gst-play
    -- crashes loading the device's old-glibc libgstmixersink.so through the
    -- bundled ld-linux.  Its --probe only checks the mixersink *factory*, which
    -- does NOT require audiomgrd to be running -- so it must run BEFORE the
    -- audiomgrd gate below (PW4 reports audiomgrd not running yet KinAMP, which
    -- uses the same native-linker path, still produces sound).
    local native = self:_probeNativeGstPlay()
    if native then return native end

    -- Check if audiomgrd is running
    local amgr_h = io.popen("pidof audiomgrd 2>/dev/null")
    local has_amgr = false
    if amgr_h then
        local pid = amgr_h:read("*a") or ""
        amgr_h:close()
        has_amgr = pid:match("%d")
    end
    if not has_amgr then
        logger.warn("TTSEngine: Rescue probe aborting — audiomgrd not running")
        return nil
    end

    -- Helper: try a focus value and check if output connects
    local function tryFocus(focus_val)
        os.execute("lipc-set-prop com.lab126.audiomgrd setFocus '" .. focus_val .. "' 2>/dev/null")
        os.execute("sleep 1 2>/dev/null || usleep 1000000 2>/dev/null")
        local h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
        if h then
            local v = h:read("*a") or ""
            h:close()
            if v:match("1") then
                logger.warn("TTSEngine: Rescue probe — setFocus='" .. focus_val .. "' made audioOutputConnected=1")
                return true
            end
        end
        return false
    end

    -- Sequence 1: setFocus tts
    if tryFocus("tts") then
        local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
        if h then
            local v = h:read("*a") or ""
            h:close()
            if v:match("^%s*1") then
                self.audio_player_type = "kindle-lipc"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Rescue probe selected kindle-lipc after setFocus=tts")
                return "kindle-lipc"
            end
        end
    end

    -- Sequence 2: setFocus playermgr
    if tryFocus("playermgr") then
        local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
        if h then
            local v = h:read("*a") or ""
            h:close()
            if v:match("^%s*1") then
                self.audio_player_type = "kindle-lipc"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Rescue probe selected kindle-lipc after setFocus=playermgr")
                return "kindle-lipc"
            end
        end
    end

    -- Sequence 3: setFocus com.lab126.playermgr
    if tryFocus("com.lab126.playermgr") then
        local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
        if h then
            local v = h:read("*a") or ""
            h:close()
            if v:match("^%s*1") then
                self.audio_player_type = "kindle-lipc"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Rescue probe selected kindle-lipc after setFocus=com.lab126.playermgr")
                return "kindle-lipc"
            end
        end
    end

    -- Sequence 4: Check if ALSA devices appeared after focus dance
    local aplay_h = io.popen("aplay -l 2>/dev/null")
    if aplay_h then
        local out = aplay_h:read("*a") or ""
        aplay_h:close()
        if not out:find("no soundcards") then
            local card, dev = out:match("card (%d+):.+device (%d+):")
            if card and dev then
                self.audio_player_type = "aplay"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Rescue probe found ALSA hw:" .. card .. "," .. dev)
                return "aplay -q -D hw:" .. card .. "," .. dev
            end
        end
    end

    -- Sequence 5: Check aplay -L for any non-default PCM
    local aL = io.popen("aplay -L 2>/dev/null")
    if aL then
        local out = aL:read("*a") or ""
        aL:close()
        for line in out:gmatch("([^\n]+)") do
            local name = line:match("^(%S+)$")
            if name and name ~= "default" and name ~= "null" then
                self.audio_player_type = "aplay"
                self._no_real_audio_output = false
                logger.warn("TTSEngine: Rescue probe found PCM:", name)
                return "aplay -q -D " .. name
            end
        end
    end

    -- Sequence 6: Try to wake up playermgr with an empty Open call
    os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    os.execute("lipc-set-prop com.lab126.playermgr Open '' 2>/dev/null")
    os.execute("sleep 1 2>/dev/null || usleep 1000000 2>/dev/null")
    local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
    if h then
        local v = h:read("*a") or ""
        h:close()
        if v:match("^%s*1") then
            self.audio_player_type = "kindle-lipc"
            self._no_real_audio_output = false
            logger.warn("TTSEngine: Rescue probe selected kindle-lipc after Open wake-up")
            return "kindle-lipc"
        end
    end

    logger.warn("TTSEngine: Kindle rescue probe exhausted — no audio path found")
    return nil
end

--- Diagnostic helper: log everything useful when gst-play fails.
-- Called when --ttssrc exits with 126/127 or when the bare-binary retry
-- also fails.  Captures file permissions, file type, memory state, and
-- direct execution smoke tests so the bug report explains WHY the OS
-- refused to run the binary (issue #35).
function TTSEngine:_diagnoseGstPlayFailure(cmd, log_file)
    logger.err("TTSEngine: ===== gst-play diagnostic block start =====")
    -- Extract the bare gst-play path from a wrapped command.
    local bare = cmd:match("(/%S-/gst%-play)$") or cmd
    logger.err("TTSEngine: diagnostic bare path:", bare)
    -- Binary existence and permissions
    local ls_h = io.popen("ls -l '" .. bare .. "' 2>&1")
    if ls_h then
        logger.err("TTSEngine: diagnostic ls:", ls_h:read("*a"):gsub("%s+$", ""))
        ls_h:close()
    end
    -- File type (architecture, static/dynamic) if `file` exists
    local file_h = io.popen("file '" .. bare .. "' 2>&1")
    if file_h then
        local ft = file_h:read("*a") or ""
        file_h:close()
        if ft:match("%S") then
            logger.err("TTSEngine: diagnostic file type:", ft:gsub("%s+$", ""))
        end
    end
    -- Memory state at time of failure
    local mem_h = io.popen("cat /proc/meminfo 2>/dev/null | grep -E 'MemFree|MemAvailable|Buffers'")
    if mem_h then
        logger.err("TTSEngine: diagnostic memory:", mem_h:read("*a"):gsub("%s+$", ""))
        mem_h:close()
    end
    -- Direct execution smoke test (bare binary, no text)
    local test_h = io.popen("'" .. bare .. "' --version 2>&1")
    if test_h then
        local test_out = test_h:read("*a") or ""
        test_h:close()
        logger.err("TTSEngine: diagnostic bare --version:", test_out:gsub("%s+$", ""))
    end
    -- Wrapped execution smoke test (same linker wrapper as real call)
    if cmd ~= bare then
        local wrap_h = io.popen(cmd .. " --version 2>&1")
        if wrap_h then
            local wrap_out = wrap_h:read("*a") or ""
            wrap_h:close()
            logger.err("TTSEngine: diagnostic wrapped --version:", wrap_out:gsub("%s+$", ""))
        end
    end
    -- Log contents from the failed run
    if log_file then
        local log_h = io.open(log_file, "r")
        if log_h then
            local log_text = log_h:read("*a") or ""
            log_h:close()
            if log_text ~= "" then
                logger.err("TTSEngine: diagnostic log:", log_text:sub(1, 500))
            end
        end
    end
    logger.err("TTSEngine: ===== gst-play diagnostic block end =====")
end

--- Check whether the Ivona EInk API library is available on the device.
-- ttssrc depends on libIvonaEInkAPI.so.1.0.  Newer Kindle firmware (e.g.
-- Kindle Basic 11th gen, KT5) ships the newer libtts_engine.so voice engine
-- but omits the old Ivona shared library, so ttssrc loads in --probe but
-- cannot create a real pipeline.  This helper detects that case so we can
-- fall back to WAV playback instead of a broken native TTS path.
function TTSEngine:_checkIvonaApiAvailable()
    -- KT5 firmware mounts /usr/lib/tts as a squashfs loop and places
    -- libIvonaEInkAPI.so.1.0 there.  The system linker finds it via
    -- /etc/ld.so.conf (which includes /usr/lib/tts), but the bundled
    -- ld-linux wrapper does not read ld.so.conf.  We must check the
    -- actual TTS library directory, not just standard paths.
    local paths = {
        "/usr/lib/tts/libIvonaEInkAPI.so.1.0",
        "/usr/lib/libIvonaEInkAPI.so.1.0",
        "/lib/libIvonaEInkAPI.so.1.0",
        "/system/lib/libIvonaEInkAPI.so.1.0",
        "/vendor/lib/libIvonaEInkAPI.so.1.0",
        "/mnt/base-us/lib/libIvonaEInkAPI.so.1.0",
    }
    for _, p in ipairs(paths) do
        local f = io.open(p, "r")
        if f then
            f:close()
            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 found at", p)
            return true
        end
        -- io.open may fail on binary files on some Kindle firmware even when
        -- the file exists (observed on KT5).  Use shell fallback.
        local rc = os.execute("test -f '" .. p .. "' 2>/dev/null")
        if rc == 0 or rc == true then
            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 found at", p, "(via test -f)")
            return true
        end
    end
    -- Also ask the dynamic linker if the dependency is resolvable.
    local ldd_h = io.popen("ldd /usr/lib/gstreamer-0.10/libgstttssrc.so 2>/dev/null | grep libIvonaEInkAPI")
    if ldd_h then
        local out = ldd_h:read("*a") or ""
        ldd_h:close()
        if out:find("=>") and not out:find("not found") then
            logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 resolved by ldd")
            return true
        end
    end
    logger.warn("TTSEngine: libIvonaEInkAPI.so.1.0 not found; ttssrc likely broken")
    return false
end

--- Probe whether the bundled gst-play can actually play a WAV file.
-- Generates a short silence WAV and runs it through gst-play with a timeout.
-- This is needed because --probe only reports element availability; on KT5
-- mixersink exists but ttssrc is broken, so we want to know if WAV playback
-- through mixersink works before selecting kindle-gst-play.
function TTSEngine:_probeKindleGstPlayWav(gst_play_cmd)
    local test_wav = "/tmp/.audiobook_gst_play_wav_test.wav"
    local ok = WavUtils.generateSilence(test_wav, 200, 22050)
    if not ok then
        logger.warn("TTSEngine: could not generate test WAV for gst-play probe")
        return false
    end

    -- Without audiomgrd focus on 'Music' the mixer never consumes the
    -- stream and the probe times out even when playback would work.
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")

    local probe_cmd = string.format(
        "timeout 3 %s '%s' 2>&1; echo rc=$?",
        gst_play_cmd, test_wav)
    local h = io.popen(probe_cmd)
    local out = h and h:read("*a") or ""
    if h then h:close() end
    os.remove(test_wav)

    local rc = tonumber(out:match("rc=(%d+)")) or 1
    logger.dbg("TTSEngine: gst-play WAV probe rc=", rc)

    -- rc 124 means timeout fired.  On some firmwares gst-play hangs in
    -- mixersink state change (missing audiomgrd focus or incompatible
    -- caps).  Do NOT treat timeout as success; a hung probe leads to a
    -- broken kindle-gst-play selection that fails on every sentence.
    if rc == 0 then
        logger.warn("TTSEngine: gst-play WAV probe succeeded")
        return true
    elseif rc == 124 then
        logger.warn("TTSEngine: gst-play WAV probe timed out (hung?)")
    end

    local has_plugin_error = out:match("Failed to load plugin")
        or out:match("undefined symbol")
        or out:match("GStreamer%-WARNING")
        or out:match("pipeline creation failed")
    if has_plugin_error then
        logger.warn("TTSEngine: gst-play WAV probe found plugin/symbol error:",
            out:gsub("\n", " "))
    else
        logger.warn("TTSEngine: gst-play WAV probe failed, rc=", rc,
            "out=", out:gsub("\n", " "))
    end
    return false
end

--- Probe the bundled kindle/gst-play helper candidates and return the first
--- command whose --probe reports mixersink=found, or nil.
--- Mirrors MediaEngine:_detectKindleGstPlay (which runs without any playermgr
--- gate and is why music playback works on PW4-class Kindles whose playermgr
--- never answers InPlayback, issue #28): bare compat binary, linker-wrapped
--- compat binary, then the native-glibc KinAMP-parity builds (soft-float pw2
--- first, hard-float last).
-- @treturn string|nil working gst-play command prefix, nil if none probe OK
function TTSEngine:_probeKindleGstPlayBin()
    local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or ".")
    local gst_play_bin = plugin_dir .. "/kindle/gst-play"
    local candidates = {}
    local gf = io.open(gst_play_bin, "r")
    if gf then
        gf:close()
        table.insert(candidates, gst_play_bin)
        if self.espeak_linker then
            table.insert(candidates, string.format(
                "%s --library-path %s:/usr/lib/tts:/usr/lib:/lib %s",
                self.espeak_linker, self.espeak_lib_path, gst_play_bin))
        end
    end
    for _, native_bin in ipairs({
        plugin_dir .. "/kindle/gst-play-native-pw2",
        plugin_dir .. "/kindle/gst-play-native",
    }) do
        local nf = io.open(native_bin, "r")
        if nf then
            nf:close()
            table.insert(candidates, native_bin)
        end
    end
    for _, cand in ipairs(candidates) do
        local ph = io.popen(cand .. " --probe 2>&1")
        if ph then
            local probe = ph:read("*a") or ""
            ph:close()
            if probe:match("mixersink=found")
                and not probe:match("mixersink=broken")
                and not probe:match("gstreamer=not_found") then
                logger.warn("TTSEngine: gst-play probe OK:", cand)
                return cand
            end
            logger.dbg("TTSEngine: gst-play probe failed:", cand, "->", probe:gsub("\n", " "):sub(1, 120))
        end
    end
    return nil
end

--- Keep the Kindle A2DP datapath alive between sentences.
-- audiomgrd suspends the BT datapath whenever the mixer goes idle, and the
-- resume after the next sentence attaches takes a randomly-varying few
-- hundred ms that swallows the start of the utterance (silence padding
-- alone proved unreliable).  Parking an infinite silence stream
-- (filesrc /dev/zero ! mixersink) in the mixer for the whole reading
-- session keeps the datapath up so sentence streams start instantly.
-- Verified on PW5: zero suspend_audio_datapath events while running.
function TTSEngine:_ensureKindleKeepalive()
    if self._keepalive_pid then
        local f = io.open("/proc/" .. self._keepalive_pid .. "/status", "r")
        if f then f:close() return end
        self._keepalive_pid = nil
    end
    -- Take focus ONCE here, not per sentence: every setFocus makes
    -- audiomgrd re-ramp gain to its stored level, which yanked the
    -- headset volume back up on every sentence boundary.
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")
    local h = io.popen(
        "gst-launch-0.10 filesrc location=/dev/zero"
        .. " ! 'audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234'"
        .. " ! mixersink stream-type=Music sync=true >/dev/null 2>&1 & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._keepalive_pid = tonumber(pid_str:match("(%d+)"))
    logger.warn("TTSEngine: kindle A2DP keepalive started, PID=", self._keepalive_pid)
end

function TTSEngine:_stopKindleKeepalive()
    if self._keepalive_pid then
        os.execute("kill " .. self._keepalive_pid .. " 2>/dev/null")
        self._keepalive_pid = nil
        logger.warn("TTSEngine: kindle A2DP keepalive stopped")
    end
end

--- Convert a WAV file to raw PCM and launch system gst-launch-0.10.
-- Some Kindle firmwares (e.g. KT5 5.17.1.0.3) have a working system
-- gst-launch-0.10 but the bundled gst-play helper hangs.  This fallback
-- strips the WAV header and feeds raw S16LE PCM directly to mixersink.
-- @param wav_file string  Path to the source WAV file
-- @return number|nil  PID of the background gst-launch process, or nil on failure
-- @return string|nil  Path to the generated raw PCM file (caller must clean up)
function TTSEngine:_trySystemGstLaunch(wav_file)
    if not self:commandExists("gst-launch-0.10") then
        logger.warn("TTSEngine: system gst-launch-0.10 not available")
        return nil, nil
    end
    if not self:commandExists("dd") then
        logger.warn("TTSEngine: dd not available, cannot strip WAV header")
        return nil, nil
    end

    -- Read WAV header to get format details
    local fh = io.open(wav_file, "rb")
    if not fh then
        logger.warn("TTSEngine: cannot open WAV file for system gst-launch fallback:", wav_file)
        return nil, nil
    end

    -- Read first 44 bytes (standard PCM WAV header)
    local header = fh:read(44)
    fh:close()

    if not header or #header < 44 then
        logger.warn("TTSEngine: WAV file too short for system gst-launch fallback")
        return nil, nil
    end

    -- Verify RIFF/WAVE signature
    if header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        logger.warn("TTSEngine: not a valid WAV file for system gst-launch fallback")
        return nil, nil
    end

    -- Parse header fields (little-endian)
    local function le_u16(offset)
        return string.byte(header, offset) + string.byte(header, offset + 1) * 256
    end
    local function le_u32(offset)
        return string.byte(header, offset)
            + string.byte(header, offset + 1) * 256
            + string.byte(header, offset + 2) * 65536
            + string.byte(header, offset + 3) * 16777216
    end

    local channels = le_u16(23)
    local rate = le_u32(25)
    local bits = le_u16(35)

    logger.warn("TTSEngine: system gst-launch fallback WAV format:",
        "rate=", rate, "channels=", channels, "bits=", bits)

    -- Generate raw PCM file by stripping header
    local raw_file = "/tmp/.abgst_system_" .. os.time() .. ".raw"
    -- Build the raw PCM file as: 0.25 s silence + payload + 0.3 s silence.
    -- The A2DP keepalive stream (_ensureKindleKeepalive) keeps the mixer
    -- and BT datapath running between sentences, so these pads only need
    -- to cover scheduling jitter, not the full datapath resume (~0.5 s)
    -- and ring/BT drain (~1 s) they previously absorbed.
    -- (bs=44 skip=1 skips exactly the 44-byte header in one block-sized
    -- step; bs=1 skip=44 would copy byte-by-byte, ~1000x slower here.)
    -- Pad sizes MUST be whole frames (channels * bytes-per-sample): an odd
    -- byte count shifts every following 16-bit sample by one byte and the
    -- payload comes out as white noise (pad_bytes/4 at 22050 Hz mono was
    -- 11025 bytes — odd).
    local frame_bytes = channels * math.floor(bits / 8)
    local lead_bytes = math.floor(rate / 4) * frame_bytes   -- ~0.25 s
    -- Full second of tail: the shm ring holds up to ~0.9 s when the
    -- pipeline tears down at EOS and its fill level varies, so a shorter
    -- pad clips the ending intermittently even with the keepalive up.
    local tail_bytes = rate * frame_bytes                   -- 1 s
    local dd_cmd = string.format(
        "( dd if=/dev/zero bs=%d count=1 2>/dev/null;"
        .. " dd if='%s' bs=44 skip=1 2>/dev/null;"
        .. " dd if=/dev/zero bs=%d count=1 2>/dev/null ) > '%s'",
        lead_bytes,
        wav_file:gsub("'", "'\\''"),
        tail_bytes,
        raw_file:gsub("'", "'\\''"))
    local dd_rc = os.execute(dd_cmd)
    if dd_rc ~= 0 and dd_rc ~= true then
        logger.warn("TTSEngine: dd failed to strip WAV header, rc=", dd_rc)
        os.remove(raw_file)
        return nil, nil
    end

    -- Build gst-launch-0.10 command with proper caps
    local caps = string.format(
        "audio/x-raw-int,endianness=1234,signed=true,width=%d,depth=%d,rate=%d,channels=%d",
        bits, bits, rate, channels)
    -- Sweep shared-memory stream files left behind by pipelines that were
    -- killed mid-play (pause/stop sends SIGTERM and gst-launch does not
    -- always close its mixer stream).  Only files whose creator PID is dead
    -- are removed; audiomgrd's own live streams are untouched.
    os.execute("for f in /dev/shm/mstream*; do p=${f#/dev/shm/mstream}; p=${p%%_*};"
        .. " [ -d /proc/$p ] || rm -f \"$f\"; done 2>/dev/null")

    -- mixersink needs stream-type=Music (the only playback type audiomgrd
    -- accepts) and sync=true: with the element's default sync=false the
    -- commit vfunc is handed mismatched in/out sample counts, rejects every
    -- buffer ("MixerSink:Commit:in != out" in syslog) and the pipeline hangs
    -- silently.  Focus is NOT set here: it is taken once per session by
    -- the keepalive (per-sentence setFocus re-ramped gain and reset the
    -- headset volume); new streams inherit it from audiomgrd's focus cache.
    local gst_log = "/tmp/.gst_system_last.log"
    local cmd = string.format(
        "gst-launch-0.10 filesrc location='%s' ! capsfilter caps='%s' ! mixersink stream-type=Music sync=true >%s 2>&1 & echo $!",
        raw_file:gsub("'", "'\\''"), caps, gst_log)

    local h = io.popen(cmd)
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    local pid = tonumber(pid_str:match("(%d+)"))

    if pid then
        logger.warn("TTSEngine: system gst-launch-0.10 fallback launched, PID=", pid,
            "rate=", rate, "channels=", channels)
        return pid, raw_file
    else
        logger.warn("TTSEngine: system gst-launch-0.10 fallback failed to launch")
        os.remove(raw_file)
        return nil, nil
    end
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
    local sr = self._pipeline_sample_rate or 22050
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
# sync=false — let the BT A2DP hardware clock control the playback rate
# via socket backpressure, instead of GStreamer's pipeline clock.
# This is CRITICAL for SIGSTOP/SIGCONT pause/resume: with sync=true,
# CLOCK_MONOTONIC advances during SIGSTOP but audio timestamps don't,
# so GStreamer sees all buffered audio as "late" on SIGCONT and plays
# it in a burst (causing choppy audio on the first sentence after
# unpause).  With sync=false there is no clock to go stale.
# The Lua caller shrinks the pipe buffer to 16KB via
# fcntl(F_SETPIPE_SZ) to reduce latency while keeping enough headroom
# to absorb CPU stalls during Piper synthesis.
gst-launch-1.0 filesrc location="$FIFO" \
  ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=1 \
  ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! queue max-size-time=500000000 max-size-bytes=131072 \
  ! mtkbtmwrpcaudiosink sync=false >/dev/null 2>"$CTRL/pipeline_stderr" &
GST_PID=$!
# Open FIFO write end — keeps it alive between individual writes.
# This BLOCKS until gst-launch opens the read end (filesrc start).
exec 3>"$FIFO"
# Signal Lua AFTER the FIFO is fully set up (both ends open).
# Lua uses the gst_pid file as a "ready" indicator before trying to
# open(O_WRONLY|O_NONBLOCK) on the FIFO for pipe buffer resize.
echo $GST_PID > "$CTRL/gst_pid"
cleanup() { exec 3>&- 2>/dev/null; kill $GST_PID 2>/dev/null; rm -f "$FIFO" "$CTRL/s.raw" "$CTRL/gst_pid" "$CTRL/pipeline_stderr"; }
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
Check stderr output from a failed MTK pipeline for fatal firmware errors
that indicate a permanent (not transient) failure.  When a fatal error is
detected, the retry count is set to MAX so no further attempts are made.
@param stderr string  Stderr output from gst-launch or the pipeline script
--]]
function TTSEngine:_checkMtkPipelineError(stderr)
    if not stderr or stderr == "" then return false end
    for _, pattern in ipairs(MTK_FATAL_ERRORS) do
        if stderr:find(pattern, 1, true) then  -- plain string match (no regex)
            logger.err("TTSEngine: FATAL MTK firmware error detected:", pattern)
            self._pipeline_retry_count = MAX_PIPELINE_RETRIES  -- skip remaining retries
            self.player_error = "bt_firmware_missing"
            -- Also set a persistent flag so the sync controller can check it
            -- and stop playback gracefully instead of re-triggering the error
            -- on every page turn.
            self._bt_fw_fatal_error = true
            return true
        end
    end
    return false
end

--[[--
Get a diagnostic time-based string for the pipeline stderr file.
The pipeline script writes its stderr to a file; this method reads it.
@return string  Stderr content, empty string on error
--]]
function TTSEngine:_readPipelineStderr()
    local log_file = PIPELINE_CTRL_DIR .. "/pipeline_stderr"
    local f = io.open(log_file, "r")
    if not f then return "" end
    local content = f:read("*a") or ""
    f:close()
    return content
end

--[[--
Start the persistent BT audio pipeline.
Creates the feeder script, launches it (piping silence/audio to gst-launch
via a named FIFO), and waits for gst-launch to initialise.
@return boolean true if pipeline started successfully
--]]
function TTSEngine:_startPersistentPipeline()
    -- ── Retry cooldown and limit check ─────────────────────────
    -- Avoid rapid retry loops that can corrupt the flash filesystem
    -- on Kobo MTK devices when the Bluetooth firmware is missing.
    if self._bt_fw_fatal_error then
        logger.err("TTSEngine: Persistent pipeline blocked — fatal MTK firmware error detected in a previous attempt")
        self:_showMtkFirmwareError()
        self.player_error = "bt_firmware_missing"
        return false
    end

    if self._pipeline_last_fail_time then
        local elapsed = os.time() - self._pipeline_last_fail_time
        if elapsed < PIPELINE_RETRY_COOLDOWN_S then
            logger.warn("TTSEngine: Pipeline retry cooldown active,",
                        "wait", PIPELINE_RETRY_COOLDOWN_S - elapsed, "more seconds (elapsed=", elapsed, ")")
            return false
        end
    end

    if (self._pipeline_retry_count or 0) >= MAX_PIPELINE_RETRIES then
        logger.err("TTSEngine: Max pipeline retries reached (",
                    MAX_PIPELINE_RETRIES, "), giving up")
        self.player_error = "bt_firmware_missing"
        return false
    end

    self:_stopPersistentPipeline("restart")

    -- Verify the mtkbtmwrpc socket is actually free before starting.
    -- An orphan gst-launch from a crashed/previous session can hold it.
    -- The killall in _stopPersistentPipeline should have freed it, but
    -- the kernel needs a moment to tear down the abstract socket.
    for attempt = 1, 5 do
        local pf = io.open("/proc/net/unix", "r")
        if pf then
            local content = pf:read("*a")
            pf:close()
            if not content:find("@kobo:mtkbtmwrpc") then
                break  -- socket is free
            end
            logger.warn("TTSEngine: mtkbtmwrpc socket still held, attempt",
                attempt, "— waiting 200ms")
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            os.execute("usleep 200000")
        else
            break  -- can't check, proceed anyway
        end
    end

    -- Configure pipeline for the actual sample rate of the audio we'll play.
    -- MBROLA voices (e.g. 16000 Hz) differ from espeak-ng default (22050 Hz).
    -- Using the wrong rate causes audio to play at wrong speed and breaks
    -- word-highlighting sync.
    self._pipeline_sample_rate = self._target_sample_rate or 22050
    logger.dbg("TTSEngine: Starting persistent pipeline at",
        self._pipeline_sample_rate, "Hz")
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
    for iter = 1, 60 do  -- 60 × 50ms = 3s
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
    local sr = self._pipeline_sample_rate or 22050
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

    if gst_pid then
        logger.warn("TTSEngine: Persistent pipeline started, wrapper=",
            self._pipeline_wrapper_pid, "gst=", self._pipeline_gst_pid)
        -- Pipeline started successfully — reset retry count
        self._pipeline_retry_count = 0
        self._pipeline_last_fail_time = nil
        return true
    end

    -- Pipeline failed to start — increment retry count and check for
    -- fatal MTK firmware errors in the pipeline stderr log.
    self._pipeline_retry_count = (self._pipeline_retry_count or 0) + 1
    self._pipeline_last_fail_time = os.time()
    logger.warn("TTSEngine: Pipeline failed to start (retry",
                self._pipeline_retry_count, "/", MAX_PIPELINE_RETRIES, ")")

    -- Check stderr for fatal MTK firmware errors
    local stderr = self:_readPipelineStderr()
    if stderr ~= "" then
        logger.warn("TTSEngine: Pipeline stderr:", stderr:sub(1, 500))
        self:_checkMtkPipelineError(stderr)
    end

    if self._bt_fw_fatal_error then
        self:_showMtkFirmwareError()
    end

    return false
end

--[[--
Stop the persistent BT audio pipeline.
Kills the feeder script and gst-launch, cleans up the FIFO.
@param reason string  Caller identification for diagnostic logging
--]]
function TTSEngine:_stopPersistentPipeline(reason)
    reason = reason or "unknown"
    logger.warn("TTSEngine: _stopPersistentPipeline, reason=", reason,
        "gst_pid=", self._pipeline_gst_pid)
    -- Signal feeder to stop (harmless if no feeder is running)
    local sf = io.open(PIPELINE_CTRL_DIR .. "/stop", "w")
    if sf then sf:write("1"); sf:close() end
    -- Kill tracked processes
    if self._pipeline_gst_pid then
        os.execute("kill -9 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    end
    if self._pipeline_wrapper_pid then
        os.execute("kill -9 " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
    end
    -- Also read gst PID from file in case Lua state was lost (crash/restart).
    -- This catches orphans whose PIDs we no longer track in memory.
    local gst_pf = io.open(PIPELINE_CTRL_DIR .. "/gst_pid", "r")
    if gst_pf then
        local file_pid = gst_pf:read("*a"):gsub("%s+", "")
        gst_pf:close()
        if file_pid ~= "" and tonumber(file_pid) ~= self._pipeline_gst_pid then
            os.execute(string.format("kill -9 %s 2>/dev/null", file_pid))
            logger.warn("TTSEngine: Killed orphan gst from PID file:", file_pid)
        end
    end
    -- Kill orphan feeder wrapper shells that Lua state doesn't track.
    -- These are /bin/sh processes not caught by killall gst-launch-1.0.
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")
    -- ALWAYS kill orphan gst-launch processes.  On Kobo, the
    -- mtkbtmwrpcaudiosink binds an exclusive abstract socket
    -- (@kobo:mtkbtmwrpc).  If ANY gst-launch holds it — even an
    -- orphan from a previous KOReader session or an SSH test — the
    -- new pipeline fails with "Address already in use".
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
    -- Kill the feeder wrapper shell too — if Lua lost track of its PID
    -- (crash / restart), it becomes orphaned under init (PID 1).
    os.execute("pkill -9 -f 'audiobook_pipeline\\.sh' 2>/dev/null")
    -- Brief wait for the kernel to release the abstract socket
    -- after SIGKILL.  Without this, the bind() in the new pipeline
    -- can race against socket teardown.
    if self._persistent_pipeline then
        os.execute("usleep 200000")
    end
    -- Clean up
    os.execute("rm -f " .. PIPELINE_FIFO .. " " .. PIPELINE_CTRL_DIR .. "/gst_pid" .. " " .. PIPELINE_CTRL_DIR .. "/pipeline_stderr")
    self._pipeline_gst_pid = nil
    self._pipeline_wrapper_pid = nil
    self._persistent_pipeline = false
    self.audio_pid = nil
    self._socket_clean = false
    logger.warn("TTSEngine: Persistent pipeline stopped, reason=", reason)
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
        -- If the audio sample rate changed (e.g. switching from espeak 22050Hz
        -- to MBROLA 16000Hz), the pipeline must be restarted with the new rate
        -- or rawaudioparse will play audio at the wrong speed.
        if self._target_sample_rate and self._pipeline_sample_rate
                and self._target_sample_rate ~= self._pipeline_sample_rate then
            logger.warn("TTSEngine: Sample rate changed from",
                self._pipeline_sample_rate, "to", self._target_sample_rate,
                "Hz — restarting pipeline")
            self:_stopPersistentPipeline("rate_change")
        else
            return true
        end
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
    -- Use /proc test instead of spawning a shell on every poll.
    -- This avoids fork+exec overhead on single-core ARM devices
    -- where it can add up with 100ms polling intervals.
    local f = io.open("/proc/" .. self.audio_pid .. "/stat", "r")
    if f then
        f:close()
        return true
    end
    return false
end

--[[--
True when the effective PocketBook playback route goes through the audio
daemon (tts_sm or hwout_mix, including the session-sticky crash fallback).
These routes feed the dmix/Loopback the daemon reads, never touch hw:0 or
the mixer (the two damage classes the pre-flight protects against), and are
the routes PocketBook's own TTS uses with or without Bluetooth.
--]]
function TTSEngine:_pbDaemonRouted()
    local prefix = self._wav_play_force_prefix
    if prefix then
        return prefix:find("hwout_mix") ~= nil or prefix:find("tts_sm") ~= nil
    end
    local dev = self._wav_play_device
    return dev == "tts_sm" or dev == "hwout_mix"
end

--[[--
Next wav-play crash fallback (issue #49).  Returns {desc=, suffix=} for the
next attempt, or nil when the ladder is exhausted.  The suffix is appended
to _wav_play_base_cmd (which ends in --no-mixer, with no -D) and carries a
device selection plus software-conversion flags.

Stage 1 converts in software to 48000 Hz stereo on the SAME device, which
matches the fixed dmix config that PocketBook's tts_sm chain ends in.
Stages 2-3 target the daemon-routed dmix (hwout_mix) directly, skipping
the nested plug+softvol refinement that aborts inside alsa-lib on some
PocketBook firmware even at native parameters.
--]]
function TTSEngine:_nextWavPlayRetry()
    if not self._wav_play_base_cmd then return nil end
    local conv = "--rate 48000 --channels 2"
    local stage = (self._wav_play_retry_stage or 0) + 1
    local suffix, desc
    if stage == 1 then
        local dev = self._wav_play_device
        suffix = (dev and (" -D " .. dev) or "") .. " " .. conv
        desc = "software conversion to 48000 Hz stereo"
    elseif stage == 2 and self._pb_has_hwout_mix then
        suffix = " -D hwout_mix " .. conv
        desc = "daemon-routed dmix (hwout_mix) + conversion"
    elseif stage == 3 and self._pb_has_hwout_mix then
        suffix = " -D plug:hwout_mix " .. conv
        desc = "plug:hwout_mix + conversion"
    end
    if not suffix then
        self._wav_play_retry_stage = 0
        return nil
    end
    self._wav_play_retry_stage = stage
    return { desc = desc, suffix = suffix }
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
function TTSEngine:_startProcessWatcher(bt_retry_allowed, skip_on_fail, conv_retried)
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
            -- Hard timeout: if the process has been running for more than
            -- 3x the expected duration (min 30s), it is likely hung (e.g.,
            -- snd_pcm_writei blocked because ALSA state is corrupted).
            -- Force-kill it so the reading chain doesn't stall forever.
            local elapsed_ms = time.to_ms(UIManager:getTime() - launch_time)
            local expected = engine._expected_play_duration_ms or 5000
            local hard_timeout_ms = math.max(30000, expected * 3)
            if elapsed_ms > hard_timeout_ms then
                logger.err("TTSEngine: Process watcher hard timeout after",
                    elapsed_ms, "ms (expected", expected, "ms), force-killing PID",
                    engine.audio_pid)
                engine:_killAudioProcess()
                engine:onPlaybackComplete()
                return
            end
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
                -- Crash detection: a player that dies on an ALSA assertion
                -- or abort still exits "naturally" from the process table's
                -- point of view, so without this check a crashing player
                -- looks like normal completion and the book keeps "reading"
                -- silently (PocketBook tts_sm empty-interval assertion).
                local player_stderr = nil
                if engine._gst_status_file then
                    local sf = io.open(engine._gst_status_file, "r")
                    if sf then
                        player_stderr = sf:read("*a") or ""
                        sf:close()
                    end
                end
                local crashed = player_stderr and (
                    player_stderr:find("Assertion")
                    or player_stderr:find("assert failed")
                    or player_stderr:find("Segmentation")
                    or player_stderr:find("Aborted"))

                -- wav-play crash: walk the session fallback ladder
                -- (conversion first, then daemon-routed dmix devices that
                -- bypass the crashing plug refinement entirely; issue #49).
                if crashed and engine.audio_player_type == "aplay"
                        and engine._wav_play_base_cmd
                        and engine.current_audio_file then
                    local retry = engine:_nextWavPlayRetry()
                    if retry then
                        logger.err("TTSEngine: wav-play crashed (",
                            player_stderr:match("Assertion[^\n]*") or "assertion/abort",
                            ") — retrying:", retry.desc)
                        os.remove(engine._gst_status_file)
                        engine._wav_play_retry_prefix =
                            engine._wav_play_base_cmd .. retry.suffix
                        local retry_pid_cmd = string.format(
                            '%s "%s" >/dev/null 2>>%s & echo $!',
                            engine._wav_play_retry_prefix, engine.current_audio_file,
                            engine._gst_status_file)
                        engine._last_pid_cmd = retry_pid_cmd
                        local handle = io.popen(retry_pid_cmd)
                        local pid_str = handle and handle:read("*a") or ""
                        if handle then handle:close() end
                        engine.audio_pid = tonumber(pid_str:match("(%d+)"))
                        engine._audio_launched_at = UIManager:getTime()
                        engine:_startProcessWatcher(bt_retry_allowed, skip_on_fail, true)
                        return
                    end
                end

                if crashed then
                    engine._player_crash_count = (engine._player_crash_count or 0) + 1
                    logger.err("TTSEngine: audio player crashed (count:",
                        engine._player_crash_count, "), stderr:",
                        player_stderr:sub(1, 300))
                    if engine._player_crash_count >= 3 then
                        engine._player_crash_count = 0
                        engine.is_speaking = false
                        engine.audio_pid = nil
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        UIManager:show(InfoMessage:new{
                            text = _("The audio player keeps crashing, playback was stopped.")
                                .. "\n\n" .. _("Last error:") .. " "
                                .. player_stderr:sub(1, 200)
                                .. "\n\n" .. _("Please generate a bug report (Audiobook > Generate bug report) and share it on GitHub."),
                            timeout = 12,
                        })
                        if engine.on_fail_callback then
                            engine.on_fail_callback()
                        end
                        return
                    end
                    -- Skip this sentence; the chain continues and the next
                    -- sentence may succeed (or the counter escalates).
                    engine:onPlaybackComplete()
                    return
                end

                -- Normal completion (process streamed successfully then exited)
                -- Detect rapid failure: if aplay exits in < 200ms and we have
                -- no real audio output (no soundcard), this is likely an instant
                -- failure.  Track consecutive rapid exits and bail out to prevent
                -- a runaway loop that freezes single-core devices.
                local RAPID_EXIT_MS = 200
                local is_kindle_dev = Device:isKindle()
                local is_pb_dev = engine:isPocketBook()
                if elapsed_ms < RAPID_EXIT_MS and (engine._no_real_audio_output or is_kindle_dev or is_pb_dev) then
                    engine._rapid_fail_count = (engine._rapid_fail_count or 0) + 1
                    logger.warn("TTSEngine: rapid audio exit (" .. elapsed_ms
                        .. "ms), no soundcard — count:", engine._rapid_fail_count)
                    if engine._rapid_fail_count >= 3 then
                        logger.err("TTSEngine: 3 consecutive rapid audio failures — "
                            .. "no audio output available, stopping playback")
                        engine.is_speaking = false
                        engine.audio_pid = nil
                        engine.play_generation = (engine.play_generation or 0) + 1
                        engine:cleanup()
                        engine._rapid_fail_count = 0
                        -- Capture last stderr for the message
                        local stderr_hint = ""
                        if engine._gst_status_file then
                            local sf = io.open(engine._gst_status_file, "r")
                            if sf then
                                local out = sf:read("*a") or ""; sf:close()
                                out = out:match("^%s*(.-)%s*$") or out
                                if out ~= "" then
                                    stderr_hint = "\n\nLast error: " .. out:sub(1, 200)
                                end
                            end
                        end
                        local msg
                        if is_kindle_dev then
                            msg = _("No audio output available.\n\nKindle has no built-in speaker. Audio needs Bluetooth headphones connected via Kindle Settings.\n\nThe Kindle audio subsystem did not expose a usable ALSA device. Please generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue -- it will help identify the correct audio path for this Kindle model.")
                        elseif is_pb_dev then
                            msg = _("No audio output available.\n\nThe audio player exited immediately. Please check that a playback device is available (speaker or Bluetooth headphones)." .. stderr_hint .. "\n\nIf this persists, generate a bug report (Audiobook > Generate bug report) and share it on the GitHub issue.")
                        else
                            msg = _("No audio output available.\n\nThis device has no built-in speaker. Please connect a Bluetooth audio device first:\n\n1. Go to Audiobook > Bluetooth settings > Bluetooth\n2. Turn Bluetooth on\n3. Scan and pair your headphones/speaker\n4. Then start read-along again.")
                        end
                        UIManager:show(InfoMessage:new{
                            text = msg,
                            timeout = 12,
                        })
                        if engine.on_fail_callback then
                            engine.on_fail_callback()
                        end
                        return
                    end
                else
                    -- Successful playback (or at least not instant failure)
                    engine._rapid_fail_count = 0
                    engine._player_crash_count = 0
                end
                logger.warn("TTSEngine: Process watcher → normal completion, elapsed=", elapsed_ms, "ms")

                -- A crash-retry that played to completion becomes the
                -- working command for the rest of the session (issue #49).
                if engine._wav_play_retry_prefix then
                    engine._wav_play_force_prefix = engine._wav_play_retry_prefix
                    engine._wav_play_retry_prefix = nil
                    engine._wav_play_retry_stage = 0
                    logger.warn("TTSEngine: crash fallback works, keeping it for this session")
                end

                -- Capture wav-play / gst-play stderr for diagnostics
                if engine._gst_status_file then
                    local sf = io.open(engine._gst_status_file, "r")
                    if sf then
                        local stderr_out = sf:read("*a") or ""
                        sf:close()
                        if stderr_out ~= "" then
                            logger.warn("TTSEngine: player stderr:", stderr_out:sub(1, 500))
                        end
                    end
                end

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
    local elapsed_ms = 0
    if self._audio_launched_at then
        elapsed_ms = time.to_ms(UIManager:getTime() - self._audio_launched_at)
    end
    logger.dbg("TTSEngine: onPlaybackComplete gen=", self.play_generation,
        "pid=", self.audio_pid, "elapsed=", elapsed_ms, "ms",
        "expected=", self._expected_play_duration_ms or 0, "ms")
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
Send a signal to a tracked pipeline PID, but only if the process is
still alive.  Prevents signalling a stale PID after a crash or restart.
--]]
function TTSEngine:_pipelineSignal(pid, sig)
    if not pid then return false end
    local ok = os.execute("kill -0 " .. pid .. " 2>/dev/null")
    if ok == 0 or ok == true then
        os.execute("kill -" .. sig .. " " .. pid .. " 2>/dev/null")
        return true
    end
    return false
end

--[[--
Pause playback.
--]]
function TTSEngine:pause()
    if self.is_speaking and not self.is_paused then
        self.is_paused = true
        self.pause_time = UIManager:getTime()
        -- Android: pause via MediaPlayer API
        if self.audio_player_type == "android" and self._android_tts then
            self._android_tts:pausePlayback()
        -- PocketBook InkView: no direct pause API; audio plays to natural
        -- end but word-highlighting and sentence advance are suspended.
        elseif self.audio_player_type == "pb-inkview" then
            -- no-op: timing loop checks is_paused
        -- Kindle LIPC: pause via playermgr
        elseif self.audio_player_type == "kindle-lipc" then
            os.execute("lipc-set-prop com.lab126.playermgr Pause '' 2>/dev/null")
        -- Freeze only gst-launch (SIGSTOP).  The wrapper shell script is
        -- left running so it stays blocked on the FIFO; this prevents the
        -- MTK BT sink from seeing a full underrun, which causes stutter
        -- on resume.  With the wrapper alive the FIFO stays primed with
        -- data and the MTK A2DP connection remains in a stable state.
        elseif self._persistent_pipeline then
            if self:_pipelineSignal(self._pipeline_gst_pid, "STOP") then
                logger.warn("TTSEngine: Paused persistent pipeline, gst=",
                    self._pipeline_gst_pid)
            else
                logger.warn("TTSEngine: Pause failed — gst-launch dead, clearing pipeline")
                self._persistent_pipeline = false
                self._pipeline_gst_pid = nil
                self._pipeline_wrapper_pid = nil
            end
        elseif self.audio_pid then
            os.execute("kill -STOP " .. self.audio_pid .. " 2>/dev/null")
        end
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
        local pause_ms = time.to_ms(pause_duration)
        self.playback_start_time = self.playback_start_time + pause_duration
        -- Accumulate total pause time so the completion timer knows how
        -- much real playback time has actually elapsed.
        self._total_pause_ms = (self._total_pause_ms or 0) + pause_ms
        -- Android: resume via MediaPlayer API
        if self.audio_player_type == "android" and self._android_tts then
            self._android_tts:resumePlayback()
        -- PocketBook InkView: no direct resume API; timing loop resumes
        -- automatically when is_paused is cleared above.
        elseif self.audio_player_type == "pb-inkview" then
            -- no-op
        -- Kindle LIPC: resume via playermgr
        elseif self.audio_player_type == "kindle-lipc" then
            os.execute("lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null")
        -- Unfreeze only gst-launch (SIGCONT).  The wrapper was never
        -- frozen, so it is already blocked on the FIFO; as soon as
        -- gst-launch resumes reading the audio flows again seamlessly.
        elseif self._persistent_pipeline then
            if self:_pipelineSignal(self._pipeline_gst_pid, "CONT") then
                logger.warn("TTSEngine: Resumed persistent pipeline, pause was",
                    pause_ms, "ms, total_pause=", self._total_pause_ms, "ms")
            else
                logger.warn("TTSEngine: Resume failed — gst-launch dead, will restart on next play()")
                self._persistent_pipeline = false
                self._pipeline_gst_pid = nil
                self._pipeline_wrapper_pid = nil
            end
        elseif self.audio_pid then
            os.execute("kill -CONT " .. self.audio_pid .. " 2>/dev/null")
        end
        -- Restart the timing loop (it exited when is_paused was true)
        self:_runTimingLoop()
    end
end

--[[--
Stop playback.
--]]
function TTSEngine:stop()
    -- Always bump generation and clear state, even if not speaking.
    -- This ensures stale scheduled callbacks (launchAndStart, checkProcess,
    -- updateTiming) exit immediately regardless of what state we were in.
    logger.dbg("TTSEngine: stop(), is_speaking=", self.is_speaking,
        "persistent=", self._persistent_pipeline)
    -- End of the reading session: stop streaming keepalive silence so the
    -- BT datapath can suspend and save battery.
    self:_stopKindleKeepalive()
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

    -- Stop Android pipeline/MediaPlayer if active
    if self.audio_player_type == "android" and self._android_tts then
        self._android_tts:stopPipeline()
    end

    -- Stop PocketBook InkView player: play a zero-length path to halt
    -- the current file.  The generation bump above + completion timer
    -- cancellation prevent any further sentence advance.
    if self.audio_player_type == "pb-inkview" and _inkview_audio then
        pcall(_inkview_audio.PlayFile, "")
    end

    -- Stop Kindle LIPC playermgr if active
    if self.audio_player_type == "kindle-lipc" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    -- Stop kindle-gst-play / kindle-ttssrc process if active
    if (self.audio_player_type == "kindle-gst-play"
            or self.audio_player_type == "kindle-ttssrc")
        and self._gst_play_pid then
        os.execute("kill " .. self._gst_play_pid .. " 2>/dev/null")
        self._gst_play_pid = nil
    end

    -- Stop Kindle native TTS via FFI or shell (includes fallback mode)
    if self.audio_player_type == "kindle-native-tts"
        or self.audio_player_type == "kindle-native-tts-fallback" then
        if self._lipc_handle and _lipc_lib then
            pcall(_lipc_lib.LipcSetStringProperty, self._lipc_handle,
                "com.lab126.playermgr", "Stop", "")
        end
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline("engine_stop")
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
    -- Shut down Android TTS engine and MediaPlayer
    if self._android_tts then
        self._android_tts:shutdown()
        self._android_tts = nil
    end
    -- Stop Kindle LIPC playermgr
    if self.audio_player_type == "kindle-lipc" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end
    -- Kill kindle-gst-play process
    if self._gst_play_pid then
        os.execute("kill " .. self._gst_play_pid .. " 2>/dev/null")
        self._gst_play_pid = nil
    end
    -- Close Kindle native TTS LIPC handle (includes fallback mode)
    if self.audio_player_type == "kindle-native-tts"
        or self.audio_player_type == "kindle-native-tts-fallback" then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        if self._lipc_handle and _lipc_lib then
            pcall(_lipc_lib.LipcClose, self._lipc_handle)
            self._lipc_handle = nil
        end
    end
    -- Stop persistent pipeline or legacy keepalive
    if self._persistent_pipeline then
        self:_stopPersistentPipeline("force_kill_all")
    else
        self:_stopBtKeepalive()
    end
    if self.audio_pid then
        os.execute("kill -9 " .. self.audio_pid .. " 2>/dev/null")
        self.audio_pid = nil
    end
    -- Stop platform-native helper daemon if it is running.
    self:_stopNativeDaemon()
    -- SIGKILL to guarantee hung gst-launch processes die (e.g. stuck in
    -- BT audio driver).  _stopPersistentPipeline already used SIGKILL for
    -- the pipeline; this catches any legacy-path or newly spawned strays.
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")
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
    -- Only clear audio_pid for the legacy (non-persistent) path.
    -- For the persistent pipeline, audio_pid points to the gst-launch
    -- process which keeps running between sentences.  Clearing it here
    -- breaks pause/resume and causes _isAudioProcessRunning to return
    -- false spuriously.
    if not self._persistent_pipeline then
        self.audio_pid = nil
    end
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
    -- Tear down any platform-native daemon when leaving the native backend.
    if self.backend == self.BACKENDS.NATIVE and backend ~= self.BACKENDS.NATIVE then
        self:_stopNativeDaemon()
    end
    self.backend = backend
    -- Invalidate cached audio player: backend choice can change which player
    -- is appropriate (e.g. switching to/from kindle-native-tts changes whether
    -- Ivona text-synth or kindle-lipc/gst-play WAV-decode is the right path).
    self._cached_player = nil
    self.audio_player_type = nil
    self._native_tts_text = nil
    logger.dbg("TTSEngine: Backend switched to", backend)
    -- Restore correct backend_cmd for the selected backend
    if backend == self.BACKENDS.PIPER then
        self.backend_cmd = self.piper_cmd or "piper"
    elseif backend == self.BACKENDS.ESPEAK then
        -- Restore bundled espeak-ng path if available
        local plugin_dir = Utils.normalizeDirPath(self.plugin_dir or "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin")
        local bundled_bin = plugin_dir .. "/espeak-ng/bin/espeak-ng"
        local f = io.open(bundled_bin, "r")
        if f then
            f:close()
            self.backend_cmd = bundled_bin
        else
            self.backend_cmd = "espeak-ng"
        end
    elseif backend == self.BACKENDS.NATIVE then
        self.backend_cmd = self.plugin:getSetting("native_helper_path") or ""
    end
end

function TTSEngine:getPiperSampleRate()  return self._piper:getSampleRate() end
function TTSEngine:listPiperVoices()     return self._piper:listVoices() end

--[[--
Installed Android TTS voices (empty on other backends or if the helper
dex is too old).  Ensures the engine is initialized first.
@return table  list of { name, locale, quality, network }
--]]
function TTSEngine:listAndroidVoices()
    if self.backend ~= self.BACKENDS.ANDROID then return {} end
    local atts = self:_ensureAndroidTts()
    if not atts or not atts.listVoices then return {} end
    local ok, voices = pcall(function() return atts:listVoices() end)
    if ok and type(voices) == "table" then return voices end
    return {}
end

--[[--
Forget the cached Android language/voice so the next sentence reapplies
the current settings (after the user picks a new voice).
--]]
function TTSEngine:invalidateAndroidVoice()
    self._android_tts_lang = nil
    self._android_tts_voice = nil
    self._android_lang_warned = nil
end

-- Thin delegates — keep the public API surface unchanged for synccontroller
function TTSEngine:piperPrefetchAsync(text)     self._piper:enqueue(text) end
function TTSEngine:_launchNextPiperPrefetch()    self._piper:launchNext() end
function TTSEngine:consumePiperQueueEntry(text)  return self._piper:consume(text) end
function TTSEngine:getPiperPrefetchStatus(text)  return self._piper:getStatus(text) end

--[[--
Low-resource Piper mode (setting A).  One sentence per batch, current
sentence prioritized.  Enabled persistently via the "piper_low_resource"
setting, or for the session by the RTF auto-degrade escalation.
@return boolean
--]]
function TTSEngine:_piperLowResource()
    if self._session_low_resource then return true end
    if self.plugin and self.plugin:getSetting("piper_low_resource", false) then
        return true
    end
    return false
end

--[[--
Aggressive long-sentence splitting for Piper (setting B).  Enabled
persistently via the "piper_aggressive_split" setting, or for the session
by the RTF auto-degrade escalation.
@return boolean
--]]
function TTSEngine:_piperAggressiveSplit()
    if self._session_split_long then return true end
    if self.plugin and self.plugin:getSetting("piper_aggressive_split", false) then
        return true
    end
    return false
end

return TTSEngine
