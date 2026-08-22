--[[--
Bluetooth Media Control (AVRCP) Module
Handles BT headset media buttons (play/pause/next/prev) and sends
playback status / metadata back to the connected BT device.

Two mechanisms for receiving media button events:
  1. **evdev** — If BlueZ/mtkbtd creates a virtual input device for AVRCP
     passthrough commands, we open it and read key events directly.
  2. **D-Bus polling** — If no evdev device is found, we poll the
     org.bluez.MediaControl1 / MediaPlayer1 interfaces via D-Bus.

For sending feedback to the BT device:
  - Uses the org.bluez.MediaPlayer1 D-Bus interface (if available) to
    set Track metadata, Status, and Position.
  - Falls back to dbus-send commands to update AVRCP target properties.

@module btmediacontrol
--]]

local Device = require("device")
local UIManager = require("ui/uimanager")
local logger = require("logger")
local _ = require("audiobook_gettext")

local BtMediaControl = {}

-- ── Linux media key codes ────────────────────────────────────────────
local KEY_NEXTSONG     = 163
local KEY_PLAYPAUSE    = 164
local KEY_PREVIOUSSONG = 165
local KEY_STOPCD       = 166
local KEY_PLAYCD       = 200
local KEY_PAUSECD      = 201
local KEY_FASTFORWARD  = 208
local KEY_REWIND       = 168

-- Event map: media key codes → our internal event names
BtMediaControl.MEDIA_KEY_MAP = {
    [KEY_PLAYPAUSE]    = "MediaPlayPause",
    [KEY_PLAYCD]       = "MediaPlay",
    [KEY_PAUSECD]      = "MediaPause",
    [KEY_STOPCD]       = "MediaStop",
    [KEY_NEXTSONG]     = "MediaNext",
    [KEY_PREVIOUSSONG] = "MediaPrev",
    [KEY_FASTFORWARD]  = "MediaFastForward",
    [KEY_REWIND]       = "MediaRewind",
}

-- D-Bus constants
local DBUS_DEST = "com.kobo.mtk.bluedroid"

-- ── State ────────────────────────────────────────────────────────────

-- Path to the opened AVRCP evdev device (nil if not found)
BtMediaControl._avrcp_evdev_path = nil
-- Whether the evdev-based input is active
BtMediaControl._evdev_active = false
-- Original event_map before we merged media keys
BtMediaControl._original_event_map = nil
-- Whether the D-Bus polling fallback is active
BtMediaControl._dbus_polling_active = false
-- Reference to the plugin for callbacks
BtMediaControl._plugin = nil
-- Last known status sent to BT device
BtMediaControl._last_sent_status = nil

-- ══════════════════════════════════════════════════════════════════════
-- RECEIVING MEDIA BUTTONS
-- ══════════════════════════════════════════════════════════════════════

--[[--
Start listening for BT media button events.
Tries evdev first, falls back to D-Bus polling.

@param plugin  The Audiobook plugin instance (for pause/resume/next/prev callbacks)
--]]
function BtMediaControl.start(plugin)
    BtMediaControl._plugin = plugin

    -- Android (Boox): AVRCP arrives via MediaSession, not BlueZ evdev.
    if Device.isAndroid and Device:isAndroid() then
        return BtMediaControl._startAndroidMediaSession(plugin)
    end

    -- Try evdev approach first
    local found = BtMediaControl._tryEvdevApproach()
    if found then
        logger.warn("BtMediaControl: AVRCP evdev device found and opened")
        return true
    end

    -- Kindle: no BlueZ AVRCP — advertise playback state via btui (if present)
    -- and keep rescanning input nodes; AirPods stem needs an AVRCP target.
    if Device.isKindle and Device:isKindle() then
        logger.warn("BtMediaControl: Kindle AVRCP path (no BlueZ evdev)")
        BtMediaControl._startKindleAvrcpSupport()
        return true
    end

    -- Fall back to D-Bus key monitoring
    logger.warn("BtMediaControl: No AVRCP evdev device found, trying D-Bus polling")
    BtMediaControl._startDbusPolling()
    return true
end

