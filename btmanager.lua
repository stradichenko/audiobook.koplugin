--[[--
Bluetooth Manager for Kobo and Kindle devices.

Supports three Bluetooth environments:
  - MTK (Clara 2E, Sage, Libra Colour, etc.): uses the Kobo-specific
    mtkbtd service (com.kobo.mtk.bluedroid) and GStreamer
    mtkbtmwrpcaudiosink for audio.
  - BlueZ (Libra 2/Io, etc.): uses the standard org.bluez D-Bus
    interface and ALSA audio output.
  - Kindle: BT is managed by Amazon firmware via lipc (Lab126 IPC).
    The plugin can toggle BT on/off via lipc but cannot scan, pair,
    or enumerate devices -- users must pair through Kindle Settings.

The stack is auto-detected on first use.  All D-Bus operations are
routed through the detected destination transparently.

Reference: OGKevin/kobo.koplugin BT investigation
  https://ogkevin.github.io/kobo.koplugin/dev/investigations/bluetooth/

@module btmanager
--]]

local Device = require("device")
local logger = require("logger")
local _ = require("audiobook_gettext")

local BTManager = {}

-- D-Bus constants (DBUS_DEST is set by detectStack)
local DBUS_DEST = "org.bluez"  -- safe default; overridden for MTK
local ADAPTER_PATH = "/org/bluez/hci0"
local ROOT_PATH = "/"
local ADAPTER_IFACE = "org.bluez.Adapter1"
local DEVICE_IFACE = "org.bluez.Device1"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local OBJMGR_IFACE = "org.freedesktop.DBus.ObjectManager"

