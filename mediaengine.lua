--[[--
MediaEngine -- Audio file playback with seeking for pre-recorded audiobooks.
Supports mpv (JSON IPC), mplayer (slave mode), gst-play-1.0, aplay fallbacks,
and Kindle-specific backends (LIPC playermgr, bundled gst-play).

@module koplugin.audiobook.mediaengine
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local time = require("ui/time")
local _ = require("audiobook_gettext")

local ffi = require("ffi")
pcall(function() ffi.cdef[[ int kill(int pid, int sig); ]] end)
pcall(function() ffi.cdef[[ int mkfifo(const char *pathname, unsigned int mode); ]] end)

local MediaEngine = {}

MediaEngine.BACKENDS = {
    MPV = "mpv",
    MPLAYER = "mplayer",
    FFMPEG_PIPE = "ffmpeg-pipe",
    GST_PLAY = "gst-play",
    GST_PIPELINE = "gst-pipeline",
    APLAY = "aplay",
    WAV_PLAY = "wav-play",
    KINDLE_LIPC = "kindle-lipc",
    KINDLE_GST_PLAY = "kindle-gst-play",
    ANDROID = "android",
}

function MediaEngine:new(o)
    o = o or {}
    setmetatable(o, self)
    self.__index = self
    o.backend = nil
    o.backend_cmd = nil
    o.audio_pid = nil
    o.play_generation = 0
    o.current_path = nil
    o.current_duration = nil
    o.is_playing = false
    o.is_paused = false
    o._socket_path = nil
    o._fifo_path = nil
    o._ipc_file = nil
    o._pending_callbacks = {}
    o._position_timer = nil
    o._on_complete = nil
    o._on_fail = nil
    o._seek_target = nil
    o._plugin_dir = o.plugin_dir or "."
    -- Elapsed-time tracking for backends without IPC (gst-play, aplay)
    o._play_start_time = nil
    o._pause_start_time = nil
    o._total_pause_ms = 0
    o._seek_offset = 0
    -- Android live-seek health (session-only): set when the one-shot probe
    -- finds MediaPlayer.seekTo is a no-op, switching seeks to seek-by-restart.
    o._seek_probe_done = false
    o._seek_to_broken = false
    -- Kindle-specific state
    o._gst_play_cmd = nil
    o._lipc_fallback_tried = false
    -- Persistent GStreamer pipeline state (MTK Bluetooth path)
    o._use_persistent_pipeline = false
    o._persistent_pipeline_active = false
    o._pipeline_gst_pid = nil
    o._pipeline_wrapper_pid = nil
    o._media_ctrl_dir = "/tmp/audiobook_media_ctrl"
    o._media_fifo = "/tmp/audiobook_media_fifo"
    o._media_script = "/tmp/audiobook_media_pipeline.sh"
    o._current_pcm_file = nil
    -- Digital playback volume (0.0..1.0).  Applied as an ffmpeg `volume`
    -- filter in the decode pipeline, so it works without depending on
    -- Amazon's (model-specific) LIPC volume property.  1.0 = unchanged.
    o._volume = 1.0
    return o
end

-- ---------------------------------------------------------------------------
-- Utility
-- ---------------------------------------------------------------------------

function MediaEngine:commandExists(cmd)
    local handle = io.popen("command -v " .. cmd .. " 2>/dev/null")
    if not handle then return false end
    local result = handle:read("*l")
    handle:close()
    return result ~= nil and result ~= ""
end

--- Take audiomgrd 'Music' focus once per KOReader session.
-- Every setFocus makes audiomgrd re-ramp gain to its stored level, which
-- resets the headset volume on each call -- so seeks and track switches
-- must not re-issue it.  New streams inherit focus from audiomgrd's cache.
-- Exception: Apple AirPods often drop the A2DP audio session after a short
-- blip; forcing Music focus again on recovery is required to resume sound.
function MediaEngine._takeMusicFocusOnce(force)
    if MediaEngine._focus_taken and not force then return end
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'Music' 2>/dev/null")
    MediaEngine._focus_taken = true
end

function MediaEngine._clearMusicFocusFlag()
    MediaEngine._focus_taken = false
end

--- Best-effort connected headset name from Kindle btfd (for AirPods heuristics).
function MediaEngine:_kindleConnectedHeadsetName()
    if not self:_isKindle() then return nil end
    local h = io.popen("lipc-hash-prop com.lab126.btfd ListConnected 2>/dev/null")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    -- Prefer the first non-empty bd_name.
    for name in out:gmatch('bd_name%s*=%s*"(.-)"') do
        if name ~= "" then return name end
    end
    return nil
end

function MediaEngine:_isAppleAirPodsHeadset()
    local name = self:_kindleConnectedHeadsetName()
    if not name then return false end
    name = name:lower()
    return name:find("airpods", 1, true) ~= nil
        or name:find("beats", 1, true) ~= nil
end

function MediaEngine:_kindleA2dpRouteUp()
    if not self:_isKindle() then return true end
    local h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
    if not h then return false end
    local v = h:read("*a") or ""
    h:close()
    return v:match("^%s*1") ~= nil
end

function MediaEngine:_kindleConnectedHeadsetMac()
    if not self:_isKindle() then return nil end
    -- Prefer ListConnected; fall back to ListPaired when A2DP is stale and
    -- the headset no longer appears in the connected list (common after
    -- audiomgrd drops the idle AirPods session).  Finally reuse the last
    -- MAC we successfully saw this session — cycle was skipping with
    -- "no connected MAC" even though AirPods were still paired.
    for _, prop in ipairs({ "ListConnected", "ListPaired" }) do
        local h = io.popen("lipc-hash-prop com.lab126.btfd " .. prop .. " 2>/dev/null")
        if h then
            local out = h:read("*a") or ""
            h:close()
            -- Kindle prints "34:0E:22:..." — accept hex + colon only.
            local mac = out:match('bd_address%s*=%s*"([%x:]+)"')
            if mac and #mac >= 11 then
                self._kindle_last_headset_mac = mac
                return mac
            end
        end
    end
    return self._kindle_last_headset_mac
end

--- Kindle A2DP (esp. AirPods): SIGSTOP/SIGCONT leaves the pipeline frozen while
--- audiomgrd drops the idle headset session — resume must re-attach Music focus
--- and restart the gst pipeline at the pause position.
function MediaEngine:_kindleNeedsPipelineRestartOnResume()
    if not self:_isKindle() then return false end
    return self.backend == self.BACKENDS.KINDLE_GST_PLAY
        or self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE
        or self.backend == self.BACKENDS.FFMPEG_PIPE
end

--- Silence stream that keeps audiomgrd's A2DP datapath awake while paused
--- (same trick as TTSEngine:_ensureKindleKeepalive). Without this, pause
--- suspends A2DP and resume-restart plays into a dead route until the user
--- manually Disconnect/Connect the headset.
function MediaEngine:_startKindleA2dpKeepalive(reason)
    if not self:_isKindle() then return end
    if self._keepalive_pid then
        local f = io.open("/proc/" .. self._keepalive_pid .. "/status", "r")
        if f then f:close(); return end
        self._keepalive_pid = nil
    end
    MediaEngine._takeMusicFocusOnce(true)
    -- Tag the cmdline with abk-keepalive so content-only cleanup can spare it.
    local h = io.popen(
        "gst-launch-0.10 filesrc location=/dev/zero"
        .. " ! 'audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234'"
        .. " ! mixersink stream-type=Music sync=true"
        .. " >/tmp/abk-keepalive.log 2>&1 & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._keepalive_pid = tonumber(pid_str:match("(%d+)"))
    self._keepalive_reason = reason or "?"
    logger.warn("MediaEngine: Kindle A2DP keepalive started (", self._keepalive_reason,
        ") PID=", self._keepalive_pid)
end

function MediaEngine:_stopKindleA2dpKeepalive(only_if_reason)
    if only_if_reason and self._keepalive_reason ~= only_if_reason then
        return
    end
    local pid = self._keepalive_pid
    self._keepalive_pid = nil
    self._keepalive_reason = nil
    if not pid then return end
    os.execute("kill -9 " .. tostring(pid) .. " 2>/dev/null")
    -- Fallback in case $! was a wrapper shell: match the gst-launch argv.
    -- (abk-keepalive only appears in the log redirection, never in cmdline.)
    os.execute("pkill -9 -f 'filesrc location=/dev/zero' 2>/dev/null")
    logger.warn("MediaEngine: Kindle A2DP keepalive stopped PID=", pid)
end

--- Bridge A2DP across a Storyteller/playlist file boundary.
--- Always starts silence keepalive. Optionally Disconnect→Connect the headset
--- when opts.cycle_bt is true (plugin setting kindle_bt_reconnect_on_track).
--- @param callback function|nil  callback(ok)
--- @param opts table|nil  { cycle_bt = boolean }
function MediaEngine:prepareKindleTrackAdvance(callback, opts)
    opts = opts or {}
    if not self:_isKindle() then
        if callback then callback(true) end
        return
    end
    self:_startKindleA2dpKeepalive("track-advance")
    if not opts.cycle_bt then
        logger.warn("MediaEngine: prepareKindleTrackAdvance — keepalive only (BT cycle off)")
        if callback then callback(true) end
        return
    end
    logger.warn("MediaEngine: prepareKindleTrackAdvance — cycling BT before next file")
    self:_cycleKindleA2dpRoute(function(ok)
        logger.warn("MediaEngine: track-advance A2DP cycle ok=", ok and "yes" or "no")
        -- Keep keepalive running across the subsequent MediaSync:start/play gap.
        if callback then callback(ok) end
    end)
end

--- Public: cycle BT A2DP and restart content at the current position.
--- Used by the player "Fix audio" button when AirPods go silent mid-play.
--- @param on_done function|nil  optional callback(ok, reason)
---   reason: "started" | "no_path" | "no_mac" | "route_up" | "route_down"
function MediaEngine:fixKindleA2dpAudio(on_done)
    if not self:_isKindle() then
        if on_done then on_done(false, "not_kindle") end
        return false
    end
    if not self.current_path then
        if on_done then on_done(false, "no_path") end
        return false
    end
    local pos = 0
    pcall(function() pos = self:getPosition() or 0 end)
    if pos <= 0 then pos = self._seek_offset or 0 end
    local complete = self._on_complete
    local fail = self._on_fail
    local gen = self.play_generation
    self._seek_offset = math.max(0, pos)
    logger.warn("MediaEngine: fixKindleA2dpAudio at", self._seek_offset)
    local mac = self:_kindleConnectedHeadsetMac()
    if not mac then
        logger.warn("MediaEngine: fixKindleA2dpAudio aborted (no headset MAC)")
        if on_done then on_done(false, "no_mac") end
        return false
    end
    self:_startKindleA2dpKeepalive("fix-audio")
    self:_cycleKindleA2dpRoute(function(ok)
        if self.play_generation ~= gen and not self.is_playing then
            -- superseded
        end
        logger.warn("MediaEngine: fixKindleA2dpAudio route ok=", ok and "yes" or "no")
        self.is_paused = false
        self:play(complete, fail)
        UIManager:scheduleIn(1.5, function()
            self:_stopKindleA2dpKeepalive("fix-audio")
        end)
        if on_done then on_done(ok, ok and "route_up" or "route_down") end
    end)
    return true
end

--- Disconnect/Connect cycle that re-arms A2DP (same as BTManager:connect).
--- Non-blocking: invokes callback(ok) when done.
function MediaEngine:_cycleKindleA2dpRoute(callback)
    local mac = self:_kindleConnectedHeadsetMac()
    if not mac then
        logger.warn("MediaEngine: A2DP cycle skipped (no connected MAC)")
        if callback then callback(false) end
        return
    end
    logger.warn("MediaEngine: cycling Kindle A2DP for", mac)
    os.execute(string.format(
        "lipc-set-prop com.lab126.btfd Disconnect '%s' 2>/dev/null", mac))
    UIManager:scheduleIn(2.5, function()
        os.execute(string.format(
            "lipc-set-prop com.lab126.btfd Connect '%s' 2>/dev/null", mac))
        local attempts = 0
        local function wait_route()
            attempts = attempts + 1
            local up = self:_kindleA2dpRouteUp()
            if up or attempts >= 10 then
                MediaEngine._clearMusicFocusFlag()
                MediaEngine._takeMusicFocusOnce(true)
                logger.warn("MediaEngine: A2DP cycle done up=", up and "yes" or "no",
                    "attempts=", attempts)
                if callback then callback(up) end
                return
            end
            UIManager:scheduleIn(1.0, wait_route)
        end
        UIManager:scheduleIn(1.0, wait_route)
    end)
end

--- Ensure A2DP is up before resume/play. Uses keepalive/focus first, cycles BT if needed.
function MediaEngine:_ensureKindleA2dpRoute(callback)
    MediaEngine._clearMusicFocusFlag()
    MediaEngine._takeMusicFocusOnce(true)
    if self:_kindleA2dpRouteUp() then
        if callback then callback(true) end
        return
    end
    -- Keepalive may still be attaching; brief retry before a full BT cycle.
    UIManager:scheduleIn(0.8, function()
        if self:_kindleA2dpRouteUp() then
            MediaEngine._takeMusicFocusOnce(true)
            if callback then callback(true) end
            return
        end
        self:_cycleKindleA2dpRoute(callback)
    end)
end

--- Halt the Kindle ffmpeg|gst pipeline without clearing pause/callbacks.
function MediaEngine:_haltKindlePipelineForPause(reason)
    self:_nextGeneration() -- cancel completion / position watchers
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end
    local pid = self.audio_pid
    self.audio_pid = nil
    if pid and ffi.C.kill then
        pcall(function() ffi.C.kill(-pid, 15) end) -- SIGTERM group
        pcall(function() ffi.C.kill(pid, 15) end)
        pcall(function() ffi.C.kill(-pid, 9) end)
        pcall(function() ffi.C.kill(pid, 9) end)
    end
    if self:_isKindle() then
        -- Kill content pipelines only; keepalive is started right after.
        self:_killOrphanKindleGstPipelines(reason or "pause-halt", 120000, { content_only = true })
    end
    if self._progress_file then
        os.remove(self._progress_file)
        self._progress_file = nil
    end
    self._use_progress_position = false
end

--[[--
Build an ffmpeg atempo filter string for the given playback speed.
atempo accepts 0.5..2.0; chain multiple filters for speeds outside that range.
@return string  Filter string suitable for -filter:a, or empty string for 1.0x.
--]]
function MediaEngine:_atempoFilterString(speed)
    speed = tonumber(speed) or 1.0
    if math.abs(speed - 1.0) < 0.01 then return "" end
    local filters = {}
    local remaining = speed
    while remaining > 2.0 + 0.001 do
        table.insert(filters, "atempo=2.0")
        remaining = remaining / 2.0
    end
    while remaining < 0.5 - 0.001 do
        table.insert(filters, "atempo=0.5")
        remaining = remaining / 0.5
    end
    table.insert(filters, string.format("atempo=%.3f", remaining))
    return " -filter:a \"" .. table.concat(filters, ",") .. "\""
end

--[[--
Probe for ffmpeg in the plugin's bin/ directory or PATH.
The release zip may ship ELF binaries with a .bin extension so they survive
Windows zip extractors; rename .bin back to the original name if needed.
@return string|nil  absolute path to ffmpeg binary, or nil
--]]
function MediaEngine:_findFfmpeg()
    -- Bundled ffmpeg is a glibc Linux binary. Spawning it on Android (Bionic)
    -- hard-crashes KOReader — never touch it on this platform.
    if Device.isAndroid and Device:isAndroid() then
        return nil
    end
    if self._plugin_dir then
        local plugin_ffmpeg = self._plugin_dir .. "/bin/ffmpeg"
        -- Release zip ships ffmpeg as ffmpeg.bin; rename on first use.
        -- If both files exist (e.g. after a plugin update), replace the old
        -- ffmpeg with the freshly shipped .bin so updates actually take effect.
        local bin_path = plugin_ffmpeg .. ".bin"
        local b = io.open(bin_path, "r")
        if b then
            b:close()
            os.remove(plugin_ffmpeg)
            local ok, err = os.rename(bin_path, plugin_ffmpeg)
            if ok then
                logger.warn("MediaEngine: renamed", bin_path, "to", plugin_ffmpeg)
            else
                logger.warn("MediaEngine: failed to rename", bin_path, ":", err)
                -- Return the .bin path as a fallback so playback can still work.
                return bin_path
            end
        end
        local f = io.open(plugin_ffmpeg, "r")
        if f then
            f:close()
            return plugin_ffmpeg
        end
    end
    local h = io.popen("command -v ffmpeg 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    return nil
end

function MediaEngine:_getTempDir()
    if Device.isAndroid and Device:isAndroid() then
        -- Prefer Android app cache. Never use /tmp on Android — often not
        -- writable for the KOReader sandbox.
        if self._android_cache_dir then
            return self._android_cache_dir
        end
        local ok, android = pcall(require, "android")
        if ok and android then
            local cache = android.jni:context(android.app.activity.vm, function(jni)
                local cache_file = jni:callObjectMethod(
                    android.app.activity.clazz,
                    "getCacheDir",
                    "()Ljava/io/File;"
                )
                if cache_file == nil then return nil end
                local abs_path = jni:callObjectMethod(
                    cache_file, "getAbsolutePath", "()Ljava/lang/String;"
                )
                jni.env[0].DeleteLocalRef(jni.env, cache_file)
                if abs_path == nil then return nil end
                local result = jni:to_string(abs_path)
                jni.env[0].DeleteLocalRef(jni.env, abs_path)
                return result
            end)
            if cache then
                self._android_cache_dir = cache .. "/audiobook"
                local ok_lfs, lfs = pcall(require, "libs/libkoreader-lfs")
                if ok_lfs and lfs then
                    lfs.mkdir(self._android_cache_dir)
                end
                return self._android_cache_dir
            end
        end
    end
    return os.getenv("TMPDIR") or "/tmp"
end

--- Direct MediaPlayer via JNI (no dex, no ffmpeg). Preferred for EPUB overlays.
function MediaEngine:_ensureAndroidPlayer()
    if self._android_player then return self._android_player end
    if not (Device.isAndroid and Device:isAndroid()) then return nil end
    local ok, AndroidPlayer = pcall(dofile, self._plugin_dir .. "/androidplayer.lua")
    if not ok or not AndroidPlayer then
        logger.err("MediaEngine: androidplayer.lua failed:", AndroidPlayer)
        return nil
    end
    local player = AndroidPlayer:new()
    if player:init() then
        self._android_player = player
        return player
    end
    return nil
end

--- Reuse the plugin's AndroidTts bridge (shared with TTSEngine when available).
--- Kept for TTS sentence playback only — audiobooks use AndroidPlayer.
function MediaEngine:_ensureAndroidTts()
    if self._android_tts then return self._android_tts end
    local plugin = self.plugin
    if plugin and plugin.tts_engine and plugin.tts_engine._android_tts then
        self._android_tts = plugin.tts_engine._android_tts
        return self._android_tts
    end
    local ok, AndroidTts = pcall(dofile, self._plugin_dir .. "/androidtts.lua")
    if not ok or not AndroidTts then return nil end
    local atts = AndroidTts:new{ plugin_dir = self._plugin_dir }
    if atts:init() then
        self._android_tts = atts
        return atts
    end
    return nil
end

function MediaEngine:_fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    return false
end

function MediaEngine:_nextGeneration()
    self.play_generation = self.play_generation + 1
    return self.play_generation
end

--[[--
Detect whether the MTK Bluetooth audio sink is available.
This sink holds an exclusive abstract socket, so we must use a persistent
pipeline instead of killing and restarting the player on seek/pause.
@return boolean true if mtkbtmwrpcaudiosink is available
--]]
function MediaEngine:_hasMtkSink()
    if not self:commandExists("gst-launch-1.0") then return false end
    local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1 && echo yes || echo no")
    if not h then return false end
    local result = h:read("*l") == "yes"
    h:close()
    return result
end

-- ---------------------------------------------------------------------------
-- Backend detection
-- ---------------------------------------------------------------------------

function MediaEngine:detectBackend()
    if self.backend then
        return self.backend, self.backend_cmd
    end

    -- 1) mpv -- best seeking, JSON IPC, handles all formats
    if self:commandExists("mpv") then
        self.backend = self.BACKENDS.MPV
        self.backend_cmd = "mpv"
        logger.warn("MediaEngine: selected mpv backend")
        return self.backend, self.backend_cmd
    end

    -- 2) mplayer -- slave mode, reasonable seeking
    if self:commandExists("mplayer") then
        self.backend = self.BACKENDS.MPLAYER
        self.backend_cmd = "mplayer"
        logger.warn("MediaEngine: selected mplayer backend")
        return self.backend, self.backend_cmd
    end

    -- 3) Android: direct MediaPlayer via JNI (Boox / KOReader Android).
    -- Never fall through to ffmpeg-pipe: the bundled glibc ffmpeg SIGSEGVs
    -- under Android Bionic, and aplay does not exist.
    if Device.isAndroid and Device:isAndroid() then
        local player = self:_ensureAndroidPlayer()
        if player then
            self.backend = self.BACKENDS.ANDROID
            self.backend_cmd = "android-mediaplayer"
            logger.warn("MediaEngine: selected Android MediaPlayer backend (direct JNI)")
            return self.backend, self.backend_cmd
        end
        self.backend_error = _(
            "Android audio playback is unavailable.\n\n" ..
            "Could not initialize the system MediaPlayer. Restart KOReader and try again.")
        logger.err("MediaEngine: Android MediaPlayer unavailable; refusing CLI fallbacks")
        return nil, nil
    end

    -- 4) Kindle backends FIRST on Kindle hardware: there is no ALSA and no
    -- aplay, so the ffmpeg-pipe backend (which pipes WAV to aplay) can
    -- never produce sound here; audio must go through Amazon's
    -- mixersink → audiomgrd → BT pipeline.  The kindle-gst-play backend
    -- decodes non-WAV formats by streaming bundled-ffmpeg output into the
    -- system GStreamer (see _playSystemGstLaunch).
    if self:_isKindle() then
        local gst_play_detected = self:_detectKindleGstPlay()
        if gst_play_detected then
            self.backend = self.BACKENDS.KINDLE_GST_PLAY
            self.backend_cmd = self._gst_play_cmd
            logger.warn("MediaEngine: selected kindle-gst-play backend")
            return self.backend, self.backend_cmd
        end

        local lipc_detected = self:_detectKindleLipc()
        if lipc_detected then
            self.backend = self.BACKENDS.KINDLE_LIPC
            self.backend_cmd = "lipc"
            logger.warn("MediaEngine: selected kindle-lipc backend")
            return self.backend, self.backend_cmd
        end
    end

    -- 4) ffmpeg pipe -- decodes any format ffmpeg supports (m4b, aac, ogg,
    -- flac, etc.) and pipes raw WAV to aplay.  Preferred over gst-play on
    -- devices where gstreamer lacks AAC decoders (common on Kobo).
    local ffmpeg_cmd = self:_findFfmpeg()
    if ffmpeg_cmd then
        self.backend = self.BACKENDS.FFMPEG_PIPE
        self.backend_cmd = ffmpeg_cmd
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected ffmpeg-pipe backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected ffmpeg-pipe backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 4) gst-play-1.0 -- preferred over gst-launch because playbin handles
    -- URI fragments (#t=) for time-offset seeking, which uridecodebin does not.
    if self:commandExists("gst-play-1.0") then
        self.backend = self.BACKENDS.GST_PLAY
        self.backend_cmd = "gst-play-1.0"
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected gst-play-1.0 backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected gst-play-1.0 backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 4) gst-launch-1.0 -- build custom pipeline (fallback)
    if self:commandExists("gst-launch-1.0") then
        self.backend = self.BACKENDS.GST_PIPELINE
        self.backend_cmd = "gst-launch-1.0"
        if self:_hasMtkSink() then
            self._use_persistent_pipeline = true
            logger.warn("MediaEngine: selected gst-launch-1.0 backend with persistent pipeline (MTK)")
        else
            logger.warn("MediaEngine: selected gst-launch-1.0 backend")
        end
        return self.backend, self.backend_cmd
    end

    -- 6) aplay -- WAV only, no seeking
    if self:commandExists("aplay") then
        self.backend = self.BACKENDS.APLAY
        self.backend_cmd = "aplay"
        logger.warn("MediaEngine: selected aplay backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    -- 7) bundled wav-play -- WAV only, no seeking
    local wav_play_path = self._plugin_dir .. "/wav-play"
    local f = io.open(wav_play_path, "r")
    if f then
        f:close()
        self.backend = self.BACKENDS.WAV_PLAY
        self.backend_cmd = wav_play_path
        logger.warn("MediaEngine: selected bundled wav-play backend (WAV only, no seek)")
        return self.backend, self.backend_cmd
    end

    logger.err("MediaEngine: no audio backend found")
    return nil, nil
end

-- ---------------------------------------------------------------------------
-- Kindle-specific backend detection
-- Mirrors the logic in TTSEngine:findAudioPlayer() for LIPC playermgr
-- and bundled kindle/gst-play backends.
-- ---------------------------------------------------------------------------

--- Check if the device is a Kindle via KOReader's Device module or
--- fallback heuristics.
-- @treturn bool
function MediaEngine:_isKindle()
    return Device.isKindle and Device:isKindle()
end

--- Probe whether Kindle playermgr (LIPC) is available: lipc-set-prop,
--- lipc-get-prop exist, and com.lab126.playermgr InPlayback property
--- can be read (returns a digit).
-- @treturn string|nil "kindle-lipc" if available, nil otherwise
function MediaEngine:_detectKindleLipc()
    if not self:_isKindle() then return nil end

    local h = io.popen("command -v lipc-set-prop 2>/dev/null && command -v lipc-get-prop 2>/dev/null")
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    if out == "" then return nil end

    local ph = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>&1")
    if not ph then return nil end
    local val = ph:read("*a") or ""
    ph:close()
    val = val:match("^%s*(%d+)")
    if val then
        -- playermgr service exists and responds.
        -- Check for wavparse in GStreamer plugins: if present, playermgr
        -- can decode WAV files via GStreamer natively.  If absent, audio
        -- files need-- to be transcoded to WAV and played via kindle-gst-play.
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
        if not has_wavparse then
            -- No wavparse -- playermgr cannot decode WAV natively.
            -- Only use kindle-lipc if we can detect the bundled gst-play
            -- as a fallback, since the file is already transcoded to WAV
            -- by the plugin's transcoder before reaching MediaEngine.
            -- If gst-play exists, we prefer KINDLE_GST_PLAY; if not,
            -- try kindle-lipc anyway (the file may be MP3 which playermgr
            -- handles natively via decodebin).
            local plugin_dir = self._plugin_dir or "."
            local gst_play_bin = plugin_dir .. "/kindle/gst-play"
            local gf = io.open(gst_play_bin, "r")
            if not gf then
                -- No gst-play available; skip LIPC if wavparse is absent
                -- because playermgr will fail silently on WAV files.
                -- MP3 files may still work, but we can't be sure.
                logger.warn("MediaEngine: Kindle LIPC available but no wavparse and no gst-play -- will try LIPC for non-WAV files")
            else
                gf:close()
                logger.warn("MediaEngine: Kindle LIPC available but no wavparse -- gst-play present for WAV fallback")
            end
        end
        logger.warn("MediaEngine: Found Kindle LIPC playermgr service, InPlayback=", val,
            "wavparse=", has_wavparse)
        return "kindle-lipc"
    end
    logger.warn("MediaEngine: lipc-get-prop playermgr InPlayback returned:", val)
    return nil
end

--- Probe for the bundled kindle/gst-play binary and verify that
--- GStreamer mixersink is available.  gst-play feeds raw PCM to
--- mixersink → audiomgrd → BT headphones.
-- @treturn string|nil "kindle-gst-play" if available, nil otherwise
function MediaEngine:_detectKindleGstPlay()
    if not self:_isKindle() then return nil end

    local plugin_dir = self._plugin_dir or "."
    local gst_play_bin = plugin_dir .. "/kindle/gst-play"
    local gf = io.open(gst_play_bin, "r")
    if not gf then
        logger.dbg("MediaEngine: kindle/gst-play not bundled")
        -- System pipelines alone are enough (see comment below).
        if self:commandExists("gst-launch-0.10") then
            self._gst_play_cmd = nil
            return "kindle-gst-play"
        end
        return nil
    end
    gf:close()

    -- The bundled binary may need the bundled dynamic linker: builds from
    -- the Nix cross toolchain carry a /nix/store ELF interpreter that does
    -- not exist on the device, so bare execution fails with "not found".
    -- Probe bare first, then wrapped (mirroring ttsengine).
    local linker = plugin_dir .. "/espeak-ng/lib/ld-linux-armhf.so.3"
    local lf = io.open(linker, "r")
    local candidates = { gst_play_bin }
    if lf then
        lf:close()
        table.insert(candidates, string.format(
            "%s --library-path %s/espeak-ng/lib:/usr/lib/tts:/usr/lib:/lib %s",
            linker, plugin_dir, gst_play_bin))
    end

    -- KinAMP-parity fallback (audio-less PW4-class Kindles): a native-glibc
    -- gst-play built with koxtoolchain runs under the SYSTEM linker -- no glibc
    -- mixing -- so it can load the device's old-glibc libgstmixersink.so where
    -- the compat candidates above crash.  Run bare: its ELF interpreter is the
    -- device's system linker and it dlopens libgstreamer by absolute path, so
    -- no linker wrapper or LD_LIBRARY_PATH is needed (KinAMP parity).
    -- Tried LAST: the loop breaks on the first candidate that reports
    -- mixersink=found, so devices where the compat binary works never reach this
    -- and cannot regress.
    --
    -- Soft-float kindlepw2 variant first (firmware < 5.16.3), then hard-float
    -- kindlehf variant (firmware >= 5.16.3).
    local native_bins = {
        plugin_dir .. "/kindle/gst-play-native-pw2",
        plugin_dir .. "/kindle/gst-play-native",
    }
    for _, native_bin in ipairs(native_bins) do
        local nf = io.open(native_bin, "r")
        if nf then
            nf:close()
            table.insert(candidates, native_bin)
        end
    end

    local gst_play_cmd = nil
    for _, cand in ipairs(candidates) do
        local ph = io.popen(cand .. " --probe 2>&1")
        if ph then
            local probe = ph:read("*a") or ""
            ph:close()
            -- Accept the binary as long as mixersink is present and usable.
            -- GStreamer warnings about unrelated plugins (e.g. ttssrc failing
            -- to load because libIvonaEInkAPI.so is stripped on newer
            -- firmware) do not affect our WAV playback path.
            if probe:match("mixersink=found")
                and not probe:match("mixersink=broken")
                and not probe:match("gstreamer=not_found") then
                gst_play_cmd = cand
                break
            end
        end
    end

    if gst_play_cmd then
        logger.warn("MediaEngine: Found bundled kindle-gst-play with mixersink")
        self._gst_play_cmd = gst_play_cmd
        return "kindle-gst-play"
    end

    -- Bundled binary unusable, but the kindle-gst-play backend can still
    -- play everything through the system GStreamer: WAV via raw PCM
    -- filesrc, other formats via bundled-ffmpeg streaming (see
    -- _playSystemGstLaunch*).  Selecting kindle-lipc here instead used to
    -- strand PW5 on the dead playermgr ("none of 4 strategies got
    -- InPlayback=1").
    if self:commandExists("gst-launch-0.10") then
        logger.warn("MediaEngine: bundled gst-play unusable, using system gst-launch-0.10 pipelines")
        self._gst_play_cmd = nil
        return "kindle-gst-play"
    end

    logger.warn("MediaEngine: kindle-gst-play probe failed and no system gst-launch-0.10")
    return nil
end

-- ---------------------------------------------------------------------------
-- Duration probing
-- ---------------------------------------------------------------------------

function MediaEngine:_findFfprobe()
    if Device.isAndroid and Device:isAndroid() then
        return nil
    end
    -- Check bundled binary first (release zip may ship it as ffprobe.bin).
    if self._plugin_dir then
        local plugin_ffprobe = self._plugin_dir .. "/bin/ffprobe"
        local bin_path = plugin_ffprobe .. ".bin"
        local b = io.open(bin_path, "r")
        if b then
            b:close()
            os.remove(plugin_ffprobe)
            local ok = os.rename(bin_path, plugin_ffprobe)
            if ok then
                logger.warn("MediaEngine: renamed", bin_path, "to", plugin_ffprobe)
            else
                return bin_path
            end
        end
        local f = io.open(plugin_ffprobe, "r")
        if f then f:close() return plugin_ffprobe end
    end
    -- Fall back to PATH.
    local h = io.popen("command -v ffprobe 2>/dev/null")
    if h then
        local result = h:read("*l")
        h:close()
        if result and result ~= "" then return result end
    end
    return nil
end

function MediaEngine:_probeDurationFfprobe(path)
    local ffprobe = self:_findFfprobe()
    if not ffprobe then return nil end

    local cmd = string.format(
        '"%s" -v error -show_entries format=duration -of csv=p=0 "%s" 2>/dev/null',
        ffprobe:gsub('"', '\\"'),
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("^%s*([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: ffprobe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationGstDiscoverer(path)
    local cmd = string.format(
        'gst-discoverer-1.0 "%s" 2>/dev/null | grep -i "^  Duration:"',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    -- Parse "  Duration: 0:11:36.163265306"
    local hh, mm, ss = out:match("Duration:%s*(%d+):(%d+):([%d%.]+)")
    if hh and mm and ss then
        local secs = tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
        if secs and secs > 0 then
            logger.dbg("MediaEngine: gst-discoverer duration =", secs)
            return secs
        end
    end
    return nil
end

function MediaEngine:_probeDurationMpv(path)
    -- Quick probe via mpv --no-video --frames=0
    local cmd = string.format(
        'mpv --no-video --frames=0 --really-quiet --term-playing-msg="${=duration}" "%s" 2>/dev/null',
        path:gsub('"', '\\"')
    )
    local h = io.popen(cmd)
    if not h then return nil end
    local out = h:read("*a") or ""
    h:close()
    local secs = tonumber(out:match("([%d%.]+)"))
    if secs and secs > 0 then
        logger.dbg("MediaEngine: mpv probe duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:_probeDurationWav(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    -- WAV header: byte 22-23 = channels, 24-27 = sample rate, 28-31 = byte rate,
    -- 40-43 = data chunk size
    f:seek("set", 22)
    local channels_data = f:read(2)
    local rate_data = f:read(4)
    f:seek("set", 40)
    local data_size_data = f:read(4)
    f:close()
    if not channels_data or not rate_data or not data_size_data then return nil end
    local channels = channels_data:byte(1) + channels_data:byte(2) * 256
    local rate = rate_data:byte(1) + rate_data:byte(2) * 256 +
                 rate_data:byte(3) * 65536 + rate_data:byte(4) * 16777216
    local data_size = data_size_data:byte(1) + data_size_data:byte(2) * 256 +
                      data_size_data:byte(3) * 65536 + data_size_data:byte(4) * 16777216
    if channels > 0 and rate > 0 and data_size > 0 then
        local secs = data_size / (rate * channels * 2)
        logger.dbg("MediaEngine: WAV header duration =", secs)
        return secs
    end
    return nil
end

function MediaEngine:probeDuration(path)
    local ext = path:match("%.([^.]+)$") or ""
    ext = ext:lower()

    -- ffprobe is most reliable for all formats
    local dur = self:_probeDurationFfprobe(path)
    if dur then return dur end

    -- Bundled ffmpeg (no ffprobe shipped): parse "Duration: HH:MM:SS.cc"
    -- from its banner output.
    local ffmpeg = self:_findFfmpeg()
    if ffmpeg then
        local h = io.popen(string.format(
            "%s -i '%s' 2>&1", ffmpeg:gsub("'", "'\\''"), path:gsub("'", "'\\''")))
        if h then
            local out = h:read("*a") or ""
            h:close()
            local hh, mm, ss = out:match("Duration:%s*(%d+):(%d+):([%d%.]+)")
            if hh then
                return tonumber(hh) * 3600 + tonumber(mm) * 60 + tonumber(ss)
            end
        end
    end

    -- gst-discoverer-1.0 fallback (Kobo, etc.)
    dur = self:_probeDurationGstDiscoverer(path)
    if dur then return dur end

    -- mpv can also probe
    if self.backend == self.BACKENDS.MPV then
        dur = self:_probeDurationMpv(path)
        if dur then return dur end
    end

    -- WAV fallback: parse header directly
    if ext == "wav" then
        dur = self:_probeDurationWav(path)
        if dur then return dur end
    end

    logger.warn("MediaEngine: could not probe duration for", path)
    return nil
end

-- ---------------------------------------------------------------------------
-- IPC helpers (mpv)
-- ---------------------------------------------------------------------------

function MediaEngine:_hasLuaSocket()
    local ok, socket = pcall(require, "socket")
    return ok and socket ~= nil
end

function MediaEngine:_mpvSendIpc(cmd_table, timeout_ms)
    timeout_ms = timeout_ms or 500
    if not self._socket_path then return nil end

    -- Try LuaSocket first
    if self:_hasLuaSocket() then
        local ok, socket = pcall(require, "socket")
        if ok then
            local unix = socket.unix and socket.unix()
            if unix then
                unix:settimeout(timeout_ms / 1000)
                local connected, err = unix:connect(self._socket_path)
                if connected then
                    local ok_json, json = pcall(require, "json")
                    if ok_json and json then
                        local payload = json.encode(cmd_table) .. "\n"
                        unix:send(payload)
                        local response = unix:receive("*l")
                        unix:close()
                        if response then
                            local ok2, decoded = pcall(json.decode, response)
                            if ok2 then return decoded end
                        end
                    end
                else
                    logger.dbg("MediaEngine: LuaSocket connect failed:", err)
                end
            end
        end
    end

    -- Fallback: write directly to Unix socket via FFI
    if ffi.C.open then
        local ok_json, json = pcall(require, "json")
        if ok_json and json then
            local O_WRONLY = 1
            local fd = ffi.C.open(self._socket_path, O_WRONLY)
            if fd >= 0 then
                local payload = json.encode(cmd_table) .. "\n"
                ffi.C.write(fd, payload, #payload)
                ffi.C.close(fd)
                -- For commands that don't need response, this is sufficient
                return {data = true}
            end
        end
    end

    return nil
end

function MediaEngine:_mpvSendFifo(command_str)
    if not self._fifo_path then return false end
    local f = io.open(self._fifo_path, "w")
    if f then
        f:write(command_str .. "\n")
        f:close()
        return true
    end
    return false
end

function MediaEngine:_setupMpvIpc()
    local tmpdir = self:_getTempDir()
    local gen = self.play_generation

    -- Try Unix socket first
    self._socket_path = string.format("%s/mpv-audiobook-%d.sock", tmpdir, gen)
    -- Remove stale socket
    os.remove(self._socket_path)

    -- Also prepare FIFO fallback
    self._fifo_path = string.format("%s/mpv-fifo-%d", tmpdir, gen)
    os.remove(self._fifo_path)
    if ffi.C.mkfifo then
        ffi.C.mkfifo(self._fifo_path, 384) -- 0600 octal = 384 decimal
    else
        os.execute("mkfifo '" .. self._fifo_path:gsub("'", "'\\''") .. "'")
    end
end

function MediaEngine:_cleanupIpc()
    if self._socket_path then
        os.remove(self._socket_path)
        self._socket_path = nil
    end
    if self._fifo_path then
        os.remove(self._fifo_path)
        self._fifo_path = nil
    end
    if self._ipc_file then
        os.remove(self._ipc_file)
        self._ipc_file = nil
    end
end

-- ---------------------------------------------------------------------------
-- Playback control
-- ---------------------------------------------------------------------------

function MediaEngine:load(path)
    if not path or path == "" then
        logger.err("MediaEngine: load() called with empty path")
        return false
    end

    self:detectBackend()
    if not self.backend then
        logger.err("MediaEngine: no backend available")
        return false
    end

    -- Pre-start the persistent pipeline on MTK so play() has no latency.
    if self._use_persistent_pipeline then
        if not self:_startPersistentPipeline() then
            logger.warn("MediaEngine: persistent pipeline failed on load, falling back")
            self._use_persistent_pipeline = false
        end
    end

    self.current_path = path
    self.current_duration = self:probeDuration(path)
    self.is_playing = false
    self.is_paused = false
    self._seek_offset = 0
    self._use_progress_position = false
    self._progress_file = nil

    logger.warn("MediaEngine: loaded", path,
        "backend=", self.backend,
        "duration=", self.current_duration)
    return true
end

function MediaEngine:play(on_complete, on_fail)
    if not self.current_path then
        logger.err("MediaEngine: play() called without load()")
        if on_fail then on_fail("no file loaded") end
        return false
    end

    -- Kindle A2DP (AirPods): any stop→play gap (seek, track advance, resume)
    -- lets audiomgrd suspend the datapath.  Park silence first so orphan-kill
    -- never leaves the mixer empty.
    if self:_isKindle() and self:_kindleNeedsPipelineRestartOnResume() then
        if not self._keepalive_pid then
            self:_startKindleA2dpKeepalive("play-bridge")
        end
        self:_killOrphanKindleGstPipelines("play-preflight", 100000, { content_only = true })
    elseif self:_isKindle() then
        self:_killOrphanKindleGstPipelines("play-preflight", 300000)
    end

    self:stop()
    local gen = self:_nextGeneration()
    self._on_complete = on_complete
    self._on_fail = on_fail
    self.is_playing = false
    self.is_paused = false
    self._android_playback_confirmed = false

    if self._use_persistent_pipeline then
        local ok = self:_playPersistentPipeline(gen)
        if ok then
            self.is_playing = true
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = nil
            self._total_pause_ms = 0
            return true
        end
        logger.warn("MediaEngine: persistent pipeline play failed, falling back to standard backend")
        self._use_persistent_pipeline = false
    end

    local ok = false
    if self.backend == self.BACKENDS.MPV then
        ok = self:_playMpv(gen)
    elseif self.backend == self.BACKENDS.MPLAYER then
        ok = self:_playMplayer(gen)
    elseif self.backend == self.BACKENDS.FFMPEG_PIPE then
        ok = self:_playFfmpegPipe(gen)
    elseif self.backend == self.BACKENDS.GST_PLAY then
        ok = self:_playGstPlay(gen)
    elseif self.backend == self.BACKENDS.GST_PIPELINE then
        ok = self:_playGstPipeline(gen)
    elseif self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        ok = self:_playAplay(gen)
    elseif self.backend == self.BACKENDS.KINDLE_GST_PLAY then
        ok = self:_playKindleGstPlay(gen)
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        ok = self:_playKindleLipc(gen)
    elseif self.backend == self.BACKENDS.ANDROID then
        ok = self:_playAndroid(gen)
    else
        logger.err("MediaEngine: unknown backend", self.backend)
        if on_fail then on_fail("unknown backend") end
        return false
    end

    if ok then
        self.is_playing = true
        self.is_paused = false
        self._play_start_time = UIManager:getTime()
        self._pause_start_time = nil
        self._total_pause_ms = 0
    else
        self.is_playing = false
        self.is_paused = false
    end
    return ok
end

--[[--
Spawn a backend command in the background, capture its PID, and start the
position poller + completion watcher.  Every spawning backend shares this
boilerplate; only the command string and a few shell knobs differ.

@param cmd   string  the shell command to run inside `sh -c`
@param gen   number  the play generation guarding the deferred PID read
@param opts  table   optional:
  name   string   label for the temp PID file and logs (default "audio")
  exec   bool     prefix the command with `exec` (default true).  Use false
                  for pipelines: `exec a | b` would replace the shell with the
                  last stage, losing the PID we just echoed.
  setsid bool     run under setsid so kill(-pid) reaches the whole group
                  (needed for ffmpeg|gst pipelines)
  quiet  bool     redirect the wrapper's stdout/stderr to /dev/null
  delay  number   seconds to wait before reading the PID file (default 0.3)
@return true
--]]
function MediaEngine:_spawnTracked(cmd, gen, opts)
    opts = opts or {}
    local name = opts.name or "audio"
    local pid_file = self:_getTempDir() .. "/" .. name .. "-pid-" .. gen
    os.remove(pid_file)

    local setsid = ""
    if opts.setsid and self:commandExists("setsid") then setsid = "setsid " end
    local exec = (opts.exec ~= false) and "exec " or ""
    local redirect = opts.quiet and " >/dev/null 2>&1" or ""
    local wrapper = string.format(
        "%ssh -c 'echo $$ > %s; %s%s'%s &",
        setsid, pid_file, exec, cmd:gsub("'", "'\\''"), redirect)
    os.execute(wrapper)

    -- Retry PID capture a few times: on slow Kindle devices the wrapper shell
    -- may not have written the PID file within the first 0.3 s, leaving the
    -- old pipeline untracked.  An untracked pipeline keeps playing across seeks
    -- and sounds like audio looping/stuttering.
    local function try_capture_pid(attempt)
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        local pid
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            pid = tonumber(pid_str)
        end
        if pid then
            self.audio_pid = pid
            logger.warn("MediaEngine: " .. name .. " PID =", self.audio_pid)
            os.remove(pid_file)
            self:_startPositionPoller(gen)
            self:_startCompletionWatcher(gen)
        elseif attempt < 5 then
            -- Kindle + AirPods: PID file can lag >0.3s while A2DP renegotiates.
            -- Retry longer before giving up — never orphan-kill here: that was
            -- murdering the just-started stream (brief sound, then silence).
            UIManager:scheduleIn(0.25, function()
                try_capture_pid(attempt + 1)
            end)
        else
            logger.warn("MediaEngine: " .. name .. " PID capture failed after retries")
            -- Last resort: recover PID from the abk-progress ffmpeg cmdline
            -- without killing anything.
            if name == "kindle-gst" and self:_isKindle() then
                local ph = io.popen("pgrep -f 'abk-progress-" .. tostring(gen) .. "' 2>/dev/null")
                if ph then
                    local recovered = tonumber((ph:read("*l") or ""):match("%d+"))
                    ph:close()
                    if recovered then
                        self.audio_pid = recovered
                        logger.warn("MediaEngine: recovered kindle-gst PID via pgrep =", recovered)
                    end
                end
            end
            os.remove(pid_file)
            self:_startPositionPoller(gen)
            self:_startCompletionWatcher(gen)
        end
    end
    UIManager:scheduleIn(opts.delay or 0.3, function()
        try_capture_pid(1)
    end)

    return true
end

-- ---------------------------------------------------------------------------
-- Android MediaPlayer playback (Boox, KOReader Android)
-- ---------------------------------------------------------------------------

function MediaEngine:_playAndroid(gen)
    local player = self:_ensureAndroidPlayer()
    if not player then
        logger.err("MediaEngine: Android MediaPlayer unavailable")
        if self._on_fail then self._on_fail("android mediaplayer unavailable") end
        return false
    end

    pcall(function() player:stop() end)

    -- Store rate on the player before play(); JNI applies it after prepare().
    pcall(function()
        player:setSpeed(self._playback_speed or 1.0)
    end)

    local offset = self._seek_offset or 0
    local seek_ms = math.floor(offset * 1000)
    local ok = player:play(self.current_path, seek_ms)
    if not ok then
        logger.err("MediaEngine: Android play failed for", self.current_path)
        if self._on_fail then self._on_fail("android playback failed") end
        return false
    end

    local dur_ms = player:getDurationMs()
    if dur_ms and dur_ms > 0 then
        self.current_duration = dur_ms / 1000
    end

    self._android_playback_confirmed = false
    -- Match Readest-style SMIL sync: highlight at the Media Overlay clock
    -- (clipBegin), not an artificial delay.  BT/e-ink micro-skew is handled
    -- by the Overlay sync offset setting / mini-player −/+ nudge (100 ms).
    -- The old 0.25 s default made sentence underlines visibly lag the narration.
    self.position_latency_s = 0

    logger.warn("MediaEngine: Android play", self.current_path,
        "offset=", offset, "duration=", self.current_duration)

    -- Apply saved media volume (♪ buttons) as MediaPlayer gain.
    pcall(function()
        player:setVolume(self._volume or 1.0)
    end)

    self:_startAndroidCompletionWatcher(gen)
    return true
end

function MediaEngine:_startAndroidCompletionWatcher(gen)
    local player = self._android_player
    if not player then return end
    local poll_count = 0
    -- Slow playback needs proportionally more 0.1 s polls to reach the end.
    local max_polls = math.max(600,
        math.floor((self.current_duration or 300) * 10
            / math.min(1.0, math.max(0.25, self._playback_speed or 1.0))))
    local function poll()
        if self.play_generation ~= gen then return end
        if not self.is_playing then return end
        if self.is_paused then
            UIManager:scheduleIn(0.25, poll)
            return
        end
        poll_count = poll_count + 1
        if poll_count == 15 and not self._android_playback_confirmed then
            if player._ever_confirmed_playing or player._audio_started then
                self._android_playback_confirmed = true
            else
                -- Only fail if MediaPlayer never produced a progressing position.
                local pos_ms = player:getPositionMs() or 0
                local start_ms = math.floor((self._seek_offset or 0) * 1000)
                if pos_ms <= start_ms + 100 then
                    logger.err("MediaEngine: Android playback failed to start")
                    self.is_playing = false
                    if self._on_fail then
                        local cb = self._on_fail
                        self._on_fail = nil
                        cb("android playback failed to start")
                    end
                    return
                end
                self._android_playback_confirmed = true
            end
        end
        if player:isPlaying() or player._ever_confirmed_playing then
            self._android_playback_confirmed = true
        end
        if player:isPlaybackDone() then
            self.is_playing = false
            self.is_paused = false
            if self._on_complete then
                local cb = self._on_complete
                self._on_complete = nil
                cb()
            end
            return
        end
        if poll_count >= max_polls then
            logger.warn("MediaEngine: Android playback timed out")
            pcall(function() player:stop() end)
            self.is_playing = false
            if self._on_fail then
                local cb = self._on_fail
                self._on_fail = nil
                cb("android playback timeout")
            end
            return
        end
        UIManager:scheduleIn(0.2, poll)
    end
    UIManager:scheduleIn(0.4, poll)
end

function MediaEngine:_playMpv(gen)
    self:_setupMpvIpc()

    local ipc_arg
    if self:_hasLuaSocket() then
        ipc_arg = string.format('--input-ipc-server="%s"', self._socket_path)
    else
        ipc_arg = string.format('--input-file="%s"', self._fifo_path)
    end

    local cmd = string.format(
        '%s %s --no-video --really-quiet --idle=no --keep-open=no "%s" &',
        self.backend_cmd,
        ipc_arg,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mpv launch gen=", gen, "cmd=", cmd:sub(1, 200))

    -- Spawn in background and capture PID
    local pid_file = self:_getTempDir() .. "/mpv-pid-" .. gen
    os.remove(pid_file)
    local wrapper = string.format("sh -c 'echo $$ > %s; exec %s' &", pid_file, cmd)
    os.execute(wrapper)

    -- Wait briefly for PID file
    UIManager:scheduleIn(0.2, function()
        if self.play_generation ~= gen then return end
        local pf = io.open(pid_file, "r")
        if pf then
            local pid_str = pf:read("*l")
            pf:close()
            self.audio_pid = tonumber(pid_str)
            logger.warn("MediaEngine: mpv PID =", self.audio_pid)
        end
        os.remove(pid_file)
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playMplayer(gen)
    self._ipc_file = self:_getTempDir() .. "/mplayer-fifo-" .. gen
    os.remove(self._ipc_file)
    os.execute("mkfifo '" .. self._ipc_file:gsub("'", "'\\''") .. "'")

    local cmd = string.format(
        '%s -slave -input file="%s" -really-quiet -novideo "%s" &',
        self.backend_cmd,
        self._ipc_file,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: mplayer launch gen=", gen)
    os.execute(cmd)

    UIManager:scheduleIn(0.3, function()
        if self.play_generation ~= gen then return end
        self:_startPositionPoller(gen)
        self:_startCompletionWatcher(gen)
    end)

    return true
end

function MediaEngine:_playFfmpegPipe(gen)
    -- ffmpeg decodes to raw PCM; on Kobo we pipe through gstreamer
    -- to the MTK Bluetooth sink because aplay has no ALSA soundcards.
    -- We use raw s16le instead of WAV because wavparse chokes on piped
    -- WAV streams with incomplete headers.
    -- Seeking is done via process restart with -ss offset.
    -- Pause/resume uses SIGSTOP/SIGCONT on the shell PID.
    local offset = self._seek_offset or 0
    local path = self.current_path:gsub('"', '\\"')
    local ffmpeg = self.backend_cmd

    -- Detect whether to use gstreamer + mtkbtmwrpcaudiosink or fall back to aplay
    local has_mtk_sink = false
    local has_gst_launch = self:commandExists("gst-launch-1.0")
    if has_gst_launch then
        local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1 && echo yes || echo no")
        if h then
            has_mtk_sink = h:read("*l") == "yes"
            h:close()
        end
    end

    -- Raw PCM format: s16le, 44100 Hz, stereo.
    -- gstreamer pipeline uses audio/x-raw caps instead of wavparse.
    local player_cmd
    if has_mtk_sink then
        player_cmd = 'gst-launch-1.0 fdsrc fd=0 ! audio/x-raw,format=S16LE,rate=44100,channels=2 ! audioconvert ! audioresample ! mtkbtmwrpcaudiosink'
    else
        player_cmd = 'aplay -f S16_LE -r 44100 -c 2'
    end

    local atempo = self:_atempoFilterString(self._playback_speed)
    -- Splice the digital volume gain into the audio filter chain.
    local vol = self._volume or 1.0
    if math.abs(vol - 1.0) >= 0.001 then
        local vf = string.format("volume=%.3f", vol)
        if atempo == "" then
            atempo = ' -filter:a "' .. vf .. '"'
        else
            atempo = atempo:gsub('"$', "," .. vf .. '"')
        end
    end

    -- If a session recording is active, also write decoded audio to a WAV file.
    local wav_out = ""
    if self.plugin and self.plugin.session_recorder
            and self.plugin.session_recorder:isRecording() then
        local audio_dir = self.plugin.session_recorder._session_dir .. "/audio"
        os.execute('mkdir -p "' .. audio_dir:gsub('"', '\\"') .. '" 2>/dev/null')
        local wav_path = audio_dir .. "/playback.wav"
        wav_out = string.format(' -f wav "%s"', wav_path:gsub('"', '\\"'))
    end

    local cmd
    if offset > 0 then
        cmd = string.format(
            'nice -n 10 "%s" -ss %d -i "%s"%s -ar 44100 -ac 2 -f s16le -%s 2>/dev/null | %s',
            ffmpeg, math.floor(offset), path, atempo, wav_out, player_cmd
        )
    else
        cmd = string.format(
            'nice -n 10 "%s" -i "%s"%s -ar 44100 -ac 2 -f s16le -%s 2>/dev/null | %s',
            ffmpeg, path, atempo, wav_out, player_cmd
        )
    end

    logger.warn("MediaEngine: ffmpeg-pipe launch gen=", gen,
        "offset=", offset,
        "sink=", has_mtk_sink and "mtkbtmwrpcaudiosink" or "aplay",
        "wav_out=", wav_out ~= "" and "yes" or "no",
        "cmd=", cmd:sub(1, 220))

    -- Kill any stale ffmpeg/gst-launch processes before starting.
    -- Previous crashes can leave zombie processes that hold the MTK
    -- Bluetooth socket, causing "Address already in use" errors.
    os.execute("killall -9 ffmpeg gst-launch-1.0 2>/dev/null")

    -- exec=false: `exec a | b` would replace the shell with the last pipeline
    -- stage (gst-launch), losing the PID we capture.
    return self:_spawnTracked(cmd, gen, { name = "ffmpeg", exec = false })
end

function MediaEngine:_playGstPlay(gen)
    -- gst-play-1.0 has limited seeking; we use it for playback and
    -- implement seek via process restart at new position.
    -- On Kobo with MTK Bluetooth, force the correct audio sink.
    local sink_arg = ""
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink_arg = " --audiosink=mtkbtmwrpcaudiosink"
    end
    -- Best-effort time offset for seeking: append #t=<seconds> URI fragment
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        path = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
    end
    local cmd = string.format(
        '%s --quiet%s "%s"',
        self.backend_cmd,
        sink_arg,
        path
    )

    logger.warn("MediaEngine: gst-play launch gen=", gen,
        "seek_offset=", self._seek_offset or 0,
        "sink=", sink_arg ~= "" and "mtkbtmwrpcaudiosink" or "auto")

    return self:_spawnTracked(cmd, gen, { name = "gst-play" })
end

function MediaEngine:_playGstPipeline(gen)
    -- Build a decodebin pipeline for generic audio playback.
    -- Use uridecodebin when a time offset is set so GStreamer can
    -- attempt to start from that position via URI fragment (#t=).
    local sink = "autoaudiosink"
    if Device:isKobo() and os.execute("gst-inspect-1.0 mtkbtmwrpcaudiosink >/dev/null 2>&1") == 0 then
        sink = "mtkbtmwrpcaudiosink"
    end

    local cmd
    local path = self.current_path:gsub('"', '\\"')
    if self._seek_offset and self._seek_offset > 0 then
        -- uridecodebin supports #t= URI fragments for some formats
        local uri = string.format("file://%s#t=%d", path, math.floor(self._seek_offset))
        cmd = string.format(
            '%s uridecodebin uri="%s" ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            uri,
            sink
        )
    else
        cmd = string.format(
            '%s filesrc location="%s" ! decodebin ! audioconvert ! audioresample ! ' ..
            '"audio/x-raw,format=S16LE,rate=48000,channels=2" ! %s',
            self.backend_cmd,
            path,
            sink
        )
    end

    logger.warn("MediaEngine: gst-pipeline launch gen=", gen,
        "seek_offset=", self._seek_offset or 0)

    return self:_spawnTracked(cmd, gen, { name = "gst-pipe" })
end

function MediaEngine:_playAplay(gen)
    local cmd = string.format(
        '%s "%s"',
        self.backend_cmd,
        self.current_path:gsub('"', '\\"')
    )

    logger.warn("MediaEngine: aplay/wav-play launch gen=", gen)

    -- Set aplay start time for elapsed-time tracking
    self._aplay_start_time = UIManager:getTime()

    return self:_spawnTracked(cmd, gen, { name = "aplay" })
end

-- ---------------------------------------------------------------------------
-- Kindle-specific playback methods
-- ---------------------------------------------------------------------------

--[[--
Kill any previous audiobook pipeline spawned for the Kindle gst-launch-0.10
backends.  The ffmpeg path is identifiable by its -progress file path
containing "abk-progress", and every audiobook pipeline ends in
"mixersink stream-type=Music".  Calling this before starting a new stream
prevents two streams from mixing in mixersink, which the user hears as an
echo/loop.
--]]
function MediaEngine:_killOrphanKindleGstPipelines(name, wait_us, opts)
    name = name or "kindle-gst"
    opts = opts or {}
    local content_only = opts.content_only
    logger.warn("MediaEngine: killing orphan Kindle audiobook pipelines (", name,
        content_only and ", content_only" or "", ")")
    -- ffmpeg side of the ffmpeg|gst-launch pipeline.  Use multiple patterns
    -- because busybox pkill on some firmwares matches the full command line
    -- differently than procps pkill.
    os.execute("pkill -9 -f 'abk-progress' 2>/dev/null")
    os.execute("pkill -9 -f 'ffmpeg.*abk-progress' 2>/dev/null")
    os.execute("killall -9 ffmpeg 2>/dev/null")
    -- Content gst side (fdsrc → mixersink).  Keep /dev/zero keepalive alive
    -- when content_only so pause→resume does not drop the A2DP datapath.
    os.execute("pkill -9 -f 'gst-launch-0.10 fdsrc' 2>/dev/null")
    os.execute("pkill -9 -f 'kindle-gst-pid-' 2>/dev/null")
    if not content_only then
        -- Full cleanup: every Music mixersink, including TTS/audiobook keepalive.
        os.execute("pkill -9 -f 'mixersink stream-type=Music' 2>/dev/null")
        os.execute("killall -9 gst-launch-0.10 2>/dev/null")
        self._keepalive_pid = nil
    end

    -- Give the mixer a moment to release the old stream before the new one
    -- attaches; without this the new stream can still overlap the tail of the
    -- dying one.
    wait_us = wait_us or 300000
    if wait_us and wait_us > 0 then
        os.execute("usleep " .. tostring(wait_us))
    end

    if not content_only then
        -- Verify: on some firmwares pkill/killall silently fail.  Poll until no
        -- audiobook gst-launch-0.10 process remains, up to a short timeout.
        local deadline = UIManager:getTime() + 1.5
        while UIManager:getTime() < deadline do
            local h = io.popen("pgrep -c 'gst-launch-0.10' 2>/dev/null")
            local count
            if h then
                count = tonumber(h:read("*a"))
                h:close()
            end
            if not count or count == 0 then break end
            logger.warn("MediaEngine:", count, "gst-launch-0.10 still alive; re-killing")
            os.execute("killall -9 gst-launch-0.10 2>/dev/null")
            os.execute("pkill -9 -f 'mixersink stream-type=Music' 2>/dev/null")
            os.execute("usleep 100000")
        end
    end
    logger.warn("MediaEngine: orphan Kindle audiobook pipeline cleanup done (", name, ")")
end

--[[--
Play a WAV through the system gst-launch-0.10 with the pipeline verified
working on PW5/PW6 firmware:

    filesrc ! caps ! mixersink stream-type=Music sync=true

mixersink needs stream-type=Music (the only playback stream type audiomgrd
accepts) and sync=true: with the element's default sync=false the commit
vfunc is handed mismatched in/out sample counts, rejects every buffer
("MixerSink:Commit:in != out" in syslog) and the pipeline hangs silently.
audiomgrd must also be focused on 'Music' before the stream attaches.

Seeking is done by skipping bytes when stripping the WAV header.

@treturn boolean|nil true on launch, nil if the file is not a plain PCM WAV
    (caller should fall back to the bundled gst-play binary)
--]]
function MediaEngine:_playSystemGstLaunch(gen)
    local fh = io.open(self.current_path, "rb")
    if not fh then return nil end
    local header = fh:read(44)
    fh:close()
    if not header or #header < 44
        or header:sub(1, 4) ~= "RIFF" or header:sub(9, 12) ~= "WAVE" then
        -- Not a plain PCM WAV (mp3/m4b/etc.): stream bundled-ffmpeg output
        -- straight into the same mixersink pipeline.
        return self:_playSystemGstLaunchFfmpeg(gen)
    end
    local function le_u16(off)
        return string.byte(header, off) + string.byte(header, off + 1) * 256
    end
    local function le_u32(off)
        return le_u16(off) + le_u16(off + 2) * 65536
    end
    local fmt = le_u16(21)
    local channels = le_u16(23)
    local rate = le_u32(25)
    local bits = le_u16(35)
    if fmt ~= 1 or channels < 1 or channels > 2 or rate == 0
        or (bits ~= 8 and bits ~= 16) then
        return nil
    end

    -- Strip header (+ seek offset) into a raw PCM temp file.
    -- tail -c +N is 1-indexed; frame-align the seek so we never start
    -- mid-sample.
    local frame_bytes = channels * (bits / 8)
    local seek_frames = math.floor((self._seek_offset or 0) * rate)
    local skip = 44 + seek_frames * frame_bytes
    if self._system_raw_file then
        os.remove(self._system_raw_file)
    end
    local raw_file = self:_getTempDir() .. "/kindle-gst-raw-" .. gen .. ".pcm"
    -- Lead-in: audiomgrd suspends the A2DP datapath while idle and resume
    -- takes a few hundred ms after the stream attaches, swallowing the
    -- start of the clip; half a second of silence up front absorbs that.
    -- Tail: at EOS the pipeline tears down while the ring buffer and BT
    -- chain still hold ~1 s of audio, cutting off the end.
    local rc = os.execute(string.format(
        "( dd if=/dev/zero bs=%d count=1 2>/dev/null;"
        .. " tail -c +%d '%s';"
        .. " dd if=/dev/zero bs=%d count=1 2>/dev/null ) > '%s' 2>/dev/null",
        -- whole frames only: a non-frame-aligned pad byte count shifts all
        -- following 16-bit samples and turns the payload into white noise
        math.floor(rate / 2) * frame_bytes,
        skip + 1,
        self.current_path:gsub("'", "'\\''"),
        rate * frame_bytes,
        raw_file:gsub("'", "'\\''")))
    if rc ~= 0 and rc ~= true then
        os.remove(raw_file)
        return nil
    end
    self._system_raw_file = raw_file
    -- What the user hears lags wall-clock position by the lead-in pad plus
    -- the mixer ring (~0.9 s) and BT chain (~0.3 s); the sync loop
    -- subtracts this so highlights match the audible audio.
    self.position_latency_s = 1.7

    -- Sweep shm stream files orphaned by pipelines killed mid-play
    -- (pause/seek), then take audio focus before the stream attaches.
    os.execute("for f in /dev/shm/mstream*; do p=${f#/dev/shm/mstream}; p=${p%%_*};"
        .. " [ -d /proc/$p ] || rm -f \"$f\"; done 2>/dev/null")
    local apple = self:_isAppleAirPodsHeadset()
    if apple and not self:_kindleA2dpRouteUp() then
        MediaEngine._clearMusicFocusFlag()
        MediaEngine._takeMusicFocusOnce(true)
    else
        MediaEngine._takeMusicFocusOnce()
    end
    if apple then
        self.position_latency_s = 2.2
    end

    -- Nuke any previous audiobook gst-launch-0.10 pipeline before attaching
    -- a new stream to mixersink.  If the old pipeline is still draining its
    -- ring buffer while the new one starts, the user hears both streams as an
    -- echo/loop ("this is this is an an example example").
    self:_killOrphanKindleGstPipelines("kindle-gst-wav", 150000,
        self._keepalive_pid and { content_only = true } or nil)

    local caps = string.format(
        "audio/x-raw-int,endianness=1234,signed=true,width=%d,depth=%d,rate=%d,channels=%d",
        bits, bits, rate, channels)
    local cmd = string.format(
        "gst-launch-0.10 filesrc location='%s' ! capsfilter caps='%s'"
        .. " ! mixersink stream-type=Music sync=true",
        raw_file:gsub("'", "'\\''"), caps)
    logger.warn("MediaEngine: system gst-launch gen=", gen,
        "rate=", rate, "ch=", channels, "seek_offset=", self._seek_offset or 0,
        "apple_airpods=", apple and "yes" or "no")

    local ok = self:_spawnTracked(cmd, gen, { name = "kindle-gst", quiet = true })
    if ok then
        self:_startA2dpWatchdog(gen)
    end
    return ok
end

--[[--
Play a non-WAV file (mp3/m4b/aac/...) on Kindle by streaming bundled-ffmpeg
output into the system GStreamer:

    ffmpeg -ss <seek> -i file -f s16le -ar 22050 -ac 1 -af apad=pad_dur=1 -
      | gst-launch-0.10 fdsrc ! caps ! mixersink stream-type=Music sync=true

Verified on PW5 against Storyteller EPUB audio.  No temp files, instant
start, seeking via ffmpeg -ss.  22050/mono is deliberate: audiomgrd's
output record is mono and resamples to 48 kHz anyway, and the lower input
rate keeps the decode cheap on this CPU.  apad appends the 1 s tail that
would otherwise be swallowed by the ring/BT chain at EOS.

@treturn boolean|nil true on launch, nil when ffmpeg or gst-launch are
    unavailable (caller falls back to the bundled gst-play binary)
--]]
function MediaEngine:_playSystemGstLaunchFfmpeg(gen)
    local ffmpeg = self:_findFfmpeg()
    if not ffmpeg or not self:commandExists("gst-launch-0.10") then
        return nil
    end

    -- Guarantee a single audiobook pipeline: kill any still-running ffmpeg
    -- stream before starting a new one.  PID capture is asynchronous, so a
    -- rapid restart (seek / volume change) that lands inside that window never
    -- tracks the freshly spawned pipeline; stop() then can't kill it and it
    -- keeps playing -> overlapping audio.
    self:_killOrphanKindleGstPipelines("kindle-gst-ffmpeg", 150000,
        self._keepalive_pid and { content_only = true } or nil)

    -- Take focus after the old pipeline has had a moment to tear down.
    -- AirPods: if the A2DP route is down, force a fresh Music focus so
    -- audiomgrd re-binds the headset (once-per-session is not enough).
    local apple = self:_isAppleAirPodsHeadset()
    if apple and not self:_kindleA2dpRouteUp() then
        MediaEngine._clearMusicFocusFlag()
        MediaEngine._takeMusicFocusOnce(true)
    else
        MediaEngine._takeMusicFocusOnce()
    end

    local seek = self._seek_offset or 0

    -- Position is read from ffmpeg's own -progress feed (out_time) instead of
    -- wall-clock.  Because the downstream mixersink (sync=true) throttles
    -- consumption to realtime, ffmpeg is back-pressured to realtime and its
    -- out_time reflects exactly how far the decoded stream has been pushed --
    -- immune to the variable spawn/decode startup delay and to CPU stalls
    -- (if ffmpeg stalls, out_time freezes and the highlight waits instead of
    -- creeping ahead).  See getPosition() / _readLastOutTime().
    local progress_file = self:_getTempDir() .. "/abk-progress-" .. gen
    os.remove(progress_file)
    self._progress_file = progress_file
    self._use_progress_position = true

    -- adelay lead-in absorbs A2DP datapath resume (otherwise swallows start);
    -- apad covers ring/BT buffers at EOS.  AirPods Pro need a longer lead-in
    -- before the AAC/SBC sink is ready to accept PCM.
    local adelay_ms = apple and 900 or 500
    local apad_s = apple and 1.5 or 1.0
    -- adelay prepends silence inside the decoded stream; getPosition() subtracts it.
    self._progress_adelay_s = adelay_ms / 1000

    -- :all=1 is required because the input may be stereo: without it adelay
    -- would delay only channel 0 and -ac 1 would mix delayed left with
    -- undelayed right, producing a persistent echo.
    local pipeline = string.format(
        "%s -loglevel error -progress '%s' -nostats -ss %.3f -i '%s'"
        .. " -f s16le -ar 22050 -ac 1"
        .. " -af adelay=%d:all=1%s,apad=pad_dur=%.1f - 2>/dev/null"
        .. " | gst-launch-0.10 fdsrc"
        .. " ! 'audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234'"
        .. " ! mixersink stream-type=Music sync=true",
        ffmpeg:gsub("'", "'\\''"), progress_file:gsub("'", "'\\''"), seek,
        self.current_path:gsub("'", "'\\''"), adelay_ms, self:_volumeFilterPart(), apad_s)
    -- out_time is the PRODUCER side: it leads what the listener hears by the
    -- whole downstream buffer -- OS pipe (~1.5 s when full) + gst/mixersink
    -- ring (~0.9 s) + BT chain (~0.3 s) ~= 2.7 s.  AirPods buffer a bit more.
    self.position_latency_s = apple and 3.2 or 2.7
    logger.warn("MediaEngine: system gst-launch (ffmpeg stream) gen=", gen,
        "seek_offset=", seek, "progress=", progress_file,
        "apple_airpods=", apple and "yes" or "no",
        "adelay_ms=", adelay_ms)

    -- setsid: the wrapper shell becomes a process-group leader so stop()'s
    -- kill(-pid) takes down ffmpeg AND gst-launch; without it the pipeline
    -- would be orphaned and keep playing.  exec=false: it's a pipeline.
    local ok = self:_spawnTracked(pipeline, gen,
        { name = "kindle-gst", setsid = true, exec = false, quiet = true })
    if ok then
        self:_startA2dpWatchdog(gen)
        -- Drop transitional keepalive once content is attached (not pause keepalive).
        UIManager:scheduleIn(1.5, function()
            if self.play_generation ~= gen then return end
            if not self.is_playing or self.is_paused then return end
            local reason = self._keepalive_reason
            if reason == "play-bridge" or reason == "seek-bridge"
                or reason == "track-advance" or reason == "fix-audio"
                or reason == "route-recovery" then
                self:_stopKindleA2dpKeepalive(reason)
            end
        end)
    end
    return ok
end

-- ---------------------------------------------------------------------------
-- Persistent GStreamer pipeline for MTK Bluetooth (Kobo)
-- Keeps gst-launch alive across seeks and pause/resume so the exclusive
-- mtkbtmwrpcaudiosink abstract socket is never torn down.
-- ---------------------------------------------------------------------------

function MediaEngine:_writePersistentPipelineScript()
    local sr = 44100
    local channels = 2
    local silence_samples = math.floor(sr * 0.05)
    local silence_bytes = silence_samples * channels * 2
    -- Use the same ffmpeg binary that backend detection selected (usually the
    -- bundled one in plugins/audiobook.koplugin/bin/ffmpeg).  The bare 'ffmpeg'
    -- command is not in PATH on Kobo, so the script silently failed to decode
    -- any audio and users heard silence while TTS (which does not use ffmpeg)
    -- worked fine.
    local ffmpeg = self.backend_cmd or "ffmpeg"
    local script = string.format([=[
#!/bin/sh
CTRL="%s"
FIFO="%s"
FFMPEG="%s"
mkdir -p "$CTRL"
rm -f "$CTRL/stop" "$CTRL/play" "$CTRL/pause" "$CTRL/done" "$CTRL/gst_pid" "$CTRL/pipeline_stderr"
rm -f "$FIFO"
mkfifo "$FIFO"
# Silence chunk: ~50ms at %dHz 16-bit stereo = %d bytes
dd if=/dev/zero bs=%d count=1 of="$CTRL/s.raw" 2>/dev/null
gst-launch-1.0 filesrc location="$FIFO" \
  ! rawaudioparse use-sink-caps=false format=pcm pcm-format=s16le sample-rate=%d num-channels=%d \
  ! audioconvert ! audioresample \
  ! "audio/x-raw,format=S16LE,rate=48000,channels=2" \
  ! queue max-size-time=500000000 max-size-bytes=131072 \
  ! mtkbtmwrpcaudiosink sync=false >/dev/null 2>"$CTRL/pipeline_stderr" &
GST_PID=$!
exec 3>"$FIFO"
echo $GST_PID > "$CTRL/gst_pid"
cleanup() { exec 3>&- 2>/dev/null; kill $GST_PID 2>/dev/null; rm -f "$FIFO" "$CTRL/s.raw" "$CTRL/gst_pid" "$CTRL/pipeline_stderr" "$CTRL/pause"; }
trap cleanup EXIT TERM
CURRENT_FFMPEG_PID=""
while kill -0 $GST_PID 2>/dev/null && [ ! -f "$CTRL/stop" ]; do
  if [ -f "$CTRL/pause" ]; then
    rm -f "$CTRL/pause"
    if [ -n "$CURRENT_FFMPEG_PID" ]; then
      kill -9 $CURRENT_FFMPEG_PID 2>/dev/null || true
      wait $CURRENT_FFMPEG_PID 2>/dev/null || true
      CURRENT_FFMPEG_PID=""
    fi
  fi
  if [ -f "$CTRL/play" ]; then
    FILE=$(sed -n '1p' "$CTRL/play")
    OFFSET=$(sed -n '2p' "$CTRL/play")
    FILT=$(sed -n '3p' "$CTRL/play")
    WAV_OUT=$(sed -n '4p' "$CTRL/play")
    rm -f "$CTRL/play" "$CTRL/done"
    if [ -n "$CURRENT_FFMPEG_PID" ]; then
      # SIGKILL and a tiny wait so the new ffmpeg starts quickly; a lingering
      # tail of old-volume audio is less jarring than a long pause while we
      # politely wait for SIGTERM shutdown.
      kill -9 $CURRENT_FFMPEG_PID 2>/dev/null || true
      wait $CURRENT_FFMPEG_PID 2>/dev/null || true
      CURRENT_FFMPEG_PID=""
    fi
    if [ -n "$FILT" ]; then
      "$FFMPEG" -ss "$OFFSET" -i "$FILE" -filter:a "$FILT" -f s16le -ar 44100 -ac 2 - $WAV_OUT >&3 2>>"$CTRL/pipeline_stderr" &
    else
      "$FFMPEG" -ss "$OFFSET" -i "$FILE" -f s16le -ar 44100 -ac 2 - $WAV_OUT >&3 2>>"$CTRL/pipeline_stderr" &
    fi
    CURRENT_FFMPEG_PID=$!
  fi
  if [ -z "$CURRENT_FFMPEG_PID" ] || ! kill -0 $CURRENT_FFMPEG_PID 2>/dev/null; then
    CURRENT_FFMPEG_PID=""
    cat "$CTRL/s.raw" >&3
  fi
  usleep 1000
done
if [ -n "$CURRENT_FFMPEG_PID" ]; then
  kill $CURRENT_FFMPEG_PID 2>/dev/null || true
  wait $CURRENT_FFMPEG_PID 2>/dev/null || true
fi
]=], self._media_ctrl_dir, self._media_fifo, ffmpeg:gsub("'", "'\\''"), sr, silence_bytes, silence_bytes, sr, channels)
    local f = io.open(self._media_script, "w")
    if not f then return false end
    f:write(script)
    f:close()
    os.execute("chmod +x " .. self._media_script)
    return true
end

function MediaEngine:_startPersistentPipeline()
    self:_stopPersistentPipeline("restart")

    -- Wait for the exclusive MTK socket to be released.
    for attempt = 1, 5 do
        local pf = io.open("/proc/net/unix", "r")
        if pf then
            local content = pf:read("*a")
            pf:close()
            if not content:find("@kobo:mtkbtmwrpc") then
                break
            end
            logger.warn("MediaEngine: mtkbtmwrpc socket still held, attempt", attempt)
            os.execute("killall -9 gst-launch-1.0 2>/dev/null")
            os.execute("usleep 200000")
        else
            break
        end
    end

    if not self:_writePersistentPipelineScript() then
        logger.err("MediaEngine: cannot write persistent pipeline script")
        return false
    end

    os.execute("rm -f " .. self._media_ctrl_dir .. "/stop " .. self._media_ctrl_dir .. "/play " .. self._media_ctrl_dir .. "/pause " .. self._media_ctrl_dir .. "/done")

    -- Launch the wrapper in its own session/process group (setsid) so that
    -- stop() can reliably kill the wrapper and its ffmpeg/gst-launch children
    -- without affecting KOReader itself.
    local setsid_prefix = self:commandExists("setsid") and "setsid " or ""
    local h = io.popen(setsid_prefix .. self._media_script .. " >/dev/null 2>/dev/null & echo $!")
    local pid_str = h and h:read("*a") or ""
    if h then h:close() end
    self._pipeline_wrapper_pid = tonumber(pid_str:match("(%d+)"))

    local gst_pid = nil
    for iter = 1, 60 do
        local pf = io.open(self._media_ctrl_dir .. "/gst_pid", "r")
        if pf then
            local pid = pf:read("*a")
            pf:close()
            gst_pid = tonumber((pid or ""):match("(%d+)"))
            if gst_pid then break end
        end
        os.execute("usleep 50000")
    end

    self._pipeline_gst_pid = gst_pid
    self.audio_pid = gst_pid
    self._persistent_pipeline_active = true

    -- Shrink the FIFO pipe buffer from 64KB to 16KB.  At 44100Hz stereo 16-bit
    -- (~176KB/s) a 64KB buffer holds ~370ms of decoded audio; when switching
    -- ffmpeg (volume change / seek) that old audio plays at the old level before
    -- the new stream reaches the sink, causing a audible stutter.  16KB is
    -- ~90ms, enough to absorb CPU stalls but short enough to keep switching
    -- artifacts brief.
    self._pipe_buffer_delay_ms = 400
    if gst_pid then
        local bit = require("bit")
        local O_WRONLY = 1
        local O_NONBLOCK = 2048
        local F_SETPIPE_SZ = 1031
        local fd = ffi.C.open(self._media_fifo, bit.bor(O_WRONLY, O_NONBLOCK))
        if fd >= 0 then
            local ret = ffi.C.fcntl(fd, F_SETPIPE_SZ, ffi.new("int", 16384))
            if ret >= 0 then
                self._pipe_buffer_delay_ms = 90
                logger.warn("MediaEngine: persistent pipeline FIFO shrunk to 16KB")
            else
                logger.warn("MediaEngine: fcntl F_SETPIPE_SZ failed, errno=", ffi.errno())
            end
            ffi.C.close(fd)
        else
            logger.warn("MediaEngine: could not open FIFO for pipe resize, errno=", ffi.errno())
        end
    end

    if gst_pid then
        logger.warn("MediaEngine: persistent pipeline started, wrapper=", self._pipeline_wrapper_pid, "gst=", gst_pid)
        return true
    end

    logger.err("MediaEngine: persistent pipeline failed to start")
    self:_stopPersistentPipeline("start_failed")
    return false
end

function MediaEngine:_stopPersistentPipeline(reason)
    reason = reason or "unknown"
    logger.warn("MediaEngine: _stopPersistentPipeline, reason=", reason, "gst_pid=", self._pipeline_gst_pid)

    local sf = io.open(self._media_ctrl_dir .. "/stop", "w")
    if sf then sf:write("1"); sf:close() end

    if self._pipeline_gst_pid then
        os.execute("kill -9 " .. self._pipeline_gst_pid .. " 2>/dev/null")
    end
    if self._pipeline_wrapper_pid then
        os.execute("kill -9 " .. self._pipeline_wrapper_pid .. " 2>/dev/null")
    end
    os.execute("killall -9 gst-launch-1.0 2>/dev/null")

    if self._pipeline_wrapper_pid then
        for _ = 1, 20 do
            local pf = io.open("/proc/" .. self._pipeline_wrapper_pid .. "/status", "r")
            if not pf then break end
            pf:close()
            os.execute("usleep 50000")
        end
    end

    os.execute("rm -rf " .. self._media_ctrl_dir)
    os.execute("rm -f " .. self._media_fifo .. " " .. self._media_script)

    self._pipeline_gst_pid = nil
    self._pipeline_wrapper_pid = nil
    self._persistent_pipeline_active = false
end

-- Build the ffmpeg -filter:a chain used by the persistent MTK pipeline.
-- Combines speed (atempo) and digital volume gain so both take effect
-- without duplicating the construction logic in play() and seek().
function MediaEngine:_persistentFilterChain()
    local filter_arg = self:_atempoFilterString(self._playback_speed or 1.0)
    local filter_chain = filter_arg:match('-filter:a%s*"(.-)"') or ""
    local vol_part = self:_volumeFilterPart()
    if vol_part ~= "" then
        if filter_chain ~= "" then
            filter_chain = filter_chain .. vol_part
        else
            filter_chain = vol_part:sub(2) -- drop leading comma
        end
    end
    return filter_chain
end

function MediaEngine:_playPersistentPipeline(gen)
    if not self._persistent_pipeline_active then
        if not self:_startPersistentPipeline() then
            logger.err("MediaEngine: persistent pipeline unavailable, disabling for this session")
            self._use_persistent_pipeline = false
            return false
        end
    end

    local filter_chain = self:_persistentFilterChain()

    -- If a session recording is active, also write decoded audio to a WAV file.
    -- Use the persisted session directory so the WAV tee works even after the
    -- plugin widget is recreated on document open.
    local wav_out = ""
    local session_dir = nil
    if self.plugin and self.plugin.session_recorder then
        if self.plugin.session_recorder:isRecording() and self.plugin.session_recorder._session_dir then
            session_dir = self.plugin.session_recorder._session_dir
        else
            local last_dir = self.plugin:getSetting("session_recorder_last_dir", nil)
            if last_dir then
                local pid_path = last_dir .. "/.video.pid"
                local pid_f = io.open(pid_path, "r")
                if pid_f then
                    local pid = tonumber(pid_f:read("*l") or "")
                    pid_f:close()
                    if pid and io.open("/proc/" .. pid, "r") then
                        session_dir = last_dir
                    end
                end
            end
        end
    end
    if session_dir then
        local audio_dir = session_dir .. "/audio"
        os.execute('mkdir -p "' .. audio_dir:gsub('"', '\\"') .. '" 2>/dev/null')
        local wav_path = audio_dir .. "/playback.wav"
        wav_out = string.format(' -f wav "%s"', wav_path:gsub('"', '\\"'))
        logger.warn("MediaEngine: session wav_out enabled:", wav_path)
    else
        logger.warn("MediaEngine: no active session dir for wav_out")
    end

    os.remove(self._media_ctrl_dir .. "/done")
    local f = io.open(self._media_ctrl_dir .. "/play", "w")
    if not f then
        logger.err("MediaEngine: cannot write play control file")
        return false
    end
    f:write(self.current_path .. "\n")
    f:write(tostring(self._seek_offset or 0) .. "\n")
    f:write(filter_chain .. "\n")
    f:write(wav_out .. "\n")
    f:close()

    self._play_start_time = UIManager:getTime()
    self._pause_start_time = nil
    self._total_pause_ms = 0
    self.is_playing = true
    self.is_paused = false

    self:_startPositionPoller(gen)
    if self.current_duration and self.current_duration > 0 then
        self:_startPersistentCompletionWatcher(gen, self.current_duration)
    else
        logger.warn("MediaEngine: unknown duration, skipping completion watcher for persistent pipeline")
    end

    return true
end

function MediaEngine:_startPersistentCompletionWatcher(gen, duration)
    duration = duration or 0
    local pipe_delay_ms = self._pipe_buffer_delay_ms or 400
    local engine = self
    local function check()
        if engine.play_generation ~= gen then return end
        if not engine.is_playing then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.5, check)
            return
        end
        if engine._play_start_time then
            local wall_ms = time.to_ms(UIManager:getTime() - engine._play_start_time)
            local real_ms = wall_ms - (engine._total_pause_ms or 0)
            local needed_ms = duration * 1000 + pipe_delay_ms + 500
            if real_ms < needed_ms then
                local wait_s = (needed_ms - real_ms) / 1000
                if wait_s < 0.2 then wait_s = 0.2 end
                UIManager:scheduleIn(wait_s, check)
                return
            end
        end
        logger.warn("MediaEngine: persistent pipeline playback complete")
        engine.is_playing = false
        engine.is_paused = false
        if engine._on_complete then
            local cb = engine._on_complete
            engine._on_complete = nil
            cb()
        end
    end
    local initial_delay_s = duration + (pipe_delay_ms / 1000) + 0.5
    UIManager:scheduleIn(initial_delay_s, check)
end

function MediaEngine:_playKindleGstPlay(gen)
    -- Prefer the system gst-launch-0.10 pipeline (verified working on
    -- PW5/PW6, see _playSystemGstLaunch).  The bundled gst-play binary
    -- sets neither stream-type nor sync on mixersink and hangs on these
    -- firmwares.  Fall back to it only for non-PCM-WAV input or when
    -- gst-launch-0.10 is missing.
    if self:commandExists("gst-launch-0.10") then
        local ok = self:_playSystemGstLaunch(gen)
        if ok then return ok end
    end

    if not (self._gst_play_cmd or self.backend_cmd) then
        -- Diagnose the most common Kindle failure: the file is not a plain
        -- PCM WAV and the bundled ffmpeg decoder is missing.  The system
        -- GStreamer on these devices has no mp3/aac/wavparse plugins, so
        -- without ffmpeg there is no way to decode Audiobookshelf tracks.
        local is_wav = false
        local fh = io.open(self.current_path, "rb")
        if fh then
            local header = fh:read(12)
            fh:close()
            is_wav = header and #header >= 12
                and header:sub(1, 4) == "RIFF"
                and header:sub(9, 12) == "WAVE"
        end
        local has_ffmpeg = self:_findFfmpeg() ~= nil
        logger.err("MediaEngine: no bundled gst-play and system pipeline failed",
            "is_wav=", is_wav, "has_ffmpeg=", has_ffmpeg)
        if self._on_fail then
            if not is_wav and not has_ffmpeg then
                self._on_fail(_("Cannot play this audio file. Kindle's GStreamer can only play raw PCM WAV files; MP3/M4B/AAC files need the bundled ffmpeg decoder. Please install the release .zip (not 'Source code') from GitHub so plugins/audiobook.koplugin/bin/ffmpeg is present."))
            else
                self._on_fail("no usable Kindle audio pipeline")
            end
        end
        return false
    end

    -- kindle/gst-play: a custom binary that feeds raw PCM to GStreamer's
    -- mixersink element, bypassing the missing wavparse on stripped firmware.
    -- The binary reads WAV files, strips the header, and pipes PCM to
    -- mixersink → audiomgrd → BT headphones.
    --
    -- Seeking: use the --seek=<seconds> argument.  Re-launch on seek.
    local gst_cmd = self._gst_play_cmd or self.backend_cmd

    -- Add seek offset if present
    local args = ""
    if self._seek_offset and self._seek_offset > 0 then
        args = string.format(" --seek=%d", math.floor(self._seek_offset))
    end

    local path = self.current_path:gsub('"', '\\"')
    local cmd = string.format(
        '%s%s "%s"',
        gst_cmd,
        args,
        path
    )
    logger.warn("MediaEngine: kindle-gst-play launch gen=", gen,
        "seek_offset=", self._seek_offset or 0)

    return self:_spawnTracked(cmd, gen, { name = "kindle-gst" })
end

function MediaEngine:_playKindleLipc(gen)
    -- Kindle LIPC: use Amazon's playermgr service via lipc-set-prop
    -- to play audio files.  playermgr uses GStreamer internally and
    -- routes audio through audiomgrd → BT headphones.
    --
    -- Seeking: seek-by-restart using Open + Play with the requested
    -- time offset approximated by InPlayback polling.
    --
    -- Supported file formats: MP3, AAC, possibly WAV (depends on
    -- wavparse availability in the device's GStreamer installation).
    -- The transcoder in main.lua already converts unsupported formats
    -- to MP3 or WAV before reaching MediaEngine.

    local file_path = self.current_path

    -- Stop any previous playback first
    os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")

    -- Request audio focus from audiomgrd
    os.execute("lipc-set-prop com.lab126.audiomgrd setFocus 'audiobook' 2>/dev/null")

    -- Enable GStreamer debug logging
    os.execute("lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>/dev/null")

    -- Helper to run LIPC commands and capture output
    local function lipc_cmd(cmd)
        local h = io.popen(cmd .. " 2>&1")
        local out = ""
        if h then out = h:read("*a") or ""; h:close() end
        return out
    end

    -- Try multiple strategies to start playback:
    local file_uri = "file://" .. file_path
    local started = false
    local strategies = {
        {name = "Open(URI)+Play", cmd1 = string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_uri),
            cmd2 = "lipc-set-prop com.lab126.playermgr Play ''"},
        {name = "Open(path)+Play", cmd1 = string.format(
            "lipc-set-prop com.lab126.playermgr Open '%s'", file_path),
            cmd2 = "lipc-set-prop com.lab126.playermgr Play ''"},
        {name = "Play(URI)", cmd1 = "", cmd2 = string.format(
            "lipc-set-prop com.lab126.playermgr Play '%s'", file_uri)},
        {name = "Play(path)", cmd1 = "", cmd2 = string.format(
            "lipc-set-prop com.lab126.playermgr Play '%s'", file_path)},
    }

    for _, s in ipairs(strategies) do
        if started then break end
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
        if s.cmd1 ~= "" then
            local out1 = lipc_cmd(s.cmd1)
            logger.warn("MediaEngine: kindle-lipc", s.name, "Open:", out1)
        end
        local out2 = lipc_cmd(s.cmd2)
        logger.warn("MediaEngine: kindle-lipc", s.name, "Play:", out2)

        -- Check if playback started
        local in_play = lipc_cmd("lipc-get-prop com.lab126.playermgr InPlayback")
        started = in_play:match("^%s*(%d+)") == "1"
        logger.warn("MediaEngine: kindle-lipc InPlayback:", in_play, "for strategy:", s.name)
    end

    if not started then
        logger.err("MediaEngine: Kindle LIPC -- none of 4 strategies got InPlayback=1")
        -- Try fallback to gst-play once
        if self._gst_play_cmd and not self._lipc_fallback_tried then
            self._lipc_fallback_tried = true
            logger.warn("MediaEngine: kindle-lipc failed, falling back to kindle-gst-play")
            self.backend = self.BACKENDS.KINDLE_GST_PLAY
            self.backend_cmd = self._gst_play_cmd
            return self:_playKindleGstPlay(gen)
        end
        self.is_playing = false
        if self._on_fail then
            local cb = self._on_fail
            self._on_fail = nil
            cb("kindle-lipc playback failed")
        end
        return false
    end

    self._lipc_fallback_tried = false
    self._audio_launched_at = UIManager:getTime()
    logger.warn("MediaEngine: kindle-lipc playback started")

    self:_startPositionPoller(gen)

    -- For Kindle LIPC, completion is detected by polling the InPlayback
    -- property instead of PID-based process watcher (playermgr is a
    -- system daemon, not a child process we spawned).
    local engine = self
    local poll_count = 0
    local dur_ms = (self.current_duration or 3600) * 1000
    local max_polls = math.max(300, math.floor(dur_ms * 3 / 100))
    local startup_polls = 5
    local ever_playing = false
    local function pollLipcDone()
        if engine.play_generation ~= gen then return end
        if not engine.is_playing then return end
        if engine.is_paused then
            UIManager:scheduleIn(0.3, pollLipcDone)
            return
        end
        poll_count = poll_count + 1
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
                        logger.warn("MediaEngine: Kindle LIPC playback complete, elapsed=",
                            elapsed_ms, "ms")
                        engine.is_playing = false
                        if engine._on_complete then
                            local cb = engine._on_complete
                            engine._on_complete = nil
                            cb()
                        end
                        return
                    elseif elapsed_ms > 5000 then
                        -- Never started playing after 5 seconds → failure
                        logger.err("MediaEngine: Kindle LIPC playback never started, elapsed=",
                            elapsed_ms, "ms")
                        engine.is_playing = false
                        if engine._on_fail then
                            local cb = engine._on_fail
                            engine._on_fail = nil
                            cb("playback never started")
                        end
                        return
                    end
                end
            end
        end
        if poll_count > max_polls then
            logger.warn("MediaEngine: Kindle LIPC max polls reached, forcing stop")
            engine.is_playing = false
            if engine._on_complete then
                local cb = engine._on_complete
                engine._on_complete = nil
                cb()
            end
            return
        end
        UIManager:scheduleIn(0.1, pollLipcDone)
    end
    UIManager:scheduleIn(0.1, pollLipcDone)
    return true
end

-- ---------------------------------------------------------------------------
-- Position polling
-- ---------------------------------------------------------------------------

function MediaEngine:_startPositionPoller(gen)
    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    local function poll()
        if self.play_generation ~= gen or not self.is_playing then
            return
        end
        -- Poll at 1Hz for position updates (e-ink friendly rate)
        self._position_timer = UIManager:scheduleIn(1.0, poll)
    end

    self._position_timer = UIManager:scheduleIn(1.0, poll)
end

--- Kindle A2DP watchdog: if audiomgrd drops the output route mid-play
--- (common with AirPods Pro renegotiating AAC), re-take Music focus and
--- soft-restart once at the current position.
function MediaEngine:_startA2dpWatchdog(gen)
    if not self:_isKindle() then return end
    if self._a2dp_watchdog_gen == gen then return end
    self._a2dp_watchdog_gen = gen
    local misses = 0
    local function tick()
        if self.play_generation ~= gen then return end
        if not self.is_playing or self.is_paused then return end
        if self:_kindleA2dpRouteUp() then
            misses = 0
            -- Healthy play lasting a few ticks clears one-shot recovery flags.
            self._a2dp_auto_retry_done = nil
            self._a2dp_route_restart_done = nil
        else
            misses = misses + 1
            logger.warn("MediaEngine: A2DP route down (miss=", misses, ")")
            if misses >= 2 then
                MediaEngine._clearMusicFocusFlag()
                MediaEngine._takeMusicFocusOnce(true)
                if not self._a2dp_route_restart_done then
                    self._a2dp_route_restart_done = true
                    local pos = 0
                    pcall(function() pos = self:getPosition() or 0 end)
                    local complete_cb = self._on_complete
                    local fail_cb = self._on_fail
                    self._seek_offset = math.max(0, pos)
                    logger.warn("MediaEngine: A2DP route recovery — BT cycle + restart at",
                        self._seek_offset)
                    -- Park keepalive while cycling so we do not go fully idle.
                    self:_startKindleA2dpKeepalive("route-recovery")
                    self:_cycleKindleA2dpRoute(function(ok)
                        if self.play_generation ~= gen then return end
                        logger.warn("MediaEngine: route recovery cycle ok=", ok and "yes" or "no")
                        self:play(complete_cb, fail_cb)
                        UIManager:scheduleIn(1.2, function()
                            self:_stopKindleA2dpKeepalive()
                        end)
                    end)
                    return
                end
                misses = 0
            end
        end
        UIManager:scheduleIn(1.5, tick)
    end
    UIManager:scheduleIn(2.0, tick)
end

function MediaEngine:_startCompletionWatcher(gen)
    -- Watch for process exit via PID polling
    local function check()
        if self.play_generation ~= gen then return end
        if not self.is_playing then return end

        -- Check if process is still alive
        if self.audio_pid then
            local h = io.open("/proc/" .. self.audio_pid .. "/status", "r")
            if not h then
                -- Process exited.  Distinguish EOS from a premature A2DP drop
                -- (AirPods Pro often kill the stream after a short blip).
                local pos = 0
                pcall(function() pos = self:getPosition() or 0 end)
                local dur = tonumber(self.current_duration) or 0
                -- Avoid false positives on short SMIL clips (1–3 s): only treat
                -- as premature when clearly far from natural EOS.
                local premature = false
                if dur > 4 then
                    premature = pos < (dur - 1.5)
                elseif dur > 0 then
                    premature = pos < (dur * 0.45)
                else
                    premature = pos < 1.0
                end

                self.is_playing = false
                self.is_paused = false
                self.audio_pid = nil

                if premature and self:_isKindle() then
                    logger.warn("MediaEngine: premature pipeline exit at", pos,
                        "dur=", dur, "— treating as fail (A2DP recovery)")
                    MediaEngine._clearMusicFocusFlag()
                    MediaEngine._takeMusicFocusOnce(true)
                    local fail_cb = self._on_fail
                    local complete_cb = self._on_complete
                    self._on_fail = nil
                    self._on_complete = nil
                    -- One automatic restart for Apple headsets / Kindle GST.
                    if not self._a2dp_auto_retry_done
                        and (self:_isAppleAirPodsHeadset()
                            or self.backend == self.BACKENDS.KINDLE_GST_PLAY) then
                        self._a2dp_auto_retry_done = true
                        self._seek_offset = math.max(0, pos)
                        UIManager:scheduleIn(0.6, function()
                            if self.play_generation ~= gen then return end
                            logger.warn("MediaEngine: A2DP auto-retry at", self._seek_offset)
                            self:play(complete_cb, fail_cb)
                        end)
                        return
                    end
                    if fail_cb then
                        fail_cb("premature pipeline exit")
                    elseif complete_cb then
                        -- No fail handler: avoid advancing SMIL as if EOS.
                        logger.warn("MediaEngine: premature exit, no on_fail; not completing")
                    end
                    return
                end

                self._a2dp_auto_retry_done = nil
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
            h:close()
        end

        -- For backends without IPC, estimate completion from elapsed time.
        -- Skip this on the ffmpeg -progress path: out_time is the producer
        -- side and reaches the end while ~the downstream buffer is still
        -- draining, so a position>=duration test would clip each chapter's
        -- tail.  There, completion is driven purely by PID exit above (the
        -- wrapper shell lives until gst-launch finishes actual playout).
        if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY
            or self.backend == self.BACKENDS.GST_PLAY or self.backend == self.BACKENDS.GST_PIPELINE
            or self.backend == self.BACKENDS.KINDLE_GST_PLAY or self.backend == self.BACKENDS.ANDROID)
            and not self._use_progress_position
            and self._play_start_time and self.current_duration then
            local pos = self:getPosition()
            if pos >= self.current_duration then
                self.is_playing = false
                self.is_paused = false
                if self._on_complete then
                    local cb = self._on_complete
                    self._on_complete = nil
                    cb()
                end
                return
            end
        end

        UIManager:scheduleIn(0.5, check)
    end

    UIManager:scheduleIn(1.0, check)
end

-- ---------------------------------------------------------------------------
-- Pause / Resume / Stop
-- ---------------------------------------------------------------------------

function MediaEngine:pause()
    if not self.is_playing or self.is_paused then return end
    -- Snapshot while the pipeline is still live. Setting is_paused first
    -- made Kindle getPosition() miss or reuse a stale mark, so resume jumped.
    local live_pos = 0
    pcall(function() live_pos = self:getPosition() or 0 end)
    if not live_pos or live_pos < 0 then live_pos = 0 end

    self.is_paused = true
    self._pause_start_time = UIManager:getTime()

    if self._persistent_pipeline_active then
        -- Ask the wrapper to kill the ffmpeg feeder while keeping gst-launch
        -- alive.  Stopping the whole group with SIGSTOP freezes GStreamer's
        -- clock and the MTK sink; on resume the buffered burst stutters for
        -- several seconds.  Killing only the decoder lets the pipeline drain
        -- cleanly and keeps the exclusive MTK socket open.
        local pf = io.open(self._media_ctrl_dir .. "/pause", "w")
        if pf then pf:write("1"); pf:close() end
        logger.warn("MediaEngine: paused persistent pipeline (ffmpeg feeder), wrapper=", self._pipeline_wrapper_pid)
        return
    end

    if self.backend == self.BACKENDS.ANDROID and self._android_player then
        -- Query/re-anchor via AndroidPlayer BEFORE trusting getPosition():
        -- is_paused is already true here, and a leftover _paused_position from
        -- the previous pause would otherwise be returned as a stale SMIL mark.
        self._paused_position = nil
        local ap_pos = nil
        pcall(function() ap_pos = self._android_player:pause() end)
        local pos = 0
        if ap_pos and ap_pos > 0 then
            pos = ap_pos / 1000
        else
            pcall(function()
                pos = (self._android_player:getPositionMs() or 0) / 1000
            end)
        end
        self._paused_position = math.max(0, pos)
        self._seek_offset = self._paused_position
        logger.warn("MediaEngine: Android pause at", self._paused_position)
        return
    end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", true}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause yes")
        end
        return
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
        return
    end

    -- Kindle gst/AirPods: do NOT SIGSTOP.  Idle A2DP is torn down by
    -- audiomgrd within seconds; SIGCONT then produces a silent "playing"
    -- pipeline.  Halt content, park a silence keepalive so A2DP stays up.
    if self:_kindleNeedsPipelineRestartOnResume() then
        self._paused_position = math.max(0, live_pos)
        self._seek_offset = self._paused_position
        logger.warn("MediaEngine: Kindle A2DP pause-halt at", self._paused_position,
            "apple=", self:_isAppleAirPodsHeadset() and "yes" or "no")
        self:_haltKindlePipelineForPause("pause-halt")
        self:_startKindleA2dpKeepalive("pause")
        return
    end

    if self.audio_pid and ffi.C.kill then
        -- Signal the whole process group: for the ffmpeg|gst-launch
        -- pipeline audio_pid is a setsid'd wrapper shell, and stopping
        -- only the shell leaves both pipeline halves playing.
        ffi.C.kill(-self.audio_pid, 19) -- SIGSTOP group
        ffi.C.kill(self.audio_pid, 19)  -- SIGSTOP pid (non-leader case)
    end
end

function MediaEngine:resume()
    if not self.is_playing or not self.is_paused then return end

    if self._persistent_pipeline_active then
        -- Restart the ffmpeg feeder at the position where we paused.  The
        -- wrapper kept gst-launch alive and fed silence while we were paused,
        -- so the MTK socket never closed and the clock never jumped.
        -- Read the position while still paused so we resume exactly where we
        -- left off, then update the pause bookkeeping.
        local resume_pos = self:getPosition()
        self.is_paused = false
        if self._pause_start_time then
            self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
            self._pause_start_time = nil
        end
        local filter_chain = self:_persistentFilterChain()
        os.remove(self._media_ctrl_dir .. "/done")
        local f = io.open(self._media_ctrl_dir .. "/play", "w")
        if f then
            f:write(self.current_path .. "\n")
            f:write(tostring(resume_pos) .. "\n")
            f:write(filter_chain .. "\n")
            f:close()
        end
        logger.warn("MediaEngine: resumed persistent pipeline at", resume_pos, "wrapper=", self._pipeline_wrapper_pid)
        return
    end

    if self.backend == self.BACKENDS.ANDROID and self._android_player then
        local resume_pos = self._paused_position
        if resume_pos == nil then
            pcall(function() resume_pos = self:getPosition() or 0 end)
        end
        resume_pos = math.max(0, tonumber(resume_pos) or 0)
        self._seek_offset = resume_pos
        -- Keep pause mark until after a successful resume so seek-restart and
        -- SMIL highlight can still read it if MediaPlayer start fails.
        self._paused_position = resume_pos

        self.is_paused = false
        if self._pause_start_time then
            self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
            self._pause_start_time = nil
        end

        local player = self._android_player
        local has_player = player and player._mp_ref
        local resumed = false
        if has_player then
            -- Force AndroidPlayer's resume seek target from our SMIL mark.
            player._last_mp_pos_ms = math.floor(resume_pos * 1000)
            local ok, result = pcall(function() return player:resume() end)
            resumed = ok and result ~= false
        end

        if not resumed then
            -- MediaPlayer was released / HAL dropped the session: seek-restart
            -- at the saved pause position instead of the original start offset.
            logger.warn("MediaEngine: Android resume via seek-restart at", resume_pos)
            local complete = self._on_complete
            local fail = self._on_fail
            self:play(complete, fail)
            return
        end

        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        logger.warn("MediaEngine: Android resume at", resume_pos)
        return
    end

    if self._pause_start_time then
        self._total_pause_ms = self._total_pause_ms + time.to_ms(UIManager:getTime() - self._pause_start_time)
        self._pause_start_time = nil
    end

    -- Kindle A2DP: ensure route (keepalive / BT cycle), then restart content.
    if self:_kindleNeedsPipelineRestartOnResume() then
        local pos = self._paused_position
        if pos == nil then
            pcall(function() pos = self:getPosition() or 0 end)
        end
        pos = math.max(0, tonumber(pos) or 0)
        local complete = self._on_complete
        local fail = self._on_fail
        local resume_gen = self.play_generation
        self.is_paused = false
        self._paused_position = nil
        self._seek_offset = pos
        logger.warn("MediaEngine: Kindle A2DP resume-restart at", pos,
            "route_up=", self:_kindleA2dpRouteUp() and "yes" or "no",
            "keepalive=", self._keepalive_pid or "none")
        self:_ensureKindleA2dpRoute(function(ok)
            if self.play_generation ~= resume_gen and self.is_playing and not self.is_paused then
                -- Another stop/seek superseded this resume.
            end
            logger.warn("MediaEngine: resume route ready ok=", ok and "yes" or "no")
            self:play(complete, fail)
            -- Drop keepalive after content is attached so it does not mix.
            UIManager:scheduleIn(1.2, function()
                self:_stopKindleA2dpKeepalive()
            end)
        end)
        return
    end

    self.is_paused = false

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "pause", false}})
        elseif self._fifo_path then
            self:_mpvSendFifo("set pause no")
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write("pause\n")
                f:close()
            end
        end
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        -- Kindle playermgr: Resume (set Play again)
        os.execute("lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null")
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE
        or self.backend == self.BACKENDS.KINDLE_GST_PLAY then
        -- After a paused seek the process was killed; restart it.
        if self.audio_pid and ffi.C.kill then
            ffi.C.kill(-self.audio_pid, 18) -- SIGCONT group
            ffi.C.kill(self.audio_pid, 18)  -- SIGCONT pid
        else
            self:play(self._on_complete, self._on_fail)
        end
    elseif self.audio_pid and ffi.C.kill then
        ffi.C.kill(-self.audio_pid, 18) -- SIGCONT group
        ffi.C.kill(self.audio_pid, 18)  -- SIGCONT pid
    end
end

function MediaEngine:stop()
    self:_nextGeneration()
    self.is_playing = false
    self.is_paused = false

    if self._position_timer then
        UIManager:unschedule(self._position_timer)
        self._position_timer = nil
    end

    if self.backend == self.BACKENDS.ANDROID and self._android_player then
        pcall(function() self._android_player:stop() end)
    end

    if self._persistent_pipeline_active then
        self:_stopPersistentPipeline("stop")
    end

    -- Kill audio process (for most backends).
    -- Kill the process group first so ffmpeg/gst-launch children inside
    -- the shell pipeline also receive the signal.  Fall back to the
    -- individual PID if the group kill fails.
    local dying_pid = self.audio_pid
    if dying_pid then
        if ffi.C.kill then
            ffi.C.kill(-dying_pid, 15) -- SIGTERM to process group
            ffi.C.kill(dying_pid, 15)  -- SIGTERM to shell itself
            UIManager:scheduleIn(0.3, function()
                local h = io.open("/proc/" .. dying_pid .. "/status", "r")
                if h then
                    h:close()
                    ffi.C.kill(-dying_pid, 9) -- SIGKILL to group
                    ffi.C.kill(dying_pid, 9)  -- SIGKILL to shell
                end
            end)
        end
        self.audio_pid = nil
    end

    -- Fallback for slow Kindle boots where PID capture failed: nuke any orphan
    -- pipelines we may have spawned, otherwise seek-by-restart leaves the old
    -- audio running and the user hears overlapping/looping audio.
    -- Run unconditionally on Kindle hardware even if the current backend was
    -- not (yet) detected as KINDLE_GST_PLAY.
    -- Spare the pause keepalive unless the caller requested a hard stop
    -- (user Stop / end of book) via _kill_keepalive_on_stop.
    if self:_isKindle() then
        if not dying_pid and not ffi.C.kill then
            logger.warn("MediaEngine: ffi.C.kill unavailable; relying on pkill fallback for Kindle gst")
        end
        local spare_keepalive = self._keepalive_pid and not self._kill_keepalive_on_stop
        self:_killOrphanKindleGstPipelines("stop", spare_keepalive and 100000 or 300000,
            spare_keepalive and { content_only = true } or nil)
        if not spare_keepalive then
            self:_stopKindleA2dpKeepalive()
        end
        self._kill_keepalive_on_stop = nil
    end

    -- Remove the raw PCM temp file created by _playSystemGstLaunch
    if self._system_raw_file then
        os.remove(self._system_raw_file)
        self._system_raw_file = nil
    end

    -- Remove the ffmpeg -progress feed and disable progress-based position
    -- tracking; the next play() re-enables it if it takes that path.
    if self._progress_file then
        os.remove(self._progress_file)
        self._progress_file = nil
    end
    self._use_progress_position = false

    -- For mplayer, also send quit command
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("quit\n")
            f:close()
        end
    end

    -- For mpv, send quit via IPC
    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            pcall(function()
                self:_mpvSendIpc({command = {"quit"}})
            end)
        elseif self._fifo_path then
            self:_mpvSendFifo("quit")
        end
    end

    -- For Kindle LIPC, tell playermgr to stop
    if self.backend == self.BACKENDS.KINDLE_LIPC then
        os.execute("lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null")
    end

    self:_cleanupIpc()
    self._on_complete = nil
    self._on_fail = nil
    self._play_start_time = nil
    self._aplay_start_time = nil
    self._pause_start_time = nil
    self._total_pause_ms = 0
    -- NOTE: do NOT reset _seek_offset here.
    -- GST backends use seek-by-restart: seek() sets _seek_offset, calls stop(),
    -- then schedules play().  If we zero it here, the restart loses its target.
    -- _seek_offset is reset in load() when a new file is loaded.
end

-- ---------------------------------------------------------------------------
-- Seeking
-- ---------------------------------------------------------------------------

function MediaEngine:seek(seconds, mode)
    mode = mode or "absolute"

    -- Non-seekable backends
    if self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY then
        logger.warn("MediaEngine: seek not supported on", self.backend)
        return false
    end

    -- Remember whether we were actually playing (not paused) so we can stay
    -- paused after a seek.  is_playing stays true when paused; is_paused is
    -- the real indicator.
    local was_playing = self.is_playing and not self.is_paused

    if self.backend == self.BACKENDS.ANDROID then
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)
        if self.current_duration and self.current_duration > 0 then
            target = math.min(target, self.current_duration)
        end
        self._seek_offset = target
        self._paused_position = target
        local player = self._android_player
        if self.is_paused then
            -- Stay paused; resume() plays from _paused_position / _last_mp_pos_ms.
            if player then
                pcall(function()
                    player._last_mp_pos_ms = math.floor(target * 1000)
                    player:seekToMs(math.floor(target * 1000))
                end)
            end
            logger.warn("MediaEngine: Android seek while paused", target)
            return true
        end
        if not player then
            return false
        end
        if self._seek_to_broken then
            -- Live MediaPlayer.seekTo is a no-op on this device (probe below
            -- detected it).  play() seeks before start(), which does work —
            -- same seek-by-restart as the GST backends.
            logger.warn("MediaEngine: Android seek-by-restart", target)
            local complete = self._on_complete
            local fail = self._on_fail
            return self:play(complete, fail)
        end
        local target_ms = math.floor(target * 1000)
        player:seekToMs(target_ms)
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        if not self._seek_probe_done then
            -- One-shot probe: on some Boox HALs live seekTo is a no-op (UI
            -- jumps, audio keeps the old timeline).  Verify the position
            -- actually moved; if not, switch this session to seek-by-restart.
            self._seek_probe_done = true
            local gen = self.play_generation
            UIManager:scheduleIn(0.35, function()
                if self.play_generation ~= gen then return end
                if not self.is_playing or self.is_paused then return end
                if self._seek_to_broken then return end
                local pos_ms = tonumber(player:getPositionMs()) or 0
                if math.abs(pos_ms - target_ms) > 1000 then
                    logger.warn("MediaEngine: Android live seek ignored",
                        "wanted=", target_ms, "got=", pos_ms,
                        "-- switching to seek-by-restart")
                    self._seek_to_broken = true
                    local complete = self._on_complete
                    local fail = self._on_fail
                    self:play(complete, fail)
                end
            end)
        end
        return true
    end

    if self.backend == self.BACKENDS.MPV then
        local mode_str = mode == "relative" and "relative" or "absolute"
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"seek", seconds, mode_str}})
            return true
        elseif self._fifo_path then
            local cmd = string.format("seek %f %s", seconds, mode_str)
            return self:_mpvSendFifo(cmd)
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        local cmd
        if mode == "relative" then
            cmd = string.format("seek %f 0", seconds) -- 0 = relative seconds
        else
            cmd = string.format("seek %f 2", seconds) -- 2 = absolute seconds
        end
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(cmd .. "\n")
                f:close()
                return true
            end
        end
    elseif self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE
        or self.backend == self.BACKENDS.KINDLE_GST_PLAY
        or self.backend == self.BACKENDS.FFMPEG_PIPE then
        -- For relative seeks, compute target from current position.
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)

        -- Kindle A2DP (esp. AirPods): a no-op seek-by-restart right after play
        -- tears down a healthy pipeline → brief sound, then silence.
        -- Skip when we are already at/near the requested offset.
        do
            local current = self:getPosition() or 0
            local started_at = self._seek_offset or 0
            local near_current = math.abs(current - target) < 0.6
            local near_start = math.abs(started_at - target) < 0.25
            local just_started = false
            if self._play_start_time then
                local ok_ms, age_ms = pcall(function()
                    return time.to_ms(UIManager:getTime() - self._play_start_time)
                end)
                if ok_ms and type(age_ms) == "number" then
                    just_started = age_ms < 2500
                elseif near_start and was_playing then
                    just_started = true
                end
            end
            if was_playing and (near_current or (near_start and just_started)) then
                logger.warn("MediaEngine: skip no-op seek-by-restart",
                    "req=", seconds, "target=", target,
                    "current=", current, "seek_offset=", started_at)
                return true
            end
        end

        -- Keep pause-resume position in sync when seeking while paused.
        if self.is_paused then
            self._paused_position = target
        end

        if self._persistent_pipeline_active then
            logger.warn("MediaEngine: persistent-pipeline seek mode=", mode,
                "req=", seconds, "current=", self:getPosition(),
                "target=", target, "was_playing=", was_playing)
            self._seek_offset = target
            self._play_start_time = UIManager:getTime()
            self._total_pause_ms = 0
            self._pause_start_time = nil
            -- Cancel old completion watcher.
            self:_nextGeneration()
            local new_gen = self.play_generation
            local filter_chain = self:_persistentFilterChain()
            if was_playing then
                -- Write new play control with the target offset; the wrapper
                -- will kill the old ffmpeg and restart at the new position.
                os.remove(self._media_ctrl_dir .. "/done")
                local f = io.open(self._media_ctrl_dir .. "/play", "w")
                if f then
                    f:write(self.current_path .. "\n")
                    f:write(tostring(target) .. "\n")
                    f:write(filter_chain .. "\n")
                    f:close()
                end
                self.is_playing = true
                self.is_paused = false
            else
                -- Seeking while paused must not start audio.  Tell the wrapper
                -- to keep the ffmpeg feeder killed; resume() will issue the
                -- play command from the new offset.
                local pf = io.open(self._media_ctrl_dir .. "/pause", "w")
                if pf then pf:write("1"); pf:close() end
                self.is_playing = true
                self.is_paused = true
                self._pause_start_time = UIManager:getTime()
            end
            self:_startPersistentCompletionWatcher(new_gen, self.current_duration)
            return true
        end

        -- Seek via process restart with time offset.
        logger.warn("MediaEngine: seek-by-restart mode=", mode, "req=", seconds,
            "current=", self:getPosition(), "target=", target,
            "was_playing=", was_playing, "backend=", self.backend)
        -- Preserve callbacks before stop() nils them.
        local saved_on_complete = self._on_complete
        local saved_on_fail = self._on_fail
        self._seek_offset = target
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        self._pause_start_time = nil
        -- Bridge A2DP across the stop→play gap (AirPods go silent otherwise).
        if was_playing and self:_kindleNeedsPipelineRestartOnResume() then
            self:_startKindleA2dpKeepalive("seek-bridge")
        end
        self:stop()
        -- Capture the generation AFTER stop() (stop bumps it).  The scheduled
        -- restart fires unless something else supersedes it in the 0.5 s gap
        -- (another seek/stop/play, which bumps the generation again).  NOTE:
        -- capturing before stop() made this guard always true -> the restart
        -- was always cancelled, so seeks (and volume changes, which seek to
        -- re-apply the gain) silently killed playback.
        local restart_gen = self.play_generation
        -- Only restart playback if we were actually playing before the seek.
        -- When paused, restore the paused state so resume() can restart us.
        if was_playing then
            UIManager:scheduleIn(0.5, function()
                if self.play_generation ~= restart_gen then
                    logger.dbg("MediaEngine: seek restart cancelled (generation changed)")
                    return
                end
                if self:_kindleNeedsPipelineRestartOnResume() then
                    self:_ensureKindleA2dpRoute(function()
                        if self.play_generation ~= restart_gen then return end
                        self:play(saved_on_complete, saved_on_fail)
                    end)
                else
                    self:play(saved_on_complete, saved_on_fail)
                end
            end)
        else
            self.is_playing = true
            self.is_paused = true
            self._on_complete = saved_on_complete
            self._on_fail = saved_on_fail
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = UIManager:getTime()
        end
        return true
    elseif self.backend == self.BACKENDS.KINDLE_LIPC then
        -- Seek via re-open at new position.  Kindle playermgr does not
        -- support direct seeking; we stop and restart via Open+Play.
        local target = seconds
        if mode == "relative" then
            target = self:getPosition() + seconds
        end
        target = math.max(0, target)
        logger.warn("MediaEngine: Kindle LIPC seek mode=", mode, "req=", seconds,
            "current=", self:getPosition(), "target=", target,
            "was_playing=", was_playing)
        local saved_on_complete = self._on_complete
        local saved_on_fail = self._on_fail
        self._seek_offset = target
        self._play_start_time = UIManager:getTime()
        self._total_pause_ms = 0
        self._pause_start_time = nil
        self:stop()
        -- Capture generation AFTER stop() (see the GST branch above for why).
        local lipc_restart_gen = self.play_generation
        -- Restart playback at new position
        if was_playing then
            UIManager:scheduleIn(0.5, function()
                if self.play_generation ~= lipc_restart_gen then
                    logger.dbg("MediaEngine: Kindle LIPC seek restart cancelled")
                    return
                end
                self:play(saved_on_complete, saved_on_fail)
            end)
        else
            self.is_playing = true
            self.is_paused = true
            self._on_complete = saved_on_complete
            self._on_fail = saved_on_fail
            self._play_start_time = UIManager:getTime()
            self._pause_start_time = UIManager:getTime()
        end
        return true
    end

    return false