--- Android MediaSession path (AirPods stem / BT headset buttons on Boox).
function BtMediaControl._startAndroidMediaSession(plugin)
    if BtMediaControl._android_session then
        BtMediaControl._android_session:startPolling(plugin)
        return true
    end
    local plugin_dir = (plugin and plugin.path) or "."
    local ok, AndroidMediaSession = pcall(dofile,
        plugin_dir:gsub("/+$", "") .. "/androidmediasession.lua")
    if not ok or not AndroidMediaSession then
        -- Fallback: same folder as this module.
        local here = debug.getinfo(1, "S").source:match("^@(.*/)[^/]*$") or "./"
        ok, AndroidMediaSession = pcall(dofile, here .. "androidmediasession.lua")
    end
    if not ok or not AndroidMediaSession then
        logger.warn("BtMediaControl: AndroidMediaSession load failed:", AndroidMediaSession)
        return false
    end
    local session = AndroidMediaSession:new()
    if not session:init(plugin_dir) then
        logger.warn("BtMediaControl: Android MediaSession helper unavailable")
        return false
    end
    BtMediaControl._android_session = session
    session:startSession("Audiobook", "")
    session:startPolling(plugin)
    logger.warn("BtMediaControl: Android MediaSession AVRCP active")
    return true
end

function BtMediaControl.getAndroidSession()
    return BtMediaControl._android_session
end

--[[--
Stop listening for BT media button events.
--]]
function BtMediaControl.stop()
    BtMediaControl._stopEvdev()
    BtMediaControl._stopDbusPolling()
    BtMediaControl._stopKindleAvrcpSupport()
    if BtMediaControl._android_session then
        pcall(function()
            BtMediaControl._android_session:stopPolling()
            BtMediaControl._android_session:stopSession()
        end)
    end
    BtMediaControl._plugin = nil
end

-- ── evdev approach ───────────────────────────────────────────────────

--[[--
Scan /sys/class/input/ for an AVRCP virtual input device.
BlueZ creates these with "(AVRCP)" in the name.

@return string|nil  Path to the evdev device (e.g. "/dev/input/event5")
@return string|nil  Device name
--]]
function BtMediaControl._findAvrcpEvdevDevice()
    -- Method 1: scan /sys/class/input/ for AVRCP device name
    -- Collect all AVRCP devices, prefer the device-specific one (has
    -- the BT device name like "OpenRun Pro by Shokz (AVRCP)") over the
    -- generic "AVRCP" device.
    local handle = io.popen(
        'for d in /sys/class/input/event*; do '
        .. '  name_file="$d/device/name"; '
        .. '  [ -f "$name_file" ] && name=$(cat "$name_file") && '
        .. '  echo "$d $name"; '
        .. 'done 2>/dev/null'
    )
    if handle then
        local output = handle:read("*a")
        handle:close()
        local generic_path, generic_name = nil, nil
        for line in output:gmatch("[^\n]+") do
            local sys_path, dev_name = line:match("^(%S+)%s+(.+)$")
            if sys_path and dev_name then
                local ev_num = sys_path:match("event(%d+)")
                if ev_num and dev_name:lower():find("avrcp") then
                    local dev_path = "/dev/input/event" .. ev_num
                    -- Prefer device-specific name (contains more than just "AVRCP")
                    if dev_name ~= "AVRCP" then
                        logger.warn("BtMediaControl: Found device-specific AVRCP evdev:",
                            dev_path, "name:", dev_name)
                        return dev_path, dev_name
                    else
                        generic_path = dev_path
                        generic_name = dev_name
                    end
                end
            end
        end
        -- Fall back to generic AVRCP device
        if generic_path then
            logger.warn("BtMediaControl: Found generic AVRCP evdev:",
                generic_path, "name:", generic_name)
            return generic_path, generic_name
        end
    end

    -- Method 2: check /proc/bus/input/devices for AVRCP / media keys.
    -- Blocks end at a blank line; KEY= usually appears after Handlers=.
    handle = io.popen("cat /proc/bus/input/devices 2>/dev/null")
    if handle then
        local output = handle:read("*a")
        handle:close()
        local current_name, current_handlers, current_key_bitmap = nil, nil, nil
        local function consider_block()
            if not current_name or not current_handlers then return nil end
            local lname = current_name:lower()
            local name_hit = lname:find("avrcp", 1, true)
                or lname:find("media key", 1, true)
                or lname:find("consumer control", 1, true)
                or lname:find("airpods", 1, true)
                or lname:find("beats", 1, true)
                or lname:find("headset", 1, true)
                or lname:find("headphone", 1, true)
            local key_hit = current_key_bitmap
                and (BtMediaControl._keyBitmapHasCode(current_key_bitmap, KEY_PLAYPAUSE)
                    or BtMediaControl._keyBitmapHasCode(current_key_bitmap, KEY_PLAYCD)
                    or BtMediaControl._keyBitmapHasCode(current_key_bitmap, KEY_PAUSECD))
            if not (name_hit or key_hit) then return nil end
            local event_dev = current_handlers:match("(event%d+)")
            if not event_dev then return nil end
            local dev_path = "/dev/input/" .. event_dev
            logger.warn("BtMediaControl: Found media input:",
                dev_path, "name:", current_name,
                "name_hit=", name_hit and "yes" or "no",
                "key_hit=", key_hit and "yes" or "no")
            return dev_path, current_name
        end
        for line in (output .. "\n"):gmatch("([^\n]*)\n") do
            if line == "" then
                local path, name = consider_block()
                if path then return path, name end
                current_name, current_handlers, current_key_bitmap = nil, nil, nil
            else
                local name = line:match('^N: Name="(.-)"')
                if name then current_name = name end
                local handlers = line:match("^H: Handlers=(.*)")
                if handlers then current_handlers = handlers end
                local keys = line:match("^B: KEY=(.*)")
                if keys then current_key_bitmap = keys end
            end
        end
        local path, name = consider_block()
        if path then return path, name end
    end

    return nil, nil
