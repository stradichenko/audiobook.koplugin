--[[--
Bluetooth Manager for Kobo devices.

Controls Bluetooth via D-Bus using the Kobo-specific mtkbtd service
(com.kobo.mtk.bluedroid) which exposes standard BlueZ-compatible interfaces.

Supported operations:
  - Power on/off the Bluetooth adapter
  - Start/stop device discovery (scanning)
  - List discovered and paired devices
  - Pair, connect, and disconnect devices

@module btmanager
--]]

local logger = require("logger")

local BTManager = {}

-- D-Bus constants
local DBUS_DEST = "com.kobo.mtk.bluedroid"
local ADAPTER_PATH = "/org/bluez/hci0"
local ROOT_PATH = "/"
local ADAPTER_IFACE = "org.bluez.Adapter1"
local DEVICE_IFACE = "org.bluez.Device1"
local PROPS_IFACE = "org.freedesktop.DBus.Properties"
local OBJMGR_IFACE = "org.freedesktop.DBus.ObjectManager"
local BLUEDROID_IFACE = "com.kobo.bluetooth.BluedroidManager1"

--- Run a dbus-send command and return the raw output.
-- @string cmd  full dbus-send command
-- @treturn string output (may be empty)
-- @treturn bool   true if command succeeded (exit code 0)
local function dbus(cmd)
    local handle = io.popen(cmd .. " 2>/dev/null; echo \"__EXIT:$?\"")
    if not handle then return "", false end
    local output = handle:read("*a")
    handle:close()
    local exit_code = output:match("__EXIT:(%d+)%s*$")
    output = output:gsub("__EXIT:%d+%s*$", "")
    return output, exit_code == "0"
end

--- Build a dbus-send command.
-- @string path    object path
-- @string method  full interface.method name
-- @string ...     additional arguments
-- @treturn string command
local function dbus_cmd(path, method, ...)
    local args = table.concat({...}, " ")
    return string.format(
        "dbus-send --system --print-reply --dest=%s %s %s %s",
        DBUS_DEST, path, method, args
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
    local out = get_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered")
    return out:match("boolean true") ~= nil
end

--- Power on the Bluetooth adapter.
-- @treturn bool success
function BTManager:powerOn()
    logger.dbg("BTManager: powering on")
    local _, ok = set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:true")
    -- Give the stack a moment to initialize
    if ok then os.execute("sleep 2") end
    return self:isPowered()
end

--- Power off the Bluetooth adapter.
-- @treturn bool success
function BTManager:powerOff()
    logger.dbg("BTManager: powering off")
    set_property(ADAPTER_PATH, ADAPTER_IFACE, "Powered", "variant:boolean:false")
    os.execute("sleep 1")
    return not self:isPowered()
end

-----------------------------------------------------------------------
-- Discovery (scanning)
-----------------------------------------------------------------------

--- Start BT device discovery.
-- @treturn bool success
function BTManager:startDiscovery()
    logger.dbg("BTManager: starting discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StartDiscovery"))
    return ok
end

--- Stop BT device discovery.
-- @treturn bool success
function BTManager:stopDiscovery()
    logger.dbg("BTManager: stopping discovery")
    local _, ok = dbus(dbus_cmd(ADAPTER_PATH, ADAPTER_IFACE .. ".StopDiscovery"))
    return ok
end

--- Check whether discovery is active.
-- @treturn bool
function BTManager:isDiscovering()
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

--- Filter devices: only those that are audio-related OR paired.
-- Unnamed BLE beacons are dropped.
-- @treturn table filtered device list
function BTManager:listAudioDevices()
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
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:pair(address)
    logger.dbg("BTManager: pairing with", address)
    local path = mac_to_path(address)
    -- Trust first so auto-connect works later
    set_property(path, DEVICE_IFACE, "Trusted", "variant:boolean:true")
    local out, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Pair"))
    if not ok then
        local err = out:match("Error[^\n]*") or "Pairing failed"
        return false, err
    end
    return true
end

--- Connect to a (paired) device.
-- @string address  MAC address
-- @treturn bool success
-- @treturn string error message (if any)
function BTManager:connect(address)
    logger.dbg("BTManager: connecting to", address)
    local path = mac_to_path(address)
    local out, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Connect"))
    if not ok then
        local err = out:match("Error[^\n]*") or "Connection failed"
        return false, err
    end
    -- Wait a moment for A2DP to set up
    os.execute("sleep 2")
    return true
end

--- Disconnect a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:disconnect(address)
    logger.dbg("BTManager: disconnecting", address)
    local path = mac_to_path(address)
    local _, ok = dbus(dbus_cmd(path, DEVICE_IFACE .. ".Disconnect"))
    return ok
end

--- Remove (un-pair) a device.
-- @string address  MAC address
-- @treturn bool success
function BTManager:remove(address)
    logger.dbg("BTManager: removing", address)
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

return BTManager
