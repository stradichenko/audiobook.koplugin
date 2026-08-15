--[[--
Bug Report Generator
Collects device and plugin diagnostics for troubleshooting.
Privacy-conscious: no book content, highlights, or personal file paths.

@module bugreport
--]]

local Device = require("device")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")

local _utils_dir = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
local Utils = dofile(_utils_dir .. "utils.lua")
_utils_dir = Utils.normalizeDirPath(_utils_dir) .. "/"

local BugReport = {}

--- Sanitize a path: strip user-identifiable directory components.
-- Replaces /home/<user>/ and /sdcard/ account dirs with generic placeholders.
local function sanitizePath(path)
    if not path then return "nil" end
    path = path:gsub("/home/[^/]+/", "/home/<user>/")
    path = path:gsub("/Users/[^/]+/", "/Users/<user>/")
    path = path:gsub("/storage/emulated/%d+/", "/sdcard/")
    return path
end

--- Run a shell command and return trimmed stdout (max 500 chars).
local function shellCapture(cmd, timeout_s)
    local full_cmd
    if timeout_s then
        -- BusyBox timeout expects "timeout SECS PROG [ARGS]" and cannot
        -- run shell builtins (for, if, etc.) directly.  Wrap the entire
        -- command in "sh -c '...'" so timeout gets a single executable.
        -- Single quotes inside the command are escaped as '\''.
        local escaped = cmd:gsub("'", "'\\''")
        full_cmd = "timeout " .. timeout_s .. " sh -c '" .. escaped .. "' 2>/dev/null"
    else
        full_cmd = cmd .. " 2>/dev/null"
    end
    local handle = io.popen(full_cmd)
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()
    output = output:gsub("^%s+", ""):gsub("%s+$", "")
    if #output > 1500 then
        output = output:sub(1, 1500) .. "…(truncated)"
    end
    return output ~= "" and output or nil
end

--- Check if a file/dir exists.
-- Uses io.open with an lfs.attributes fallback for devices where io.open
-- may fail on binary files (observed on some Kindle models). Never shell
-- out: paths here come from settings and the filesystem, and a path with
-- shell metacharacters must not reach sh.
local function fileExists(path)
    local f = io.open(path, "r")
    if f then f:close() return true end
    local ok, lfs = pcall(require, "libs/libkoreader-lfs")
    if ok and lfs then
        return lfs.attributes(path, "mode") ~= nil
    end
    return false
end

--- Check /var free space.  Returns use_pct (0-100) and free_kb, or nil.
local function checkVarSpace()
    local df_h = io.popen("df /var 2>/dev/null | tail -1")
    if not df_h then return nil, nil end
    local line = df_h:read("*a") or ""
    df_h:close()
    local _fs, _blocks, _used, avail, pct = line:match("^(%S+)%s+(%S+)%s+(%S+)%s+(%S+)%s+(%S+)")
    local use_pct = tonumber(pct and pct:match("(%d+)"))
    local free_kb = tonumber(avail)
    return use_pct, free_kb
end