end

--- Return true if a /proc/bus/input/devices KEY= bitmap includes keycode.
function BtMediaControl._keyBitmapHasCode(bitmap, keycode)
    if not bitmap or not keycode then return false end
    -- KEY= words are little-endian hex longs (native long width).  Use 32-bit
    -- words as a practical common case on Kindle ARM; also try 64-bit.
    local words = {}
    for hex in bitmap:gmatch("%x+") do
        table.insert(words, tonumber(hex, 16) or 0)
    end
    for _, bits_per_word in ipairs({32, 64}) do
        local idx = math.floor(keycode / bits_per_word) + 1
        local bit = keycode % bits_per_word
        local word = words[idx]
        if word and math.floor(word / (2 ^ bit)) % 2 == 1 then
            return true
        end
    end
    return false
end

--[[--
Try to open the AVRCP evdev device and merge media keys into the event map.
@return boolean  true if an AVRCP device was found and opened
--]]
function BtMediaControl._tryEvdevApproach()
    local dev_path, dev_name = BtMediaControl._findAvrcpEvdevDevice()
    if not dev_path then
        return false
    end

    -- Check if the device is already opened by KOReader's input system
    if Device.input and Device.input.opened_devices
            and Device.input.opened_devices[dev_path] then
        logger.warn("BtMediaControl: AVRCP device already opened:", dev_path)
        -- Just ensure our keys are in the event map
        BtMediaControl._mergeMediaKeyMap()
        BtMediaControl._avrcp_evdev_path = dev_path
        BtMediaControl._evdev_active = true
        return true
    end

    -- Open the evdev device
    if Device.input and Device.input.open then
        local ok, fd = pcall(Device.input.open, Device.input, dev_path)
        if ok and fd then
            logger.warn("BtMediaControl: Opened AVRCP evdev:", dev_path, "fd:", fd)
            BtMediaControl._avrcp_evdev_path = dev_path
            BtMediaControl._evdev_active = true
            BtMediaControl._mergeMediaKeyMap()
            return true
        else
            logger.warn("BtMediaControl: Failed to open AVRCP device:", dev_path, fd)
        end
    end

    return false
end