end

-- ---------------------------------------------------------------------------
-- Position / Duration queries
-- ---------------------------------------------------------------------------

--- Read the latest out_time from ffmpeg's -progress feed (see
--- _playSystemGstLaunchFfmpeg).  Tails the file so it stays cheap even for a
--- multi-hour book.  Returns seconds into the decoded stream, or nil if the
--- feed has not produced a numeric timestamp yet.
function MediaEngine:_readLastOutTime()
    local path = self._progress_file
    if not path then return nil end
    local f = io.open(path, "rb")
    if not f then return nil end
    local size = f:seek("end")
    if not size or size == 0 then f:close(); return nil end
    local back = (size > 4096) and 4096 or size
    f:seek("set", size - back)
    local tail = f:read("*a") or ""
    f:close()
    -- ffmpeg emits "out_time=HH:MM:SS.ffffff" per progress block (and
    -- "out_time=N/A" before the first frame, which the numeric pattern skips).
    -- Take the LAST match.
    local last
    for h, m, s in tail:gmatch("out_time=(%d+):(%d+):([%d%.]+)") do
        last = tonumber(h) * 3600 + tonumber(m) * 60 + tonumber(s)
    end
    return last
end

function MediaEngine:getPosition()
    -- During a seek gap (after stop, before play restarts), return the seek
    -- offset so the UI doesn't flicker back to zero.
    if not self.is_playing then
        -- Hold the paused/seek target so the UI doesn't flicker back to zero.
        local held = tonumber(self._paused_position) or tonumber(self._seek_offset) or 0
        return math.max(0, held)
    end

    -- Kindle A2DP pause-halt: pipeline is gone; hold the saved pause position.
    if self.is_paused and self._paused_position ~= nil then
        return self._paused_position
    end

    -- Android: MediaPlayer position; while paused prefer the saved pause mark.
    if self.backend == self.BACKENDS.ANDROID and self._android_player then
        if self.is_paused and self._paused_position ~= nil then
            return self._paused_position
        end
        local pos_ms = self._android_player:getPositionMs()
        if pos_ms then
            local pos = pos_ms / 1000
            -- Keep seek_offset fresh so STOPPED→play restarts from here.
            if not self.is_paused then
                self._seek_offset = pos
            end
            return pos
        end
    end

    -- ffmpeg -progress backed position (EPUB read-along path): anchored to the
    -- actual decoded-stream progress rather than wall-clock, so startup jitter
    -- and stalls don't leak into the highlight.
    if self._use_progress_position then
        local ot = self:_readLastOutTime()
        if ot then
            return (self._seek_offset or 0)
                + math.max(0, ot - (self._progress_adelay_s or 0))
        end
        -- No numeric out_time yet.  Hold at seek_offset during the brief
        -- intro/startup (mirrors the iPad sitting on the first line until
        -- narration begins).  If ffmpeg never produces a feed (e.g. a build
        -- without -progress), fall through to the wall-clock estimate after a
        -- grace period so the UI never freezes permanently.
        local ok, elapsed_ms = pcall(function()
            return time.to_ms(UIManager:getTime()
                - (self._play_start_time or UIManager:getTime()))
        end)
        if not (ok and elapsed_ms and elapsed_ms > 3000) then
            return self._seek_offset or 0
        end
        -- else: fall through to wall-clock below
    end

    -- Android: use the same wall-clock path as other non-IPC backends.
    -- Do NOT trust MediaPlayer.getCurrentPosition() alone via JNI (often
    -- stuck at 0 on Boox).  MediaEngine._play_start_time is real wall time.

    -- For backends without IPC (gst-play, aplay, ffmpeg-pipe, android), estimate from elapsed time.
    -- Scale elapsed real time by playback speed so the reported position tracks the
    -- actual audio position when atempo / speed filters are in use.
    if self._play_start_time then
        local ok, elapsed_ms = pcall(function()
            if self.is_paused and self._pause_start_time then
                return time.to_ms(self._pause_start_time - self._play_start_time) - self._total_pause_ms
            else
                return time.to_ms(UIManager:getTime() - self._play_start_time) - self._total_pause_ms
            end
        end)
        if ok and elapsed_ms then
            local speed = self._playback_speed or 1.0
            local pos = math.max(0, elapsed_ms / 1000) * speed + (self._seek_offset or 0)
            pos = math.min(pos, self.current_duration or pos)
            logger.dbg("MediaEngine: getPosition elapsed=", elapsed_ms, "offset=", self._seek_offset,
                "speed=", speed, "pos=", pos)
            return pos
        else
            logger.warn("MediaEngine: getPosition elapsed-time failed, ok=", ok, "err=", elapsed_ms)
        end
        -- Fall through to other methods if elapsed-time fails
    end

    -- For aplay legacy fallback
    if (self.backend == self.BACKENDS.APLAY or self.backend == self.BACKENDS.WAV_PLAY)
        and self._aplay_start_time then
        local ok, elapsed = pcall(function()
            return time.to_ms(UIManager:getTime() - self._aplay_start_time) / 1000
        end)
        if ok and elapsed then
            return math.min(elapsed, self.current_duration or elapsed)
        end
    end

    -- Try mpv IPC for accurate position
    if self.backend == self.BACKENDS.MPV and self:_hasLuaSocket() and self._socket_path then
        local resp = self:_mpvSendIpc({command = {"get_property", "time-pos"}}, 300)
        if resp and resp.data then
            local pos = tonumber(resp.data)
            if pos then return pos end
        end
    end

    -- Try mplayer slave mode
    if self.backend == self.BACKENDS.MPLAYER and self._ipc_file then
        local f = io.open(self._ipc_file, "w")
        if f then
            f:write("get_time_pos\n")
            f:close()
        end
        -- Response comes asynchronously; we'd need a reader thread.
        -- For now, return estimated position.
    end

    return 0