--- Scan /proc/*/fd/ for deleted files in /var/ that still consume space.
-- These are "invisible" to du but count against df.  On Kindle the main
-- culprit is audiomgrd holding /var/tmp/audiomgrd.err open after deletion.
local function scanDeletedVarFiles()
    local cmd = [[for pid in $(ls /proc | grep -E '^[0-9]+$'); do
  for fd in /proc/$pid/fd/*; do
    link=$(readlink $fd 2>/dev/null)
    if echo "$link" | grep -qE '^/var/.*\(deleted\)'; then
      comm=$(cat /proc/$pid/comm 2>/dev/null || echo '?')
      size=$(ls -l $fd 2>/dev/null | awk '{print $5}')
      echo "$pid ($comm): $size bytes - $link"
    fi
  done
done | head -20]]
    return shellCapture(cmd, 8)
end

--- Collect device and OS information.
local function collectDeviceInfo()
    local info = {}
    info.platform = Device.getPlatform and Device:getPlatform() or "unknown"
    info.model = Device.getDeviceModel and Device:getDeviceModel() or "unknown"
    info.is_android = Device.isAndroid and Device:isAndroid() or false
    info.is_kindle = Device.isKindle and Device:isKindle() or false
    info.is_kobo = Device.isKobo and Device:isKobo() or false
    info.is_pocketbook = Device.isPocketBook and Device:isPocketBook() or false
    info.has_eink = Device.hasEinkScreen and Device:hasEinkScreen() or false

    -- Screen dimensions
    local screen = Device.screen
    if screen then
        info.screen_width = screen.getWidth and screen:getWidth() or "?"
        info.screen_height = screen.getHeight and screen:getHeight() or "?"
        info.screen_dpi = screen.getDPI and screen:getDPI() or "?"
    end

    -- Kernel / uname
    info.uname = shellCapture("uname -a", 3)

    -- Architecture
    info.arch = shellCapture("uname -m", 2)

    -- Android-specific
    if info.is_android then
        info.android_version = shellCapture("getprop ro.build.version.release", 2)
        info.android_sdk = shellCapture("getprop ro.build.version.sdk", 2)
        info.android_device = shellCapture("getprop ro.product.model", 2)
        info.android_brand = shellCapture("getprop ro.product.brand", 2)
    end

    return info
end

--- Collect KOReader version info.
local function collectKoreaderInfo()
    local info = {}

    -- KOReader version
    local ok, Version = pcall(require, "version")
    if ok and Version then
        info.koreader_version = Version.getCurrentRevision and Version:getCurrentRevision() or "unknown"
    else
        -- Fallback: try reading git_rev file
        local rev_file = io.open("git-rev", "r")
        if rev_file then
            info.koreader_version = rev_file:read("*l") or "unknown"
            rev_file:close()
        else
            info.koreader_version = "unknown"
        end
    end

    return info
end

--- Collect plugin-specific diagnostics.
local function collectPluginInfo(plugin)
    local info = {}
    local engine = plugin and plugin.tts_engine

    -- Plugin meta
    local ok, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    if ok and meta then
        info.plugin_name = meta.name or "audiobook"
        info.plugin_fullname = meta.fullname or "?"
        info.plugin_version = meta.version or "unknown"
    end

    info.plugin_dir = sanitizePath(_utils_dir)
    info.cwd = shellCapture("pwd", 2)

    -- Initialization state.  Several menus (Audiobookshelf, Open audiobook,
    -- etc.) depend on these flags, so report them explicitly.
    info.init_ok = (plugin and plugin._init_ok) and "yes" or "no"
    info.init_error = plugin and plugin._init_error or nil
    info.has_tts_engine = (plugin and plugin.tts_engine) and "yes" or "no"
    info.has_media_engine = (plugin and plugin.media_engine) and "yes" or "no"
    info.has_media_sync = (plugin and plugin.media_sync) and "yes" or "no"
    info.has_transcoder = (plugin and plugin.transcoder) and "yes" or "no"
    info.has_abs_sync = (plugin and plugin._abs_sync) and "yes" or "no"
    info.media_modules_error = plugin and plugin._media_modules_error or nil

    if not engine then
        info.tts_backend = "engine not initialized"
        -- Continue so the init-state fields above are still returned.
    else
        -- TTS state
        info.tts_backend = engine.backend or "nil (none detected)"
        info.tts_backend_cmd = engine.backend_cmd and sanitizePath(engine.backend_cmd) or "nil"
        info.tts_backend_error = engine.backend_error or "none"
        info.player_error = engine.player_error and "yes" or "no"
        info.audio_player_type = engine.audio_player_type or "not set"
        info.audio_player_cached = engine._cached_player or "not set"
        info.no_real_audio_output = engine._no_real_audio_output and "yes" or "no"

        -- Android bridge state: on Android every CLI probe fails by design,
        -- so the bundled-binary fields alone make a working setup look
        -- broken (issue #44).  Report the JNI bridge explicitly.
        if Device:isAndroid() then
            local dex_path = (engine.plugin_dir or _utils_dir:sub(1, -2)) .. "/android/tts_helper.dex"
            info.has_tts_helper_dex = fileExists(dex_path) and "yes" or "no"
            info.android_tts_bridge = engine._android_tts and "loaded" or "not loaded"
            if engine._android_tts then
                local ok_st, st = pcall(function() return engine._android_tts:getInitStatus() end)
                info.android_tts_init = ok_st and tostring(st) or "error"
                -- Which system TTS engine is active; the key datapoint for
                -- slow-synthesis reports (issue #53).
                local ok_eng, eng = pcall(function() return engine._android_tts:getDefaultEngine() end)
                info.android_tts_engine = ok_eng and tostring(eng) or "error"
            end
            -- PCM streamer state (issue #44): the persisted toggle plus the
            -- session-only auto-degrade flag that flips after a stalled clip.
            info.android_pcm_stream = tostring(plugin:getSetting("android_pcm_stream", false))
            info.android_pcm_auto = tostring(engine._android_pcm_auto or false)
        end

        -- PocketBook pre-flight snapshot from the most recent play() attempt
        -- (BT-adapter gate that prevents direct ALSA on PB632/PB700c).
        if engine._pb_pre_flight_state then
            local s = engine._pb_pre_flight_state
            info.pb_pre_flight = string.format(
                "is_pb=%s has_bt_adapter=%s has_tts_sm=%s no_real_audio=%s player_type=%s pt_is_bt_routed=%s",
                tostring(s.is_pb), tostring(s.has_bt_adapter),
                tostring(s.has_tts_sm), tostring(s.no_real_audio),
                tostring(s.player_type), tostring(s.pt_is_bt_routed))
        else
            info.pb_pre_flight = "not yet evaluated"
        end
        -- Raw sysfs read used by the pre-flight to detect the BT adapter.
        local hci_f = io.open("/sys/class/bluetooth/hci0/address", "r")
        if hci_f then
            info.bt_hci0_address = (hci_f:read("*l") or ""):gsub("[^%w:]+", "")
            hci_f:close()
            if info.bt_hci0_address == "" then info.bt_hci0_address = "empty" end
        else
            info.bt_hci0_address = "missing"
        end
    end

    -- MediaEngine backend (EPUB overlay / audiobook file playback)
    local meng = plugin and plugin.media_engine
    if meng then
        info.media_backend = meng.backend or "nil (none detected)"
        info.media_backend_cmd = meng.backend_cmd and sanitizePath(meng.backend_cmd) or "nil"
        info.media_backend_error = meng.backend_error or "none"
        if Device:isAndroid() then
            info.media_android_bridge = (meng._android_player and "player-jni")
                or (meng._android_tts and "tts-dex")
                or "not loaded"
        end
    end

    -- Bundled binaries presence (check both original and .bin-renamed variants)
    local plugin_dir = (engine and engine.plugin_dir) or _utils_dir:sub(1, -2)
    local espeak_path = plugin_dir .. "/espeak-ng/bin/espeak-ng"
    local piper_path = plugin_dir .. "/piper/piper"
    info.has_bundled_espeak = fileExists(espeak_path) or fileExists(espeak_path .. ".bin")
    info.has_bundled_piper = fileExists(piper_path) or fileExists(piper_path .. ".bin")
    local wav_play_path = plugin_dir .. "/wav-play/wav-play"
    info.has_bundled_wav_play = fileExists(wav_play_path) or fileExists(wav_play_path .. ".bin")
    -- ffmpeg is required on Kindle to decode MP3/M4B audiobooks because the
    -- system GStreamer is stripped (no mp3/wavparse decoder).  Report whether
    -- the release-zip binary is actually present.
    local ffmpeg_path = plugin_dir .. "/bin/ffmpeg"
    info.has_bundled_ffmpeg = fileExists(ffmpeg_path) or fileExists(ffmpeg_path .. ".bin")
    info.ffmpeg_bin_ls = shellCapture("ls -la '" .. plugin_dir .. "/bin/' 2>/dev/null", 3)
    -- Show what's on disk in the binary directories
    info.espeak_bin_ls = shellCapture("ls -la '" .. plugin_dir .. "/espeak-ng/bin/' 2>/dev/null", 3)
    info.piper_bin_ls = shellCapture("ls -la '" .. plugin_dir .. "/piper/' 2>/dev/null | head -10", 3)
    info.has_piper_model = false
    local piper_dir = plugin_dir .. "/piper"
    local piper_ls = shellCapture("ls " .. piper_dir .. "/*.onnx 2>/dev/null", 3)
    if piper_ls then
        info.has_piper_model = true
        -- Just show filenames, not full paths
        info.piper_models = piper_ls:gsub(piper_dir .. "/", "")
    end

    -- Current settings (non-private subset)
    if plugin.getSetting then
        info.settings = {
            tts_backend = plugin:getSetting("tts_backend", "auto"),
            speech_rate = plugin:getSetting("speech_rate", 1.0),
            speech_pitch = plugin:getSetting("speech_pitch", 50),
            speech_volume = plugin:getSetting("speech_volume", 1.0),
            highlight_style = plugin:getSetting("highlight_style", "background"),
            auto_advance = plugin:getSetting("auto_advance", true),
            highlight_words = plugin:getSetting("highlight_words", true),
            highlight_sentences = plugin:getSetting("highlight_sentences", true),
            espeak_cold_start = plugin:getSetting("espeak_cold_start", true),
            keep_playing_on_lid_close = plugin:getSetting("keep_playing_on_lid_close", false),
            bt_media_control = plugin:getSetting("bt_media_control", true),
            piper_model = plugin:getSetting("piper_model", nil) and
                sanitizePath(plugin:getSetting("piper_model", "")) or "none",
        }
    end

    return info
end

--- Collect system audio and TTS tool availability.
-- @param plugin table
-- @param skip_intensive boolean  When true, skip probes that write temp
--     files, spawn background processes, or call FFI (issue #28).
local function collectAudioInfo(plugin, skip_intensive)
    local info = {}

    if skip_intensive then
        info._skipped_intensive = "true"
    end

    -- TTS command availability
    local tts_cmds = {"espeak-ng", "espeak", "piper", "pico2wave", "flite", "festival"}
    info.tts_in_path = {}
    for _, cmd in ipairs(tts_cmds) do
        if Utils.commandExists(cmd) then
            info.tts_in_path[cmd] = shellCapture("which " .. cmd, 2) or "found"
        end
    end

    -- Audio player availability
    local player_cmds = {"aplay", "paplay", "mpv", "mplayer", "play", "gst-launch-1.0", "gst-inspect-1.0"}
    info.players_in_path = {}
    for _, cmd in ipairs(player_cmds) do
        if Utils.commandExists(cmd) then
            info.players_in_path[cmd] = true
        end
    end

    -- ALSA soundcards
    local cards = io.open("/proc/asound/cards", "r")
    if cards then
        info.alsa_cards = cards:read("*a") or "empty"
        cards:close()
        info.alsa_cards = info.alsa_cards:gsub("^%s+", ""):gsub("%s+$", "")
        if info.alsa_cards == "" then info.alsa_cards = "none" end
    else
        info.alsa_cards = "not available (/proc/asound/cards missing)"
    end

    -- ALSA PCM devices (may reveal BT sinks not in /proc/asound/cards)
    if Utils.commandExists("aplay") then
        info.alsa_pcm_devices = shellCapture("aplay -L 2>/dev/null | head -20", 3) or "none"
    end

    -- ALSA mixer controls (helps diagnose muted/zero-volume on PocketBook)
    info.alsa_mixer = shellCapture("amixer contents 2>/dev/null | head -40", 3)
        or shellCapture("cat /proc/asound/card0/codec* 2>/dev/null | head -20", 3)
        or "not available"

    -- ALSA default PCM mapping: where does "default" actually point?
    -- On PocketBook, "default" may route to a Loopback card, not the real audiocodec.
    info.alsa_default_pcm = shellCapture(
        "aplay -D default --dump-hw-params /dev/null 2>&1 | head -5", 3)
        or shellCapture("cat /usr/share/alsa/alsa.conf 2>/dev/null | grep -A2 'pcm.!default' | head -5", 3)
        or "not available"

    -- wav-play last stderr output (if available)
    info.wav_play_last_log = shellCapture(
        "cat /tmp/wav-play-last.log 2>/dev/null | tail -20", 3) or "none"

    -- wav-play stderr captured by ttsengine.lua (more current than wav-play-last.log)
    info.wav_play_gst_status = shellCapture(
        "cat /tmp/.gst_status 2>/dev/null | tail -30", 3) or "none"

    -- PocketBook-specific ALSA diagnostics
    if Device.isPocketBook and Device:isPocketBook() then
        -- Read files directly (BusyBox timeout + sh -c is unreliable
        -- on some PocketBook models for file reads).
        local function readFileLines(path, maxlines)
            local f = io.open(path, "r")
            if not f then return nil end
            local lines = {}
            for line in f:lines() do
                lines[#lines + 1] = line
                if maxlines and #lines >= maxlines then break end
            end
            f:close()
            local text = table.concat(lines, "\n")
            if #text > 1500 then text = text:sub(1, 1500) .. "...(truncated)" end
            return text ~= "" and text or nil
        end
        -- /etc/asound.conf: the audio routing config (tts_sm, hp, etc.)
        info.pb_asound_conf = readFileLines("/etc/asound.conf") or "not found"
        -- /proc/asound/pcm: all PCM subdevices
        info.pb_proc_asound_pcm = readFileLines("/proc/asound/pcm") or "not found"
        -- ALSA top-level config file
        info.pb_alsa_conf_path = "not found"
        for _, p in ipairs({"/usr/share/alsa/alsa.conf", "/etc/alsa/alsa.conf"}) do
            if fileExists(p) then
                info.pb_alsa_conf_path = p
                break
            end
        end
        -- Device config (model, variant, BT name)
        info.pb_device_cfg = readFileLines("/ebrmain/config/device.cfg", 30) or "not found"
    end

    -- Bluetooth
    info.bt_available = Utils.commandExists("bluetoothctl") or
                        Utils.commandExists("hcitool") or
                        fileExists("/sys/class/bluetooth") or false

    -- BT adapter present?
    info.bt_hci_devices = shellCapture("ls -1 /sys/class/bluetooth/ 2>/dev/null", 2) or "none"
    info.bt_sdio_bt_pwr = shellCapture("grep -c '^sdio_bt_pwr ' /proc/modules 2>/dev/null", 1) == "1" and "loaded" or "not loaded"
    info.bt_rfkill = shellCapture("rfkill list bluetooth 2>/dev/null", 4) or "rfkill not available"

    -- Paired / connected BT devices (bluetoothctl)
    -- Older BlueZ (< 5.65) doesn't support "devices Paired" subcommand
    -- and outputs "Too many arguments" to stdout.
    -- NOTE: bluetoothctl + pipe inside io.popen hangs on Kobo MTK devices
    -- because spawned D-Bus threads keep the stdout pipe open.  Capture
    -- full output and filter in Lua instead.
    if Utils.commandExists("bluetoothctl") then
        local paired = shellCapture("bluetoothctl paired-devices 2>/dev/null", 3)
            or shellCapture("bluetoothctl devices Paired 2>/dev/null", 3)
        if not paired or paired:match("[Tt]oo many") or paired:match("[Ii]nvalid") then
            paired = shellCapture("bluetoothctl devices 2>/dev/null", 3)
            if paired then
                local lines = {}
                for line in paired:gmatch("[^\n]+") do
                    table.insert(lines, line)
                    if #lines >= 10 then break end
                end
                paired = table.concat(lines, "\n")
            end
        end
        info.bt_paired_devices = paired or "none"

        local connected = shellCapture("bluetoothctl info 2>/dev/null", 3)
        if connected then
            local filtered = {}
            for line in connected:gmatch("[^\n]+") do
                if line:match("Device") or line:match("Name")
                    or line:match("Connected") or line:match("Paired") then
                    table.insert(filtered, line)
                end
            end
            connected = table.concat(filtered, "\n")
        end
        info.bt_connected_devices = connected or "none"

        -- Adapter state: powered/pairable/discoverable
        local adapter = shellCapture("bluetoothctl show 2>/dev/null", 3)
        if adapter then
            local filtered = {}
            for line in adapter:gmatch("[^\n]+") do
                if line:match("Powered") or line:match("Pairable")
                    or line:match("Discoverable") or line:match("Controller") then
                    table.insert(filtered, line)
                end
            end
            adapter = table.concat(filtered, "\n")
        end
        info.bt_adapter_info = adapter ~= "" and adapter or "unavailable"
    end

    -- Shell printf portability (Kobo busybox ash needs printf, not echo -e)
    info.bt_printf_test = shellCapture("printf 'line1\\nline2\\n' 2>/dev/null | wc -l", 2) or "unknown"

    -- Busybox sleep fractional support
    info.bt_sleep_test = shellCapture("sleep 0.1 2>&1 && echo 'ok' || echo 'unsupported'", 2) or "unknown"

    -- hcitool fallback (older Kobo firmware)
    if Utils.commandExists("hcitool") then
        info.bt_hcitool_con = shellCapture("hcitool con 2>/dev/null", 3) or "none"
    end

    -- Kobo BT daemon
    info.bt_daemon_running = shellCapture("pidof mtkbtmwrpc 2>/dev/null || pidof bluetoothd 2>/dev/null", 2) or "not running"

    -- bluetoothd binary location (key for Kobo pairing)
    local daemon_paths = {
        "/libexec/bluetooth/bluetoothd",
        "/usr/libexec/bluetooth/bluetoothd",
        "/usr/lib/bluetooth/bluetoothd",
    }
    info.bt_daemon_path = "not found"
    for _, p in ipairs(daemon_paths) do
        if fileExists(p) then
            info.bt_daemon_path = p
            break
        end
    end
    if info.bt_daemon_path == "not found" then
        local which_bt = shellCapture("which bluetoothd 2>/dev/null", 2)
        if which_bt then info.bt_daemon_path = which_bt .. " (via PATH)" end
    end

    -- Detected BT stack (MTK vs BlueZ)
    if plugin and plugin.bt_manager and plugin.bt_manager.getStackType then
        info.bt_stack = plugin.bt_manager:getStackType()
        info.bt_gst_sink = plugin.bt_manager:getGstBtSink() or "none (aplay fallback)"
        -- BlueALSA diagnostics
        info.bluealsa_bundled = plugin.bt_manager:hasBluealsaBundled() and "yes" or "no"
        info.bluealsa_running = plugin.bt_manager:isBluealsaRunning() and "yes" or "no"
        -- Capture bluealsa startup log if it exists (written by startBluealsa)
        local ba_log_h = io.open("/tmp/.bluealsa_start.log", "r")
        if ba_log_h then
            local ba_log = ba_log_h:read("*a") or ""
            ba_log_h:close()
            if #ba_log > 0 then
                info.bluealsa_start_log = ba_log:sub(1, 1500)
            end
        end
    end

    -- GStreamer BT sink
    if Utils.commandExists("gst-inspect-1.0") then
        local bt_sink = shellCapture("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -5", 3)
        info.gst_bt_sink_mtk = bt_sink or "not found"
        -- List all available audio sinks
        info.gst_audio_sinks = shellCapture("gst-inspect-1.0 --list-elements 2>/dev/null | grep -i 'sink\\|audio' || gst-inspect-1.0 2>/dev/null | grep -i 'sink\\|audio'", 3) or "none found"
    end

    -- Kobo BT socket (abstract socket used by mtkbtmwrpc)
    info.bt_abstract_socket = shellCapture("cat /proc/net/unix 2>/dev/null | grep -i 'kobo\\|mtk\\|bluetooth' | head -5", 2) or "none"

    -- Kindle BT diagnostics via lipc
    if Device.isKindle and Device:isKindle() then
        info.kindle_lipc_available = Utils.commandExists("lipc-get-prop") and "yes" or "no"
        if Utils.commandExists("lipc-get-prop") then
            -- Probe service+property combinations (varies by Kindle generation)
            local services = {
                "com.lab126.btfd",
                "com.lab126.btService",
                "com.lab126.cmd",
                "com.lab126.acsbt",
            }
            local properties = { "btEnabled", "btPowerState", "BTstate" }
            for _, svc in ipairs(services) do
                for _, prop in ipairs(properties) do
                    local val = shellCapture("lipc-get-prop " .. svc .. " " .. prop .. " 2>/dev/null", 2)
                    if val and val ~= "" then
                        info.kindle_bt_service = svc
                        info.kindle_bt_prop = prop
                        info.kindle_bt_enabled = val
                        info.kindle_bt_paired = shellCapture("lipc-get-prop " .. svc .. " btPairedDevicesList 2>/dev/null", 2) or "n/a"
                        info.kindle_bt_connected = shellCapture("lipc-get-prop " .. svc .. " btConnectedDevices 2>/dev/null", 2) or "n/a"
                        info.kindle_bt_connected_name = shellCapture("lipc-get-prop " .. svc .. " BTconnectedDevName 2>/dev/null", 2) or "n/a"
                        break
                    end
                end
                if info.kindle_bt_service then break end
            end
            if not info.kindle_bt_service then
                info.kindle_bt_service = "none responded"
                -- List available lipc services for debugging
                info.kindle_lipc_services = shellCapture("lipc-probe -l 2>/dev/null | grep -i 'bt\\|blue' | head -5", 2) or "none"
                -- List available properties for each BT service
                local props_dump = {}
                for _, svc in ipairs(services) do
                    local props = shellCapture("lipc-probe " .. svc .. " 2>/dev/null | head -20", 3)
                    if props and props ~= "" then
                        table.insert(props_dump, svc .. ": " .. props)
                    end
                end
                if #props_dump > 0 then
                    info.kindle_bt_props = table.concat(props_dump, "\n")
                end
            end
        end

        -- Kindle audio subsystem probing.
        -- Kindle Basic 2022 (and similar speakerless models) has no
        -- standard ALSA card.  These fields help identify what audio
        -- path Amazon exposes when BT headphones are connected.
        info.kindle_dev_snd = shellCapture("ls -la /dev/snd/ 2>/dev/null", 3) or "not found"
        info.kindle_aplay_l = shellCapture("aplay -l 2>&1 | head -15", 3) or "n/a"
        info.kindle_aplay_L = shellCapture("aplay -L 2>&1 | head -20", 3) or "n/a"
        info.kindle_proc_asound_pcm = shellCapture("cat /proc/asound/pcm 2>/dev/null", 3) or "not found"
        info.kindle_audio_procs = shellCapture(
            "ps 2>/dev/null | grep -iE 'audio|alsa|pulse|btfd|a2dp|bluez|sound' | grep -v grep | head -10", 3
        ) or "none"
        info.kindle_pulseaudio = shellCapture("pactl info 2>/dev/null | head -10", 3) or "not available"
        info.kindle_pa_sinks = shellCapture("pactl list sinks short 2>/dev/null", 3) or "none"
        -- lipc audio/sound services
        info.kindle_lipc_audio = shellCapture("lipc-probe com.lab126.audio 2>/dev/null | head -20", 3) or "not found"
        info.kindle_lipc_audio_svcs = shellCapture(
            "lipc-probe -l 2>/dev/null | grep -iE 'audio|sound|media|player' | head -5", 3
        ) or "none"
        -- Audio-related binaries
        local audio_bins = {}
        for _, b in ipairs({"aplay", "paplay", "mpv", "mplayer", "play", "madplay", "mpg123", "ffplay", "sox"}) do
            local loc = shellCapture("which " .. b .. " 2>/dev/null", 2)
            if loc then audio_bins[b] = loc end
        end
        info.kindle_audio_bins = audio_bins
        -- Kernel sound modules
        info.kindle_snd_modules = shellCapture("lsmod 2>/dev/null | grep -i snd | head -10", 3) or "n/a"
        -- ALSA config files
        info.kindle_asound_conf = shellCapture("cat /etc/asound.conf 2>/dev/null | head -10", 3) or "not found"

        -- btfd A2DP reverse-engineering: understand how Amazon routes
        -- BT audio so we can inject PCM data into the same path.
        local btfd_pid = shellCapture("pidof btfd 2>/dev/null", 2)
        info.kindle_btfd_pid = btfd_pid or "not running"
        if btfd_pid and btfd_pid:match("%d") then
            local pid = btfd_pid:match("(%d+)")
            info.kindle_btfd_cmdline = shellCapture("cat /proc/" .. pid .. "/cmdline 2>/dev/null | tr '\\0' ' '", 2) or "n/a"
            info.kindle_btfd_fds = shellCapture("ls -la /proc/" .. pid .. "/fd/ 2>/dev/null | head -30", 3) or "n/a"
            info.kindle_btfd_sockets = shellCapture("cat /proc/" .. pid .. "/net/unix 2>/dev/null | head -20", 3) or "n/a"
            info.kindle_btfd_maps = shellCapture("cat /proc/" .. pid .. "/maps 2>/dev/null | grep -iE 'audio|alsa|pulse|blue|a2dp|sbc|socket|pipe' | head -20", 3) or "n/a"
        end
        -- BT HCI interface: is BlueZ's /dev/hci0 or /sys/class/bluetooth present?
        info.kindle_hci_devs = shellCapture("ls -la /dev/hci* 2>/dev/null", 2) or "none"
        info.kindle_sys_bt = shellCapture("ls -la /sys/class/bluetooth/ 2>/dev/null", 2) or "none"
        info.kindle_hciconfig = shellCapture("hciconfig -a 2>/dev/null | head -20", 3) or "not available"
        -- D-Bus: does it exist? Is BlueZ registered?
        info.kindle_dbus_running = shellCapture("pidof dbus-daemon 2>/dev/null", 2) or "not running"
        info.kindle_dbus_bluez = shellCapture("dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -i blue | head -5", 3) or "no bluez on dbus"
        -- Unix/network sockets that mention bt/audio/a2dp
        info.kindle_bt_sockets = shellCapture("cat /proc/net/unix 2>/dev/null | grep -iE 'bt|audio|a2dp|blue|sbc' | head -15", 3) or "none"
        -- LIPC: what happens when Amazon plays audio internally?
        info.kindle_lipc_tts_props = shellCapture("lipc-probe com.lab126.kaf.TTSService 2>/dev/null | head -15", 3) or "not found"
        info.kindle_lipc_audio_player = shellCapture("lipc-probe com.lab126.audioPlayer 2>/dev/null | head -15", 3) or "not found"

        -- audiomgrd: Amazon's audio manager daemon -- likely controls ALSA
        -- card lifecycle and routes audio to btfd for BT output.
        local amgr_pid = shellCapture("pidof audiomgrd 2>/dev/null", 2)
        info.kindle_audiomgrd_pid = amgr_pid or "not running"
        if amgr_pid and amgr_pid:match("%d") then
            local pid = amgr_pid:match("(%d+)")
            info.kindle_audiomgrd_cmdline = shellCapture("cat /proc/" .. pid .. "/cmdline 2>/dev/null | tr '\\0' ' '", 2) or "n/a"
            info.kindle_audiomgrd_fds = shellCapture("ls -la /proc/" .. pid .. "/fd/ 2>/dev/null | head -30", 3) or "n/a"
            info.kindle_audiomgrd_maps = shellCapture("cat /proc/" .. pid .. "/maps 2>/dev/null | grep -iE 'audio|alsa|snd|pcm|mixer|pipe|socket|hw' | head -20", 3) or "n/a"
        end
        -- LIPC services discovered in v0.1.5.24: playermgr and audiomgrd
        info.kindle_lipc_playermgr = shellCapture("lipc-probe com.lab126.playermgr 2>/dev/null | head -20", 3) or "not found"
        info.kindle_lipc_audiomgrd = shellCapture("lipc-probe com.lab126.audiomgrd 2>/dev/null | head -20", 3) or "not found"
        -- v0.1.5.27: capture actual playermgr/audiomgrd state values
        info.kindle_playermgr_inplayback = shellCapture("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null", 2) or "n/a"
        info.kindle_playermgr_tts_state = shellCapture("lipc-get-prop com.lab126.playermgr TTS_State 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_output_connected = shellCapture("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_current_output = shellCapture("lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>/dev/null", 2) or "n/a"
        info.kindle_audiomgrd_volume = shellCapture("lipc-get-prop com.lab126.audiomgrd speakerVolume 2>/dev/null", 2) or "n/a"
        -- AirPods Pro / Apple headset diagnostics (btfd hash lists + route).
        -- Used to confirm A2DP is up when audio dies after a short blip.
        info.kindle_btfd_list_connected = shellCapture(
            "lipc-hash-prop com.lab126.btfd ListConnected 2>/dev/null | head -40", 3) or "n/a"
        info.kindle_btfd_list_paired = shellCapture(
            "lipc-hash-prop com.lab126.btfd ListPaired 2>/dev/null | head -40", 3) or "n/a"
        local connected_dump = info.kindle_btfd_list_connected or ""
        local apple_name = connected_dump:match('bd_name%s*=%s*"(.-)"')
        info.kindle_apple_headset = "no"
        if apple_name and apple_name:lower():find("airpods", 1, true) then
            info.kindle_apple_headset = "airpods:" .. apple_name
        elseif apple_name and apple_name:lower():find("beats", 1, true) then
            info.kindle_apple_headset = "beats:" .. apple_name
        elseif apple_name then
            info.kindle_apple_headset = "other:" .. apple_name
        end
        info.kindle_abk_gst_pids = shellCapture(
            "pgrep -af 'abk-progress|gst-launch-0.10|mixersink' 2>/dev/null | head -15", 3) or "none"
        -- Input / AVRCP discovery for AirPods stem play-pause.
        info.kindle_input_devices = shellCapture(
            "cat /proc/bus/input/devices 2>/dev/null | head -120", 3) or "n/a"
        info.kindle_input_event_nodes = shellCapture(
            "ls -la /dev/input/ 2>/dev/null | head -40", 2) or "n/a"
        info.kindle_btui = shellCapture(
            "command -v btui 2>/dev/null; ls -la /usr/bin/btui 2>/dev/null", 2) or "not found"
        -- Full ALSA config: v0.1.5.24 showed dmix0 on hw:0,0 -- we need
        -- the complete config to see all defined PCMs and their routing.
        info.kindle_asound_conf_full = shellCapture("cat /etc/asound.conf 2>/dev/null", 5) or "not found"
        -- Dynamic ALSA card: check if /dev/snd/ changes after poking
        -- audiomgrd.  List all of /dev/snd/ before and after.
        info.kindle_dev_snd_full = shellCapture("ls -la /dev/snd/ 2>/dev/null", 3) or "empty"
        -- All LIPC services (not just bt-related) for discovery
        info.kindle_lipc_all_services = shellCapture("lipc-probe -l 2>/dev/null | head -40", 3) or "n/a"
        -- v0.1.5.30: LIPC playback smoke test -- multi-strategy.
        -- Generate a 1-second 22050Hz mono 16-bit WAV (silence) and try
        -- 4 LIPC strategies + 2 aplay strategies.
        -- NOTE: first line MUST be a real command (not a variable assignment)
        -- because shellCapture prepends 'timeout N' which wraps only line 1.
        if not skip_intensive then
            info.kindle_lipc_test = shellCapture([[trap 'rm -f /tmp/.lipc_test.wav' EXIT
dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF'
  printf '\x24\xac\x00\x00'
  printf 'WAVE'
  printf 'fmt '
  printf '\x10\x00\x00\x00'
  printf '\x01\x00'
  printf '\x01\x00'
  printf '\x22\x56\x00\x00'
  printf '\x44\xac\x00\x00'
  printf '\x02\x00'
  printf '\x10\x00'
  printf 'data'
  printf '\x04\xac\x00\x00'
  cat
} > /tmp/.lipc_test.wav
echo "wav_size=$(wc -c < /tmp/.lipc_test.wav 2>/dev/null)"
echo "setFocus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
echo "gstLog=$(lipc-set-prop com.lab126.playermgr gstLogLevel 2 2>&1)"
echo "--- strategy1: Open(URI)+Play ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_uri=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.lipc_test.wav' 2>&1)"
echo "play1=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "tts_state1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- strategy2: Open(path)+Play ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_path=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.lipc_test.wav' 2>&1)"
echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback2=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy3: Play(URI) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_uri=$(lipc-set-prop com.lab126.playermgr Play 'file:///tmp/.lipc_test.wav' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback3=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy4: Play(path) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_path=$(lipc-set-prop com.lab126.playermgr Play '/tmp/.lipc_test.wav' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback4=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- strategy5: aplay dmix0 ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "aplay_dmix0=$(aplay -D dmix0 /tmp/.lipc_test.wav 2>&1 | head -3)"
echo "--- strategy6: aplay default ---"
echo "aplay_default=$(aplay -D default /tmp/.lipc_test.wav 2>&1 | head -3)"
echo "--- audiomgrd state ---"
echo "audioOutput=$(lipc-get-prop com.lab126.audiomgrd audioCurrentOutput 2>&1)"
echo "outputConn=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)"
rm -f /tmp/.lipc_test.wav
]], 20) or "failed"
        else
            info.kindle_lipc_test = "skipped (/var nearly full)"
        end
        -- audiomgrd error log (audiomgrd logs to /var/tmp/audiomgrd.err)
        info.kindle_audiomgrd_err = shellCapture("tail -20 /var/tmp/audiomgrd.err", 3) or "n/a"
        -- GStreamer plugins available on device
        info.kindle_gst_plugins = shellCapture("ls /usr/lib/gstreamer-*/ 2>/dev/null | head -30", 3) or "n/a"
        -- v0.1.5.31: tts.orchestrator -- Amazon's native TTS service.
        -- GStreamer on Kindle is stripped (no wavparse/audioconvert), so
        -- playermgr cannot decode WAV files.  The native TTS path is:
        --   tts.orchestrator → ttssrc (GStreamer) → mixersink → audiomgrd → A2DP → BT
        -- If we can speak text through tts.orchestrator, audio will flow.
        info.kindle_tts_orchestrator = shellCapture("lipc-probe com.lab126.tts.orchestrator 2>/dev/null | head -30", 3) or "not found"
        -- audiomgrd isStarted property (is the audio subsystem initialized?)
        info.kindle_audiomgrd_is_started = shellCapture("lipc-get-prop com.lab126.audiomgrd isStarted 2>/dev/null", 2) or "n/a"
        -- GStreamer + audio tools on the device
        info.kindle_gst_tools = shellCapture([[echo "gst_launch=$(which gst-launch-1.0 2>/dev/null || echo not_found)"
echo "gst_inspect=$(which gst-inspect-1.0 2>/dev/null || echo not_found)"
echo "gst_launch_010=$(which gst-launch-0.10 2>/dev/null || echo not_found)"
echo "gst_inspect_010=$(which gst-inspect-0.10 2>/dev/null || echo not_found)"
echo "amixer=$(which amixer 2>/dev/null || echo not_found)"
echo "pactl=$(which pactl 2>/dev/null || echo not_found)"
]], 3) or "n/a"
        -- Shared memory segments (audiomgrd uses libaudioShmbuffer)
        info.kindle_shm = shellCapture("ls -la /dev/shm/ 2>/dev/null || echo 'no /dev/shm'", 3) or "n/a"
        -- Full A2DP socket state (both .a2dp_ctrl and .a2dp_data)
        info.kindle_a2dp_sockets = shellCapture("cat /proc/net/unix 2>/dev/null | grep -i a2dp", 3) or "none"
        -- GStreamer element inspection (what does ttssrc/mixersink accept?)
        info.kindle_gst_inspect_ttssrc = shellCapture("gst-inspect-0.10 ttssrc 2>/dev/null | head -40", 3) or "n/a"
        info.kindle_gst_inspect_mixersink = shellCapture("gst-inspect-0.10 mixersink 2>/dev/null | head -40", 3) or "n/a"
        info.kindle_gst_inspect_fdsrc = shellCapture("gst-inspect-0.10 fdsrc 2>/dev/null | head -30", 3) or "n/a"
        info.kindle_gst_inspect_capsfilter = shellCapture("gst-inspect-0.10 capsfilter 2>/dev/null | head -30", 3) or "n/a"
        -- v0.1.6.4: List all LIPC properties exposed by playermgr and audiomgrd.
        -- Newer firmware (e.g. Colorsoft 5.18.6) may omit properties that exist
        -- on older devices (e.g. tts.orchestrator "speak").
        info.kindle_playermgr_props = shellCapture("lipc-probe com.lab126.playermgr 2>/dev/null | head -40", 3) or "n/a"
        info.kindle_audiomgrd_props = shellCapture("lipc-probe com.lab126.audiomgrd 2>/dev/null | head -40", 3) or "n/a"

        -- v0.1.5.31: TTS orchestrator smoke test.
        -- Try to make the native TTS speak, which routes through the
        -- working audio pipeline (ttssrc → mixersink → audiomgrd → BT).
        -- Also test: can we write raw PCM to a pipe that audiomgrd reads?
        if not skip_intensive then
            info.kindle_tts_test = shellCapture([[echo "--- tts.orchestrator probe ---"
echo "tts_orch_props=$(lipc-probe com.lab126.tts.orchestrator 2>&1 | head -30)"
echo "--- try native TTS speak ---"
echo "tts_speak=$(lipc-set-prop com.lab126.tts.orchestrator speak 'test' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_state_after=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "inplayback_after=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- try audiomgrd direct ---"
echo "amgrd_started=$(lipc-get-prop com.lab126.audiomgrd isStarted 2>&1)"
echo "amgrd_focus=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)"
echo "--- ALSA after setFocus ---"
echo "aplay_l_after=$(aplay -l 2>&1 | head -5)"
echo "dev_snd_after=$(ls /dev/snd/ 2>/dev/null | grep pcm)"
echo "--- A2DP socket state ---"
echo "a2dp_socks=$(cat /proc/net/unix 2>/dev/null | grep a2dp)"
]], 15) or "failed"
        else
            info.kindle_tts_test = "skipped (/var nearly full)"
        end

        -- v0.1.5.32: Deeper TTS + audio path exploration.
        -- GStreamer 0.10 is stripped (no wavparse). tts.orchestrator is
        -- running with voices.  We need to trigger native TTS.

        -- tts.orchestrator: read hash properties and orchestratorStarted
        info.kindle_tts_orch_started = shellCapture(
            "lipc-get-prop com.lab126.tts.orchestrator orchestratorStarted 2>&1", 3) or "n/a"
        info.kindle_tts_orch_hash_cmd = shellCapture(
            "which lipc-hash-prop 2>/dev/null || echo not_found", 2) or "n/a"
        info.kindle_tts_orch_langs = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator supportedLanguages 2>&1 | head -20", 5) or "n/a"
        -- v0.1.5.33: get FULL voices list (was truncated at 20 lines)
        info.kindle_tts_orch_voices = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator voices 2>&1 | head -80", 8) or "n/a"
        info.kindle_tts_orch_installed = shellCapture(
            "lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20", 5) or "n/a"

        -- lipc-send-event: v0.1.5.33 used the service as source ("Failed to
        -- open LIPC" -- can't impersonate another publisher).  v0.1.5.34:
        -- use our own source name so we can actually publish events.
        info.kindle_tts_event_test = shellCapture([[echo "--- lipc-send-event from custom source ---"
echo "evt1=$(lipc-send-event com.lab126.audiobook speak -s 'hello world' 2>&1)"
echo "tts1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- send ttsSpeak from kaf source ---"
echo "evt2=$(lipc-send-event com.lab126.kaf ttsSpeak -s 'hello' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- send readScreen from custom source ---"
echo "evt3=$(lipc-send-event com.lab126.audiobook readScreen -s 'hello' 2>&1)"
echo "tts3=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
]], 15) or "failed"

        -- v0.1.5.34 FIX: lipc-hash-prop has no -w flag! v0.1.5.33 used
        -- non-existent -w which just printed usage.  Correct approach:
        -- pipe hash data through stdin in the format { key = "val" }.
        info.kindle_tts_check_voice = shellCapture([[echo "--- checkVoice write via stdin pipe ---"
cv1=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
echo "cv1=$cv1"
echo "cv1_rc=$?"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_cv1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "play_cv1=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- checkVoice with voice name ---"
cv2=$(echo '{ language_code = "en_us", voice = "joanna" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>&1)
echo "cv2=$cv2"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_cv2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- write text to voices hash ---"
v1=$(echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>&1)
echo "voices_write=$v1"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_v1=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- checkVoice read (null input) ---"
echo "cv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator checkVoice 2>&1 | head -10)"
]], 15) or "failed"

        -- v0.1.5.33: try TTS URI schemes via playermgr.
        -- playermgr might accept special URIs for TTS mode.
        info.kindle_tts_uri_test = shellCapture([[lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- tts:// URI ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_tts=$(lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>&1)"
echo "play_tts=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_tts=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "play_tts_ip=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- ttssrc:// URI ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "open_ttssrc=$(lipc-set-prop com.lab126.playermgr Open 'ttssrc://hello world' 2>&1)"
echo "play_ttssrc=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_ttssrc=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "--- Play with tts: ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "play_tts2=$(lipc-set-prop com.lab126.playermgr Play 'tts://hello' 2>&1)"
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "state_tts2=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
]], 15) or "failed"

        -- v0.1.5.35: Test VoiceView-compatible native TTS via PlayParameter.
        -- VoiceView capture showed: playermgr accepts SSML text via
        -- PlayParameter JSON → ttssrc → Ivona SDK → mixersink → BT.
        info.kindle_native_tts_test = shellCapture([[lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- Strategy A: PlayParameter only ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_a=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_a=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy B: Open+PlayParameter+Play ---"
lipc-set-prop com.lab126.playermgr Open '{"type":"TTS"}' 2>&1
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_b=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_b=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy C: PlayParameter+Play ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '{"type":"TTS"}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_c=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_c=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy D: Open+PlayParameter+Play(empty) ---"
lipc-set-prop com.lab126.playermgr Open '' 2>&1
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"Testing native TTS."}}' 2>&1
lipc-set-prop com.lab126.playermgr Play '' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_d=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_d=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "--- Strategy E: SSML with marks ---"
lipc-set-prop com.lab126.playermgr PlayParameter '{"type":"TTS","data":{"paramName":"textsource","paramValue":"<mark name=\"1\"/>Testing <mark name=\"9\"/>native <mark name=\"16\"/>TTS."}}' 2>&1
sleep 2 2>/dev/null || usleep 2000000 2>/dev/null
echo "tts_e=$(lipc-get-prop com.lab126.playermgr TTS_State 2>&1)"
echo "ip_e=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
]], 30) or "failed"

        -- PlayParameter + raw PCM: strip the 44-byte WAV header, set
        -- GStreamer caps via PlayParameter, try Open/Play with raw audio.
        -- If mixersink accepts S16LE @ 22050 without a parser, this works.
        -- v0.1.6.4: Also note when /var is full (raw_size=0 means the test
        -- file could not be written, which blocks ALL audio on the device).
        if not skip_intensive then
            info.kindle_raw_pcm_test = shellCapture([[trap 'rm -f /tmp/.pcm_test.wav /tmp/.pcm_test.raw' EXIT
dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF'
  printf '\x24\xac\x00\x00'
  printf 'WAVE'
  printf 'fmt '
  printf '\x10\x00\x00\x00'
  printf '\x01\x00'
  printf '\x01\x00'
  printf '\x22\x56\x00\x00'
  printf '\x44\xac\x00\x00'
  printf '\x02\x00'
  printf '\x10\x00'
  printf 'data'
  printf '\x04\xac\x00\x00'
  cat
} > /tmp/.pcm_test.wav
if [ ! -s /tmp/.pcm_test.wav ]; then
  echo "raw_size=0  (/var full? cannot write test file)"
  echo "df_var=$(df /var 2>/dev/null | tail -1)"
else
  dd if=/tmp/.pcm_test.wav of=/tmp/.pcm_test.raw bs=1 skip=44 2>/dev/null
  echo "raw_size=$(wc -c < /tmp/.pcm_test.raw 2>/dev/null)"
fi
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
echo "--- PlayParameter + raw PCM (path) ---"
echo "param=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
echo "open=$(lipc-set-prop com.lab126.playermgr Open '/tmp/.pcm_test.raw' 2>&1)"
echo "play=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback_raw=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
echo "--- PlayParameter + raw PCM (URI) ---"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
echo "param2=$(lipc-set-prop com.lab126.playermgr PlayParameter 'audio/x-raw,format=S16LE,rate=22050,channels=1' 2>&1)"
echo "open2=$(lipc-set-prop com.lab126.playermgr Open 'file:///tmp/.pcm_test.raw' 2>&1)"
echo "play2=$(lipc-set-prop com.lab126.playermgr Play '' 2>&1)"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "inplayback_raw_uri=$(lipc-get-prop com.lab126.playermgr InPlayback 2>&1)"
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
rm -f /tmp/.pcm_test.wav /tmp/.pcm_test.raw
]], 20) or "failed"
        else
            info.kindle_raw_pcm_test = "skipped (/var nearly full)"
        end

        if not skip_intensive then
            -- v0.1.6.5: kindle-gst-play --ttssrc test.
            -- On Colorsoft, playermgr is non-functional but ttssrc bypasses it.
            -- Use the same linker wrapper as ttsengine.lua so the test matches
            -- actual execution (issue #23).
            local gst_play_path = nil
            for _, p in ipairs({
                info.plugin_dir and info.plugin_dir .. "kindle/gst-play" or nil,
                _utils_dir .. "kindle/gst-play",
                "/mnt/us/koreader/plugins/audiobook.koplugin/kindle/gst-play",
                "/mnt/onboard/.adds/koreader/plugins/audiobook.koplugin/kindle/gst-play",
            }) do
                if p and fileExists(p) then
                    gst_play_path = p
                    break
                elseif p and fileExists(p .. ".bin") then
                    -- Release zips ship ELF binaries with a .bin suffix.
                    gst_play_path = p .. ".bin"
                    break
                end
            end
            if gst_play_path then
                local espeak_lib = gst_play_path:gsub("/kindle/gst%-play(%.bin)?$", "/espeak-ng/lib")
                local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
                local gst_cmd = gst_play_path
                -- ttssrc depends on libIvonaEInkAPI.so.1.0 in /usr/lib/tts.
                local ivona_env = "LD_LIBRARY_PATH=/usr/lib/tts:$LD_LIBRARY_PATH "
                if fileExists(ld_linux) then
                    gst_cmd = ld_linux .. " --library-path " .. espeak_lib .. ":/usr/lib/tts:/usr/lib:/lib " .. gst_play_path
                end
                info.kindle_gst_ttssrc_test = shellCapture(
                    "echo '--- kindle-gst-play --ttssrc ---'; "
                    .. ivona_env .. gst_cmd .. " --ttssrc 'hello world' 2>&1; "
                    .. "echo 'exit_code=$?'",
                    15) or "failed"
            else
                info.kindle_gst_ttssrc_test = "binary_not_found"
            end
        else
            info.kindle_gst_ttssrc_test = "skipped (/var nearly full)"
        end

        -- v0.1.6.5: Try different audiomgrd setFocus values.
        -- Colorsoft may need a specific client name to grant audio focus.
        info.kindle_setfocus_test = shellCapture([[
echo "--- setFocus tts ---"
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1
echo "--- setFocus playermgr ---"
lipc-set-prop com.lab126.audiomgrd setFocus 'playermgr' 2>&1
echo "--- setFocus com.lab126.playermgr ---"
lipc-set-prop com.lab126.audiomgrd setFocus 'com.lab126.playermgr' 2>&1
echo "--- setFocus com.lab126.koreader.tts ---"
lipc-set-prop com.lab126.audiomgrd setFocus 'com.lab126.koreader.tts' 2>&1
]], 10) or "failed"

        if not skip_intensive then
            -- v0.1.6.5: Raw PCM via gst-launch-0.10 with explicit caps.
            -- If mixersink accepts raw audio without wavparse, this works.
            info.kindle_gst_raw_pipeline_test = shellCapture([[trap 'rm -f /tmp/.gst_raw_test.wav /tmp/.gst_raw_test.raw' EXIT

dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF$¬  WAVEfmt      "V  D¬    data¬  '
  cat
} > /tmp/.gst_raw_test.wav 2>/dev/null

dd if=/tmp/.gst_raw_test.wav of=/tmp/.gst_raw_test.raw bs=1 skip=44 2>/dev/null
if [ -s /tmp/.gst_raw_test.raw ]; then
  lipc-set-prop com.lab126.audiomgrd setFocus Music 2>/dev/null || true
  echo "--- filesrc + capsfilter raw PCM ---"
  timeout 3 gst-launch-0.10 -v filesrc location=/tmp/.gst_raw_test.raw ! capsfilter caps="audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234" ! mixersink stream-type=Music sync=true 2>&1 | head -15
  echo "--- fdsrc + capsfilter raw PCM ---"
  timeout 3 gst-launch-0.10 -v fdsrc location=/tmp/.gst_raw_test.raw ! capsfilter caps="audio/x-raw-int,rate=22050,channels=1,width=16,depth=16,signed=true,endianness=1234" ! mixersink stream-type=Music sync=true 2>&1 | head -15
else
  echo "raw_file_missing=/var_full?"
fi
rm -f /tmp/.gst_raw_test.wav /tmp/.gst_raw_test.raw
]], 15) or "failed"
        else
            info.kindle_gst_raw_pipeline_test = "skipped (/var nearly full)"
        end

        -- amixer: check ALSA mixer controls (audiomgrd may expose some)
        info.kindle_amixer = shellCapture("amixer 2>&1 | head -20", 3) or "n/a"
        info.kindle_amixer_scontrols = shellCapture("amixer scontrols 2>&1 | head -10", 3) or "n/a"

        -- GStreamer plugin directory: version, path, permissions.
        -- v0.1.5.33: separate writable test from dir listing to avoid
        -- truncation hiding the answer (v0.1.5.32 was cut off).
        info.kindle_gst_plugin_dir = shellCapture([[echo "--- GStreamer libs ---"
ls -la /usr/lib/libgstreamer* 2>/dev/null | head -5 || echo "no libgstreamer"
echo "--- plugin dir ---"
for d in /usr/lib/gstreamer-*/; do
  if [ -d "$d" ]; then
    echo "dir=$d"
    ls "$d" 2>/dev/null | head -15
  fi
done
]], 5) or "n/a"
        info.kindle_gst_dir_writable = shellCapture([[for d in /usr/lib/gstreamer-*/; do
  if [ -d "$d" ]; then
    echo "dir=$d"
    if touch "${d}.__gst_test" 2>/dev/null; then
      rm -f "${d}.__gst_test"
      echo "writable=yes"
    else
      echo "writable=no"
    fi
    echo "registry=$(ls -la ${d}registry.* 2>/dev/null || echo none)"
    echo "gst_ver_dir=$(basename $d)"
  fi
done
]], 5) or "n/a"

        -- com.lab126.kaf: Kindle Application Framework (may have TTS events)
        info.kindle_kaf_probe = shellCapture(
            "lipc-probe com.lab126.kaf 2>/dev/null | head -30", 3) or "not found"

        -- Available tools for potential A2DP socket or audio injection
        info.kindle_socket_tools = shellCapture([[echo "socat=$(which socat 2>/dev/null || echo not_found)"
echo "nc=$(which nc 2>/dev/null || echo not_found)"
echo "ncat=$(which ncat 2>/dev/null || echo not_found)"
echo "python=$(which python 2>/dev/null || which python3 2>/dev/null || echo not_found)"
echo "perl=$(which perl 2>/dev/null || echo not_found)"
echo "busybox=$(which busybox 2>/dev/null || echo not_found)"
echo "toybox=$(which toybox 2>/dev/null || echo not_found)"
echo "strace=$(which strace 2>/dev/null || echo not_found)"
]], 3) or "n/a"

        -- v0.1.5.34 FIX: lipc-wait-event requires an event-name argument.
        -- v0.1.5.33 omitted it ("Both event source and event name are
        -- expected").  Use '*' wildcard to capture all events.
        if not skip_intensive then
            info.kindle_wait_events = shellCapture([[echo "--- tts.orchestrator events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.tts.orchestrator '*' 2>&1 &
WPID=
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator checkVoice 2>/dev/null
echo '{ Voice = "joanna", LanguageCode = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator voices 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait  2>/dev/null
echo "--- playermgr events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.playermgr '*' 2>&1 &
WPID=
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
lipc-set-prop com.lab126.playermgr Open 'tts://hello world' 2>/dev/null
lipc-set-prop com.lab126.playermgr Play '' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait  2>/dev/null
echo "--- audiomgrd events (5s) ---"
lipc-wait-event -s 5 -m com.lab126.audiomgrd '*' 2>&1 &
WPID=
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
sleep 4 2>/dev/null || usleep 4000000 2>/dev/null
wait  2>/dev/null
]], 20) or "n/a"
        else
            info.kindle_wait_events = "skipped (/var nearly full)"
        end


        -- v0.1.5.33: voice config files on the device
        info.kindle_tts_voice_configs = shellCapture([[echo "--- /usr/lib/tts/ ---"
find /usr/lib/tts/ -name '*.json' 2>/dev/null | head -20 || echo "not found"
echo "--- English voice config ---"
for f in /usr/lib/tts/english/*.json /usr/lib/tts/en_*/*.json; do
  if [ -f "$f" ]; then
    echo "file=$f"
    cat "$f" 2>/dev/null | head -30
  fi
done
echo "--- voice dirs ---"
ls -d /usr/lib/tts/*/ 2>/dev/null || echo "none"
echo "--- English liblanguage ---"
ls -la /usr/lib/tts/english/liblanguage_english.so 2>/dev/null || echo "not found"
]], 8) or "n/a"

        -- v0.1.5.34 FIX: lipc-hash-prop has no -w or -v flags.
        -- Use stdin pipe for writes, -n for reads.
        info.kindle_tts_hash_write = shellCapture([[echo "--- write to supportedLanguages hash ---"
sl=$(echo '{ language_code = "en" }' | lipc-hash-prop com.lab126.tts.orchestrator supportedLanguages 2>&1)
echo "sl=$sl"
echo "--- write to installedVoices hash ---"
iv=$(echo '{ language_code = "en_us" }' | lipc-hash-prop com.lab126.tts.orchestrator installedVoices 2>&1)
echo "iv=$iv"
echo "--- read installedVoices ---"
echo "iv_read=$(lipc-hash-prop -n com.lab126.tts.orchestrator installedVoices 2>&1 | head -20)"
]], 8) or "n/a"

        -- v0.1.5.34: VoiceView / accessibility service probe.
        -- VoiceView is Amazon's screen reader -- when active, it triggers
        -- the native TTS pipeline.  Find related LIPC services/properties.
        info.kindle_voiceview_probe = shellCapture([[echo "--- accessibility/voiceview LIPC services ---"
lipc-probe -l 2>/dev/null | grep -iE 'voice|access|a11y|screen.?read|tts' | head -20
echo "---"
echo "--- com.lab126.voiceview probe ---"
lipc-probe com.lab126.voiceview 2>&1 | head -20
echo "--- com.lab126.accessibility probe ---"
lipc-probe com.lab126.accessibility 2>&1 | head -20
echo "--- com.lab126.tts probe ---"
lipc-probe com.lab126.tts 2>&1 | head -20
echo "--- pillow (UI framework) probe ---"
lipc-probe com.lab126.pillow 2>&1 | head -20
echo "--- full service list (voice/tts/a11y) ---"
lipc-probe -l 2>/dev/null | grep -iE 'voice|tts|a11y|access|speak|screen.?read|pillow' | head -20
]], 10) or "n/a"

        -- v0.1.5.37: liblipc.so FFI diagnostic -- test if a named LIPC
        -- connection can trigger PlayParameter (the CLI tools use anonymous
        -- connections which playermgr may ignore).
        if not skip_intensive then
            info.kindle_lipc_ffi_test = (function()
                local ok, result = pcall(function()
                local lines = {}
                local function log(s) lines[#lines + 1] = s end
                -- 1) Check liblipc.so exists
                local lib_path = nil
                for _, p in ipairs({"/usr/lib/liblipc.so", "/usr/lib/liblipc.so.0"}) do
                    local f = io.open(p, "r")
                    if f then f:close(); lib_path = p; break end
                end
                log("liblipc_path=" .. (lib_path or "not found"))
                if not lib_path then return table.concat(lines, "\n") end
                -- 2) Dump key exported symbols
                local nm = shellCapture("nm -D " .. lib_path .. " 2>/dev/null | grep -i 'Lipc\\|lipc' | head -30", 5)
                log("symbols=" .. (nm or "nm failed"))
                -- 3) Try FFI load + named connection + PlayParameter
                local ffi_ok, ffi = pcall(require, "ffi")
                if not ffi_ok then log("ffi=not available"); return table.concat(lines, "\n") end
                -- Declare LIPC functions (wrapped in pcall to tolerate duplicate cdef)
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
                local load_ok, lipc_lib = pcall(ffi.load, "lipc")
                if not load_ok then log("ffi_load=failed: " .. tostring(lipc_lib)); return table.concat(lines, "\n") end
                log("ffi_load=ok")
                -- 3a) Anonymous connection (same as lipc-set-prop)
                local code = ffi.new("int[1]")
                local h_anon = lipc_lib.LipcOpenNoName(code)
                log("anon_open=" .. tostring(code[0]) .. " handle=" .. tostring(h_anon ~= nil and h_anon or "nil"))
                if h_anon ~= nil and code[0] == 0 then
                    local rc = lipc_lib.LipcSetStringProperty(h_anon,
                        "com.lab126.playermgr", "PlayParameter",
                        '{"type":"TTS","data":{"paramName":"textsource","paramValue":"FFI anonymous test."}}')
                    log("anon_set_pp=" .. tostring(rc))
                    -- Brief wait then check TTS_State
                    os.execute("sleep 2 2>/dev/null || usleep 2000000 2>/dev/null")
                    local st = ffi.new("int[1]")
                    lipc_lib.LipcGetIntProperty(h_anon, "com.lab126.playermgr", "TTS_State", st)
                    log("anon_tts_state=" .. tostring(st[0]))
                    local ip = ffi.new("int[1]")
                    lipc_lib.LipcGetIntProperty(h_anon, "com.lab126.playermgr", "InPlayback", ip)
                    log("anon_inplayback=" .. tostring(ip[0]))
                    lipc_lib.LipcSetStringProperty(h_anon, "com.lab126.playermgr", "Stop", "")
                    lipc_lib.LipcClose(h_anon)
                end
                -- 3b) Named connection (might be what VoiceView does)
                -- Use a different name than the engine's cached handle to avoid
                -- LIPC error 17 (ALREADY_REGISTERED) when the engine is running.
                code[0] = 0
                local h_named = lipc_lib.LipcOpenEx("com.lab126.koreader.diag", code)
                log("named_open=" .. tostring(code[0]) .. " handle=" .. tostring(h_named ~= nil and h_named or "nil"))
                if h_named ~= nil and code[0] == 0 then
                    -- Set audio focus via named connection
                    lipc_lib.LipcSetStringProperty(h_named,
                        "com.lab126.audiomgrd", "setFocus", "tts")
                    local rc = lipc_lib.LipcSetStringProperty(h_named,
                        "com.lab126.playermgr", "PlayParameter",
                        '{"type":"TTS","data":{"paramName":"textsource","paramValue":"FFI named test."}}')
                    log("named_set_pp=" .. tostring(rc))
                    os.execute("sleep 2 2>/dev/null || usleep 2000000 2>/dev/null")
                    local st = ffi.new("int[1]")
                    lipc_lib.LipcGetIntProperty(h_named, "com.lab126.playermgr", "TTS_State", st)
                    log("named_tts_state=" .. tostring(st[0]))
                    local ip = ffi.new("int[1]")
                    lipc_lib.LipcGetIntProperty(h_named, "com.lab126.playermgr", "InPlayback", ip)
                    log("named_inplayback=" .. tostring(ip[0]))
                    lipc_lib.LipcSetStringProperty(h_named, "com.lab126.playermgr", "Stop", "")
                    lipc_lib.LipcClose(h_named)
                end
                return table.concat(lines, "\n")
                end)
                if not ok then return "pcall_error: " .. tostring(result) end
                return result
            end)()
        else
            info.kindle_lipc_ffi_test = "skipped (/var nearly full)"
        end


        -- v0.1.5.34: check if running as root (needed for GStreamer plugin dir)
        -- Only report yes/no, not the actual username (privacy).
        info.kindle_is_root = shellCapture("[ \"$(id -u 2>/dev/null)\" = '0' ] && echo yes || echo no", 2) or "n/a"

        -- v0.1.5.34: full English voice config (was truncated at 5 lines)
        info.kindle_voice_config_full = shellCapture(
            "cat /usr/lib/tts/english/en_us_joanna24_a11y.json 2>/dev/null | head -40", 5) or "n/a"

        -- v0.1.5.34: probe libtts_engine.so and voice data files
        info.kindle_tts_engine_probe = shellCapture([[echo "--- libtts_engine.so ---"
ls -la /usr/lib/tts/libtts_engine.so 2>/dev/null || echo "not found"
echo "--- strings from libtts_engine.so (speak/synth/init) ---"
strings /usr/lib/tts/libtts_engine.so 2>/dev/null | grep -iE 'speak|synth|init|play|audio|text|voice|tts' | head -20 || echo "no strings cmd"
echo "--- English voice data ---"
ls -la /mnt/base-us/voice/english/ 2>/dev/null | head -10 || echo "not found"
ls -la /usr/lib/tts/english/ 2>/dev/null | head -10 || echo "not found"
]], 8) or "n/a"

        -- Mixer API: check if audiomgrd exposes Unix sockets for PCM data
        info.kindle_audiomgrd_net = shellCapture([[echo "--- audiomgrd socket fds ---"
AMGR_PID=$(pidof audiomgrd 2>/dev/null)
if [ -n "$AMGR_PID" ]; then
  ls -la /proc/$AMGR_PID/fd/ 2>/dev/null | grep socket | head -10
  echo "--- socket inodes ---"
  for sock in $(ls -la /proc/$AMGR_PID/fd/ 2>/dev/null | grep socket | sed 's/.*\[\(.*\)\]/\1/'); do
    grep "$sock" /proc/net/unix 2>/dev/null
    grep "$sock" /proc/net/tcp 2>/dev/null
    grep "$sock" /proc/net/udp 2>/dev/null
  done | head -20
fi
]], 5) or "n/a"

        -- v0.1.x.x: Deep audio architecture probe for firmwares where
        -- audiomgrd reports no output despite BT headphones being paired.
        -- This section investigates Android/Bluedroid stack migration
        -- and alternative initialization sequences (issue #32).

        -- 1) Android / Bluedroid audio stack detection.
        -- Newer Kindle firmware may use Android's audio stack instead of
        -- the traditional audiomgrd → btfd pipeline.
        info.kindle_android_audio = shellCapture([[echo "=== Android audio processes ==="
ps 2>/dev/null | grep -iE 'audioflinger|audioserver|audio_hw|mediaserver|media\.server' | grep -v grep | head -10 || echo "none"
echo "=== Audio HAL libs ==="
ls -la /usr/lib/audio.primary.*.so /usr/lib/libaudio*.so /system/lib/audio.primary.*.so /system/lib/libaudio*.so 2>/dev/null | head -10 || echo "none"
echo "=== Audio policy files ==="
find /etc /system/etc /usr/share /vendor/etc -maxdepth 3 -name '*audio_policy*' -o -name '*audio_effects*' -o -name '*audio_output*' 2>/dev/null | head -15 || echo "none"
echo "=== Audio config files ==="
cat /etc/audio_policy.conf 2>/dev/null | head -30 || echo "no /etc/audio_policy.conf"
cat /system/etc/audio_policy.conf 2>/dev/null | head -30 || echo "no /system/etc/audio_policy.conf"
echo "=== Binder devices ==="
ls -la /dev/binder /dev/hwbinder /dev/vndbinder 2>/dev/null || echo "no binder devices"
echo "=== getprop audio properties ==="
for p in $(getprop 2>/dev/null | grep -iE 'audio|bt|a2dp|bluetooth|sound' | cut -d']' -f1 | tr -d '[]'); do
  echo "$p=$(getprop $p 2>/dev/null)"
done | head -30 || echo "getprop not available"
]], 10) or "n/a"

        -- 2) Full audiomgrd and playermgr property dump.
        -- On some firmwares properties exist but have different names.
        info.kindle_audiomgrd_all_props = shellCapture(
            "lipc-probe com.lab126.audiomgrd 2>/dev/null | head -60", 5) or "n/a"
        info.kindle_playermgr_all_props = shellCapture(
            "lipc-probe com.lab126.playermgr 2>/dev/null | head -60", 5) or "n/a"

        -- 3) Read every known audiomgrd property even if undocumented.
        info.kindle_audiomgrd_deep = shellCapture([[echo "=== audiomgrd deep read ==="
for prop in isStarted audioOutputConnected audioCurrentOutput speakerVolume setFocus audioState btState outputDevice outputRoute sinkState streamState; do
  val=$(lipc-get-prop com.lab126.audiomgrd "$prop" 2>&1)
  rc=$?
  echo "prop=$prop rc=$rc val=$val"
done
]], 8) or "n/a"

        -- 4) Read every known playermgr property.
        info.kindle_playermgr_deep = shellCapture([[echo "=== playermgr deep read ==="
for prop in InPlayback TTS_State State CurrentState Position Duration Volume Mute gstLogLevel; do
  val=$(lipc-get-prop com.lab126.playermgr "$prop" 2>&1)
  rc=$?
  echo "prop=$prop rc=$rc val=$val"
done
]], 8) or "n/a"

        -- 5) Try aggressive initialization sequences to trigger audiomgrd
        -- into recognizing BT output.  These are safe (no sound produced).
        if not skip_intensive then
            info.kindle_audio_trigger = shellCapture([[echo "=== Trigger sequence tests ==="
-- Sequence A: setFocus tts + query outputConnected
echo "--- seqA: setFocus tts ---"
val1=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)
echo "before_focus=$val1"
focusA=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)
echo "setFocus_tts_rc=$focusA"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
val2=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)
echo "after_tts_focus=$val2"
-- Sequence B: setFocus playermgr
echo "--- seqB: setFocus playermgr ---"
focusB=$(lipc-set-prop com.lab126.audiomgrd setFocus 'playermgr' 2>&1)
echo "setFocus_playermgr_rc=$focusB"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
val3=$(lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>&1)
echo "after_pm_focus=$val3"
-- Sequence C: setFocus with BT state hint
echo "--- seqC: BT-aware focus ---"
val4=$(lipc-get-prop com.lab126.audiomgrd btState 2>&1 || echo "no_btState")
echo "btState=$val4"
-- Sequence D: Query audioState if it exists
echo "--- seqD: audioState ---"
val5=$(lipc-get-prop com.lab126.audiomgrd audioState 2>&1 || echo "no_audioState")
echo "audioState=$val5"
]], 15) or "failed"
        else
            info.kindle_audio_trigger = "skipped (/var nearly full)"
        end

        -- 6) D-Bus deep inspection: list ALL services, not just BlueZ.
        -- Newer firmware may expose audio routing via D-Bus instead of LIPC.
        info.kindle_dbus_all = shellCapture([[echo "=== D-Bus service list ==="
dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -v '^method' | head -30 || echo "dbus not available"
echo "=== D-Bus audio-related ==="
dbus-send --system --print-reply --dest=org.freedesktop.DBus /org/freedesktop/DBus org.freedesktop.DBus.ListNames 2>/dev/null | grep -iE 'audio|media|blue|a2dp|pulse|pipewire' | head -15 || echo "none"
]], 8) or "n/a"

        -- 7) Full process tree (not just audio-filtered).
        -- Reveals if unexpected daemons (e.g. Android audioserver) are running.
        info.kindle_all_procs = shellCapture(
            "ps 2>/dev/null | grep -v 'ps$' | grep -v grep | head -40", 3) or "n/a"

        -- 8) Bluedroid deep inspection.
        -- The A2DP control socket at /data/misc/bluedroid/.a2dp_ctrl suggests
        -- Amazon switched to Android's Bluedroid stack on some firmwares.
        info.kindle_bluedroid = shellCapture([[echo "=== Bluedroid state ==="
ls -la /data/misc/bluedroid/ 2>/dev/null || echo "no /data/misc/bluedroid"
echo "=== BT config ==="
cat /data/misc/bluedroid/bt_config.conf 2>/dev/null | head -20 || echo "no bt_config.conf"
echo "=== BT stack processes ==="
ps 2>/dev/null | grep -iE 'bluedroid|btif|bta|btm|btstack' | grep -v grep | head -10 || echo "none"
echo "=== A2DP data socket ==="
cat /proc/net/unix 2>/dev/null | grep a2dp | head -10 || echo "no a2dp sockets"
]], 8) or "n/a"

        -- 9) Library dependency check: what do audiomgrd and btfd link to?
        -- Missing libraries may explain why the audio pipeline fails to init.
        info.kindle_audio_deps = shellCapture([[echo "=== audiomgrd deps ==="
ldd $(which audiomgrd 2>/dev/null || echo /usr/bin/audiomgrd) 2>/dev/null | head -20 || echo "ldd not available"
echo "=== btfd deps ==="
ldd $(which btfd 2>/dev/null || echo /usr/bin/btfd) 2>/dev/null | head -20 || echo "ldd not available"
echo "=== Missing libs in /usr/lib ==="
ls -la /usr/lib/libaudio*.so* /usr/lib/libbt*.so* /usr/lib/libsbc*.so* /usr/lib/liba2dp*.so* 2>/dev/null | head -20 || echo "none found"
]], 8) or "n/a"

        -- 10) Check if any ALSA card appears after aggressive focus dance.
        -- Some firmwares dynamically register ALSA cards only after focus.
        if not skip_intensive then
            info.kindle_alsa_after_focus = shellCapture([[echo "=== ALSA before focus ==="
aplay -l 2>&1 | head -5
aplay -L 2>&1 | head -10
echo "=== Triggering focus dance ==="
lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>/dev/null
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
lipc-set-prop com.lab126.playermgr Stop '' 2>/dev/null
lipc-set-prop com.lab126.playermgr Open '' 2>/dev/null
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
echo "=== ALSA after focus ==="
aplay -l 2>&1 | head -5
aplay -L 2>&1 | head -10
echo "=== /dev/snd after focus ==="
ls -la /dev/snd/ 2>/dev/null || echo "empty"
]], 12) or "failed"
        else
            info.kindle_alsa_after_focus = "skipped (/var nearly full)"
        end

        -- 11) Check for new/unexpected LIPC services that might handle audio.
        -- Filter for anything containing audio, media, sound, bt, blue, player.
        info.kindle_lipc_audio_candidates = shellCapture(
            "lipc-probe -l 2>/dev/null | grep -iE 'audio|media|sound|bt|blue|player|music|stream|sink' | head -20", 3) or "n/a"

        -- 12) Inspect /proc/asound for any dynamically created cards
        -- (some firmwares use card aliases or timers instead of real cards).
        info.kindle_asound_full = shellCapture([[echo "=== /proc/asound/ ==="
ls -la /proc/asound/ 2>/dev/null || echo "not found"
echo "=== /proc/asound/cards ==="
cat /proc/asound/cards 2>/dev/null || echo "not found"
echo "=== /proc/asound/devices ==="
cat /proc/asound/devices 2>/dev/null || echo "not found"
echo "=== /proc/asound/pcm ==="
cat /proc/asound/pcm 2>/dev/null || echo "not found"
echo "=== amixer scontrols ==="
amixer scontrols 2>&1 | head -10 || echo "amixer not available"
]], 8) or "n/a"

        -- v0.1.x.x: Targeted diagnostics for missing libIvonaEInkAPI.so.1.0
        -- (issue #32).  The TTS pipeline is intact except for this single
        -- shared library.  If it exists anywhere on the device, a simple
        -- LD_LIBRARY_PATH addition may restore audio.

        -- 13) Search the entire device for Ivona and related audio libraries.
        info.kindle_ivona_search = shellCapture([[echo "=== Ivona library search ==="
find /usr /system /vendor /mnt /data /opt /lib -maxdepth 5 -name '*Ivona*' -o -name '*ivona*' 2>/dev/null | head -30 || echo "find not available or no matches"
echo "=== ldd on libgstttssrc.so ==="
ldd /usr/lib/gstreamer-0.10/libgstttssrc.so 2>/dev/null | head -20 || echo "ldd not available"
echo "=== NEEDED entries (readelf) ==="
readelf -d /usr/lib/gstreamer-0.10/libgstttssrc.so 2>/dev/null | grep -iE 'NEEDED|RPATH|RUNPATH' | head -15 || echo "readelf not available"
echo "=== objdump NEEDED ==="
objdump -p /usr/lib/gstreamer-0.10/libgstttssrc.so 2>/dev/null | grep -iE 'NEEDED|RPATH|RUNPATH' | head -15 || echo "objdump not available"
echo "=== strings referencing Ivona ==="
strings /usr/lib/gstreamer-0.10/libgstttssrc.so 2>/dev/null | grep -iE 'ivona|eink|tts' | head -20 || echo "strings not available"
]], 15) or "n/a"

        -- 14) Check common Android and alternate library paths for audio libs.
        info.kindle_lib_paths = shellCapture([[echo "=== ld.so.cache ==="
ldconfig -p 2>/dev/null | grep -iE 'ivona|audio|tts' | head -15 || echo "ldconfig not available"
echo "=== ld.so.conf ==="
cat /etc/ld.so.conf 2>/dev/null || echo "no ld.so.conf"
ls -la /etc/ld.so.conf.d/ 2>/dev/null | head -5 || echo "no ld.so.conf.d"
echo "=== System lib dirs ==="
for d in /system/lib /system/lib64 /vendor/lib /vendor/lib64 /odm/lib /mnt/base-us/system/lib /usr/local/lib /lib; do
  if [ -d "$d" ]; then
    echo "--- $d ---"
    ls -la "$d"/libIvona* "$d"/libivona* "$d"/libaudioClient* "$d"/libaudioShm* "$d"/libmixer* 2>/dev/null | head -5
  fi
done
]], 10) or "n/a"

        -- 15) Dump libaudioClient.so symbols for potential alternative path.
        -- libaudioClient.so exists on this firmware and might expose a
        -- simple audio playback API if the GStreamer path cannot be restored.
        info.kindle_audio_client = shellCapture([[echo "=== libaudioClient.so ==="
ls -la /usr/lib/libaudioClient.so* 2>/dev/null || echo "not found"
echo "=== nm symbols (play/write/audio/track) ==="
nm -D /usr/lib/libaudioClient.so.1.0 2>/dev/null | grep -iE 'play|write|audio|track|start|stop|create|init|open|close|pcm|stream' | head -25 || echo "nm not available"
echo "=== readelf dynamic symbols ==="
readelf -s /usr/lib/libaudioClient.so.1.0 2>/dev/null | grep -iE 'play|write|audio|track|start|stop|create|init|open|close|pcm|stream' | head -25 || echo "readelf not available"
echo "=== ldd deps ==="
ldd /usr/lib/libaudioClient.so.1.0 2>/dev/null | head -15 || echo "ldd not available"
]], 10) or "n/a"

        -- 16) Re-test raw PCM → mixersink WITH audiomgrd focus set first.
        -- The previous test failed possibly because focus was not granted.
        -- This test sets focus, generates a proper raw PCM file, and tries
        -- both system gst-launch-0.10 and the bundled gst-play helper.
        if not skip_intensive then
            info.kindle_raw_pcm_focused = shellCapture([[trap 'rm -f /tmp/.pcm_focus_test.raw /tmp/.pcm_focus_test.wav' EXIT
-- Generate 1-second 22050 Hz mono S16LE silence
dd if=/dev/zero bs=44100 count=1 2>/dev/null | {
  printf 'RIFF\x24\xac\x00\x00WAVEfmt \x10\x00\x00\x00\x01\x00\x01\x00\x22\x56\x00\x00\x44\xac\x00\x00\x02\x00\x10\x00data\x04\xac\x00\x00'
  cat
} > /tmp/.pcm_focus_test.wav
dd if=/tmp/.pcm_focus_test.wav of=/tmp/.pcm_focus_test.raw bs=1 skip=44 2>/dev/null
echo "raw_size=$(wc -c < /tmp/.pcm_focus_test.raw 2>/dev/null)"
-- Set focus
echo "--- setFocus tts ---"
focus_rc=$(lipc-set-prop com.lab126.audiomgrd setFocus 'tts' 2>&1)
echo "focus_rc=$focus_rc"
sleep 1 2>/dev/null || usleep 1000000 2>/dev/null
-- Test 1: system gst-launch-0.10 with raw PCM + capsfilter
echo "--- gst-launch-0.10 raw PCM ---"
timeout 3 gst-launch-0.10 -v filesrc location=/tmp/.pcm_focus_test.raw ! capsfilter caps="audio/x-raw-int,endianness=1234,signed=true,width=16,depth=16,rate=22050,channels=1" ! mixersink stream-type=Music sync=true 2>&1 | head -20
echo "gst_exit=$?"
-- Test 2: try without capsfilter (let mixersink negotiate)
echo "--- gst-launch-0.10 raw PCM no capsfilter ---"
timeout 3 gst-launch-0.10 -v filesrc location=/tmp/.pcm_focus_test.raw ! mixersink stream-type=Music sync=true 2>&1 | head -15
echo "gst2_exit=$?"
rm -f /tmp/.pcm_focus_test.raw /tmp/.pcm_focus_test.wav
]], 18) or "failed"
        else
            info.kindle_raw_pcm_focused = "skipped (/var nearly full)"
        end

        -- 17) Check if any library path environment variable or config
        -- points to a location where Ivona libs might live.
        info.kindle_env_paths = shellCapture([[echo "=== Env vars ==="
echo "LD_LIBRARY_PATH=$LD_LIBRARY_PATH"
echo "LD_PRELOAD=$LD_PRELOAD"
echo "PATH=$PATH"
echo "=== Mounted partitions ==="
cat /proc/mounts 2>/dev/null | grep -v '^rootfs' | head -20 || echo "no mounts"
echo "=== All .so files with 'audio' in name ==="
find /usr /system /vendor /mnt /data -maxdepth 4 -name '*audio*.so*' 2>/dev/null | head -25 || echo "find not available"
]], 10) or "n/a"
    end

    -- /tmp writable (needed for WAV files)
    info.tmp_writable = fileExists("/tmp") and os.execute("touch /tmp/.audiobook_test 2>/dev/null && rm /tmp/.audiobook_test 2>/dev/null") ~= nil

    -- kindle-gst-play: bundled GStreamer WAV player for devices without wavparse.
    -- Reports whether the binary exists, GStreamer loads, and which elements
    -- are available (especially mixersink which is the only audio path).
    if Device.isKindle and Device:isKindle() then
        -- Locate the plugin directory from the engine or from our own path so
        -- the report works regardless of whether KOReader is installed under
        -- /mnt/us, /opt, or a relative path.
        local plugin_dir = nil
        if plugin and plugin.tts_engine and plugin.tts_engine.plugin_dir then
            plugin_dir = plugin.tts_engine.plugin_dir
        else
            plugin_dir = _utils_dir:sub(1, -2)
        end
        plugin_dir = plugin_dir:gsub("/$", "")

        --- Probe a single gst-play variant and return structured diagnostics.
        -- @tparam string bin_path absolute path to the binary
        -- @tparam string variant key suffix for info fields (e.g. "", "_native", "_native_pw2")
        -- @tparam string|nil wrapped_cmd optional command using bundled ld-linux
        local function probeGstPlayVariant(bin_path, variant, wrapped_cmd)
            local suffix = variant ~= "" and "_" .. variant or ""
            if not fileExists(bin_path) then
                info["kindle_gst_play" .. suffix .. "_probe"] = "binary_not_found"
                return
            end

            local cmd = wrapped_cmd or ("'" .. bin_path .. "'")
            -- Wrap in ( ... ); echo rc=$? so the EXIT CODE is always captured
            -- even when the probe crashes producing no stdout.
            info["kindle_gst_play" .. suffix .. "_probe"] = shellCapture(
                "( " .. cmd .. " --probe ) 2>&1; echo \"rc=$?\"", 8) or "probe_timed_out_or_crashed"
            info["kindle_gst_play" .. suffix .. "_version"] = shellCapture(
                cmd .. " --version 2>&1", 2) or "n/a"
            info["kindle_gst_play" .. suffix .. "_file"] = shellCapture(
                "file '" .. bin_path .. "' 2>&1", 2) or "n/a"
            info["kindle_gst_play" .. suffix .. "_interp"] = shellCapture(
                "readelf -l '" .. bin_path .. "' 2>/dev/null | grep -i 'interpreter'", 3)
                or shellCapture("strings -n 6 '" .. bin_path .. "' 2>/dev/null | grep -m1 'ld-linux'", 3)
                or "n/a"
            info["kindle_gst_play" .. suffix .. "_glibc"] = shellCapture(
                "readelf -V '" .. bin_path .. "' 2>/dev/null | grep -oE 'GLIBC_[0-9.]+' | sort -V | uniq | tail -3", 3) or "n/a"
        end

        local gst_play_bin = plugin_dir .. "/kindle/gst-play"
        local espeak_lib = plugin_dir .. "/espeak-ng/lib"
        local ld_linux = espeak_lib .. "/ld-linux-armhf.so.3"
        local compat_cmd = nil
        if fileExists(ld_linux) then
            compat_cmd = ld_linux .. " --library-path " .. espeak_lib .. ":/usr/lib:/lib '" .. gst_play_bin .. "'"
        end
        -- Compat binary (hard-float, bundled glibc).
        probeGstPlayVariant(gst_play_bin, "", compat_cmd)

        -- Native hard-float variant (kindlehf, firmware >= 5.16.3).
        local native_path = plugin_dir .. "/kindle/gst-play-native"
        probeGstPlayVariant(native_path, "native", nil)

        -- Native soft-float variant (kindlepw2, firmware < 5.16.3).
        local native_pw2_path = plugin_dir .. "/kindle/gst-play-native-pw2"
        probeGstPlayVariant(native_pw2_path, "native_pw2", nil)

        -- KinAMP presence check (useful fallback diagnostic).
        info.kinamp_available = fileExists("/mnt/us/KinAMP/startkinamp_koreader.sh") and "yes" or "no"

        -- Last gst-play playback log (stderr captured during actual play)
        info.kindle_gst_play_last_log = shellCapture(
            "cat /tmp/.gst_play_last.log 2>/dev/null", 2) or "none"
        -- Last ttssrc fallback log (stderr from kindle-native-tts-fallback path)
        info.kindle_ttssrc_fallback_log = shellCapture(
            "cat /tmp/.ttssrc_fallback.log 2>/dev/null", 2) or "none"
    end

    -- Root-cause diagnostic: find deleted files in /var/ still held open
    -- by processes.  These consume space invisible to du but visible to df.
    -- On Kindle the primary culprit is audiomgrd's stderr log.
    info.kindle_deleted_var_files = scanDeletedVarFiles() or "none_found"

    -- Clean up temp files that benchmark tests may have left in /var/tmp.
    -- The TTS orchestrator and audiomgrd can create files there during
    -- probing; on a 64MB /var tmpfs this can fill the filesystem and
    -- break subsequent TTS attempts (issue #23).
    -- Also remove plugin temp files (WAV, FIFO, logs) from previous sessions.
    os.execute("rm -f /var/tmp/audiobook_*.wav /var/tmp/audiobook_*.xml /var/tmp/audiobook_*.txt /var/tmp/audiobook_*.done /var/tmp/piper_server_* /var/tmp/.gst_play_last.log /var/tmp/.ttssrc_* /var/tmp/audiomgrd.err /var/tmp/*.tmp 2>/dev/null")

    return info
end

--- Collect memory and resource info.
local function collectResourceInfo()
    local info = {}
    info.meminfo = shellCapture("head -5 /proc/meminfo 2>/dev/null", 2)
    info.disk_tmp = shellCapture("df -h /tmp 2>/dev/null | tail -1", 2)
    info.disk_var = shellCapture("df -h /var 2>/dev/null | tail -1", 2)
    info.disk_var_usage = shellCapture(
        "du -sk /var/* 2>/dev/null | sort -rn | head -15", 3) or "n/a"
    return info
end

--- Format a table of key-value pairs as aligned text lines.
local function formatSection(title, data, indent)
    indent = indent or ""
    local lines = {indent .. "── " .. title .. " ──"}
    if type(data) ~= "table" then
        table.insert(lines, indent .. "  " .. tostring(data))
        return table.concat(lines, "\n")
    end
    -- Sort keys for deterministic output
    local keys = {}
    for k in pairs(data) do table.insert(keys, k) end
    table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
    for _, k in ipairs(keys) do
        local v = data[k]
        if type(v) == "table" then
            table.insert(lines, indent .. "  " .. tostring(k) .. ":")
            local subkeys = {}
            for sk in pairs(v) do table.insert(subkeys, sk) end
            table.sort(subkeys, function(a, b) return tostring(a) < tostring(b) end)
            for _, sk in ipairs(subkeys) do
                table.insert(lines, indent .. "    " .. tostring(sk) .. ": " .. tostring(v[sk]))
            end
        elseif type(v) == "boolean" then
            table.insert(lines, indent .. "  " .. tostring(k) .. ": " .. (v and "yes" or "no"))
        else
            table.insert(lines, indent .. "  " .. tostring(k) .. ": " .. tostring(v))
        end
    end
    return table.concat(lines, "\n")
end

--- Generate the full bug report as a plain-text string.
-- Each collector is wrapped in pcall so one failing section does not
-- crash the entire report (issue #28).
-- @param plugin table  The Audiobook plugin instance
-- @return string  The formatted bug report text
function BugReport.generate(plugin)
    -- Check /var free space up front.  If critically full, skip probes
    -- that write temp files or spawn background processes.
    local var_pct, _free_kb = checkVarSpace()
    local skip_intensive = var_pct and var_pct >= 90
    local var_warning = nil
    if var_pct and var_pct >= 95 then
        var_warning = "WARNING: /var is " .. var_pct .. "% full."
            .. " This is the most common cause of silent TTS failures on Kindle."
            .. " Please reboot the device to clear /var, then test again."
    elseif skip_intensive then
        var_warning = "WARNING: /var is " .. var_pct
            .. "% full.  Intensive probes were skipped to avoid a crash."
    end

    local ok_device, device = pcall(collectDeviceInfo)
    if not ok_device then device = {section_error = tostring(device)} end

    local ok_koreader, koreader = pcall(collectKoreaderInfo)
    if not ok_koreader then koreader = {section_error = tostring(koreader)} end

    local ok_plugin, pluginInfo = pcall(collectPluginInfo, plugin)
    if not ok_plugin then pluginInfo = {section_error = tostring(pluginInfo)} end

    local ok_audio, audio = pcall(collectAudioInfo, plugin, skip_intensive)
    if not ok_audio then audio = {section_error = tostring(audio)} end

    local ok_resources, resources = pcall(collectResourceInfo)
    if not ok_resources then resources = {section_error = tostring(resources)} end

    local timestamp = os.date("!%Y-%m-%dT%H:%M:%SZ")

    local version = "unknown"
    local ok_meta, meta = pcall(dofile, _utils_dir .. "_meta.lua")
    if ok_meta and meta then
        version = meta.version or version
    end

    local sections = {
        "=== Audiobook Read-Along Bug Report (v" .. version .. ") ===",
        "Generated: " .. timestamp,
        var_warning and "\n*** " .. var_warning .. " ***\n" or "",
        "",
        formatSection("Device", device),
        "",
        formatSection("KOReader", koreader),
        "",
        formatSection("Plugin", pluginInfo),
        "",
        formatSection("Audio & TTS", audio),
        "",
        formatSection("Resources", resources),
        "",
        "── Recent plugin debug log ──",
        (function()
            -- The live ring buffer registered by main.lua at plugin init.
            local DebugLog = package.loaded["audiobook_debuglog"]
            if DebugLog and DebugLog.tail then
                return DebugLog.tail(150)
            end
            return "(debuglog.lua unavailable)"
        end)(),
        "",
        "=== End of Bug Report ===",
    }

    return table.concat(sections, "\n")
end

--- Generate and save the bug report to a file the user can access.
-- Writes sections incrementally to reduce peak memory usage (issue #28).
-- @param plugin table  The Audiobook plugin instance
-- @return string|nil  Path to the saved report, or nil on failure
function BugReport.generateAndSave(plugin)
    -- Pick a user-accessible save location.
    local save_dir
    if Device.isKobo and Device:isKobo() then
        save_dir = "/mnt/onboard"
    elseif Device.isKindle and Device:isKindle() then
        save_dir = "/mnt/us"
    elseif Device.isPocketBook and Device:isPocketBook() then
        save_dir = "/mnt/ext1"
    elseif Device:isAndroid() then
        save_dir = "/sdcard"
    else
        save_dir = os.getenv("HOME") or "/tmp"
    end

    local filename = "audiobook-bug-report-" .. os.date("!%Y%m%d-%H%M%S") .. ".txt"
    local filepath = save_dir .. "/" .. filename

    local f, err = io.open(filepath, "w")
    if not f then
        filepath = "/tmp/" .. filename
        f, err = io.open(filepath, "w")
    end
    if not f then
        logger.err("BugReport: Cannot save report:", err)
        return nil
    end

    -- Stream-write: generate and write in chunks instead of one giant string.
    local ok, report = pcall(BugReport.generate, plugin)
    if ok and report then
        -- Write in ~4KB chunks to keep memory footprint low.
        local chunk_size = 4096
        local pos = 1
        while pos <= #report do
            f:write(report:sub(pos, pos + chunk_size - 1))
            pos = pos + chunk_size
        end
    else
        f:write("Bug report generation failed:\n" .. tostring(report) .. "\n")
    end

    f:close()
    logger.dbg("BugReport: Saved to", filepath)
    return filepath
end

--- Menu callback: generate report and show result to user.
-- Wrapped in pcall so any crash during generation is caught gracefully
-- instead of crashing KOReader (issue #28).
-- @param plugin table  The Audiobook plugin instance
function BugReport.menuCallback(plugin)
    local ok, filepath = pcall(BugReport.generateAndSave, plugin)
    if ok and filepath then
        local display_path = sanitizePath(filepath)
        UIManager:show(InfoMessage:new{
            text = _("Bug report saved to:\n\n") .. display_path ..
                _("\n\nConnect your device via USB to retrieve the file. Please share it when reporting issues on GitHub."),
            timeout = 15,
        })
    elseif ok then
        -- generateAndSave returned nil (could not open file)
        UIManager:show(InfoMessage:new{
            text = _("Could not save bug report file.\n\nPlease check that /tmp or /var has free space, then try again."),
            timeout = 10,
        })
    else
        -- pcall caught an error -- show a safe fallback
        logger.err("BugReport: menuCallback crashed:", tostring(filepath))
        UIManager:show(InfoMessage:new{
            text = _("Bug report generation failed.\n\nThis usually means temporary storage (/var) is full. Please reboot your Kindle and try again."),
            timeout = 12,
        })
    end
end

return BugReport