--[[--
Merge media key codes into KOReader's event_map and install
event_map_adapter + UIManager.event_handlers so media key presses
are dispatched directly to our handlers (like SleepCover / Power).

KOReader dispatch flow for adapter-mapped keys:
  evdev EV_KEY → event_map[code] → event_map_adapter[name](ev)
  → returns string → UIManager.event_handlers[string]()

This bypasses the widget tree (no onKeyPress needed) and gives us
reliable global handling regardless of what widget is focused.
--]]
function BtMediaControl._mergeMediaKeyMap()
    if not Device.input or not Device.input.event_map then return end
    if BtMediaControl._keys_installed then return end

    -- Save original map entries for restoration
    BtMediaControl._original_event_map = {}
    BtMediaControl._original_adapters = {}
    BtMediaControl._original_handlers = {}

    -- Step 1: Add key codes → names in event_map
    for keycode, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
        BtMediaControl._original_event_map[keycode] = Device.input.event_map[keycode]
        Device.input.event_map[keycode] = event_name
    end

    -- Step 2: Add event_map_adapter entries (convert press/release → string)
    -- The adapter function receives the raw ev and returns a string on press.
    local adapter = Device.input.event_map_adapter
    if adapter then
        for _, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
            if not BtMediaControl._original_adapters[event_name] then
                BtMediaControl._original_adapters[event_name] = adapter[event_name]
                adapter[event_name] = function(ev)
                    -- Only handle key press, ignore repeat/release
                    if Device.input:isEvKeyPress(ev) then
                        return event_name
                    end
                end
            end
        end
    end

    -- Step 3: Register UIManager.event_handlers for each media event name
    if UIManager.event_handlers then
        for _, event_name in pairs(BtMediaControl.MEDIA_KEY_MAP) do
            if not BtMediaControl._original_handlers[event_name] then
                BtMediaControl._original_handlers[event_name] = UIManager.event_handlers[event_name]
                UIManager.event_handlers[event_name] = function()
                    BtMediaControl._dispatchMediaEvent(event_name)
                end
            end
        end
    end

    BtMediaControl._keys_installed = true
    logger.warn("BtMediaControl: Media key map + adapters + handlers installed")
end

--[[--
Close the AVRCP evdev device and restore event_map, adapters, and handlers.
--]]
function BtMediaControl._stopEvdev()
    if BtMediaControl._avrcp_evdev_path and Device.input then
        pcall(Device.input.close, Device.input, BtMediaControl._avrcp_evdev_path)
        logger.warn("BtMediaControl: Closed AVRCP evdev:", BtMediaControl._avrcp_evdev_path)
    end

    -- Restore everything we changed
    if BtMediaControl._keys_installed and Device.input then
        -- Restore event_map
        if BtMediaControl._original_event_map then
            for keycode, orig_val in pairs(BtMediaControl._original_event_map) do
                Device.input.event_map[keycode] = orig_val
            end
        end
        -- Restore event_map_adapter
        if BtMediaControl._original_adapters and Device.input.event_map_adapter then
            for name, orig_fn in pairs(BtMediaControl._original_adapters) do
                Device.input.event_map_adapter[name] = orig_fn
            end
        end
        -- Restore UIManager.event_handlers
        if BtMediaControl._original_handlers and UIManager.event_handlers then
            for name, orig_fn in pairs(BtMediaControl._original_handlers) do
                UIManager.event_handlers[name] = orig_fn
            end
        end
    end

    BtMediaControl._avrcp_evdev_path = nil
    BtMediaControl._evdev_active = false
    BtMediaControl._original_event_map = nil
    BtMediaControl._original_adapters = nil
    BtMediaControl._original_handlers = nil
    BtMediaControl._keys_installed = false
end

-- ── D-Bus polling fallback ───────────────────────────────────────────
-- If no evdev device exists, poll for AVRCP button events via D-Bus.
-- mtkbtd may expose a MediaControl1 or MediaPlayer1 interface that
-- reflects button presses from the connected headset.

function BtMediaControl._startDbusPolling()
    if BtMediaControl._dbus_polling_active then return end
    BtMediaControl._dbus_polling_active = true
    BtMediaControl._last_dbus_status = nil

    BtMediaControl._pollDbusMediaControl()
end

function BtMediaControl._stopDbusPolling()
    BtMediaControl._dbus_polling_active = false
end