end

function MediaEngine:getDuration()
    return self.current_duration or 0
end

function MediaEngine:isPlaying()
    return self.is_playing
end

function MediaEngine:isPaused()
    return self.is_paused
end

-- ---------------------------------------------------------------------------
-- Playback speed (mpv / mplayer / Android; pipeline backends restart)
-- ---------------------------------------------------------------------------

function MediaEngine:setSpeed(speed)
    speed = tonumber(speed) or 1.0
    if speed < 0.5 then speed = 0.5 end
    if speed > 3.0 then speed = 3.0 end
    local old_speed = self._playback_speed or 1.0
    self._playback_speed = speed

    if self.backend == self.BACKENDS.ANDROID then
        -- MediaPlayer applies the rate live via PlaybackParams (also stored
        -- for the next play(), which re-applies it after prepare()).
        if self._android_player then
            pcall(function() self._android_player:setSpeed(speed) end)
        end
        return
    end

    if not self.is_playing then return end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "speed", speed}})
        elseif self._fifo_path then
            self:_mpvSendFifo(string.format("set speed %f", speed))
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then
                f:write(string.format("speed_set %f\n", speed))
                f:close()
            end
        end
    elseif self.backend == self.BACKENDS.FFMPEG_PIPE
        or self.backend == self.BACKENDS.GST_PLAY
        or self.backend == self.BACKENDS.GST_PIPELINE then
        -- ffmpeg-pipe and the persistent MTK pipeline support speed only via
        -- the atempo filter, so restart at the current position when speed changes.
        if math.abs(speed - old_speed) >= 0.01 then
            local pos = self:getPosition() or 0
            logger.warn("MediaEngine: restarting pipeline for speed change",
                old_speed, "->", speed, "at pos", pos)
            self:seek(pos, "absolute")
        end
    end
    -- aplay / wav-play / Kindle do not support speed control