-- Detected stack state (set once by detectStack, then cached)
local bt_stack = nil        -- "mtk", "bluez", or "kindle"
local gst_bt_sink = nil     -- "mtkbtmwrpcaudiosink" or nil
local bluetoothd_path = nil -- resolved path to bluetoothd binary
local has_bluetoothctl = nil -- cached availability of bluetoothctl
local has_lipc = nil         -- cached availability of lipc (Kindle)
local lipc_bt_service = nil  -- "com.lab126.btfd" or similar
local lipc_bt_prop = nil     -- readable property ("btEnabled", "BTstate", etc.)
local lipc_bt_write_prop = nil  -- writable property (may differ from read prop)
local lipc_bt_write_is_str = false -- true if write prop takes string "true"/"false"
-- com.lab126.btfd isAudibleAvailable probe result: 1 = Audible available,
-- 0 = definitively unavailable, nil = unknown (probe failed or N/A).
-- Kindles without Audible reject "true"/"false" and "1"/"0" for BTenable
-- and require the "1:1"/"0:1" pair format instead (issue #2).
local lipc_bt_audible_available = nil

--- Detect which Bluetooth stack this device uses.
-- Called lazily from dbus_cmd() on first BT operation; a no-op
-- after the first successful detection.
local function detectStack()
    if bt_stack then return end

    -- Kindle: BT is managed by Amazon firmware, not BlueZ.
    -- Detect early to avoid useless BlueZ probes.
    if Device.isKindle and Device:isKindle() then
        bt_stack = "kindle"
        -- Check for lipc (Lab126 IPC) to toggle BT power.
        -- The service and property names vary across Kindle generations:
        --   com.lab126.btfd       btEnabled   (some PW5+)
        --   com.lab126.btService  btEnabled   (PW11 and others)
        --   com.lab126.cmd        btEnabled   (older Kindles, some PW4)
        --   com.lab126.acsbt      btEnabled   (some models)
        --   com.lab126.kaf        wifiBTProp   (PW4, some PW5 firmware)
        -- Some models use btPowerState instead of btEnabled.
        -- Kindle Basic 2022 (11th Gen) uses BTstate (read) + BTenable (write).
        -- On PW4 and some PW5 firmware, none of the above may respond.
        -- KAF (Kindle Application Framework) with wifiBTProp or btPowerState
        -- is the correct API for newer firmware.
        -- Also try KAF file-based: /var/local/kaf/bt/power
        local lh = io.popen("which lipc-get-prop 2>/dev/null")
        local lr = lh and lh:read("*a") or ""
        if lh then lh:close() end
        if lr:match("%S") then
            -- Probe service+property combinations until one responds
            local services = {
                "com.lab126.btfd",
                "com.lab126.btService",
                "com.lab126.cmd",
                "com.lab126.acsbt",
                "com.lab126.kaf",
            }
            local properties = { "btEnabled", "btPowerState", "BTstate", "wifiBTProp" }
            for _, svc in ipairs(services) do
                for _, prop in ipairs(properties) do
                    local ph = io.popen("lipc-get-prop " .. svc .. " " .. prop .. " 2>/dev/null")
                    local pr = ph and ph:read("*a") or ""
                    if ph then ph:close() end
                    pr = pr:gsub("%s+$", "")
                    if pr ~= "" and not pr:match("^lipc") then
                        has_lipc = true
                        lipc_bt_service = svc
                        lipc_bt_prop = prop
                        -- Map read property to its write counterpart
                        if prop == "BTstate" then
                            -- BTstate is read-only; BTenable on same service is write-only (String)
                            lipc_bt_write_prop = "BTenable"
                            lipc_bt_write_is_str = true
                        elseif prop == "wifiBTProp" and svc == "com.lab126.kaf" then
                            -- KAF wifiBTProp uses string "1"/"0" or "true"/"false"
                            lipc_bt_write_prop = "wifiBTProp"
                            lipc_bt_write_is_str = true
                        elseif prop == "btPowerState" and svc == "com.lab126.kaf" then
                            -- KAF btPowerState uses string "true"/"false" on some firmware
                            lipc_bt_write_prop = "btPowerState"
                            lipc_bt_write_is_str = true
                        else
                            lipc_bt_write_prop = prop
                            lipc_bt_write_is_str = false
                        end
                        logger.warn("BTManager: Kindle lipc BT service:", svc, prop .. ":", pr,
                                    "write_prop:", lipc_bt_write_prop)
                        break
                    end
                end
                if has_lipc then break end
            end
            if has_lipc then
                -- Ask btfd whether Audible is available: its BTenable property
                -- expects a different value format on Kindles without Audible.
                -- nil means the probe failed, which is treated as unknown and
                -- handled by the write-retry in powerOn()/powerOff().
                local ah = io.popen("lipc-get-prop com.lab126.btfd isAudibleAvailable 2>/dev/null")
                local ar = ah and ah:read("*a") or ""
                if ah then ah:close() end
                lipc_bt_audible_available = tonumber(ar:gsub("%s+$", ""))
                logger.warn("BTManager: btfd isAudibleAvailable =", tostring(lipc_bt_audible_available))
            end
            if not has_lipc then
                -- Try KAF file-based API as last resort on PW4/PW5.
                -- Some Kindle firmware exposes BT power state through files in
                -- /var/local/kaf/ instead of (or in addition to) LIPC properties.
                local kaf_candidates = {
                    "/var/local/kaf/bt/power",
                    "/var/local/kaf/bt/enabled",
                    "/var/local/kaf/wifiBt/power",
                }
                for _, kf_path in ipairs(kaf_candidates) do
                    local kf = io.open(kf_path, "r")
                    if kf then
                        local val = kf:read("*a") or ""
                        kf:close()
                        val = val:gsub("%s+$", "")
                        if val ~= "" then
                            has_lipc = true  -- reuse same flag for KAF file API
                            lipc_bt_service = "kaf_file"
                            lipc_bt_prop = kf_path:match("([^/]+)$")
                            lipc_bt_write_prop = kf_path  -- store full path for write
                            lipc_bt_write_is_str = true     -- write "true"/"false" strings
                            logger.warn("BTManager: Kindle KAF file BT control:", kf_path, "=", val)
                            break
                        end
                    end
                end
                if not has_lipc then
                    has_lipc = false
                    logger.warn("BTManager: Kindle lipc available but no BT service responded")
                    logger.warn("BTManager: Diagnostic tip: try 'lipc-get-prop com.lab126.kaf wifiBTProp'")
                    logger.warn("BTManager: Diagnostic tip: try 'lipc-set-prop com.lab126.kaf wifiBTProp 1'")
                end
            end
        else
            has_lipc = false
            logger.warn("BTManager: Kindle has no lipc binary")
        end
        logger.warn("BTManager: detected Kindle platform (lipc:", has_lipc, "service:", lipc_bt_service or "none", "prop:", lipc_bt_prop or "none", ")")
        return
    end

    -- Method 1: The mtkbtmwrpcaudiosink GStreamer element is ONLY
    -- present on MTK-based Kobo devices (Clara 2E, Sage, Libra Colour).
    local h = io.popen("gst-inspect-1.0 mtkbtmwrpcaudiosink 2>/dev/null | head -1")
    local result = h and h:read("*a") or ""
    if h then h:close() end
    if result:match("Factory Details") then
        bt_stack = "mtk"
        DBUS_DEST = "com.kobo.mtk.bluedroid"
        gst_bt_sink = "mtkbtmwrpcaudiosink"
        logger.warn("BTManager: detected MTK Bluetooth stack")
        return
    end

    -- Method 2: Check if the MTK D-Bus service is registered (covers
    -- the case where GStreamer is not installed).
    h = io.popen(
        "dbus-send --system --print-reply "
        .. "--dest=org.freedesktop.DBus /org/freedesktop/DBus "
        .. "org.freedesktop.DBus.NameHasOwner "
        .. "string:'com.kobo.mtk.bluedroid' 2>/dev/null")
    result = h and h:read("*a") or ""
    if h then h:close() end
    if result:match("boolean true") then
        bt_stack = "mtk"
        DBUS_DEST = "com.kobo.mtk.bluedroid"
        gst_bt_sink = "mtkbtmwrpcaudiosink"
        logger.warn("BTManager: detected MTK Bluetooth stack (D-Bus)")
        return
    end

    -- Default: standard BlueZ (Kobo Libra 2 / Io, etc.)
    bt_stack = "bluez"
    DBUS_DEST = "org.bluez"
    gst_bt_sink = nil
    logger.warn("BTManager: detected standard BlueZ Bluetooth stack")

    -- Resolve the bluetoothd binary path.
    -- On Kobo Libra 2 / Io it lives at /libexec/bluetooth/bluetoothd
    -- rather than on PATH.
    local daemon_candidates = {
        "/libexec/bluetooth/bluetoothd",
        "/usr/libexec/bluetooth/bluetoothd",
        "/usr/lib/bluetooth/bluetoothd",
    }
    for _, p in ipairs(daemon_candidates) do
        local f = io.open(p, "r")
        if f then
            f:close()
            bluetoothd_path = p
            logger.warn("BTManager: found bluetoothd at", p)
            break
        end
    end
    if not bluetoothd_path then
        -- Fall back to PATH lookup
        local h = io.popen("which bluetoothd 2>/dev/null")
        local r = h and h:read("*a") or ""
        if h then h:close() end
        r = r:gsub("%s+$", "")
        if r ~= "" then
            bluetoothd_path = r
            logger.warn("BTManager: found bluetoothd via PATH:", r)
        else
            bluetoothd_path = "bluetoothd"  -- last resort
            logger.warn("BTManager: bluetoothd not found at known paths, using bare name")
        end
    end

    -- Check bluetoothctl availability (used for agent-based pairing)
    local bctl = io.popen("which bluetoothctl 2>/dev/null")
    local bctl_r = bctl and bctl:read("*a") or ""
    if bctl then bctl:close() end
    has_bluetoothctl = bctl_r:match("%S") ~= nil
    logger.warn("BTManager: bluetoothctl available:", has_bluetoothctl)
end

--- Check whether this device is a Kobo with the MediaTek Bluetooth stack.
-- The MTK stack is the only environment where MBROLA voices other than
-- mb-en1 trigger a firmware audio-repeat bug.
-- @treturn bool
function BTManager:isMtkKobo()
    if not bt_stack then
        detectStack()
    end
    return bt_stack == "mtk" and Device:isKobo()
end

--- Run a dbus-send command and return the raw output.
-- @string cmd  full dbus-send command
-- @treturn string output (may be empty)
-- @treturn bool   true if command succeeded (exit code 0)
local function dbus(cmd)
    local handle = io.popen(cmd .. " 2>&1; echo \"__EXIT:$?\"")
    if not handle then return "", false end
    local output = handle:read("*a")
    handle:close()
    local exit_code = output:match("__EXIT:(%d+)%s*$")
    output = output:gsub("__EXIT:%d+%s*$", "")
    return output, exit_code == "0"
end

--- Build a dbus-send command.
-- Includes a reply timeout to prevent blocking the Lua VM
-- when bluetoothd is unresponsive or not running.
-- @string path     object path
-- @string method   full interface.method name
-- @string ...      additional arguments
-- @int timeout_ms  reply timeout in ms (default 5000)
-- @treturn string command
local function dbus_cmd(path, method, ...)
    detectStack()  -- lazy init on first D-Bus operation
    local vargs = {...}
    local timeout_ms = 5000
    -- Last numeric argument is the timeout override
    if #vargs > 0 and type(vargs[#vargs]) == "number" then
        timeout_ms = table.remove(vargs)
    end
    local args = table.concat(vargs, " ")
    return string.format(
        "dbus-send --system --print-reply --reply-timeout=%d --dest=%s %s %s %s",
        timeout_ms, DBUS_DEST, path, method, args
    )
end

--- Get a D-Bus property.
-- @string path      object path
-- @string iface     interface owning the property
-- @string prop_name property name
-- @treturn string raw output
local function get_property(path, iface, prop_name)
    local cmd = dbus_cmd(path, PROPS_IFACE .. ".Get",
        string.format('string:"%s"', iface),
        string.format('string:"%s"', prop_name))
    return dbus(cmd)
end

--- Set a D-Bus property.
-- @string path      object path
-- @string iface     interface
-- @string prop_name property name
-- @string variant   variant value (e.g. "variant:boolean:true")
local function set_property(path, iface, prop_name, variant)
    local cmd = dbus_cmd(path, PROPS_IFACE .. ".Set",
        string.format('string:"%s"', iface),
        string.format('string:"%s"', prop_name),
        variant)
    return dbus(cmd)
end

-----------------------------------------------------------------------
-- Adapter power
-----------------------------------------------------------------------

--- Check whether the BT adapter is powered on.
-- @treturn bool powered state
function BTManager:isPowered()
    detectStack()
    if bt_stack == "kindle" then
        if has_lipc and lipc_bt_service and lipc_bt_prop then
            local r
            if lipc_bt_service == "kaf_file" then
                -- KAF file-based API: read from the power file
                local kf = io.open(lipc_bt_write_prop or "/var/local/kaf/bt/power", "r")
                if kf then
                    r = kf:read("*a") or ""
                    kf:close()
                else
                    r = ""
                end
            else
                local h = io.popen("lipc-get-prop " .. lipc_bt_service .. " " .. lipc_bt_prop .. " 2>/dev/null")
                r = h and h:read("*a") or ""
                if h then h:close() end
            end
            r = r:gsub("%s+$", "")
            -- BTstate returns an Int (0=off, non-zero=on); btEnabled returns 0/1;
            -- wifiBTProp returns "1"/"0" strings; some return "true"/"false"
            return r:match("[1-9]") ~= nil or r:lower() == "true"
        end
        -- No working lipc: assume BT may be on (externally managed)
        return true
    end
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered")
    return out:match("boolean true") ~= nil
end

--- Check if bluetoothd is already running.
-- @treturn bool
local function is_bluetoothd_running()
    local h = io.popen("pidof bluetoothd 2>/dev/null")
    local r = h and h:read("*a") or ""
    if h then h:close() end
    return r:match("%d+") ~= nil
end

-----------------------------------------------------------------------
-- BT hardware power module helpers (NXP/Freescale Kobo)
-----------------------------------------------------------------------

--- Check whether the sdio_bt_pwr kernel module is loaded.
-- @treturn bool true if the module is currently in /proc/modules
function BTManager:_isBtModuleLoaded()
    local h = io.open("/proc/modules", "r")
    if not h then return false end
    local data = h:read("*a")
    h:close()
    return data:match("^sdio_bt_pwr ") ~= nil or data:match("\nsdio_bt_pwr ") ~= nil
end

--- Load the sdio_bt_pwr kernel module to power on the BT chip.
-- On NXP/Freescale Kobo devices (Libra 2, etc.) the module lives at
-- /drivers/<PLATFORM>/wifi/sdio_bt_pwr.ko.  KOReader removes it on
-- startup, so hci0 never appears until we reload it.
function BTManager:_loadBtModule()
    -- Try the PLATFORM env var first (set by koreader.sh or Nickel).
    local platform = os.getenv("PLATFORM") or ""
    local candidates = {}
    if platform ~= "" then
        table.insert(candidates, "/drivers/" .. platform .. "/wifi/sdio_bt_pwr.ko")
    end
    -- Fallback: search common platform dirs.
    for _, p in ipairs({ "freescale", "mx6sll-ntx", "mx6ull-ntx", "mx50-ntx" }) do
        table.insert(candidates, "/drivers/" .. p .. "/wifi/sdio_bt_pwr.ko")
    end

    for _, path in ipairs(candidates) do
        local f = io.open(path, "r")
        if f then
            f:close()
            logger.warn("BTManager: loading sdio_bt_pwr from", path)
            os.execute("insmod " .. path .. " 2>/dev/null")
            os.execute("sleep 2")
            if self:_isBtModuleLoaded() then
                logger.warn("BTManager: sdio_bt_pwr loaded successfully")
                return true
            else
                logger.warn("BTManager: insmod returned but module not in /proc/modules")
            end
        end
    end

    logger.warn("BTManager: sdio_bt_pwr.ko not found (may not be needed on this device)")
    return false
end

--- Unblock bluetooth via rfkill.
-- On AllWinner SoC devices (PocketBook Era Color, InkPad Color 3, etc.)
-- the BT adapter is disabled via rfkill rather than a kernel module.
-- This must run before bluetoothd can claim hci0.
function BTManager:_rfkillUnblock()
    local h = io.popen("which rfkill 2>/dev/null")
    local path = h and h:read("*l") or ""
    if h then h:close() end
    -- PB632 and others have rfkill outside $PATH
    if path == "" then
        for _, candidate in ipairs({"/usr/sbin/rfkill", "/sbin/rfkill", "/usr/bin/rfkill"}) do
            local f = io.open(candidate, "r")
            if f then
                f:close()
                path = candidate
                break
            end
        end
    end
    if path == "" then
        -- No rfkill binary at all: try the sysfs interface directly.
        -- /sys/class/rfkill/rfkillN/type == "bluetooth" → write 0 to soft
        local found_sysfs = false
        local dir_h = io.popen("ls /sys/class/rfkill/ 2>/dev/null")
        if dir_h then
            for entry in dir_h:lines() do
                local type_path = "/sys/class/rfkill/" .. entry .. "/type"
                local tf = io.open(type_path, "r")
                if tf then
                    local rtype = tf:read("*l") or ""
                    tf:close()
                    if rtype == "bluetooth" then
                        local soft_path = "/sys/class/rfkill/" .. entry .. "/soft"
                        local sw = io.open(soft_path, "w")
                        if sw then
                            sw:write("0\n")
                            sw:close()
                            found_sysfs = true
                            logger.warn("BTManager: rfkill unblock via sysfs:", soft_path)
                            self._rfkill_unblocked = true
                            self._rfkill_sysfs = soft_path
                        end
                        break
                    end
                end
            end
            dir_h:close()
        end
        if not found_sysfs then
            logger.dbg("BTManager: rfkill not found on PATH, common locations, or sysfs")
        end
        return
    end
    logger.warn("BTManager: rfkill unblock bluetooth using", path)
    os.execute(path .. " unblock bluetooth 2>/dev/null")
    self._rfkill_unblocked = true
    self._rfkill_path = path
end

--- Re-block bluetooth via rfkill (reverses _rfkillUnblock).
function BTManager:_rfkillBlock()
    if not self._rfkill_unblocked then return end
    if self._rfkill_sysfs then
        local sw = io.open(self._rfkill_sysfs, "w")
        if sw then
            sw:write("1\n")
            sw:close()
            logger.warn("BTManager: rfkill block via sysfs:", self._rfkill_sysfs)
        end
    else
        local cmd = (self._rfkill_path or "rfkill") .. " block bluetooth 2>/dev/null"
        logger.warn("BTManager: rfkill block bluetooth")
        os.execute(cmd)
    end
    self._rfkill_unblocked = false
    self._rfkill_path = nil
    self._rfkill_sysfs = nil
end

--- Check for MTK firmware file before powering on.
-- The MTK Bluetooth stack needs /data/misc/bluedroid/bt_fw_fatures
-- (created by Nickel).  Without it, FifoManager init fails and the
-- repeated recovery attempts can corrupt the flash filesystem.
-- @treturn bool true if firmware file exists
function BTManager:_checkMtkFirmware()
    local fw_candidates = {
        "/data/misc/bluedroid/bt_fw_fatures",
        "/data/misc/bluedroid/bt_fw_features",
        "/data/misc/bluedroid/bt_firmware.conf",
    }
    for _, fw_path in ipairs(fw_candidates) do
        local f = io.open(fw_path, "r")
        if f then
            f:close()
            logger.warn("BTManager: MTK firmware file found at", fw_path)
            return true
        end
    end
    logger.warn("BTManager: No MTK firmware file found in /data/misc/bluedroid/")
    return false
end

--- Show a modal error informing the user that BT firmware
-- initialization requires booting into Nickel first.
function BTManager:_showFirmwareError()
    local InfoMessage = require("ui/widget/infomessage")
    local UIManager = require("ui/uimanager")
    UIManager:show(InfoMessage:new{
        text = _(
            "Bluetooth firmware files are missing.\n\n"
            .. "Your Kobo's Bluetooth chip needs to be initialized by "
            .. "the stock Kobo OS (Nickel) before it can be used in "
            .. "KOReader.\n\n"
            .. "To fix this:\n"
            .. "1. Fully power off your Kobo\n"
            .. "2. Turn it on and boot normally into Nickel\n"
            .. "3. Go to Settings → Bluetooth and turn it ON\n"
            .. "4. If you have Bluetooth headphones, pair them now\n"
            .. "5. Once Bluetooth is working in Nickel, reboot into "
            .. "KOReader\n\n"
            .. "This one-time setup is needed because the Bluetooth "
            .. "firmware configuration is written by Nickel's startup "
            .. "process and is not preserved across KOReader-only "
            .. "reboots."
        ),
        timeout = 15,
    })
end

--- Power on the Bluetooth adapter.
-- For BlueZ devices, starts the bluetoothd daemon and resets the HCI
-- adapter first (required on Kobo Libra 2 and similar).
-- For Kindle, uses lipc to enable BT through Amazon firmware.
-- @treturn bool success
function BTManager:powerOn()
    detectStack()
    logger.warn("BTManager: powering on (stack:", bt_stack, ")")

    if bt_stack == "kindle" then
        if has_lipc and lipc_bt_service and lipc_bt_write_prop then
            if lipc_bt_service == "kaf_file" then
                -- KAF file-based API: write "true"/"false" to the power file
                local wf = io.open(lipc_bt_write_prop, "w")
                if wf then
                    wf:write("true\n")
                    wf:close()
                    os.execute("sleep 2")
                end
            else
                -- Regular LIPC property-based control.  Kindles without
                -- Audible support reject the usual values for BTenable and
                -- require the "1:1" pair format instead (issue #2).  Use the
                -- pair format when the device is definitively without
                -- Audible, or as a retry when the standard write did not
                -- take effect (probe failed or unexpected rejection).
                local use_pair_format = (lipc_bt_audible_available == 0)
                    and lipc_bt_write_prop == "BTenable"
                if not use_pair_format then
                    local val = lipc_bt_write_is_str and "true" or "1"
                    os.execute("lipc-set-prop " .. lipc_bt_service .. " " .. lipc_bt_write_prop .. " " .. val .. " 2>/dev/null")
                    os.execute("sleep 2")
                    if not self:isPowered() then
                        logger.warn("BTManager: standard BTenable write did not power on, retrying with btfd 1:1 format")
                        use_pair_format = true
                    end
                end
                if use_pair_format then
                    os.execute("lipc-set-prop com.lab126.btfd BTenable 1:1 2>/dev/null")
                    os.execute("sleep 2")
                end
            end
            local powered = self:isPowered()
            logger.warn("BTManager: Kindle powerOn result:", powered,
                "service:", lipc_bt_service, "prop:", lipc_bt_write_prop)
            return powered
        end
        logger.warn("BTManager: Kindle has no working lipc BT service -- cannot manage BT")
        return false
    end

    -- ── MTK firmware file check ─────────────────────────────────────
    -- The MTK Bluetooth stack requires /data/misc/bluedroid/bt_fw_fatures
    -- to be present (created by Nickel).  Without it, FifoManager init
    -- fails and the repeated recovery attempts can corrupt flash storage.
    -- Check early so we can show a clear error before any damage occurs.
    if bt_stack == "mtk" then
        local fw_found = self:_checkMtkFirmware()
        if not fw_found then
            logger.err("BTManager: MTK firmware file not found — need to boot into Nickel first")
            self:_showFirmwareError()
            return false
        end
    end

    if bt_stack == "bluez" then
        -- BlueZ requires the bluetoothd daemon and an HCI adapter reset.
        -- On Kobo Libra 2 / Io, the daemon lives at /libexec/bluetooth/
        -- rather than on PATH (ref: OGKevin/kobo.koplugin BT investigation).

        -- On PocketBook devices, the system firmware may have already
        -- powered on BT and started bluetoothd (e.g. when the user
        -- enables BT from the device menu).  Detect this and skip
        -- the full startup sequence.
        local hci_already_up = false
        if is_bluetoothd_running() then
            local h = io.popen("hciconfig hci0 2>/dev/null")
            local r = h and h:read("*a") or ""
            if h then h:close() end
            if r:match("UP") then
                hci_already_up = true
                logger.warn("BTManager: hci0 already UP and bluetoothd running, skipping startup")
            end
        end

        if not hci_already_up then
            -- On PocketBook, try the native netagent command first.
            -- This handles rfkill, bluetoothd, and HCI initialization
            -- in one step, matching what the system Settings app does.
            if Device:isPocketBook() then
                local na = io.open("/ebrmain/cramfs/bin/netagent", "r")
                if na then
                    na:close()
                    logger.warn("BTManager: trying PocketBook netagent bt on")
                    os.execute("/ebrmain/cramfs/bin/netagent bt on 2>/dev/null")
                    os.execute("sleep 2")
                    local h = io.popen("hciconfig hci0 2>/dev/null")
                    local r = h and h:read("*a") or ""
                    if h then h:close() end
                    if r:match("UP") then
                        hci_already_up = true
                        logger.warn("BTManager: netagent brought hci0 UP")
                    else
                        logger.warn("BTManager: netagent did not bring hci0 UP, falling through")
                    end
                end
            end
        end

        if not hci_already_up then
            -- On NXP/Freescale Kobo models (Libra 2, etc.), BT hardware
            -- power is controlled by the sdio_bt_pwr kernel module.
            -- KOReader's koreader.sh removes this module on startup, so
            -- hci0 will never appear until we reload it.
            if not self:_isBtModuleLoaded() then
                self:_loadBtModule()
            end

            -- On AllWinner SoC models (PocketBook Era, InkPad Color, etc.),
            -- BT is gated by rfkill rather than a kernel module.  Unblock
            -- bluetooth before starting the daemon.
            self:_rfkillUnblock()

            local had_to_restart_btd = false
            if not is_bluetoothd_running() then
                local daemon = bluetoothd_path or "bluetoothd"
                logger.warn("BTManager: starting bluetoothd from:", daemon)
                os.execute(daemon .. " 2>/dev/null &")
                os.execute("sleep 1")
                if not is_bluetoothd_running() then
                    logger.warn("BTManager: bluetoothd failed to start from", daemon)
                end
            else
                -- bluetoothd caches the adapter list at startup.  If the
                -- adapter appears after bluetoothd started (e.g. because
                -- sdio_bt_pwr was just reloaded), it may never see hci0.
                -- Restarting bluetoothd forces a fresh adapter scan.
                -- Issue #14 (Kobo Libra 2 hci0 not found after 6s).
                logger.warn("BTManager: bluetoothd already running, restarting to pick up new adapter")
                os.execute("killall bluetoothd 2>/dev/null; sleep 1")
                local daemon = bluetoothd_path or "bluetoothd"
                os.execute(daemon .. " 2>/dev/null &")
                os.execute("sleep 1")
                had_to_restart_btd = true
            end
            -- Reset the HCI adapter.  Use ";" instead of "&&" so that
            -- "hci0 up" still runs even when "hci0 down" fails (which
            -- happens on Kobo Libra 2 when the adapter hasn't been
            -- initialised yet and hci0 doesn't exist).
            os.execute("hciconfig hci0 down 2>/dev/null; hciconfig hci0 up 2>/dev/null")
            -- Wait for the HCI device to appear.  Use integer sleep
            -- because PocketBook's BusyBox sleep rejects fractions.
            -- Increase timeout from 6s to 12s: some devices need the
            -- extra time after a bluetoothd restart (issue #14).
            local hci_ready = false
            for attempt = 1, 12 do
                os.execute("sleep 1")
                local h = io.popen("hciconfig hci0 2>/dev/null")
                local r = h and h:read("*a") or ""
                if h then h:close() end
                if r:match("hci0") then
                    hci_ready = true
                    logger.warn("BTManager: hci0 ready after", attempt, "s")
                    break
                end
            end
            if not hci_ready then
                logger.warn("BTManager: hci0 not found after 12s")
                -- Fallback: try bluetoothctl power-on, which uses D-Bus
                -- and sometimes succeeds where hciconfig fails.
                local bc = io.popen("bluetoothctl power on 2>&1")
                if bc then
                    local out = bc:read("*a") or ""
                    bc:close()
                    logger.warn("BTManager: bluetoothctl power on result:", out:gsub("\n", " "))
                    os.execute("sleep 2")
                    local h2 = io.popen("hciconfig hci0 2>/dev/null")
                    local r2 = h2 and h2:read("*a") or ""
                    if h2 then h2:close() end
                    if r2:match("hci0") then
                        hci_ready = true
                        logger.warn("BTManager: hci0 appeared after bluetoothctl power on")
                    end
                end
            end
            if not hci_ready then
                logger.err("BTManager: hci0 could not be brought up. Firmware may need initialization by the stock OS (Nickel).")
            end
        end
    end

    local _, ok = set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:true")
    -- Give the stack a moment to initialize
    if ok then os.execute("sleep 2") end

    -- Start BlueALSA proactively on BlueZ so the ALSA PCM is ready
    -- before any audio playback begins.  Previously BlueALSA was only
    -- started reactively inside findAudioPlayer() when a BT device
    -- happened to be connected at that exact moment; if the device
    -- was paired but idle, audio would fail with "no soundcards".
    if bt_stack == "bluez" and self:hasBluealsaBundled() then
        local ba_ok = self:startBluealsa()
        if not ba_ok then
            logger.err("BTManager: BlueALSA failed to start during power-on")
        end
    end

    local powered = self:isPowered()
    logger.warn("BTManager: powerOn result:", powered,
        "bluetoothd running:", is_bluetoothd_running())
    return powered
end

--- Power off the Bluetooth adapter.
-- For BlueZ devices, also stops the bluetoothd daemon.
-- @treturn bool success
function BTManager:powerOff()
    detectStack()
    logger.dbg("BTManager: powering off")

    if bt_stack == "kindle" then
        if has_lipc and lipc_bt_service and lipc_bt_write_prop then
            if lipc_bt_service == "kaf_file" then
                local wf = io.open(lipc_bt_write_prop, "w")
                if wf then
                    wf:write("false\n")
                    wf:close()
                    os.execute("sleep 1")
                end
            else
                -- Regular LIPC property-based control (see powerOn for the
                -- non-Audible btfd "1:1"/"0:1" pair format, issue #2).
                local use_pair_format = (lipc_bt_audible_available == 0)
                    and lipc_bt_write_prop == "BTenable"
                if not use_pair_format then
                    local val = lipc_bt_write_is_str and "false" or "0"
                    os.execute("lipc-set-prop " .. lipc_bt_service .. " " .. lipc_bt_write_prop .. " " .. val .. " 2>/dev/null")
                    os.execute("sleep 1")
                    if self:isPowered() then
                        logger.warn("BTManager: standard BTenable write did not power off, retrying with btfd 0:1 format")
                        use_pair_format = true
                    end
                end
                if use_pair_format then
                    os.execute("lipc-set-prop com.lab126.btfd BTenable 0:1 2>/dev/null")
                    os.execute("sleep 1")
                end
            end
        end
        return true
    end

    set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:false")
    os.execute("sleep 1")

    if bt_stack == "bluez" then
        -- Stop bluealsa daemon if we started it
        self:stopBluealsa()
        -- On PocketBook, use the native netagent to turn off BT.
        if Device:isPocketBook() then
            local na = io.open("/ebrmain/cramfs/bin/netagent", "r")
            if na then
                na:close()
                os.execute("/ebrmain/cramfs/bin/netagent bt off 2>/dev/null")
                logger.warn("BTManager: netagent bt off")
            end
        end
        -- Stop the daemon we started (safe even if it was already running)
        os.execute("killall bluetoothd 2>/dev/null")
        os.execute("hciconfig hci0 down 2>/dev/null")
        -- Unload the BT hardware power module (matches the insmod in powerOn)
        if self:_isBtModuleLoaded() then
            os.execute("rmmod sdio_bt_pwr 2>/dev/null")
            logger.warn("BTManager: unloaded sdio_bt_pwr")
        end
        -- Re-block rfkill (matches the unblock in powerOn)
        self:_rfkillBlock()
    end

    return not self:isPowered()
end

-----------------------------------------------------------------------
-- BlueALSA daemon lifecycle (BlueZ Kobo devices only)
-----------------------------------------------------------------------

-- Cached path to bundled bluealsa binary (set on first use)
local bluealsa_bin = nil

--- Resolve the bundled bluealsa binary path.
-- @treturn string|nil path to bluealsa binary, or nil if not bundled
local function findBluealsaBin()
    if bluealsa_bin then return bluealsa_bin end
    -- Same directory structure as espeak-ng: plugin_dir/bluealsa/bin/bluealsa
    local info = debug.getinfo(1, "S")
    local plugin_dir = info.source:match("^@(.*/)[^/]*$") or "./"
    local bin_path = plugin_dir .. "bluealsa/bin/bluealsa.bin"
    local orig_path = plugin_dir .. "bluealsa/bin/bluealsa"
    -- If both exist (after a plugin update), the freshly shipped .bin is
    -- always the newer build: replace the stale renamed binary.
    local bf = io.open(bin_path, "r")
    if bf then
        bf:close()
        os.remove(orig_path)
        os.rename(bin_path, orig_path)
        os.execute("chmod +x " .. orig_path .. " 2>/dev/null")
    end
    local f = io.open(orig_path, "r")
    if f then
        f:close()
        bluealsa_bin = orig_path
        logger.warn("BTManager: found bundled bluealsa at", orig_path)
        return bluealsa_bin
    end
    return nil
end

--- Resolve the bundled bluealsa directory (parent of bin/).
-- @treturn string|nil path to bluealsa/ directory
local function findBluealsaDir()
    local bin = findBluealsaBin()
    if not bin then return nil end
    return bin:match("^(.*/)[^/]*$"):gsub("bin/$", "")
end

--- Check if the bluealsa daemon is running.
-- @treturn bool
function BTManager:isBluealsaRunning()
    -- When bluealsa is launched through bundled ld-linux, the process
    -- name in /proc/pid/comm is "ld-linux-armhf." (truncated), not
    -- "bluealsa".  pidof only checks comm, so it misses the process.
    -- Use ps + grep on the full command line instead.
    local h = io.popen("ps w 2>/dev/null | grep 'bluealsa' | grep -v grep")
    local r = h and h:read("*a") or ""
    if h then h:close() end
    if r:match("bluealsa") then
        return true
    end
    -- Fallback: some BusyBox ps implementations truncate the command
    -- line.  Verify the ALSA PCM device is registered instead.
    local a = io.popen("aplay -L 2>/dev/null | grep 'bluealsa'")
    local ar = a and a:read("*a") or ""
    if a then a:close() end
    return ar:match("bluealsa") ~= nil
end

--- Start the BlueALSA daemon for BT audio bridging.
-- Only meaningful on BlueZ Kobo devices where there is no native
-- BT audio sink (no mtkbtmwrpcaudiosink, no PulseAudio).
-- The daemon registers A2DP profile with BlueZ and creates ALSA
-- PCM devices for connected BT audio devices.
-- @treturn bool success
function BTManager:startBluealsa()
    detectStack()
    if bt_stack ~= "bluez" then return false end
    if self:isBluealsaRunning() then
        logger.warn("BTManager: bluealsa already running")
        return true
    end

    local bin = findBluealsaBin()
    if not bin then
        logger.warn("BTManager: bluealsa binary not bundled")
        return false
    end

    local ba_dir = findBluealsaDir()
    -- Install D-Bus policy if not already present
    local policy_src = ba_dir .. "share/dbus-1/system.d/bluealsa.conf"
    local policy_dst = "/etc/dbus-1/system.d/bluealsa.conf"
    local pf = io.open(policy_dst, "r")
    if not pf then
        -- Copy policy file (allows root to own org.bluealsa on system bus)
        local ps = io.open(policy_src, "r")
        if ps then
            local content = ps:read("*a")
            ps:close()
            local pd = io.open(policy_dst, "w")
            if pd then
                pd:write(content)
                pd:close()
                -- Reload dbus config
                os.execute("killall -HUP dbus-daemon 2>/dev/null")
                os.execute("sleep 1")
                logger.warn("BTManager: installed bluealsa D-Bus policy")
            else
                logger.err("BTManager: cannot write D-Bus policy to", policy_dst,
                    "-- bluealsa may fail to register with D-Bus (read-only fs?)")
            end
        end
    else
        pf:close()
    end

    -- Install ALSA config for bluealsa PCM device
    -- On Kobo, /etc/asound.conf is read by libasound and defines the
    -- "bluealsa" PCM type that routes audio to BT headphones.
    local asound_dst = "/etc/asound.conf"
    local af = io.open(asound_dst, "r")
    local need_asound = true
    if af then
        local content = af:read("*a")
        af:close()
        need_asound = not content:match("pcm%.bluealsa")
    end
    if need_asound then
        local asound_src = ba_dir .. "etc/alsa/conf.d/20-bluealsa.conf"
        local as = io.open(asound_src, "r")
        if as then
            local content = as:read("*a")
            as:close()
            local ad = io.open(asound_dst, "a")  -- append, don't overwrite
            if ad then
                ad:write("\n# BlueALSA PCM (installed by audiobook.koplugin)\n")
                ad:write(content)
                ad:close()
                logger.warn("BTManager: installed bluealsa ALSA config to", asound_dst)
            else
                logger.err("BTManager: cannot write ALSA config to", asound_dst,
                    "-- aplay may not find the bluealsa PCM (read-only fs?)")
            end
        end
    end

    -- Build the library search path from bundled libs + system libs.
    -- Include wav-play/lib which reliably bundles libasound.so.2.
    -- Include /usr/lib:/lib as a last resort for other system libs.
    local espeak_lib = ba_dir:gsub("bluealsa/$", "") .. "espeak-ng/lib"
    local wav_play_lib = ba_dir:gsub("bluealsa/$", "") .. "wav-play/lib"
    local ld_path = ba_dir .. "lib:" .. espeak_lib .. ":" .. wav_play_lib .. ":/usr/lib:/lib"

    -- Detect whether the binary was built against system glibc (newer
    -- compat build) or against a newer Nix glibc (older build).
    -- The compat build has ELF interpreter /lib/ld-linux-armhf.so.3
    -- and can run directly with LD_LIBRARY_PATH.  The old build has
    -- a Nix store interpreter and needs the bundled linker.
    local function getElfInterpreter(path)
        local h = io.popen("readelf -l " .. path .. " 2>/dev/null | grep 'interpreter'")
        local r = h and h:read("*a") or ""
        if h then h:close() end
        return r:match("%[([^%]]+)%]") or ""
    end

    local interp = getElfInterpreter(bin)
    local needs_bundled_linker = interp:match("/nix/store/") ~= nil

    -- Log stderr to a temp file for diagnostics instead of discarding.
    local ba_log = "/tmp/.bluealsa_start.log"
    local cmd
    if needs_bundled_linker then
        -- Old binary: use bundled ld-linux + --library-path to isolate
        -- from the device's older glibc.
        local linker = espeak_lib .. "/ld-linux-armhf.so.3"
        local lf = io.open(linker, "r")
        local have_linker = lf ~= nil
        if lf then lf:close() end
        if have_linker then
            cmd = string.format(
                "%s --library-path %s %s --profile=a2dp-source 2>%s &",
                linker, ld_path, bin, ba_log)
        else
            cmd = string.format(
                "LD_LIBRARY_PATH=%s %s --profile=a2dp-source 2>%s &",
                ld_path, bin, ba_log)
        end
    else
        -- New compat binary: built against device glibc; just set
        -- LD_LIBRARY_PATH for non-glibc deps (libbluetooth, libdbus, etc.).
        cmd = string.format(
            "LD_LIBRARY_PATH=%s %s --profile=a2dp-source 2>%s &",
            ld_path, bin, ba_log)
    end

    logger.warn("BTManager: starting bluealsa:", cmd)
    os.execute(cmd)

    -- Give the daemon time to register with D-Bus and ALSA.
    -- Single-core Kobos need more than 1 second; poll for up to 6 s.
    local running = false
    for attempt = 1, 3 do
        os.execute("sleep 2")
        running = self:isBluealsaRunning()
        if running then
            logger.warn("BTManager: bluealsa ready after", attempt * 2, "s")
            break
        else
            logger.warn("BTManager: bluealsa not ready after attempt", attempt)
        end
    end

    if not running then
        local lf = io.open(ba_log, "r")
        if lf then
            local log_content = lf:read("*a") or ""
            lf:close()
            if log_content ~= "" then
                logger.err("BTManager: bluealsa startup log:", log_content:gsub("\n", " "))
            else
                logger.err("BTManager: bluealsa startup log is empty (daemon exited silently)")
            end
        else
            logger.err("BTManager: bluealsa startup log not found at", ba_log)
        end
    end

    logger.warn("BTManager: bluealsa started:", running)
    return running
end

--- Stop the BlueALSA daemon.
function BTManager:stopBluealsa()
    if self:isBluealsaRunning() then
        os.execute("killall bluealsa 2>/dev/null")
        os.execute("sleep 1")
        logger.warn("BTManager: bluealsa stopped")
    end
end

--- Check whether bluealsa is bundled with the plugin.
-- @treturn bool
function BTManager:hasBluealsaBundled()
    return findBluealsaBin() ~= nil
end

--- Get the ALSA device string for bluealsa playback.
-- @string address  optional MAC address (default: most recent device)
-- @treturn string ALSA device string like "bluealsa:DEV=XX:XX:XX:XX:XX:XX,PROFILE=a2dp"
function BTManager:getBluealsaDevice(address)
    if address then
        return string.format("bluealsa:DEV=%s,PROFILE=a2dp", address)
    end
    return "bluealsa"
end

--- Get the directory containing bluealsa ALSA plugins.
-- @treturn string|nil path to lib/alsa-lib/ directory
function BTManager:getBluealsaPluginDir()
    local ba_dir = findBluealsaDir()
    if not ba_dir then return nil end
    return ba_dir .. "lib/alsa-lib"
end

-----------------------------------------------------------------------
-- Discovery (scanning)
-----------------------------------------------------------------------

-- ── Kindle (btfd LIPC) device operations ────────────────────────────────
-- The Amazon firmware exposes full BT device management on the
-- com.lab126.btfd service:
--   ListPaired / ListConnected / ListDiscovered   (lipc-hash-prop)
--   Connect / Disconnect / Bond / Unbond          (lipc-set-prop, MAC arg)
--   triggerBTscan                                 (lipc-set-prop, int)
-- audioOutputConnected on com.lab126.audiomgrd reports whether the A2DP
-- audio route is actually up (BT-level "connected" is not enough for
-- sound to come out).  Verified on PW5 firmware (2025-04).

local function kindleHashProp(prop)
    local h = io.popen("lipc-hash-prop com.lab126.btfd " .. prop .. " 2>/dev/null")
    if not h then return {} end
    local out = h:read("*a") or ""
    h:close()
    local entries = {}
    local cur = nil
    for line in out:gmatch("[^\n]+") do
        if line:match("^Hash Index:") then
            if cur then table.insert(entries, cur) end
            cur = {}
        elseif cur then
            local k, v = line:match('^%s*([%w_]+)%s*=%s*"(.-)"')
            if not k then
                local ik, iv = line:match("^%s*([%w_]+)%s*=%s*%((%-?%d+)%)")
                if ik then k, v = ik, tonumber(iv) end
            end
            if k then cur[k] = v end
        end
    end
    if cur then table.insert(entries, cur) end
    return entries
end

local function kindleSetProp(prop, value)
    local rc = os.execute(string.format(
        "lipc-set-prop com.lab126.btfd %s '%s' 2>/dev/null", prop, value))
    return rc == 0 or rc == true
end

local function kindleAudioRouteUp()
    local h = io.popen("lipc-get-prop com.lab126.audiomgrd audioOutputConnected 2>/dev/null")
    if not h then return false end
    local v = h:read("*a") or ""
    h:close()
    return v:match("^%s*1") ~= nil
end

--- Start BT device discovery.
-- @treturn bool success
function BTManager:startDiscovery()
    if bt_stack == "kindle" then
        logger.warn("BTManager: kindle triggerBTscan")
        os.execute("lipc-set-prop com.lab126.btfd triggerBTscan 1 2>/dev/null")
        self._kindle_scan_until = os.time() + 12
        return true
    end
    logger.dbg("BTManager: starting discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StartDiscovery"))
    return ok
end

--- Stop BT device discovery.
-- @treturn bool success
function BTManager:stopDiscovery()
    if bt_stack == "kindle" then
        self._kindle_scan_until = nil
        return true
    end
    logger.dbg("BTManager: stopping discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StopDiscovery"))
    return ok
end

--- Check whether discovery is active.
-- @treturn bool
function BTManager:isDiscovering()
    if bt_stack == "kindle" then
        return self._kindle_scan_until ~= nil
            and os.time() < self._kindle_scan_until
    end
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Discovering")
    return out:match("boolean true") ~= nil
end

-----------------------------------------------------------------------
-- Device enumeration
-----------------------------------------------------------------------

--- List Bluetooth devices known to the adapter.
-- Parses the output of ObjectManager.GetManagedObjects.
-- @treturn table array of {path, address, name, paired, connected, icon}
function BTManager:listDevices()
    if bt_stack == "kindle" then
        local byaddr, devices = {}, {}
        local function absorb(list, force_connected)
            for _, e in ipairs(list) do
                local addr = e.bd_address
                if addr and addr ~= "" then
                    local d = byaddr[addr]
                    if not d then
                        d = {
                            address = addr,
                            name = "",
                            icon = "audio-headphones",
                            paired = false,
                            connected = false,
                        }
                        byaddr[addr] = d
                        table.insert(devices, d)
                    end
                    if e.bd_name and e.bd_name ~= "" then d.name = e.bd_name end
                    if e.is_paired == 1 then d.paired = true end
                    if e.is_connected == 1 or force_connected then d.connected = true end
                end
            end
        end
        absorb(kindleHashProp("ListPaired"))
        absorb(kindleHashProp("ListConnected"), true)
        absorb(kindleHashProp("ListDiscovered"))
        return devices
    end
    local cmd = dbus_cmd(ROOT_PATH, OBJMGR_IFACE .. ".GetManagedObjects")
    local output, ok = dbus(cmd)
    if not ok then return {} end

    local devices = {}
    local cur = nil      -- current device being parsed
    local next_prop = nil  -- which property the next variant line belongs to

    for line in output:gmatch("[^\n]+") do
        -- Detect a new object path for a device
        local path = line:match('object path "(.-)"')
        if path and path:match("/org/bluez/hci0/dev_") then
            -- Save previous device if it had a non-empty name
            if cur then
                table.insert(devices, cur)
            end
            local mac = path:match("dev_(.+)$")
            mac = mac and mac:gsub("_", ":") or ""
            cur = {
                path = path,
                address = mac,
                name = "",
                paired = false,
                connected = false,
                icon = "",
            }
            next_prop = nil
        end

        -- When we're inside a device entry, detect property keys
        if cur then
            if line:match('string "Name"%s*$') then
                next_prop = "name"
            elseif line:match('string "Paired"%s*$') then
                next_prop = "paired"
            elseif line:match('string "Connected"%s*$') then
                next_prop = "connected"
            elseif line:match('string "Icon"%s*$') then
                next_prop = "icon"
            elseif next_prop and line:match("variant") then
                if next_prop == "name" then
                    cur.name = line:match('string "(.-)"') or ""
                elseif next_prop == "paired" then
                    cur.paired = line:match("boolean true") ~= nil
                elseif next_prop == "connected" then
                    cur.connected = line:match("boolean true") ~= nil
                elseif next_prop == "icon" then
                    cur.icon = line:match('string "(.-)"') or ""
                end
                next_prop = nil
            end
        end
    end
    -- Last device
    if cur then
        table.insert(devices, cur)
    end

    return devices
end

--- Clear the cached result from listAudioDevices().
-- Call this after any operation that changes BT connection state.
function BTManager:clearAudioDeviceCache()
    self._audio_cache = nil
    self._audio_cache_time = nil
end

--- Filter devices: only those that are audio-related OR paired.
-- Unnamed BLE beacons are dropped.
-- Results are cached for 5 seconds to avoid repeated D-Bus round-trips
-- during the per-sentence play() hot path.
-- @treturn table filtered device list
function BTManager:listAudioDevices()
    local now = os.time()
    if self._audio_cache and self._audio_cache_time
        and now - self._audio_cache_time < 5 then
        return self._audio_cache
    end

    local all = self:listDevices()
    local result = {}
    local audio_icons = {
        ["audio-headphones"] = true,
        ["audio-headset"] = true,
        ["audio-card"] = true,
        ["audio-speakers"] = true,
    }
    for _, dev in ipairs(all) do
        -- Keep: has an audio icon, OR is paired, OR has a name
        if audio_icons[dev.icon] or dev.paired or (dev.name and dev.name ~= "") then
            table.insert(result, dev)
        end
    end
    -- Sort: connected first, then paired, then by name
    table.sort(result, function(a, b)
        if a.connected ~= b.connected then return a.connected end
        if a.paired ~= b.paired then return a.paired end
        return (a.name or "") < (b.name or "")
    end)

    self._audio_cache = result
    self._audio_cache_time = now
    return result
end

-----------------------------------------------------------------------
-- Device operations
-----------------------------------------------------------------------

--- Convert a MAC address to a D-Bus object path.
-- @string address e.g. "C0:86:B3:D9:35:A9"
-- @treturn string e.g. "/org/bluez/hci0/dev_C0_86_B3_D9_35_A9"
local function mac_to_path(address)
    return ADAPTER_PATH .. "/dev_" .. address:gsub(":", "_")
end

--- Pair with a device.
-- Tries three strategies in order:
--   1. bluetoothctl --agent (BlueZ >= 5.49, cleanest)
--   2. bluetoothctl with piped agent commands (older BlueZ)
--   3. Raw D-Bus Device1.Pair (last resort, needs external agent)
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:pair(address)
    self:clearAudioDeviceCache()
    logger.warn("BTManager: pairing with", address)

    if bt_stack == "kindle" then
        -- Bond via btfd; the firmware may show a confirmation dialog on
        -- the Kindle UI for devices that require it (headsets usually
        -- pair without one).
        kindleSetProp("Bond", address)
        for _ = 1, 10 do
            os.execute("sleep 1")
            for _, e in ipairs(kindleHashProp("ListPaired")) do
                if e.bd_address == address then
                    logger.warn("BTManager: kindle paired", address)
                    return true
                end
            end
        end
        return false, "Pairing timed out. If the Kindle shows a confirmation dialog, accept it and retry; otherwise pair via Kindle Settings."
    end

    local path = mac_to_path(address)

    -- Fast path: if the device is already paired (e.g. from a previous
    -- session), skip the slow bluetoothctl scripts entirely.
    local prop_out = get_property(path, DEVICE_IFACE, "Paired")
    if prop_out:match("boolean true") then
        logger.warn("BTManager: device already paired, skipping pairing")
        -- Still ensure trust is set for auto-reconnect
        set_property(path, DEVICE_IFACE, "Trusted", "variant:boolean:true")
        return true
    end

    -- Always trust the device so auto-connect works on future boots
    set_property(path, DEVICE_IFACE, "Trusted", "variant:boolean:true")

    --- Strip ANSI escape codes from bluetoothctl output.
    local function stripAnsi(s)
        return s:gsub("\27%[[%d;]*%a", ""):gsub("\27%[%?%d+[hl]", "")
    end

    if has_bluetoothctl then
        -- Strategy 1: bluetoothctl --agent NoInputNoOutput (BlueZ >= 5.49)
        -- The --agent flag registers the agent at startup, avoiding the need
        -- to pipe separate agent/default-agent commands.
        -- All sleeps use integer seconds for busybox portability.
        -- After pair, also send connect so A2DP gets established.
        logger.warn("BTManager: trying bluetoothctl --agent NoInputNoOutput")
        local script = string.format(
            "{ "
            .. "printf 'power on\\n'; sleep 1; "
            .. "printf 'trust %s\\n'; sleep 1; "
            .. "printf 'pair %s\\n'; sleep 8; "
            .. "printf 'connect %s\\n'; sleep 4; "
            .. "printf 'quit\\n'; "
            .. "} | bluetoothctl --agent NoInputNoOutput 2>&1",
            address, address, address)
        logger.warn("BTManager: running:", script:sub(1, 200))
        local h = io.popen(script)
        local out = h and h:read("*a") or ""
        if h then h:close() end
        out = stripAnsi(out)
        logger.warn("BTManager: bluetoothctl --agent output:", out:sub(1, 800))

        -- Check if --agent flag was rejected (older BlueZ)
        local agent_unsupported = out:match("unrecognized option")
            or out:match("invalid option")
            or out:match("unknown option")

        if not agent_unsupported then
            prop_out = get_property(path, DEVICE_IFACE, "Paired")
            local conn_out = get_property(path, DEVICE_IFACE, "Connected")
            if prop_out:match("boolean true") or conn_out:match("boolean true") then
                logger.warn("BTManager: pairing succeeded (--agent method)")
                return true
            end
        end

        -- Strategy 2: pipe agent commands manually (older BlueZ fallback)
        -- Only try if --agent was unsupported; if it was supported but pairing
        -- didn't complete, also try manual as some BlueZ versions need it.
        if agent_unsupported then
            logger.warn("BTManager: --agent flag not supported, trying manual agent")
        else
            logger.warn("BTManager: --agent method failed, retrying with manual agent")
        end
        script = string.format(
            "{ "
            .. "printf 'power on\\n'; sleep 1; "
            .. "printf 'agent NoInputNoOutput\\n'; sleep 1; "
            .. "printf 'default-agent\\n'; sleep 1; "
            .. "printf 'trust %s\\n'; sleep 1; "
            .. "printf 'pair %s\\n'; sleep 8; "
            .. "printf 'connect %s\\n'; sleep 4; "
            .. "printf 'quit\\n'; "
            .. "} | bluetoothctl 2>&1",
            address, address, address)
        logger.warn("BTManager: running:", script:sub(1, 250))
        h = io.popen(script)
        out = h and h:read("*a") or ""
        if h then h:close() end
        out = stripAnsi(out)
        logger.warn("BTManager: bluetoothctl manual output:", out:sub(1, 800))

        prop_out = get_property(path, DEVICE_IFACE, "Paired")
        local conn_out = get_property(path, DEVICE_IFACE, "Connected")
        if prop_out:match("boolean true") or conn_out:match("boolean true") then
            logger.warn("BTManager: pairing succeeded (manual agent method)")
            return true
        end

        -- Parse error from combined output
        local err = out:match("Failed to pair: (.-)\n") or
                    out:match("org%.bluez%.Error%.([%w]+)") or
                    "did not complete"
        -- Include a snippet of bluetoothctl output for debugging
        local snippet = out:gsub("%c+", " "):sub(1, 200)
        logger.warn("BTManager: pairing failed:", err, "output:", snippet)
        return false, err
    end

    -- Strategy 3: raw D-Bus (may fail without a registered agent)
    -- Use extended timeout (15s) since pairing can be slow
    logger.warn("BTManager: pairing via D-Bus (no bluetoothctl)")
    local pair_cmd = string.format(
        "dbus-send --system --print-reply --reply-timeout=15000 --dest=%s %s %s.Pair",
        DBUS_DEST, path, DEVICE_IFACE)
    local out, ok = dbus(pair_cmd)
    if not ok then
        local err = out:match("Error[^\n]*") or "Pairing failed (no agent)"
        logger.warn("BTManager: D-Bus pair failed:", err)
        return false, err
    end
    return true
end

--- Connect to a (paired) device.
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:connect(address)
    self:clearAudioDeviceCache()
    detectStack()
    if bt_stack == "kindle" then
        logger.warn("BTManager: kindle connect", address)
        kindleSetProp("Connect", address)
        for _ = 1, 6 do
            os.execute("sleep 1")
            if kindleAudioRouteUp() then return true end
        end
        -- The device can be BT-connected while the A2DP audio route is
        -- stale (acsbtfd then refuses to re-attach the sink: "Device
        -- already connected ... not attempting a2dp sink connection").
        -- A Disconnect/Connect cycle re-arms the route reliably.
        logger.warn("BTManager: kindle audio route down, cycling connection")
        kindleSetProp("Disconnect", address)
        os.execute("sleep 3")
        kindleSetProp("Connect", address)
        for _ = 1, 8 do
            os.execute("sleep 1")
            if kindleAudioRouteUp() then return true end
        end
        return false, "Could not establish the audio route. Is the headset powered on?"
    end
    logger.warn("BTManager: connecting to", address)
    local path = mac_to_path(address)

    -- Fast path: if already connected (e.g. from the pairing script's
    -- "connect" command), skip the D-Bus call entirely.
    local conn_out = get_property(path, DEVICE_IFACE, "Connected")
    if conn_out:match("boolean true") then
        logger.warn("BTManager: device already connected, skipping D-Bus Connect")
        -- Start BlueALSA even on the fast path; otherwise a device that
        -- was already connected when the plugin loaded would never trigger
        -- the post-connect BlueALSA startup (issue #8).
        if bt_stack == "bluez" and self:hasBluealsaBundled() then
            self:startBluealsa()
        end
        return true
    end

    -- Use a longer timeout (15s) for Connect -- BT negotiation can be slow,
    -- especially for A2DP headphones that need profile negotiation.
    local connect_cmd = dbus_cmd(path, DEVICE_IFACE .. ".Connect", 15000)

    -- Attempt 1
    local out, ok = dbus(connect_cmd)
    if not ok then
        if out:match("AlreadyConnected") then
            logger.warn("BTManager: D-Bus reports AlreadyConnected, treating as success")
            return true
        end
        local err = out:match("Error[^\n]*") or "Connection failed"
        logger.warn("BTManager: connect attempt 1 failed:", err)

        -- Retry once after a short delay.  BT headphones sometimes need
        -- a moment to become connectable after the adapter powers on.
        logger.warn("BTManager: retrying connect in 3s...")
        os.execute("sleep 3")

        -- Re-check: headphones may have connected asynchronously
        conn_out = get_property(path, DEVICE_IFACE, "Connected")
        if conn_out:match("boolean true") then
            logger.warn("BTManager: device connected during retry wait")
            -- fall through to post-connect setup
        else
            out, ok = dbus(connect_cmd)
            if not ok then
                if out:match("AlreadyConnected") then
                    logger.warn("BTManager: D-Bus reports AlreadyConnected on retry")
                    -- fall through to post-connect
                else
                    err = out:match("Error[^\n]*") or "Connection failed"
                    logger.warn("BTManager: connect attempt 2 failed:", err)
                    -- Translate known BlueZ errors to actionable messages
                    local user_err = err
                    if err:match("NotReady") then
                        user_err = "Adapter not ready -- try powering BT off and on"
                    elseif err:match("InProgress") then
                        user_err = "Another connection attempt is in progress"
                    elseif err:match("ConnectFailed") or err:match("Page Timeout")
                        or err:match("Connection refused") then
                        user_err = "Device not reachable -- ensure headphones are on and in range"
                    elseif err:match("NoSuchAdapter") then
                        user_err = "No Bluetooth adapter found"
                    end
                    return false, user_err
                end
            end
        end
    end

    if bt_stack == "mtk" then
        -- MTK: Wait for A2DP profile to come up.  Device1.Connect returns
        -- as soon as the ACL link is established, but mtkbtmwrpcaudiosink
        -- isn't usable until btservice sets up the A2DP channel.  Poll for
        -- up to 5 seconds.
        for attempt = 1, 10 do
            os.execute("sleep 0.5")
            local probe = io.popen(
                "timeout 2 gst-launch-1.0 audiotestsrc num-buffers=1 ! audio/x-raw,format=S16LE,rate=48000,channels=2 ! mtkbtmwrpcaudiosink 2>&1; echo __RC:$?"
            )
            local pout = probe and probe:read("*a") or ""
            if probe then probe:close() end
            if pout:match("PLAYING") or pout:match("PREROLLED") or pout:match("__RC:0") then
                logger.dbg("BTManager: A2DP audio sink ready after", attempt * 0.5, "s")
                return true
            end
            logger.dbg("BTManager: A2DP not ready yet, attempt", attempt)
        end
        logger.warn("BTManager: D-Bus connect OK but A2DP audio sink not ready after 5s")
        return true, "Connected but audio may not be ready yet"
    else
        -- BlueZ: the A2DP transport is set up asynchronously after
        -- Device1.Connect returns.  Give it a moment to settle.
        os.execute("sleep 2")
        -- Start bluealsa daemon if bundled (provides ALSA PCM for BT audio)
        if self:hasBluealsaBundled() then
            self:startBluealsa()
        end
        logger.warn("BTManager: BlueZ device connected, A2DP profile settling")
        return true
    end
end

--- Disconnect a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:disconnect(address)
    self:clearAudioDeviceCache()
    logger.dbg("BTManager: disconnecting", address)
    if bt_stack == "kindle" then
        return kindleSetProp("Disconnect", address)
    end
    local path = mac_to_path(address)
    local _, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Disconnect"))
    return ok
end

--- Remove (un-pair) a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:remove(address)
    self:clearAudioDeviceCache()
    logger.dbg("BTManager: removing", address)
    if bt_stack == "kindle" then
        return kindleSetProp("Unbond", address)
    end
    local path = mac_to_path(address)
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".RemoveDevice",
        string.format('objpath:"%s"', path)))
    return ok
end

--- Check if a specific device is connected.
-- @string address  MAC address
-- @treturn bool
function BTManager:isConnected(address)
    local path = mac_to_path(address)
    local out = get_property(path, DEVICE_IFACE, "Connected")
    return out:match("boolean true") ~= nil
end

--- Get the name of a device.
-- @string address  MAC address
-- @treturn string name (may be "")
function BTManager:getDeviceName(address)
    local path = mac_to_path(address)
    local out = get_property(path, DEVICE_IFACE, "Name")
    return out:match('string "(.-)"') or ""
end

--- Get the local adapter address (our MAC).
-- @treturn string MAC address, or "" if not powered
function BTManager:getAdapterAddress()
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Address")
    return out:match('string "(.-)"') or ""
end

-----------------------------------------------------------------------
-- Stack introspection (for ttsengine / bugreport)
-----------------------------------------------------------------------

--- Return the detected BT stack type.
-- @treturn string "mtk" or "bluez" (triggers detection if needed)
function BTManager:getStackType()
    detectStack()
    return bt_stack
end

--- Return the GStreamer BT audio sink element name, if any.
-- @treturn string|nil e.g. "mtkbtmwrpcaudiosink", or nil for BlueZ
function BTManager:getGstBtSink()
    detectStack()
    return gst_bt_sink
end

return BTManager