--[[--
Poll for AVRCP/MediaPlayer1 status changes via D-Bus.
Checks the connected device's MediaPlayer1 or MediaControl1 properties
for status changes that indicate headset button presses.
--]]
function BtMediaControl._pollDbusMediaControl()
    if not BtMediaControl._dbus_polling_active then return end

    local plugin = BtMediaControl._plugin
    if not plugin then
        BtMediaControl._dbus_polling_active = false
        return
    end

    -- Look for MediaPlayer1 Status property on connected device
    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s / '
        .. 'org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null '
        .. '| grep -A2 "MediaPlayer1" | grep -i "status" | head -1',
        DBUS_DEST
    )
    local handle = io.popen(cmd)
    if handle then
        local output = handle:read("*a") or ""
        handle:close()

        -- Parse status if found
        local status = output:match('string "(%w+)"')
        if status and BtMediaControl._last_dbus_status
                and status ~= BtMediaControl._last_dbus_status then
            -- Status changed — headset button was pressed
            logger.warn("BtMediaControl: D-Bus status changed:",
                BtMediaControl._last_dbus_status, "→", status)
            BtMediaControl._handleDbusStatusChange(status)
        end
        if status then
            BtMediaControl._last_dbus_status = status
        end
    end

    -- Reschedule polling (2s interval — low overhead)
    if BtMediaControl._dbus_polling_active then
        UIManager:scheduleIn(2.0, BtMediaControl._pollDbusMediaControl)
    end
end

--[[--
Handle a status change detected via D-Bus polling.
--]]
function BtMediaControl._handleDbusStatusChange(new_status)
    local plugin = BtMediaControl._plugin
    if not plugin then return end

    if new_status == "paused" then
        BtMediaControl._dispatchMediaEvent("MediaPause")
    elseif new_status == "playing" then
        BtMediaControl._dispatchMediaEvent("MediaPlay")
    elseif new_status == "stopped" then
        BtMediaControl._dispatchMediaEvent("MediaStop")
    end
end

-- ── Event dispatch ───────────────────────────────────────────────────

--[[--
Dispatch a media event to the plugin.
@param event_name string  One of "MediaPlayPause", "MediaPlay", "MediaPause",
                          "MediaStop", "MediaNext", "MediaPrev"
--]]
function BtMediaControl._dispatchMediaEvent(event_name)
    local plugin = BtMediaControl._plugin
    if not plugin then return end

    logger.warn("BtMediaControl: Dispatching media event:", event_name)

    -- Determine which controller is active: media_sync (audio files) or
    -- sync_controller (TTS).  media_sync takes priority when it is not stopped.
    local media_active = plugin.media_sync and plugin.media_sync.state ~= "stopped"
    local tts_active = not media_active and plugin.sync_controller
        and (plugin.sync_controller:isPlaying() or plugin.sync_controller:isPaused())

    if event_name == "MediaPlayPause" then
        if media_active then
            if plugin.media_sync.state == "playing" then
                plugin:pauseReadAlong()
            elseif plugin.media_sync.state == "paused" then
                plugin:resumeReadAlong()
            end
        elseif tts_active then
            if plugin.sync_controller:isPlaying() then
                plugin:pauseReadAlong()
            elseif plugin.sync_controller:isPaused() then
                plugin:resumeReadAlong()
            end
        end
    elseif event_name == "MediaPlay" then
        if media_active then
            if plugin.media_sync.state == "paused" then
                plugin:resumeReadAlong()
            end
        elseif plugin.sync_controller and plugin.sync_controller:isPaused() then
            plugin:resumeReadAlong()
        end
    elseif event_name == "MediaPause" then
        if media_active then
            if plugin.media_sync.state == "playing" then
                plugin:pauseReadAlong()
            end
        elseif plugin.sync_controller and plugin.sync_controller:isPlaying() then
            plugin:pauseReadAlong()
        end
    elseif event_name == "MediaStop" then
        plugin:stopReadAlong()
    elseif event_name == "MediaNext" then
        if media_active then
            plugin.media_sync:nextChapter()
        elseif tts_active then
            plugin.sync_controller:nextSentence()
        end
    elseif event_name == "MediaPrev" then
        if media_active then
            plugin.media_sync:prevChapter()
        elseif tts_active then
            plugin.sync_controller:prevSentence()
        end
    elseif event_name == "MediaFastForward" then
        if media_active then
            plugin.media_sync:skipForward(30)
        elseif tts_active then
            plugin.sync_controller:skipForward(30)
        end
    elseif event_name == "MediaRewind" then
        if media_active then
            plugin.media_sync:skipBack(30)
        elseif tts_active then
            plugin.sync_controller:skipBack(30)
        end
    end
end


-- ── Kindle AVRCP (AirPods stem / headset buttons) ────────────────────
-- Kindle uses Lab126 btfd/Bluedroid, not BlueZ.  There is often no
-- "(AVRCP)" evdev node.  We:
--   1) advertise playback state via `btui` when available (AVRCP TG),
--   2) periodically rescan /dev/input for media-key devices,
--   3) poll lipc for playermgr / btfd hints that a remote command arrived.