end

function MediaEngine:getSpeed()
    return self._playback_speed or 1.0
end

-- ---------------------------------------------------------------------------
-- Playback volume (digital gain)
-- ---------------------------------------------------------------------------

--- Comma-prefixed ffmpeg `volume` filter fragment, or "" at unity gain.
-- Meant to be spliced into an existing -af / -filter:a chain.
function MediaEngine:_volumeFilterPart()
    local v = self._volume or 1.0
    if math.abs(v - 1.0) < 0.001 then return "" end
    return string.format(",volume=%.3f", v)
end

--- Set playback volume as a percentage (0..100).
-- mpv/mplayer adjust live; the pipeline backends (ffmpeg/gst/kindle) restart
-- at the current position so the new gain takes effect, mirroring how speed
-- changes are handled.  Called before play() it just records the level, so the
-- initial spawn already carries it (no restart).
function MediaEngine:setVolume(pct)
    pct = tonumber(pct) or 100
    if pct < 0 then pct = 0 end
    if pct > 100 then pct = 100 end
    local v = pct / 100
    if math.abs(v - (self._volume or 1.0)) < 0.001 then return end
    self._volume = v

    -- Android: MediaPlayer.setVolume is a live per-stream gain (0..1) on top
    -- of the system/AirPods volume — no seek-restart, and independent of
    -- Spotify/YouTube Music's own level.
    if self.backend == self.BACKENDS.ANDROID and self._android_player then
        pcall(function() self._android_player:setVolume(v) end)
        logger.warn("MediaEngine: Android volume=", pct)
        return
    end

    if not self.is_playing then return end

    if self.backend == self.BACKENDS.MPV then
        if self:_hasLuaSocket() and self._socket_path then
            self:_mpvSendIpc({command = {"set_property", "volume", pct}})
        elseif self._fifo_path then
            self:_mpvSendFifo(string.format("set volume %d", pct))
        end
    elseif self.backend == self.BACKENDS.MPLAYER then
        if self._ipc_file then
            local f = io.open(self._ipc_file, "w")
            if f then f:write(string.format("volume %d 1\n", pct)); f:close() end
        end
    else
        -- ffmpeg-pipe / gst / kindle: the gain is baked into the decode
        -- pipeline, so restart to apply it.  Restart at the AUDIBLE position:
        -- getPosition() is the producer/decode position, which leads the
        -- listener by position_latency_s, so seeking to the raw value would
        -- skip the audio still in flight (~2.7 s jump forward every change).
        if not self.is_paused then
            local pos = (self:getPosition() or 0) - (self.position_latency_s or 0)
            self:seek(math.max(0, pos), "absolute")
        end
    end
end

function MediaEngine:getVolume()
    return math.floor((self._volume or 1.0) * 100 + 0.5)
end

-- ---------------------------------------------------------------------------
-- Chapter support (via m4bparser integration)
-- ---------------------------------------------------------------------------

function MediaEngine:setChapters(chapters)
    -- chapters: array of {title, start_time, end_time}
    self._chapters = chapters
end

function MediaEngine:getChapters()
    return self._chapters or {}
end

function MediaEngine:seekToChapter(index)
    local chapters = self._chapters
    if not chapters or not chapters[index] then return false end
    return self:seek(chapters[index].start_time, "absolute")
end

return MediaEngine