function BtMediaControl._startKindleAvrcpSupport()
    if BtMediaControl._kindle_avrcp_active then return end
    BtMediaControl._kindle_avrcp_active = true
    BtMediaControl._kindleAdvertisePlaybackState("paused")
    BtMediaControl._startKindleLipcEventWatch()
    BtMediaControl._pollKindleAvrcp()
end

function BtMediaControl._stopKindleAvrcpSupport()
    BtMediaControl._kindle_avrcp_active = false
    BtMediaControl._stopKindleLipcEventWatch()
end

-- PW11 / Lab126 Bluedroid never creates an AVRCP evdev node. Headset stem
-- clicks still land on playermgr / audiomgrd / btfd as LIPC events (Pause,
-- Play, Stop). Watch those in the background and treat them as toggles.
local KINDLE_AVRCP_LOG = "/tmp/abk-kindle-avrcp.log"
local KINDLE_LIPC_WATCH = {
    "com.lab126.playermgr",
    "com.lab126.audiomgrd",
    "com.lab126.btfd",
    "com.lab126.acsbt",
}

function BtMediaControl._startKindleLipcEventWatch()
    if BtMediaControl._kindle_lipc_watch_started then return end
    BtMediaControl._kindle_lipc_watch_started = true
    os.execute("rm -f " .. KINDLE_AVRCP_LOG)
    os.execute("touch " .. KINDLE_AVRCP_LOG)
    for _, svc in ipairs(KINDLE_LIPC_WATCH) do
        os.execute(string.format(
            "( lipc-wait-event -m %s '*' >> %s 2>/dev/null ) &",
            svc, KINDLE_AVRCP_LOG))
    end
    BtMediaControl._kindle_avrcp_log_pos = 0
    logger.warn("BtMediaControl: Kindle LIPC AVRCP watch started")
end

function BtMediaControl._stopKindleLipcEventWatch()
    if not BtMediaControl._kindle_lipc_watch_started then return end
    BtMediaControl._kindle_lipc_watch_started = false
    os.execute("pkill -f 'abk-kindle-avrcp' 2>/dev/null")
    -- The redirect filename is the only unique token we own.
    os.execute("pkill -f '/tmp/abk-kindle-avrcp.log' 2>/dev/null")
end

function BtMediaControl._consumeKindleLipcEvents()
    local f = io.open(KINDLE_AVRCP_LOG, "r")
    if not f then return end
    f:seek("set", BtMediaControl._kindle_avrcp_log_pos or 0)
    local chunk = f:read("*a") or ""
    BtMediaControl._kindle_avrcp_log_pos = f:seek()
    f:close()
    if chunk == "" then return end
    local now = os.time()
    for line in chunk:gmatch("[^\n]+") do
        -- Ignore our own status chatter and volume / connection noise.
        if line:find("audioOutput", 1, true)
            or line:find("speakerVolume", 1, true)
            or line:find("ListConnected", 1, true) then
            -- skip
        else
            local ev = line:lower()
            local is_pause = ev:find("%f[%a]pause%f[%A]")
            local is_play = ev:find("%f[%a]play%f[%A]")
                or ev:find("%f[%a]playparameter%f[%A]")
            local is_stop = ev:find("%f[%a]stop%f[%A]")
            local is_next = ev:find("%f[%a]next%f[%A]") or ev:find("forward", 1, true)
            local is_prev = ev:find("%f[%a]prev%f[%A]") or ev:find("backward", 1, true)
            if is_pause or is_play or is_stop or is_next or is_prev then
                if BtMediaControl._kindle_avrcp_debounce
                    and (now - BtMediaControl._kindle_avrcp_debounce) < 1 then
                    logger.warn("BtMediaControl: Kindle LIPC debounce", line)
                else
                    BtMediaControl._kindle_avrcp_debounce = now
                    logger.warn("BtMediaControl: Kindle LIPC AVRCP", line)
                    if is_next then
                        BtMediaControl._dispatchMediaEvent("MediaNext")
                    elseif is_prev then
                        BtMediaControl._dispatchMediaEvent("MediaPrev")
                    else
                        -- Stem clicks on Soundcore / AirPods are one button:
                        -- treat Play, Pause, and Stop as a toggle.
                        BtMediaControl._dispatchMediaEvent("MediaPlayPause")
                    end
                end
            end
        end
    end
end

function BtMediaControl._btuiAvailable()
    if BtMediaControl._btui_checked then
        return BtMediaControl._btui_path ~= nil
    end
    BtMediaControl._btui_checked = true
    local h = io.popen("command -v btui 2>/dev/null; ls /usr/bin/btui 2>/dev/null")
    if not h then return false end
    local out = h:read("*a") or ""
    h:close()
    local path = out:match("(/[^\n]+btui)")
    BtMediaControl._btui_path = path
    return path ~= nil
end

--- Best-effort AVRCP target state via Amazon's btui test UI (menu 33).
--- 1=stopped 2=paused 3=playing
function BtMediaControl._kindleAdvertisePlaybackState(status)
    if not BtMediaControl._btuiAvailable() then return end
    local state = ({ playing = 3, paused = 2, stopped = 1 })[status] or 1
    -- btui is an interactive menu; feed "33" (UpdatePlayBackState) + value + quit.
    local cmd = string.format(
        "( printf '33\\n%d\\n0\\n' | timeout 2 %s ) >/dev/null 2>&1 &",
        state, BtMediaControl._btui_path or "btui")
    os.execute(cmd)
    logger.warn("BtMediaControl: Kindle btui UpdatePlayBackState", state, "(", status, ")")
end

function BtMediaControl._pollKindleAvrcp()
    if not BtMediaControl._kindle_avrcp_active then return end

    -- Late-appearing media input nodes after AirPods reconnect.
    local scans = (BtMediaControl._kindle_evdev_scans or 0) + 1
    BtMediaControl._kindle_evdev_scans = scans
    if not BtMediaControl._evdev_active and scans % 4 == 0 then
        if BtMediaControl._tryEvdevApproach() then
            logger.warn("BtMediaControl: Kindle media input appeared on rescan")
        end
    end

    BtMediaControl._consumeKindleLipcEvents()

    -- Some firmwares toggle playermgr InPlayback when the headset sends AVRCP.
    local h = io.popen("lipc-get-prop com.lab126.playermgr InPlayback 2>/dev/null")
    if h then
        local v = (h:read("*a") or ""):match("(%d+)")
        h:close()
        if v then
            local n = tonumber(v)
            if BtMediaControl._last_kindle_inplayback ~= nil
                    and n ~= BtMediaControl._last_kindle_inplayback then
                logger.warn("BtMediaControl: playermgr InPlayback",
                    BtMediaControl._last_kindle_inplayback, "→", n)
                if n == 0 then
                    BtMediaControl._dispatchMediaEvent("MediaPause")
                elseif n == 1 then
                    BtMediaControl._dispatchMediaEvent("MediaPlay")
                end
            end
            BtMediaControl._last_kindle_inplayback = n
        end
    end

    if BtMediaControl._kindle_avrcp_active then
        -- LIPC log is written by background waiters; 0.4s keeps stem clicks snappy.
        UIManager:scheduleIn(0.4, BtMediaControl._pollKindleAvrcp)
    end
end

-- ══════════════════════════════════════════════════════════════════════
-- SENDING FEEDBACK TO BT DEVICE
-- ══════════════════════════════════════════════════════════════════════

--[[--
Send playback status update to the connected BT device.

Kobo's mtkbtd exposes MediaTransport1 (not MediaPlayer1), so we update
the transport State property.  Some headsets reflect this as a status
indicator or voice prompt.

On Kindle, advertise via btui UpdatePlayBackState so AirPods treat us as
an AVRCP target (required for stem play/pause to generate events).

@param status string  "playing", "paused", or "stopped"
--]]
function BtMediaControl.sendPlaybackStatus(status)
    if BtMediaControl._last_sent_status == status then return end
    BtMediaControl._last_sent_status = status

    if Device.isAndroid and Device:isAndroid() then
        local session = BtMediaControl._android_session
        if session then
            local playing = (status == "playing")
            local pos_ms = 0
            local plugin = BtMediaControl._plugin
            if plugin and plugin.media_sync and plugin.media_sync.media_engine then
                pcall(function()
                    pos_ms = math.floor((plugin.media_sync.media_engine:getPosition() or 0) * 1000)
                end)
            end
            if status == "stopped" then
                pcall(function() session:stopSession() end)
                BtMediaControl._android_session_started = false
            else
                -- startSession once; repeated start() re-requested audio focus
                -- and contributed to AirPods resume dying after ~0.5s.
                if not BtMediaControl._android_session_started then
                    pcall(function() session:startSession("Audiobook", "") end)
                    BtMediaControl._android_session_started = true
                end
                pcall(function() session:setPlaying(playing, pos_ms) end)
            end
        end
        return
    end

    if Device.isKindle and Device:isKindle() then
        BtMediaControl._kindleAdvertisePlaybackState(status)
        return
    end

    local transport_path = BtMediaControl._findMediaTransportPath()
    if not transport_path then
        logger.dbg("BtMediaControl: No MediaTransport1 path found, cannot send status")
        return
    end

    -- Map our status names to MediaTransport1 State values
    -- MediaTransport1 uses: "idle", "pending", "active"
    local state_map = {
        playing = "active",
        paused  = "pending",
        stopped = "idle",
    }
    local state = state_map[status] or "idle"

    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s %s '
        .. 'org.freedesktop.DBus.Properties.Set '
        .. 'string:"org.bluez.MediaTransport1" '
        .. 'string:"State" variant:string:"%s" 2>/dev/null',
        DBUS_DEST, transport_path, state
    )
    os.execute(cmd .. " &")
    logger.dbg("BtMediaControl: Sent transport state:", state, "(", status, ") to", transport_path)
end

--[[--
Send track metadata to the connected BT device.
Note: Requires a registered MediaPlayer via org.bluez.Media1.RegisterPlayer,
which is not yet implemented. This is a stub for future use.

@param title string     Track title (e.g. sentence or book title)
@param artist string    Artist (e.g. "TTS" or book author)
@param duration number  Duration in milliseconds (optional)
--]]
function BtMediaControl.sendTrackMetadata(title, artist, duration)
    -- MediaPlayer1 registration would be needed to push track metadata.
    -- For now just log it; a future version can use Media1.RegisterPlayer.
    logger.dbg("BtMediaControl: Track metadata (not yet sent):",
        title and title:sub(1, 60) or "(nil)")
end

--[[--
Find the D-Bus object path for MediaTransport1 on the connected device.
Caches the result for repeated calls.

On Kobo mtkbtd this is typically:
  /org/bluez/hci0/dev_XX_XX_XX_XX_XX_XX/fd0

@return string|nil  Object path
--]]
function BtMediaControl._findMediaTransportPath()
    -- Use cached value if recent
    if BtMediaControl._transport_path
            and BtMediaControl._transport_path_time
            and (os.time() - BtMediaControl._transport_path_time) < 30 then
        return BtMediaControl._transport_path
    end

    local cmd = string.format(
        'dbus-send --system --print-reply --dest=%s / '
        .. 'org.freedesktop.DBus.ObjectManager.GetManagedObjects 2>/dev/null',
        DBUS_DEST
    )
    local handle = io.popen(cmd)
    if not handle then return nil end
    local output = handle:read("*a") or ""
    handle:close()

    -- Find the object path that has MediaTransport1 interface
    -- Look for a path containing "fd" (transport endpoints) under a device
    local transport_path = nil
    local current_path = nil
    for line in output:gmatch("[^\n]+") do
        local path = line:match('object path "(.-)"')
        if path then
            current_path = path
        end
        if current_path and line:find("MediaTransport1") then
            transport_path = current_path
            break
        end
    end

    if transport_path then
        BtMediaControl._transport_path = transport_path
        BtMediaControl._transport_path_time = os.time()
        logger.dbg("BtMediaControl: Found MediaTransport1 path:", transport_path)
        return transport_path
    end

    return nil
end

--[[--
Re-scan for the AVRCP evdev device.
Call this after a BT device connects — the AVRCP input device may
appear asynchronously after the A2DP connection is established.
--]]
function BtMediaControl.rescan()
    if BtMediaControl._evdev_active then return end  -- already have a device

    local found = BtMediaControl._tryEvdevApproach()
    if found then
        logger.warn("BtMediaControl: AVRCP evdev device found on rescan")
    end

    -- Refresh the MediaTransport1 path cache
    BtMediaControl._transport_path = nil
    BtMediaControl._transport_path_time = nil
end

return BtMediaControl
